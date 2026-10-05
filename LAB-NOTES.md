# Lab notes

A log of what actually happened: deliberate break-it exercises and anything unplanned.
Only real observations go here, with commands and output copied from the session.

Template:

```
## <date> — <short title>
Phase / exercise:
Symptom:            what I saw first (alert, kubectl output, HTTP errors)
Debug commands:     in the order I ran them, with the key output lines
Root cause:
Fix:
ECS equivalent:     how the same failure would look / be debugged on ECS
Takeaway:
```

---

<!-- entries below, newest last -->

## 2026-10-05 — Tagging API listed subnets that never existed
Phase / exercise: phase 1, unplanned. Found while testing verify-clean.sh against the live stack.
Symptom:          The Resource Groups Tagging API (Project=eks-lab) returned 8 subnets. Terraform
                  created 6. The 2 extra IDs carried our exact Name tags (private-1a, public-1c),
                  but `ec2 describe-subnets` returned InvalidSubnetID.NotFound for both.
Debug commands:
  aws ec2 describe-subnets --subnet-ids <id>                      # NotFound
  aws resourcegroupstaggingapi get-resources --resource-arn-list <arns>   # still listed, with tags
  aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=CreateSubnet \
    --query 'Events[].CloudTrailEvent' | jq -r '.[]|fromjson|[.eventTime,.errorCode,.requestParameters...]'
  # -> 8 CreateSubnet calls: 6 OK + 2 Client.RequestLimitExceeded, for exactly
  #    10.42.0.0/19 and 10.42.98.0/24. The SDK retried both successfully with new IDs.
Root cause:       EC2 API throttling (shared account with a busy production platform) during the
                  parallel subnet creates. The throttled attempts left index entries in the Tagging
                  API for subnet IDs that were never created.
Fix:              Nothing was broken. Terraform state was correct. verify-clean.sh treats the
                  Tagging API as informational only and decides pass/fail on direct describe calls.
ECS equivalent:   Same for any AWS cleanup audit. Not ECS-specific.
Takeaway:         "Tagging API says it exists" isn't proof. Confirm with the service's own describe
                  call, and use CloudTrail errorCode to explain discrepancies. Also: a shared
                  account can throttle your IaC. Terraform/SDK retries hide it unless you look.

## 2026-10-05 — verify-clean.sh missed EKS-managed node group volumes and launch template
Phase / exercise: phase 1, unplanned. Found by running verify-clean.sh while the stack was up.
Symptom:          Two running t4g.medium nodes were detected, but "EBS volumes" reported clean and
                  only one of two launch templates was listed.
Debug commands:
  aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=<node ids> --query 'Volumes[].Tags'
  aws ec2 describe-instances --instance-ids <node> --query 'Reservations[0].Instances[0].Tags'
Root cause:       Provider default_tags only reach resources Terraform creates. The managed node
                  group creates its own copy of the launch template, plus the instances and volumes,
                  tagged by EKS (eks:cluster-name, kubernetes.io/cluster/eks-lab), not Project=eks-lab.
Fix:              verify-clean.sh also filters volumes and launch templates on eks:cluster-name.
Takeaway:         Anything created by a controller or managed service on your behalf (MNG, LB
                  controller, Karpenter, EBS CSI) needs its own detection tag. Check by running the
                  audit while the stack is live, not only against an empty account.
