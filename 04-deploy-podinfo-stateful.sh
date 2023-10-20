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

helm upgrade --kubeconfig eks-eu.kubeconfig --install podinfo-stateful oci://ghcr.io/stefanprodan/charts/podinfo --namespace default --wait --wait-for-jobs \
  --set-string ui.logo=https://upload.wikimedia.org/wikipedia/commons/c/cb/The_Blue_Marble_%28remastered%29.jpg \
  --set-string ui.message="I'm stateful!"

GATEWAY_HOSTNAME="$(kubectl --kubeconfig eks-eu.kubeconfig get gateways envoy-gateway -ojsonpath='{.spec.listeners[0].hostname}')"
readonly GATEWAY_HOSTNAME
readonly PODINFO_HOSTNAME_EU="${GATEWAY_HOSTNAME/#\*/podinfo.eu}"
readonly PODINFO_HOSTNAME_US="${GATEWAY_HOSTNAME/#\*/podinfo.us}"
readonly PODINFO_HOSTNAME_GLOBAL="${GATEWAY_HOSTNAME/#\*/podinfo.global}"

kubectl apply --kubeconfig eks-eu.kubeconfig --server-side -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: podinfo-stateful
spec:
  parentRefs:
  - name: envoy-gateway
    sectionName: http
  hostnames:
  - "${PODINFO_HOSTNAME_EU}"
  - "${PODINFO_HOSTNAME_GLOBAL}"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /stateful
    backendRefs:
    - name: podinfo-stateful
      port: 9898
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
  - backendRefs:
    - name: podinfo
      port: 9898
EOF

echo
echo 'Testing EU stateful...'
for _ in {1..10}; do curl -fsSL "http://${PODINFO_HOSTNAME_EU}/stateful" | gojq '.message'; done
echo
echo 'Testing US stateful...'
for _ in {1..10}; do curl -fsSL "http://${PODINFO_HOSTNAME_US}/stateful" | gojq '.message'; done
echo
echo 'Testing global stateful...'
for _ in {1..10}; do curl -fsSL "http://${PODINFO_HOSTNAME_GLOBAL}/stateful" | gojq '.message'; done

popd &>/dev/null
