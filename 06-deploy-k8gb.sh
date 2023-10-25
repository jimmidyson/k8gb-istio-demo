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

readonly cluster_geos="euus"

for cluster in eks-eu eks-us; do
  helm upgrade --kubeconfig "${cluster}.kubeconfig" --install k8gb https://www.k8gb.io/charts/k8gb-v0.11.5.tgz \
    --namespace k8gb-system --create-namespace --wait --wait-for-jobs --values - <<EOF
k8gb:
  dnsZone: "k8gb.$(tofu -chdir="tofu" output -raw "route53_zone_name")"
  edgeDNSZone: "$(tofu -chdir="tofu" output -raw "route53_zone_name")"
  edgeDNSServers:
    - "169.254.169.253"
  clusterGeoTag: "$(tofu -chdir="tofu" output -raw "cluster_region_${cluster/#eks-/}")"
  extGslbClustersGeoTags: "$(tofu -chdir="tofu" output -raw "cluster_region_${cluster_geos/${cluster/#eks-/}/}")"
  coredns:
    extra_plugins: |
      reload 2s

route53:
  enabled: true
  hostedZoneID: "$(tofu -chdir="tofu" output -raw "route53_zone_id")"
  irsaRole: "$(tofu -chdir="tofu" output -raw "k8gb_role_arn_${cluster/#eks-/}")"

coredns:
  serviceType: LoadBalancer
  service:
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: external
      service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
      service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
      service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold: "2"
      service.beta.kubernetes.io/aws-load-balancer-healthcheck-unhealthy-threshold: "2"
      service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval: "5"
      service.beta.kubernetes.io/aws-load-balancer-healthcheck-timeout: "2"
EOF

  kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -f - <<EOF
apiVersion: k8gb.absa.oss/v1beta1
kind: Gslb
metadata:
  name: podinfo
spec:
  ingress:
    ingressClassName: istio
    rules:
      - host: "podinfo.k8gb.$(tofu -chdir="tofu" output -raw "route53_zone_name")"
        http:
          paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: podinfo
                port:
                  name: http
  strategy:
    type: roundRobin
    splitBrainThresholdSeconds: 300
    dnsTtlSeconds: 30
EOF
done

popd &>/dev/null