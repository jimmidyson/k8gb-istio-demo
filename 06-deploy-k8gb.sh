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
  helm upgrade --kubeconfig "${cluster}.kubeconfig" --install aws-load-balancer-controller https://aws.github.io/eks-charts/aws-load-balancer-controller-1.6.1.tgz \
    --namespace kube-system --wait --wait-for-jobs --values - <<EOF
clusterName: "$(tofu -chdir="tofu" output -raw "cluster_name_${cluster/#eks-/}")"
region: "$(tofu -chdir="tofu" output -raw "cluster_region_${cluster/#eks-/}")"
vpcId: "$(tofu -chdir="tofu" output -raw "cluster_vpc_${cluster/#eks-/}")"
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: "$(tofu -chdir="tofu" output -raw "aws_load_balancer_controller_arn_${cluster/#eks-/}")"
EOF

  kubectl create namespace k8gb-system --dry-run=client -oyaml |
    kubectl label --dry-run=client -oyaml --local -f - \
      "elbv2.k8s.aws/pod-readiness-gate-inject=enabled" |
    kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -f -

  helm upgrade --kubeconfig "${cluster}.kubeconfig" --install k8gb https://www.k8gb.io/charts/k8gb-v0.11.5.tgz \
    --namespace k8gb-system --wait --wait-for-jobs --values - <<EOF
k8gb:
  dnsZone: "k8gb.kubecon-na-2023.$(tofu -chdir="tofu" output -raw "route53_zone_name")"
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

  helm --kubeconfig "${cluster}.kubeconfig" upgrade podinfo https://github.com/isotoma/charts/releases/download/socat-tunneller-0.2.0/socat-tunneller-0.2.0.tgz \
    --install --wait --wait-for-jobs \
    --values - <<EOF
tunnel:
  host: podinfo.default.svc.cluster.local
  port: 9898
fullnameOverride: podinfo
EOF

  kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: podinfo.default.svc.cluster.local
spec:
  hosts:
  - podinfo.default.svc.cluster.local
  - podinfo.k8gb.kubecon-na-2023.$(tofu -chdir="tofu" output -raw "route53_zone_name")
  http:
  - match:
    - uri:
        prefix: "/stateful/"
    - uri:
        exact: "/stateful"
    rewrite:
      uri: "/"
    route:
    - destination:
        host: podinfo-stateful.default.svc.cluster.local
        port:
          number: 9898
  - match:
    - uri:
        prefix: "/"
    route:
    - destination:
        host: podinfo-stateless.default.svc.cluster.local
        port:
          number: 9898
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
      - host: "podinfo.k8gb.kubecon-na-2023.$(tofu -chdir="tofu" output -raw "route53_zone_name")"
        http:
          paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: podinfo
                port:
                  number: 9898
  strategy:
    type: roundRobin
    splitBrainThresholdSeconds: 300
    dnsTtlSeconds: 5
EOF
done

popd &>/dev/null
