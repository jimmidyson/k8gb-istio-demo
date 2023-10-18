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

tofu -chdir="tofu" apply -auto-approve -input=false

aws eks update-kubeconfig \
  --region "$(tofu -chdir="tofu" output -raw cluster_region_eu)" \
  --name "$(tofu -chdir="tofu" output -raw cluster_name_eu)" --kubeconfig "eks-eu.kubeconfig"
aws eks update-kubeconfig \
  --region "$(tofu -chdir="tofu" output -raw cluster_region_us)" \
  --name "$(tofu -chdir="tofu" output -raw cluster_name_us)" --kubeconfig "eks-us.kubeconfig"

kubectl --kubeconfig eks-eu.kubeconfig apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0-rc1/standard-install.yaml
helm upgrade --kubeconfig eks-eu.kubeconfig --install nginx-gateway oci://ghcr.io/nginxinc/charts/nginx-gateway-fabric --version 0.0.0-edge --namespace nginx-gateway --create-namespace --wait --wait-for-jobs

PUBLIC_HOSTNAME_NGINX_EU="$(kubectl --kubeconfig eks-eu.kubeconfig get services -n nginx-gateway nginx-gateway-nginx-gateway-fabric -ojsonpath='{.status.loadBalancer.ingress[0].hostname}')"
readonly PUBLIC_HOSTNAME_NGINX_EU
PUBLIC_IP_NGINX_EU="$(dig +short "${PUBLIC_HOSTNAME_NGINX_EU}")"
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

PUBLIC_HOSTNAME_NGINX_US="$(kubectl --kubeconfig eks-us.kubeconfig get services -n nginx-gateway nginx-gateway-nginx-gateway-fabric -ojsonpath='{.status.loadBalancer.ingress[0].hostname}')"
readonly PUBLIC_HOSTNAME_NGINX_US
PUBLIC_IP_NGINX_US="$(dig +short "${PUBLIC_HOSTNAME_NGINX_US}")"
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

helm upgrade --kubeconfig eks-eu.kubeconfig --install podinfo oci://ghcr.io/stefanprodan/charts/podinfo --namespace default --wait --wait-for-jobs \
  --set-string ui.logo=https://upload.wikimedia.org/wikipedia/commons/b/b7/Flag_of_Europe.svg \
  --set-string ui.message="I'm in Europe!"

helm upgrade --kubeconfig eks-us.kubeconfig --install podinfo oci://ghcr.io/stefanprodan/charts/podinfo --namespace default --wait --wait-for-jobs \
  --set-string ui.logo=https://upload.wikimedia.org/wikipedia/commons/a/a9/Flag_of_the_United_States_%28DoS_ECA_Color_Standard%29.svg \
  --set-string ui.message="I'm in the USA!"

popd &>/dev/null
