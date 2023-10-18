#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Get the current directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
readonly SCRIPT_DIR

if ! aws sts get-caller-identity &>/dev/null; then
  echo 'You must be logged in to AWS to run this script.'
  exit 1
fi

eval "$(kubectl --kubeconfig eks-eu.kubeconfig get services -A -ojson | gojq -r '.items[] | select(.spec.type == "LoadBalancer") | "kubectl delete --kubeconfig eks-eu.kubeconfig services --namespace="+.metadata.namespace+" "+.metadata.name')"
eval "$(kubectl --kubeconfig eks-us.kubeconfig get services -A -ojson | gojq -r '.items[] | select(.spec.type == "LoadBalancer") | "kubectl delete --kubeconfig eks-us.kubeconfig services --namespace="+.metadata.namespace+" "+.metadata.name')"

tofu -chdir="${SCRIPT_DIR}/tofu" destroy -auto-approve -input=false

git clean -fdx
