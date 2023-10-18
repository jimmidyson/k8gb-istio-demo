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

helm upgrade --kubeconfig eks-eu.kubeconfig --install podinfo oci://ghcr.io/stefanprodan/charts/podinfo --namespace default --wait --wait-for-jobs \
  --set-string ui.logo=https://upload.wikimedia.org/wikipedia/commons/b/b7/Flag_of_Europe.svg \
  --set-string ui.message="I'm in Europe!"

GATEWAY_HOSTNAME_EU="$(kubectl --kubeconfig eks-eu.kubeconfig get gateways nginx-gateway -ojsonpath='{.spec.listeners[0].hostname}')"
readonly GATEWAY_HOSTNAME_EU
readonly PODINFO_HOSTNAME_EU="${GATEWAY_HOSTNAME_EU/#\*/podinfo}"

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
readonly PODINFO_HOSTNAME_US="${GATEWAY_HOSTNAME_US/#\*/podinfo}"

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
  rules:
  - backendRefs:
    - name: podinfo
      port: 9898
EOF

xdg-open "http://${PODINFO_HOSTNAME_EU}" &>/dev/null || open "http://${PODINFO_HOSTNAME_EU}" &>/dev/null || true
xdg-open "http://${PODINFO_HOSTNAME_US}" &>/dev/null || open "http://${PODINFO_HOSTNAME_US}" &>/dev/null || true

popd &>/dev/null
