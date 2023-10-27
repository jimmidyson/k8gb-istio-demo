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

declare -rA messages=(
  ['eks-eu']="I'm in Europe"
  ['eks-us']="I'm in the USA"
)
declare -rA logos=(
  ['eks-eu']='https://upload.wikimedia.org/wikipedia/commons/b/b7/Flag_of_Europe.svg'
  ['eks-us']='https://upload.wikimedia.org/wikipedia/commons/a/a4/Flag_of_the_United_States.svg'
)

for cluster in eks-eu eks-us; do
  helm upgrade --kubeconfig "${cluster}.kubeconfig" --install podinfo-stateless oci://ghcr.io/stefanprodan/charts/podinfo \
    --namespace default --wait --wait-for-jobs \
    --values - <<EOF
ui:
  logo: "${logos[${cluster}]}"
  message: "${messages[${cluster}]}"
EOF

  GATEWAY_HOSTNAME="$(kubectl --kubeconfig "${cluster}.kubeconfig" get gateways --namespace envoy-gateway-system envoy-gateway -ojsonpath='{.spec.listeners[0].hostname}')"
  PODINFO_HOSTNAME="${GATEWAY_HOSTNAME/#\*/podinfo.${cluster/#eks-/}}"
  PODINFO_HOSTNAME_GLOBAL="${GATEWAY_HOSTNAME/#\*/podinfo.global}"

  kubectl apply --kubeconfig "${cluster}.kubeconfig" --server-side -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: podinfo
spec:
  parentRefs:
  - name: envoy-gateway
    namespace: envoy-gateway-system
    sectionName: http
  hostnames:
  - "${PODINFO_HOSTNAME}"
  - "${PODINFO_HOSTNAME_GLOBAL}"
  rules:
  - backendRefs:
    - name: podinfo-stateless
      port: 9898
EOF
done

GATEWAY_HOSTNAME="$(kubectl --kubeconfig eks-eu.kubeconfig get gateways --namespace envoy-gateway-system envoy-gateway -ojsonpath='{.spec.listeners[0].hostname}')"
readonly GATEWAY_HOSTNAME
readonly PODINFO_HOSTNAME_EU="${GATEWAY_HOSTNAME/#\*/podinfo.eu}"
readonly PODINFO_HOSTNAME_US="${GATEWAY_HOSTNAME/#\*/podinfo.us}"
readonly PODINFO_HOSTNAME_GLOBAL="${GATEWAY_HOSTNAME/#\*/podinfo.global}"

PUBLIC_HOSTNAME_EU="$(kubectl --kubeconfig eks-eu.kubeconfig get gateways --namespace envoy-gateway-system envoy-gateway -ojsonpath='{.status.addresses[0].value}')"
readonly PUBLIC_HOSTNAME_EU
readarray -t PUBLIC_IPS_EU < <(dig +short "${PUBLIC_HOSTNAME_EU}")
readonly PUBLIC_IPS_EU

PUBLIC_HOSTNAME_US="$(kubectl --kubeconfig eks-us.kubeconfig get gateways --namespace envoy-gateway-system envoy-gateway -ojsonpath='{.status.addresses[0].value}')"
readonly PUBLIC_HOSTNAME_US
readarray -t PUBLIC_IPS_US < <(dig +short "${PUBLIC_HOSTNAME_US}")
readonly PUBLIC_IPS_US

CHANGE_RESOURCE_RECORD_ID="$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$(tofu -chdir="tofu" output -raw route53_zone_id)" \
  --no-cli-pager \
  --change-batch file://<(
    cat <<EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${PODINFO_HOSTNAME_EU}",
        "Type": "CNAME",
        "TTL": 5,
        "ResourceRecords": [
          {
            "Value": "${PUBLIC_HOSTNAME_EU}"
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${PODINFO_HOSTNAME_US}",
        "Type": "CNAME",
        "TTL": 5,
        "ResourceRecords": [
          {
            "Value": "${PUBLIC_HOSTNAME_US}"
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${PODINFO_HOSTNAME_GLOBAL}",
        "Type": "A",
        "TTL": 5,
        "ResourceRecords": $(gojq --compact-output --null-input $'$ARGS.positional | map({"Value":.})' --args -- "${PUBLIC_IPS_EU[@]}" "${PUBLIC_IPS_US[@]}")
      }
    }
  ]
}
EOF
  ) | gojq --raw-output '.ChangeInfo.Id')"

aws route53 wait resource-record-sets-changed --id "${CHANGE_RESOURCE_RECORD_ID}"

echo
echo 'Testing EU...'
for _ in {1..10}; do curl -fsS "http://${PODINFO_HOSTNAME_EU}" | gojq '.message'; done
echo
echo 'Testing US...'
for _ in {1..10}; do curl -fsS "http://${PODINFO_HOSTNAME_US}" | gojq '.message'; done
echo
echo 'Testing global...'
for _ in {1..10}; do curl -fsS "http://${PODINFO_HOSTNAME_GLOBAL}" | gojq '.message'; done

popd &>/dev/null
