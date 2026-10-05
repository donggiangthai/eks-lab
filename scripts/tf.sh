#!/usr/bin/env bash
# Run terraform in a stack with the shared lab.tfvars.
#   scripts/tf.sh 10-network init
#   scripts/tf.sh 10-network plan -out=apply.tfplan
#   scripts/tf.sh 10-network apply apply.tfplan
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VARS="$ROOT/terraform/lab.tfvars"

if [ $# -lt 2 ]; then
  echo "usage: $0 <stack-dir> <terraform-command> [args...]" >&2
  echo "stacks: $(cd "$ROOT/terraform" && ls -d [0-9]*/ | tr -d / | tr '\n' ' ')" >&2
  exit 1
fi

stack="$1"; cmd="$2"; shift 2
dir="$ROOT/terraform/$stack"
[ -d "$dir" ] || { echo "no such stack: $dir" >&2; exit 1; }
[ -f "$VARS" ] || { echo "missing $VARS (copy lab.tfvars.example)" >&2; exit 1; }

# Only commands that evaluate variables accept -var-file. Applying a saved plan
# file must NOT get it (terraform rejects variables alongside a plan file).
needs_vars=false
case "$cmd" in
  plan|destroy|import|console|refresh) needs_vars=true ;;
  apply)
    needs_vars=true
    for a in "$@"; do case "$a" in *.tfplan) needs_vars=false ;; esac; done ;;
esac

if $needs_vars; then
  exec terraform -chdir="$dir" "$cmd" -var-file="$VARS" "$@"
else
  exec terraform -chdir="$dir" "$cmd" "$@"
fi
