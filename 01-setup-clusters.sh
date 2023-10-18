#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Get the current directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
readonly SCRIPT_DIR

pushd "${SCRIPT_DIR}" &>/dev/null

if ! aws sts get-caller-identity &>/dev/null; then
  echo 'You must be logged in to AWS to run this script.'
  exit 1
fi

tofu -chdir="tofu" init -input=false
tofu -chdir="tofu" apply -auto-approve -input=false

aws eks update-kubeconfig \
  --region "$(tofu -chdir="tofu" output -raw cluster_region_eu)" \
  --name "$(tofu -chdir="tofu" output -raw cluster_name_eu)" --kubeconfig "eks-eu.kubeconfig"
aws eks update-kubeconfig \
  --region "$(tofu -chdir="tofu" output -raw cluster_region_us)" \
  --name "$(tofu -chdir="tofu" output -raw cluster_name_us)" --kubeconfig "eks-us.kubeconfig"

popd &>/dev/null
