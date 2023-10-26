#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Get the current directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR

pushd "${SCRIPT_DIR}" &>/dev/null

if ! aws sts get-caller-identity &>/dev/null; then
  echo 'You must be logged in to AWS to run this script.'
  exit 1
fi

tofu -chdir="tofu" init -input=false
tofu -chdir="tofu" apply -auto-approve -input=false

for cluster in eks-eu eks-us; do
  aws eks update-kubeconfig \
    --region "$(tofu -chdir="tofu" output -raw cluster_region_${cluster/#eks-/})" \
    --name "$(tofu -chdir="tofu" output -raw cluster_name_${cluster/#eks-/})" --kubeconfig "${cluster}.kubeconfig"
done

popd &>/dev/null
