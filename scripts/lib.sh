# shellcheck shell=bash
# Shared helpers for teardown.sh / verify-clean.sh. Source it, don't run it.
# Bash 3.2 compatible (macOS default shell): no associative arrays, no mapfile.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARS="$ROOT/terraform/lab.tfvars"

[ -f "$VARS" ] || { echo "missing $VARS (copy lab.tfvars.example)" >&2; exit 1; }

tfvar() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" "$VARS" | head -1; }

ACCOUNT_ID="$(tfvar account_id)"
PROFILE="$(tfvar aws_profile)"; PROFILE="${PROFILE:-lab}"
REGION="$(tfvar region)";       REGION="${REGION:-ap-southeast-1}"
CLUSTER="$(tfvar cluster_name)"; CLUSTER="${CLUSTER:-eks-lab}"
PROJECT_TAG="eks-lab"

# Always pin profile + region; never rely on whatever AWS_PROFILE is exported.
awsl() { aws --profile "$PROFILE" --region "$REGION" --output text "$@"; }

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

require_lab_account() {
  local acct
  acct="$(awsl sts get-caller-identity --query Account 2>/dev/null)" \
    || die "AWS credentials for profile '$PROFILE' not valid. Run: aws sso login --profile $PROFILE"
  [ "$acct" = "$ACCOUNT_ID" ] || die "profile '$PROFILE' resolves to account $acct, expected $ACCOUNT_ID"
}

cluster_status() {
  awsl eks describe-cluster --name "$CLUSTER" --query cluster.status 2>/dev/null || echo "NONE"
}

# Point kubectl at the lab cluster through a throwaway kubeconfig, so these scripts can
# never act on whatever context happens to be current (e.g. a production cluster).
use_lab_kubeconfig() {
  KUBECONFIG="$(mktemp -t eks-lab-kubeconfig)"
  export KUBECONFIG
  trap 'rm -f "$KUBECONFIG"' EXIT
  aws eks update-kubeconfig --profile "$PROFILE" --region "$REGION" --name "$CLUSTER" \
    --kubeconfig "$KUBECONFIG" >/dev/null
}

has_crd() { kubectl get crd "$1" >/dev/null 2>&1; }

# Wait until a shell condition becomes true. wait_for <timeout-sec> <description> <cmd...>
wait_for() {
  local timeout="$1" desc="$2"; shift 2
  local start; start=$(date +%s)
  until "$@"; do
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      warn "timed out after ${timeout}s waiting for: $desc"
      return 1
    fi
    sleep 10
  done
  log "done: $desc"
}

# ELBv2 load balancers / target groups created by the AWS Load Balancer Controller
# for this cluster. describe-tags is authoritative (the Tagging API can lag).
lab_elbv2_arns() {  # $1 = load-balancers | target-groups
  local kind="$1" query arns
  if [ "$kind" = "load-balancers" ]; then query='LoadBalancers[].LoadBalancerArn'; else query='TargetGroups[].TargetGroupArn'; fi
  arns="$(awsl elbv2 "describe-$kind" --query "$query" 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)"
  [ -n "$arns" ] || return 0
  # describe-tags accepts at most 20 ARNs per call
  echo "$arns" | xargs -n 20 | while read -r batch; do
    # shellcheck disable=SC2086
    awsl elbv2 describe-tags --resource-arns $batch \
      --query "TagDescriptions[?Tags[?(Key=='elbv2.k8s.aws/cluster' && Value=='$CLUSTER') || (Key=='Project' && Value=='$PROJECT_TAG')]].ResourceArn" \
      | tr '\t' '\n' | grep -v '^$' || true
  done
}

# Non-terminated EC2 instances belonging to the lab (MNG nodes, Karpenter nodes).
lab_instances() {
  {
    awsl ec2 describe-instances \
      --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" \
                "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
      --query 'Reservations[].Instances[].InstanceId'
    awsl ec2 describe-instances \
      --filters "Name=tag:Project,Values=$PROJECT_TAG" \
                "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
      --query 'Reservations[].Instances[].InstanceId'
  } | tr '\t' '\n' | grep -v '^$' | sort -u || true
}

# Subset launched by Karpenter (Terraform does not know about these).
lab_karpenter_instances() {
  awsl ec2 describe-instances \
    --filters "Name=tag-key,Values=karpenter.sh/nodepool" \
              "Name=tag:eks:eks-cluster-name,Values=$CLUSTER" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' | tr '\t' '\n' | grep -v '^$' || true
}
