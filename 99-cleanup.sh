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

if kubectl --kubeconfig eks-eu.kubeconfig get gateways --namespace envoy-ingress envoy-gateway &>/dev/null; then
  GATEWAY_HOSTNAME="$(kubectl --kubeconfig eks-eu.kubeconfig get gateways --namespace envoy-ingress envoy-gateway -ojsonpath='{.spec.listeners[0].hostname}')"
  PODINFO_HOSTNAME_EU="${GATEWAY_HOSTNAME/#\*/podinfo.eu}"
  PODINFO_HOSTNAME_US="${GATEWAY_HOSTNAME/#\*/podinfo.us}"
  PODINFO_HOSTNAME_GLOBAL="${GATEWAY_HOSTNAME/#\*/podinfo.global}"

  PUBLIC_HOSTNAME_EU="$(kubectl --kubeconfig eks-eu.kubeconfig get gateways --namespace envoy-ingress envoy-gateway -ojsonpath='{.status.addresses[0].value}')"
  readarray -t PUBLIC_IPS_EU < <(dig +short "${PUBLIC_HOSTNAME_EU}")

  PUBLIC_HOSTNAME_US="$(kubectl --kubeconfig eks-us.kubeconfig get gateways --namespace envoy-ingress envoy-gateway -ojsonpath='{.status.addresses[0].value}')"
  readarray -t PUBLIC_IPS_US < <(dig +short "${PUBLIC_HOSTNAME_US}")

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
        "ResourceRecords": $(gojq --compact-output --null-input $'$ARGS.positional | map({"Value":.})' --args -- "${PUBLIC_IPS_EU[@]}" "${PUBLIC_IPS_US[@]}")
      }
    }
  ]
}
EOF
    )
fi

if kubectl --kubeconfig eks-eu.kubeconfig get gateways --namespace istio-ingress istio-gateway &>/dev/null; then
  GATEWAY_HOSTNAME="$(kubectl --kubeconfig eks-eu.kubeconfig get gateways --namespace istio-ingress istio-gateway -ojsonpath='{.spec.listeners[0].hostname}')"
  PODINFO_HOSTNAME_EU="${GATEWAY_HOSTNAME/#\*/podinfo.eu}"
  PODINFO_HOSTNAME_US="${GATEWAY_HOSTNAME/#\*/podinfo.us}"
  PODINFO_HOSTNAME_GLOBAL="${GATEWAY_HOSTNAME/#\*/podinfo.global}"

  PUBLIC_HOSTNAME_EU="$(kubectl --kubeconfig eks-eu.kubeconfig get gateways --namespace istio-ingress istio-gateway -ojsonpath='{.status.addresses[0].value}')"
  readarray -t PUBLIC_IPS_EU < <(dig +short "${PUBLIC_HOSTNAME_EU}")

  PUBLIC_HOSTNAME_US="$(kubectl --kubeconfig eks-us.kubeconfig get gateways --namespace istio-ingress istio-gateway -ojsonpath='{.status.addresses[0].value}')"
  readarray -t PUBLIC_IPS_US < <(dig +short "${PUBLIC_HOSTNAME_US}")

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
        "ResourceRecords": $(gojq --compact-output --null-input $'$ARGS.positional | map({"Value":.})' --args -- "${PUBLIC_IPS_EU[@]}" "${PUBLIC_IPS_US[@]}")
      }
    }
  ]
}
EOF
    )
fi

for cluster in eks-eu eks-us; do
  if helm status --kubeconfig "${cluster}.kubeconfig" envoy-gateway --namespace envoy-gateway-system &>/dev/null; then
    helm uninstall --kubeconfig "${cluster}.kubeconfig" envoy-gateway --namespace envoy-gateway-system --wait
  fi

  istioctl uninstall --kubeconfig "${cluster}.kubeconfig" -y --purge || true

  kubectl --kubeconfig "${cluster}.kubeconfig" delete gateways --all --all-namespaces || true

  eval "$(kubectl --kubeconfig "${cluster}.kubeconfig" get services -A -ojson | gojq -r ".items[] | select(.spec.type == \"LoadBalancer\") | \"kubectl delete --kubeconfig ${cluster}.kubeconfig services --namespace=\"+.metadata.namespace+\" \"+.metadata.name")"
done

tofu -chdir="${SCRIPT_DIR}/tofu" destroy -auto-approve -input=false

# Duplicate --force flags are required to remove nested git repositories downloaded for tofu modules.
git clean -dx --force --force --exclude=.devbox

popd &>/dev/null
