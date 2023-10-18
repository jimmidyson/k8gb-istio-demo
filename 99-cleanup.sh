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

GATEWAY_HOSTNAME_EU="$(kubectl --kubeconfig eks-eu.kubeconfig get gateways nginx-gateway -ojsonpath='{.spec.listeners[0].hostname}')"
readonly GATEWAY_HOSTNAME_EU
readonly PODINFO_HOSTNAME_EU="${GATEWAY_HOSTNAME_EU/#\*/podinfo.eu}"

readonly PODINFO_HOSTNAME_GLOBAL="${GATEWAY_HOSTNAME_EU/#\*/podinfo.global}"

GATEWAY_HOSTNAME_US="$(kubectl --kubeconfig eks-us.kubeconfig get gateways nginx-gateway -ojsonpath='{.spec.listeners[0].hostname}')"
readonly GATEWAY_HOSTNAME_US
readonly PODINFO_HOSTNAME_US="${GATEWAY_HOSTNAME_US/#\*/podinfo.us}"

until [ -n "${PUBLIC_HOSTNAME_NGINX_EU:-}" ]; do
  sleep 0.5
  PUBLIC_HOSTNAME_NGINX_EU="$(kubectl --kubeconfig eks-eu.kubeconfig get services -n nginx-gateway nginx-gateway-nginx-gateway-fabric -ojsonpath='{.status.loadBalancer.ingress[0].hostname}')"
done
readonly PUBLIC_HOSTNAME_NGINX_EU
until [ -n "${PUBLIC_IP_NGINX_EU:-}" ]; do
  sleep 0.5
  PUBLIC_IP_NGINX_EU="$(dig +short "${PUBLIC_HOSTNAME_NGINX_EU}")"
done
readonly PUBLIC_IP_NGINX_EU

until [ -n "${PUBLIC_HOSTNAME_NGINX_US:-}" ]; do
  sleep 0.5
  PUBLIC_HOSTNAME_NGINX_US="$(kubectl --kubeconfig eks-us.kubeconfig get services -n nginx-gateway nginx-gateway-nginx-gateway-fabric -ojsonpath='{.status.loadBalancer.ingress[0].hostname}')"
done
readonly PUBLIC_HOSTNAME_NGINX_US
until [ -n "${PUBLIC_IP_NGINX_US:-}" ]; do
  sleep 0.5
  PUBLIC_IP_NGINX_US="$(dig +short "${PUBLIC_HOSTNAME_NGINX_US}")"
done
readonly PUBLIC_IP_NGINX_US

aws route53 change-resource-record-sets \
  --hosted-zone-id "$(tofu -chdir="tofu" output -raw route53_zone_id)" \
  --no-cli-pager \
  --change-batch file://<(cat <<EOF
{
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "${PODINFO_HOSTNAME_EU}",
        "Type": "A",
        "TTL": 15,
        "ResourceRecords": [
          {
            "Value": "${PUBLIC_IP_NGINX_EU}"
          }
        ]
      }
    },
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "${PODINFO_HOSTNAME_US}",
        "Type": "A",
        "TTL": 15,
        "ResourceRecords": [
          {
            "Value": "${PUBLIC_IP_NGINX_US}"
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
            "Value": "${PUBLIC_IP_NGINX_EU}"
          },
          {
            "Value": "${PUBLIC_IP_NGINX_US}"
          }
        ]
      }
    }
  ]
}
EOF
)

eval "$(kubectl --kubeconfig eks-eu.kubeconfig get services -A -ojson | gojq -r '.items[] | select(.spec.type == "LoadBalancer") | "kubectl delete --kubeconfig eks-eu.kubeconfig services --namespace="+.metadata.namespace+" "+.metadata.name')"
eval "$(kubectl --kubeconfig eks-us.kubeconfig get services -A -ojson | gojq -r '.items[] | select(.spec.type == "LoadBalancer") | "kubectl delete --kubeconfig eks-us.kubeconfig services --namespace="+.metadata.namespace+" "+.metadata.name')"

tofu -chdir="${SCRIPT_DIR}/tofu" destroy -auto-approve -input=false

git clean -fdx
