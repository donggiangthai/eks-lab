#!/usr/bin/env bash
# Report anything the lab may have left behind. Read-only. Exit 1 if leftovers found.
#
# Two layers:
#   A. Resource Groups Tagging API for Project=eks-lab: broad, but its index is not
#      authoritative: deleted resources linger for a while, and throttled create calls
#      (RequestLimitExceeded, then SDK retry) can leave entries for IDs that never existed.
#      Informational only.
#   B. Direct describe/list calls per service, including resources that are NOT tagged by
#      Terraform default_tags (created by the LB controller, Karpenter, EBS CSI, EKS).
#      These decide the exit code.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

FOUND=0
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }
report() {  # report <label> <newline-separated items>
  local label="$1" items; items="$(printf '%s\n' "$2" | grep -v -e '^$' -e '^None$' || true)"
  if [ -n "$items" ]; then
    printf '  \033[31mLEFTOVER\033[0m %s\n' "$label"
    printf '%s\n' "$items" | sed 's/^/      /'
    FOUND=$((FOUND + 1))
  else
    printf '  \033[32mclean\033[0m    %s\n' "$label"
  fi
}
lines() { tr '\t' '\n'; }

require_lab_account
echo "account $ACCOUNT_ID / $REGION / cluster $CLUSTER"

# --- A ----------------------------------------------------------------------
section "A. Tagging API (Project=$PROJECT_TAG) - informational, may lag deletions"
tagged="$(awsl resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=$PROJECT_TAG" \
  --query 'ResourceTagMappingList[].ResourceARN' | lines | grep -v '^$' || true)"
if [ -n "$tagged" ]; then printf '%s\n' "$tagged" | sed 's/^/      /'; else echo "      (none)"; fi

# --- B ----------------------------------------------------------------------
section "B. Direct checks (authoritative)"

report "EKS cluster" "$( [ "$(cluster_status)" = NONE ] || echo "$CLUSTER ($(cluster_status))" )"

report "EC2 instances (MNG + Karpenter + tagged)" "$(lab_instances)"

lab_vpcs="$(awsl ec2 describe-vpcs --filters "Name=tag:Project,Values=$PROJECT_TAG" --query 'Vpcs[].VpcId' | lines)"
report "VPCs" "$lab_vpcs"

vpc_filter=""
for v in $lab_vpcs; do vpc_filter="$vpc_filter$v,"; done
vpc_filter="${vpc_filter%,}"

report "NAT gateways" "$(awsl ec2 describe-nat-gateways \
  --filter "Name=tag:Project,Values=$PROJECT_TAG" "Name=state,Values=pending,available,deleting" \
  --query 'NatGateways[].[NatGatewayId,State]' )"

report "VPC endpoints" "$(awsl ec2 describe-vpc-endpoints --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query "VpcEndpoints[?State!='deleted'].[VpcEndpointId,ServiceName,State]")"

report "Elastic IPs" "$(awsl ec2 describe-addresses --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Addresses[].[PublicIp,AllocationId]')"

# ENIs: anything in the lab VPC, plus VPC-CNI / EKS / LB ENIs that reference the cluster.
enis="$( {
  [ -n "$vpc_filter" ] && awsl ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc_filter" \
    --query 'NetworkInterfaces[].[NetworkInterfaceId,Status,InterfaceType,Description]'
  awsl ec2 describe-network-interfaces --filters "Name=tag:cluster.k8s.amazonaws.com/name,Values=$CLUSTER" \
    --query 'NetworkInterfaces[].[NetworkInterfaceId,Status,InterfaceType,Description]'
  awsl ec2 describe-network-interfaces --filters "Name=description,Values=*$CLUSTER*" \
    --query 'NetworkInterfaces[].[NetworkInterfaceId,Status,InterfaceType,Description]'
} | sort -u )"
report "ENIs" "$enis"

# EBS: Terraform-tagged, EKS/Karpenter node volumes, EBS CSI dynamic volumes.
vols="$( {
  awsl ec2 describe-volumes --filters "Name=tag:Project,Values=$PROJECT_TAG" --query 'Volumes[].[VolumeId,State,Size]'
  awsl ec2 describe-volumes --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" --query 'Volumes[].[VolumeId,State,Size]'
  awsl ec2 describe-volumes --filters "Name=tag:KubernetesCluster,Values=$CLUSTER" --query 'Volumes[].[VolumeId,State,Size]'
  awsl ec2 describe-volumes --filters "Name=tag:eks:eks-cluster-name,Values=$CLUSTER" --query 'Volumes[].[VolumeId,State,Size]'
  awsl ec2 describe-volumes --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" --query 'Volumes[].[VolumeId,State,Size]'
} | sort -u )"
report "EBS volumes" "$vols"

report "EBS snapshots" "$(awsl ec2 describe-snapshots --owner-ids self \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" --query 'Snapshots[].[SnapshotId,VolumeSize]')"

report "ALB/NLB (LB controller or tagged)" "$(lab_elbv2_arns load-balancers)"
report "Target groups (LB controller or tagged)" "$(lab_elbv2_arns target-groups)"

sgs="$( {
  [ -n "$vpc_filter" ] && awsl ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc_filter" \
    --query "SecurityGroups[?GroupName!='default'].[GroupId,GroupName]"
  awsl ec2 describe-security-groups --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER" --query 'SecurityGroups[].[GroupId,GroupName]'
  awsl ec2 describe-security-groups --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" --query 'SecurityGroups[].[GroupId,GroupName]'
  awsl ec2 describe-security-groups --filters "Name=tag:Project,Values=$PROJECT_TAG" --query 'SecurityGroups[].[GroupId,GroupName]'
} | sort -u )"
report "Security groups" "$sgs"

report "Launch templates (MNG / Karpenter)" "$( {
  awsl ec2 describe-launch-templates --filters "Name=tag:Project,Values=$PROJECT_TAG" --query 'LaunchTemplates[].[LaunchTemplateId,LaunchTemplateName]'
  awsl ec2 describe-launch-templates --filters "Name=tag:karpenter.k8s.aws/cluster,Values=$CLUSTER" --query 'LaunchTemplates[].[LaunchTemplateId,LaunchTemplateName]'
  # EKS copies the node group launch template into an EKS-owned one tagged eks:cluster-name
  awsl ec2 describe-launch-templates --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" --query 'LaunchTemplates[].[LaunchTemplateId,LaunchTemplateName]'
} | sort -u )"

report "CloudWatch log groups" "$( {
  awsl logs describe-log-groups --log-group-name-prefix "/aws/eks/$CLUSTER" --query 'logGroups[].logGroupName'
  awsl logs describe-log-groups --log-group-name-prefix "/aws/containerinsights/$CLUSTER" --query 'logGroups[].logGroupName'
} | lines )"

# IAM is global and not reliably covered by the Tagging API. Check names that the EKS
# module / Karpenter use, then confirm ownership via tags.
iam_roles="$(aws --profile "$PROFILE" --output text iam list-roles \
  --query "Roles[?contains(RoleName,'$CLUSTER') || starts_with(RoleName,'system-eks-node-group')].RoleName" | lines)"
report "IAM roles" "$iam_roles"

report "IAM instance profiles (incl. Karpenter-managed)" "$(aws --profile "$PROFILE" --output text iam list-instance-profiles \
  --query "InstanceProfiles[?contains(InstanceProfileName,'$CLUSTER') || starts_with(InstanceProfileName,'system-eks-node-group')].InstanceProfileName" | lines)"

report "IAM policies (customer managed)" "$(aws --profile "$PROFILE" --output text iam list-policies --scope Local \
  --query "Policies[?contains(PolicyName,'$CLUSTER')].PolicyName" | lines)"

# An EKS OIDC provider would only exist if IRSA were enabled; check by tag to never
# confuse it with the account's existing providers.
oidc="$(for arn in $(aws --profile "$PROFILE" --output text iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn'); do
  aws --profile "$PROFILE" --output text iam list-open-id-connect-provider-tags --open-id-connect-provider-arn "$arn" \
    --query "Tags[?Key=='Project' && Value=='$PROJECT_TAG'].Value" | grep -q . && echo "$arn"
done)"
report "IAM OIDC providers (tagged eks-lab)" "$oidc"

report "KMS aliases" "$(awsl kms list-aliases --query "Aliases[?contains(AliasName,'$CLUSTER')].AliasName" | lines)"

report "SQS queues (Karpenter interruption)" "$(awsl sqs list-queues --queue-name-prefix "$CLUSTER" --query 'QueueUrls[]' | lines)"
report "SQS queues (Karpenter default name)" "$(awsl sqs list-queues --queue-name-prefix "Karpenter-$CLUSTER" --query 'QueueUrls[]' | lines)"

report "EventBridge rules" "$(awsl events list-rules --query "Rules[?contains(Name,'$CLUSTER')].Name" | lines)"

report "Secrets Manager secrets" "$(awsl secretsmanager list-secrets --include-planned-deletion \
  --filters "Key=tag-key,Values=Project" "Key=tag-value,Values=$PROJECT_TAG" --query 'SecretList[].[Name,DeletedDate]' 2>/dev/null)"

report "ECR repositories" "$(awsl ecr describe-repositories --query "repositories[?contains(repositoryName,'$CLUSTER')].repositoryName" 2>/dev/null | lines)"

report "OpenSearch domains" "$(awsl opensearch list-domain-names --query "DomainNames[?contains(DomainName,'$CLUSTER')].DomainName" 2>/dev/null | lines)"

# --- local state ---------------------------------------------------------------
section "C. Local Terraform state"
st_left=""
for st in "$ROOT"/terraform/[0-9]*/terraform.tfstate; do
  [ -f "$st" ] || continue
  n="$(jq '.resources | map(select(.mode=="managed")) | length' "$st")"
  [ "$n" -gt 0 ] && st_left="$st_left$(basename "$(dirname "$st")"): $n managed resources in state
"
done
report "terraform.tfstate files" "$st_left"

echo
if [ "$FOUND" -eq 0 ]; then
  printf '\033[32mALL CLEAN\033[0m\n'
else
  printf '\033[31m%d categories have leftovers\033[0m (deleted items can take a few minutes to disappear; re-run)\n' "$FOUND"
  exit 1
fi
