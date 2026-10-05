# ECS → EKS migration notes

Observations for evaluating an ECS → EKS move. Entries marked *(design)* come from planning
and still need confirming in the lab; *(observed)* means it was seen in the lab.

## Concept mapping

| ECS | EKS | Notes |
|---|---|---|
| Cluster | Cluster (control plane $0.10/h) | ECS control plane is free *(design)* |
| Capacity provider (ASG) | Managed node group | Same idea: an ASG EKS manages for you *(design)* |
| Capacity provider managed scaling | Karpenter | Karpenter picks instance types per pending pod and has no fixed ASG *(design)* |
| Container instance IAM role | Node IAM role | |
| Task role | Pod Identity association (or IRSA) | Pod Identity is the closer match: generic trust policy, no OIDC provider *(design)* |
| Task execution role | Node role (image pull) + External Secrets (secrets) | No single equivalent *(design)* |
| `awsvpc` network mode | VPC CNI, pod IP from the VPC | Pods use subnet IPs much faster, so size subnets bigger *(design)* |
| ENI trunking | VPC CNI prefix delegation | t4g.medium allocatable pods = 110 with `ENABLE_PREFIX_DELEGATION=true`. EKS set maxPods on the MNG automatically. *(observed)* |
| IAM on `ecs:*` APIs | IAM authentication + access entries for authorization | Two layers instead of one. With `authentication_mode=API` there's no aws-auth ConfigMap. The MNG node role gets an automatic `EC2_LINUX` access entry. *(observed)* |
| ALB target group (ip) | Ingress → LB controller → target group (ip) | Phase 3 |
| Deregistration delay | Same TG attribute, plus pod `preStop` + readiness gates | Phase 3 |
| Service auto scaling | HPA (pods) + Karpenter (nodes) | Phase 4 |

## Maps 1:1

## Harder on EKS

- Lead time: the control plane took 8m55s to create and the whole cluster stack about 12 min, vs seconds for an ECS cluster *(observed)*
- More things exist in your account that IaC didn't create: EKS cross-account ENIs in your subnets, an EKS-owned copy of the node launch template, an extra cluster security group (`eks-cluster-sg-*`) *(observed)*
- An extra control plane cost and a version treadmill: about 14 months of standard support per minor version, then $0.60/h extended support *(design)*
- Cleanup: controllers create AWS resources Terraform doesn't know about (ALBs, Karpenter nodes, EBS volumes), so teardown order matters *(design)*

## Better on EKS

## Cost comparison

| Item | ECS (current platform) | EKS lab (observed) |
|---|---|---|
