#!/usr/bin/env bash
# Tear the lab down in dependency order.
#
#   scripts/teardown.sh              full run: Kubernetes cleanup, then for each stack in
#                                    reverse order: show destroy plan -> confirm -> apply
#   scripts/teardown.sh k8s          Kubernetes cleanup only (steps 1-4)
#   scripts/teardown.sh plan  STACK  write + show terraform/STACK/destroy.tfplan
#   scripts/teardown.sh apply STACK  apply that saved destroy plan
#
# Why this order matters:
#   1. Argo CD apps first, or Argo recreates what we delete.
#   2. Ingress / LoadBalancer Services, while the AWS Load Balancer Controller still runs,
#      so it deletes its ALBs/NLBs/target groups. Destroying the controller (or the VPC)
#      first leaves orphaned load balancers that also block subnet/VPC deletion.
#   3. App namespaces (incl. PVCs) while the EBS CSI driver still runs, so it deletes volumes.
#   4. Karpenter NodePools/EC2NodeClasses while Karpenter still runs, so it drains and
#      terminates its own instances and instance profiles. Terraform never knew about them.
#   5. terraform destroy, highest-numbered stack first.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PROTECTED_NS="default kube-system kube-public kube-node-lease karpenter argocd"

stacks_with_state() {
  # Stacks whose local state still holds resources, highest number first.
  local d
  for d in $(cd "$ROOT/terraform" && ls -d [0-9]*/ 2>/dev/null | tr -d / | sort -r); do
    local st="$ROOT/terraform/$d/terraform.tfstate"
    if [ -f "$st" ] && [ "$(jq '.resources | length' "$st")" -gt 0 ]; then echo "$d"; fi
  done
}

# Predicates for wait_for
no_argo_apps()  { [ -z "$(kubectl get applications.argoproj.io -A -o name 2>/dev/null)" ]; }
no_lb_objects() {
  [ -z "$(kubectl get ingress -A -o name 2>/dev/null)" ] &&
  [ -z "$(kubectl get svc -A -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].metadata.name}')" ]
}
no_lab_lbs()    { [ -z "$(lab_elbv2_arns load-balancers)" ]; }
no_pvs()        { [ -z "$(kubectl get pv -o name 2>/dev/null)" ]; }
no_nodeclaims() { [ -z "$(kubectl get nodeclaims.karpenter.sh -o name 2>/dev/null)" ]; }

# ---------------------------------------------------------------------------
k8s_cleanup() {
  local status; status="$(cluster_status)"
  if [ "$status" != "ACTIVE" ]; then
    warn "cluster $CLUSTER status: $status - skipping Kubernetes cleanup"
    return 0
  fi
  use_lab_kubeconfig
  log "kubectl -> $(kubectl config current-context)"

  # 1. Argo CD
  if has_crd applications.argoproj.io; then
    log "1/4 deleting Argo CD ApplicationSets/Applications (cascade)"
    has_crd applicationsets.argoproj.io && kubectl delete applicationsets.argoproj.io -A --all --wait=false || true
    kubectl delete applications.argoproj.io -A --all --wait=false || true
    wait_for 300 "Argo applications gone" no_argo_apps || true
  else
    log "1/4 no Argo CD - skip"
  fi

  # 2. Load balancers
  log "2/4 deleting Ingresses and LoadBalancer Services"
  kubectl delete ingress -A --all --wait=false 2>/dev/null || true
  kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
    | while read -r ns name; do [ -n "$name" ] && kubectl delete svc -n "$ns" "$name" --wait=false; done
  wait_for 300 "Ingress/LB Service objects gone (controller finalizers released)" no_lb_objects || true
  wait_for 300 "no ALB/NLB tagged for $CLUSTER in AWS" no_lab_lbs \
    || warn "load balancers still present - check scripts/verify-clean.sh before destroying the VPC"

  # 3. App namespaces + PVCs
  log "3/4 deleting app namespaces and PVCs (EBS volumes)"
  local ns
  for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    case " $PROTECTED_NS " in *" $ns "*) continue ;; esac
    kubectl delete ns "$ns" --wait=false
  done
  kubectl delete pvc -n default --all --wait=false 2>/dev/null || true
  wait_for 600 "all PersistentVolumes released" no_pvs || true

  # 4. Karpenter
  if has_crd nodepools.karpenter.sh; then
    log "4/4 deleting Karpenter NodePools -> nodes drain and terminate"
    kubectl delete nodepools.karpenter.sh --all --wait=false || true
    wait_for 900 "all Karpenter NodeClaims gone" no_nodeclaims || true
    has_crd ec2nodeclasses.karpenter.k8s.aws && kubectl delete ec2nodeclasses.karpenter.k8s.aws --all --wait=true --timeout=300s || true
  else
    log "4/4 no Karpenter - skip"
  fi
  log "Kubernetes cleanup finished"
}

# ---------------------------------------------------------------------------
plan_stack() {
  local s="$1"
  log "terraform plan -destroy: $s"
  "$ROOT/scripts/tf.sh" "$s" init -input=false >/dev/null
  "$ROOT/scripts/tf.sh" "$s" plan -destroy -input=false -out=destroy.tfplan
}

apply_stack() {
  local s="$1" plan="$ROOT/terraform/$1/destroy.tfplan"
  [ -f "$plan" ] || die "no saved plan at $plan - run: $0 plan $s"
  # Guards (override with FORCE=1): destroying the controllers or the VPC while their
  # AWS-side objects still exist is exactly how orphans are created.
  if [ "${FORCE:-0}" != 1 ]; then
    case "$s" in
      30-*)
        [ -z "$(lab_karpenter_instances)" ] \
          || die "Karpenter instances still running; run '$0 k8s' first (FORCE=1 to override)" ;;
      10-*)
        [ -z "$(lab_elbv2_arns load-balancers)" ] \
          || die "lab ALB/NLB still exist and would block VPC deletion; run '$0 k8s' first" ;;
    esac
  fi
  log "applying destroy plan: $s"
  "$ROOT/scripts/tf.sh" "$s" apply -input=false destroy.tfplan
  rm -f "$plan"
}

confirm() {
  local answer
  printf '\nDestroy stack %s as planned above? Type "destroy" to continue: ' "$1"
  read -r answer </dev/tty
  [ "$answer" = "destroy" ]
}

# ---------------------------------------------------------------------------
require_lab_account
case "${1:-all}" in
  k8s)   k8s_cleanup ;;
  plan)  [ -n "${2:-}" ] || die "usage: $0 plan STACK"; plan_stack "$2" ;;
  apply) [ -n "${2:-}" ] || die "usage: $0 apply STACK"; apply_stack "$2" ;;
  all)
    [ -t 0 ] || die "full run is interactive; use the k8s / plan / apply subcommands non-interactively"
    k8s_cleanup
    for s in $(stacks_with_state); do
      plan_stack "$s"
      confirm "$s" || die "aborted at $s (nothing further destroyed)"
      apply_stack "$s"
    done
    log "all stacks destroyed - now run scripts/verify-clean.sh"
    ;;
  *) die "unknown command: $1" ;;
esac
