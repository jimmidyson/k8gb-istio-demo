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

if kubectl --kubeconfig eks-eu.kubeconfig get gateways envoy-gateway &>/dev/null; then
  GATEWAY_HOSTNAME="$(kubectl --kubeconfig eks-eu.kubeconfig get gateways envoy-gateway -ojsonpath='{.spec.listeners[0].hostname}')"
  readonly GATEWAY_HOSTNAME
  readonly PODINFO_HOSTNAME_EU="${GATEWAY_HOSTNAME/#\*/podinfo.eu}"
  readonly PODINFO_HOSTNAME_US="${GATEWAY_HOSTNAME/#\*/podinfo.us}"
  readonly PODINFO_HOSTNAME_GLOBAL="${GATEWAY_HOSTNAME/#\*/podinfo.global}"

  PUBLIC_HOSTNAME_EU="$(kubectl --kubeconfig eks-eu.kubeconfig get gateways envoy-gateway -ojsonpath='{.status.addresses[0].value}')"
  readonly PUBLIC_HOSTNAME_EU
  PUBLIC_IP_EU="$(dig +short "${PUBLIC_HOSTNAME_EU}")"
  readonly PUBLIC_IP_EU

  PUBLIC_HOSTNAME_US="$(kubectl --kubeconfig eks-us.kubeconfig get gateways envoy-gateway -ojsonpath='{.status.addresses[0].value}')"
  readonly PUBLIC_HOSTNAME_US
  PUBLIC_IP_US="$(dig +short "${PUBLIC_HOSTNAME_US}")"
  readonly PUBLIC_IP_US

  aws route53 change-resource-record-sets \
    --hosted-zone-id "$(tofu -chdir="tofu" output -raw route53_zone_id)" \
    --no-cli-pager \
    --change-batch file://<(
      cat <<EOF
{
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "${PODINFO_HOSTNAME_EU}",
        "Type": "CNAME",
        "TTL": 15,
        "ResourceRecords": [
          {
            "Value": "${PUBLIC_HOSTNAME_EU}"
          }
        ]
      }
    },
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "${PODINFO_HOSTNAME_US}",
        "Type": "CNAME",
        "TTL": 15,
        "ResourceRecords": [
          {
            "Value": "${PUBLIC_HOSTNAME_US}"
          }
        ]
      }
    },
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "${PODINFO_HOSTNAME_GLOBAL}",
        "Type": "A",
        "TTL": 15,
        "ResourceRecords": [
          {
            "Value": "${PUBLIC_IP_EU}"
          },
          {
            "Value": "${PUBLIC_IP_US}"
          }
        ]
      }
    }
  ]
}
EOF
    )
fi

kubectl --kubeconfig eks-eu.kubeconfig delete gateways --all --all-namespaces
kubectl --kubeconfig eks-us.kubeconfig delete gateways --all --all-namespaces

eval "$(kubectl --kubeconfig eks-eu.kubeconfig get services -A -ojson | gojq -r '.items[] | select(.spec.type == "LoadBalancer") | "kubectl delete --kubeconfig eks-eu.kubeconfig services --namespace="+.metadata.namespace+" "+.metadata.name')"
eval "$(kubectl --kubeconfig eks-us.kubeconfig get services -A -ojson | gojq -r '.items[] | select(.spec.type == "LoadBalancer") | "kubectl delete --kubeconfig eks-us.kubeconfig services --namespace="+.metadata.namespace+" "+.metadata.name')"

tofu -chdir="${SCRIPT_DIR}/tofu" destroy -auto-approve -input=false

# Duplicate --force flags are required to remove nested git repositories downloaded for tofu modules.
git clean -dx --force --force --exclude=.devbox

popd &>/dev/null
