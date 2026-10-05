# eks-lab

A hands-on Amazon EKS lab, built and torn down phase by phase with Terraform and Helm.
It's a learning and evaluation environment for running a PHP/Laravel platform on
Kubernetes, written by someone whose production background is Amazon ECS. So every
piece is annotated with its ECS equivalent, and with whether a choice is a lab
shortcut or something that should carry over to production.

- [LAB-NOTES.md](LAB-NOTES.md): break-it/debug log (symptom → commands → root cause → fix)
- [MIGRATION-NOTES.md](MIGRATION-NOTES.md): ECS → EKS observations and costs

## Architecture (phase 1–2)

```
                        Internet
                           │
                 ┌─────────┴─────────┐   public /24 × 3 AZ
                 │ ALB (phase 3)     │   NAT gateway (single, lab)
                 └─────────┬─────────┘
  VPC 10.42.0.0/16         │
  ┌────────────────────────┴───────────────────────────────┐
  │ private /19 × 3 AZ                                     │
  │  ┌──────────────────────┐   ┌────────────────────────┐ │
  │  │ system MNG           │   │ Karpenter nodes        │ │
  │  │ 2× t4g.medium (OD)   │   │ Spot + Graviton        │ │
  │  │ taint CriticalAddons │   │ (apps, phase 2+)       │ │
  │  │ CoreDNS, LBC,        │   └────────────────────────┘ │
  │  │ Karpenter            │                              │
  │  └──────────────────────┘   S3 gateway endpoint (ECR)  │
  └────────────────────────────────────────────────────────┘
          EKS control plane (AWS-managed), API restricted to admin IP
```

## Layout

| Path | What |
|---|---|
| `terraform/_shared/` | provider (account guard + default tags) and variables, symlinked into every stack |
| `terraform/10-network` | VPC, subnets, single NAT, S3 gateway endpoint |
| `terraform/20-eks` | EKS cluster, access entries, core add-ons, system node group |
| `terraform/30-platform` | (phase 2) Pod Identity roles, LB controller, metrics-server, Karpenter |
| `k8s/` | Plain manifests: Karpenter NodePools, the app, break-it patches, Locust |
| `app/` | Laravel demo (Nginx + PHP-FPM) |
| `scripts/` | `tf.sh` wrapper, `teardown.sh`, `verify-clean.sh` |

Each stack has its own local state; later stacks read earlier ones via `terraform_remote_state`.

## Prerequisites

terraform ≥ 1.10, kubectl, helm, aws CLI v2 with an SSO profile, jq.

```bash
cp terraform/lab.tfvars.example terraform/lab.tfvars   # set account_id + your IP; gitignored
aws sso login --profile lab
```

## Running a phase

Always plan first and apply exactly that saved plan:

```bash
scripts/tf.sh 10-network init
scripts/tf.sh 10-network plan -out=apply.tfplan
scripts/tf.sh 10-network apply apply.tfplan

scripts/tf.sh 20-eks init
scripts/tf.sh 20-eks plan -out=apply.tfplan
scripts/tf.sh 20-eks apply apply.tfplan
$(terraform -chdir=terraform/20-eks output -raw configure_kubectl)
kubectl get nodes -L node-role,kubernetes.io/arch
```

## Teardown, every session

```bash
scripts/teardown.sh        # interactive: K8s cleanup, then per-stack destroy plan + confirm
scripts/verify-clean.sh    # must print ALL CLEAN
```

Order and reasons:
1. Delete Argo CD apps so nothing gets recreated.
2. Delete Ingresses and LoadBalancer Services while the LB controller still runs, so it removes its ALBs, NLBs and target groups.
3. Delete app namespaces and PVCs while the EBS CSI driver still runs, so it removes the volumes.
4. Delete Karpenter NodePools while Karpenter still runs, so it drains and terminates its instances.
5. Run `terraform destroy`, highest-numbered stack first.

Non-interactive pieces: `teardown.sh k8s`, `teardown.sh plan <stack>`, `teardown.sh apply <stack>`.

`verify-clean.sh` checks the Tagging API (informational only, because its index can lag
deletions) and then calls each service's API directly for things Terraform never tagged:
controller-made ALBs, target groups and security groups, Karpenter instances, launch
templates and instance profiles, EBS CSI volumes, ENIs, and log groups.

## Cost notes (ap-southeast-1, on-demand list prices, approximate)

| Running | ≈ $/hour |
|---|---|
| EKS control plane (standard support) | 0.10 |
| NAT gateway (+ $0.059/GB processed) | 0.059 |
| 2× t4g.medium system nodes | 0.085 |
| Public IPv4 (NAT EIP), node EBS | ~0.01 |
| **Phase 1 total** | **≈ 0.25–0.30** |

Watch out for:
- **Extended support:** a cluster on a version past standard support costs $0.60/h instead of $0.10/h.
- **Idle ALBs:** each one costs about $0.025/h.
- **NAT data:** pulling images through NAT adds data charges. The S3 gateway endpoint takes ECR layer pulls off NAT.

## Lab shortcuts vs production

| Lab | Production |
|---|---|
| Local Terraform state | S3 backend, `use_lockfile = true`, one state per stack |
| Single NAT gateway | One NAT per AZ |
| Public API endpoint restricted to one IP | Private endpoint + VPN/SSM |
| No customer-managed KMS key | CMK if compliance requires |
| `deletion_protection = false`, 1-day log retention | Protection on, longer retention |
