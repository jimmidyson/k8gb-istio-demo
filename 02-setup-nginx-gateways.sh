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

kubectl --kubeconfig eks-eu.kubeconfig apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0-rc1/standard-install.yaml
helm upgrade --kubeconfig eks-eu.kubeconfig --install nginx-gateway oci://ghcr.io/nginxinc/charts/nginx-gateway-fabric --version 0.0.0-edge --namespace nginx-gateway --create-namespace --wait --wait-for-jobs

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

cat <<EOF | kubectl --kubeconfig eks-eu.kubeconfig apply --server-side -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: nginx-gateway
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: "*.nginx.${PUBLIC_IP_NGINX_EU}.sslip.io"
EOF

kubectl --kubeconfig eks-us.kubeconfig apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0-rc1/standard-install.yaml
helm upgrade --kubeconfig eks-us.kubeconfig --install nginx-gateway oci://ghcr.io/nginxinc/charts/nginx-gateway-fabric --version 0.0.0-edge --namespace nginx-gateway --create-namespace --wait --wait-for-jobs

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

cat <<EOF | kubectl --kubeconfig eks-us.kubeconfig apply --server-side -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: nginx-gateway
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: "*.nginx.${PUBLIC_IP_NGINX_US}.sslip.io"
EOF

popd &>/dev/null
