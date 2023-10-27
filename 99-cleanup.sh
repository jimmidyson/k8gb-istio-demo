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

ROUTE53_RESOURCE_RECORDS="$(aws route53 list-resource-record-sets --hosted-zone-id "$(tofu -chdir="tofu" output -raw route53_zone_id)" |
  gojq '.ResourceRecordSets | {"Changes": map(select(.Name | test("\\.kubecon-na-2023\\.")) | {"Action": "DELETE", "ResourceRecordSet": .})} | select(.Changes |length > 0)')"

if [[ -n ${ROUTE53_RESOURCE_RECORDS} ]]; then
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$(tofu -chdir="tofu" output -raw route53_zone_id)" \
    --no-cli-pager \
    --change-batch file://<(echo "${ROUTE53_RESOURCE_RECORDS}")
fi

for cluster in eks-eu eks-us; do
  kubectl --kubeconfig "${cluster}.kubeconfig" delete gslbs.k8gb.absa.oss --all -A

  istioctl uninstall --kubeconfig "${cluster}.kubeconfig" -y --purge

  if kubectl --kubeconfig "${cluster}.kubeconfig" get deployment -n envoy-gateway-system envoy-gateway &>/dev/null; then
    kubectl --kubeconfig "${cluster}.kubeconfig" scale deployment -n envoy-gateway-system envoy-gateway --replicas=0
  fi

  kubectl --kubeconfig "${cluster}.kubeconfig" delete gateways --all --all-namespaces || true

  eval "$(kubectl --kubeconfig "${cluster}.kubeconfig" get services -A -ojson | gojq -r ".items[] | select(.spec.type == \"LoadBalancer\") | \"kubectl delete --kubeconfig ${cluster}.kubeconfig --ignore-not-found services --namespace=\"+.metadata.namespace+\" \"+.metadata.name")"

  if helm status --kubeconfig "${cluster}.kubeconfig" envoy-gateway --namespace envoy-gateway-system &>/dev/null; then
    helm uninstall --kubeconfig "${cluster}.kubeconfig" envoy-gateway --namespace envoy-gateway-system --wait
  fi
done

tofu -chdir="${SCRIPT_DIR}/tofu" destroy -auto-approve -input=false

# Duplicate --force flags are required to remove nested git repositories downloaded for tofu modules.
git clean -dx --force --force --exclude=.devbox

popd &>/dev/null
