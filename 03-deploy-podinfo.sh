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

helm upgrade --kubeconfig eks-eu.kubeconfig --install podinfo oci://ghcr.io/stefanprodan/charts/podinfo --namespace default --wait --wait-for-jobs \
  --set-string ui.logo=https://upload.wikimedia.org/wikipedia/commons/b/b7/Flag_of_Europe.svg \
  --set-string ui.message="I'm in Europe!"

GATEWAY_HOSTNAME_EU="$(kubectl --kubeconfig eks-eu.kubeconfig get gateways nginx-gateway -ojsonpath='{.spec.listeners[0].hostname}')"
readonly GATEWAY_HOSTNAME_EU
readonly PODINFO_HOSTNAME_EU="${GATEWAY_HOSTNAME_EU/#\*/podinfo.eu}"

readonly PODINFO_HOSTNAME_GLOBAL="${GATEWAY_HOSTNAME_EU/#\*/podinfo.global}"

cat <<EOF | kubectl apply --kubeconfig eks-eu.kubeconfig --server-side -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: podinfo
spec:
  parentRefs:
  - name: nginx-gateway
    sectionName: http
  hostnames:
  - "${PODINFO_HOSTNAME_EU}"
  - "${PODINFO_HOSTNAME_GLOBAL}"
  rules:
  - backendRefs:
    - name: podinfo
      port: 9898
EOF

helm upgrade --kubeconfig eks-us.kubeconfig --install podinfo oci://ghcr.io/stefanprodan/charts/podinfo --namespace default --wait --wait-for-jobs \
  --set-string ui.logo=https://upload.wikimedia.org/wikipedia/commons/a/a9/Flag_of_the_United_States_%28DoS_ECA_Color_Standard%29.svg \
  --set-string ui.message="I'm in the USA!"

GATEWAY_HOSTNAME_US="$(kubectl --kubeconfig eks-us.kubeconfig get gateways nginx-gateway -ojsonpath='{.spec.listeners[0].hostname}')"
readonly GATEWAY_HOSTNAME_US
readonly PODINFO_HOSTNAME_US="${GATEWAY_HOSTNAME_US/#\*/podinfo.us}"

cat <<EOF | kubectl apply --kubeconfig eks-us.kubeconfig --server-side -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: podinfo
spec:
  parentRefs:
  - name: nginx-gateway
    sectionName: http
  hostnames:
  - "${PODINFO_HOSTNAME_US}"
  - "${PODINFO_HOSTNAME_GLOBAL}"
  rules:
  - backendRefs:
    - name: podinfo
      port: 9898
EOF

kubectl --kubeconfig eks-eu.kubeconfig wait --for=jsonpath='{.status.loadBalancer.ingress}' --namespace nginx-gateway services/nginx-gateway-nginx-gateway-fabric
kubectl --kubeconfig eks-us.kubeconfig wait --for=jsonpath='{.status.loadBalancer.ingress}' --namespace nginx-gateway services/nginx-gateway-nginx-gateway-fabric

PUBLIC_HOSTNAME_NGINX_EU="$(kubectl --kubeconfig eks-eu.kubeconfig get services --namespace nginx-gateway nginx-gateway-nginx-gateway-fabric -ojsonpath='{.status.loadBalancer.ingress[0].hostname}')"
readonly PUBLIC_HOSTNAME_NGINX_EU
PUBLIC_IP_NGINX_EU="$(dig +short "${PUBLIC_HOSTNAME_NGINX_EU}")"
readonly PUBLIC_IP_NGINX_EU

PUBLIC_HOSTNAME_NGINX_US="$(kubectl --kubeconfig eks-us.kubeconfig get services --namespace nginx-gateway nginx-gateway-nginx-gateway-fabric -ojsonpath='{.status.loadBalancer.ingress[0].hostname}')"
readonly PUBLIC_HOSTNAME_NGINX_US
PUBLIC_IP_NGINX_US="$(dig +short "${PUBLIC_HOSTNAME_NGINX_US}")"
readonly PUBLIC_IP_NGINX_US

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
        "TTL": 15,
        "ResourceRecords": [
          {
            "Value": "${PUBLIC_HOSTNAME_NGINX_EU}"
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${PODINFO_HOSTNAME_US}",
        "Type": "CNAME",
        "TTL": 15,
        "ResourceRecords": [
          {
            "Value": "${PUBLIC_HOSTNAME_NGINX_US}"
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
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
  ) | gojq --raw-output '.ChangeInfo.Id')"

aws route53 wait resource-record-sets-changed --id "${CHANGE_RESOURCE_RECORD_ID}"

xdg-open "http://${PODINFO_HOSTNAME_EU}" &>/dev/null || open "http://${PODINFO_HOSTNAME_EU}" &>/dev/null || true
xdg-open "http://${PODINFO_HOSTNAME_US}" &>/dev/null || open "http://${PODINFO_HOSTNAME_US}" &>/dev/null || true
xdg-open "http://${PODINFO_HOSTNAME_GLOBAL}" &>/dev/null || open "http://${PODINFO_HOSTNAME_GLOBAL}" &>/dev/null || true

popd &>/dev/null
