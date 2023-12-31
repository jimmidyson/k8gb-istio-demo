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

for cluster in eks-eu eks-us; do
  kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0-rc2/standard-install.yaml

  kubectl create namespace envoy-gateway-system --dry-run=client -oyaml |
    kubectl label --dry-run=client -oyaml --local -f - \
      "elbv2.k8s.aws/pod-readiness-gate-inject=enabled" |
    kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -f -
  helm upgrade --kubeconfig "${cluster}.kubeconfig" --install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
    --version v0.5.0 --namespace envoy-gateway-system --wait --wait-for-jobs

  kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: envoy-gateway
  namespace: envoy-gateway-system
spec:
  gatewayClassName: envoy-gateway
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: "*.envoy.$(tofu -chdir="tofu" output -raw demo_zone_name)"
    allowedRoutes:
      namespaces:
        from: All
EOF

  kubectl --kubeconfig "${cluster}.kubeconfig" wait -n envoy-gateway-system --for=condition=programmed gateways.gateway.networking.k8s.io envoy-gateway
done

for cluster in eks-eu eks-us; do
  until [ -n "$(dig +short "$(kubectl --kubeconfig "${cluster}.kubeconfig" get gateways --namespace envoy-gateway-system envoy-gateway -ojsonpath='{.status.addresses[0].value}')")" ]; do
    true
  done
done

popd &>/dev/null
