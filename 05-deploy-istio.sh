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
  kubectl create namespace istio-system --dry-run=client -oyaml |
    kubectl label --dry-run=client -oyaml --local -f - \
      "topology.istio.io/network=network-${cluster/#eks-/}" \
      "elbv2.k8s.aws/pod-readiness-gate-inject=enabled" |
    kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -f -
done

mkdir -p certs
if [ ! -f certs/root-key.pem ]; then
  openssl genrsa -out certs/root-key.pem 4096
fi
if [ ! -f certs/root-ca.conf ]; then
  cat <<EOF >certs/root-ca.conf
[ req ]
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn
[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign
[ req_dn ]
O = Istio
CN = Root CA
EOF
fi
if [ ! -f certs/root-cert.csr ]; then
  openssl req -sha256 -new -key certs/root-key.pem -config certs/root-ca.conf -out certs/root-cert.csr
fi
if [ ! -f certs/root-cert.pem ]; then
  openssl x509 -req -sha256 -days 3650 -signkey certs/root-key.pem \
    -extensions req_ext -extfile certs/root-ca.conf \
    -in certs/root-cert.csr -out certs/root-cert.pem
fi

for cluster in eks-eu eks-us; do
  mkdir -p "certs/${cluster}"
  if [ ! -f "certs/${cluster}/ca-key.pem" ]; then
    openssl genrsa -out "certs/${cluster}/ca-key.pem" 4096
  fi
  if [ ! -f "certs/${cluster}/intermediate.conf" ]; then
    cat <<EOF >"certs/${cluster}/intermediate.conf"
[ req ]
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn
[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign
subjectAltName=@san
[ san ]
DNS.1 = istiod.istio-system.svc
[ req_dn ]
O = Istio
CN = Intermediate CA
L = ${cluster}
EOF
  fi
  if [ ! -f "certs/${cluster}/ca-csr.pem" ]; then
    openssl req -sha256 -new -config "certs/${cluster}/intermediate.conf" -key "certs/${cluster}/ca-key.pem" -out "certs/${cluster}/ca-csr.pem"
  fi
  if [ ! -f "certs/${cluster}/ca-cert.pem" ]; then
    openssl x509 -req -sha256 -days 3650 \
      -CA certs/root-cert.pem -CAkey certs/root-key.pem -CAcreateserial \
      -extensions req_ext -extfile "certs/${cluster}/intermediate.conf" \
      -in "certs/${cluster}/ca-csr.pem" -out "certs/${cluster}/ca-cert.pem"
  fi
  if [ ! -f "certs/${cluster}/cert-chain.pem" ]; then
    cat "certs/${cluster}/ca-cert.pem" certs/root-cert.pem >"certs/${cluster}/cert-chain.pem"
  fi

  kubectl create secret generic cacerts --dry-run=client -oyaml \
    --from-file="certs/${cluster}/ca-cert.pem" \
    --from-file="certs/${cluster}/ca-key.pem" \
    --from-file=certs/root-cert.pem \
    --from-file="certs/${cluster}/cert-chain.pem" |
    kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -n istio-system -f -

  istioctl install --kubeconfig "${cluster}.kubeconfig" -y -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  meshConfig:
    accessLogFile: /dev/stdout
    defaultConfig:
      proxyMetadata:
        # Enable basic DNS proxying
        ISTIO_META_DNS_CAPTURE: "true"
        # Enable automatic address allocation, optional
        ISTIO_META_DNS_AUTO_ALLOCATE: "true"
  values:
    global:
      meshID: global-mesh
      multiCluster:
        clusterName: ${cluster}
      network: network-${cluster/#eks-/}
EOF

  istioctl install --kubeconfig "${cluster}.kubeconfig" -y -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: eastwest
spec:
  profile: empty
  components:
    ingressGateways:
      - name: istio-eastwestgateway
        label:
          istio: eastwestgateway
          app: istio-eastwestgateway
          topology.istio.io/network: network-${cluster/#eks-/}
        enabled: true
        k8s:
          env:
            # traffic through this gateway should be routed inside the network
            - name: ISTIO_META_REQUESTED_NETWORK_VIEW
              value: network-${cluster/#eks-/}
          service:
            ports:
              - name: status-port
                port: 15021
                targetPort: 15021
              - name: tls
                port: 15443
                targetPort: 15443
              - name: tls-istiod
                port: 15012
                targetPort: 15012
              - name: tls-webhook
                port: 15017
                targetPort: 15017
  values:
    gateways:
      istio-ingressgateway:
        injectionTemplate: gateway
    global:
      network: network-${cluster/#eks-/}
EOF

  kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side --namespace istio-system -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: cross-network-gateway
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        number: 15443
        name: tls
        protocol: TLS
      tls:
        mode: AUTO_PASSTHROUGH
      hosts:
        - "*.local"
EOF

  case "${cluster}" in
  eks-eu)
    istioctl --kubeconfig "${cluster}.kubeconfig" create-remote-secret --name="${cluster}" |
      kubectl --kubeconfig eks-us.kubeconfig apply --server-side -f -
    ;;
  eks-us)
    istioctl --kubeconfig "${cluster}.kubeconfig" create-remote-secret --name="${cluster}" |
      kubectl --kubeconfig eks-eu.kubeconfig apply --server-side -f -
    ;;
  esac

  kubectl --kubeconfig "${cluster}.kubeconfig" label namespace default istio-injection=enabled --overwrite
  readarray -t deployment_names < <(kubectl --kubeconfig "${cluster}.kubeconfig" get deployments -oname)
  kubectl --kubeconfig "${cluster}.kubeconfig" rollout restart "${deployment_names[@]}"

  kubectl create namespace istio-ingress --dry-run=client -oyaml |
    kubectl label --dry-run=client -oyaml --local -f - \
      "elbv2.k8s.aws/pod-readiness-gate-inject=enabled" |
    kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -f -

  kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: istio-gateway
  namespace: istio-ingress
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: "*.istio.$(tofu -chdir="tofu" output -raw demo_zone_name)"
    allowedRoutes:
      namespaces:
        from: All
EOF

  kubectl --kubeconfig "${cluster}.kubeconfig" wait -n istio-ingress --for=condition=programmed gateways.gateway.networking.k8s.io istio-gateway

  GATEWAY_HOSTNAME="$(kubectl --kubeconfig "${cluster}.kubeconfig" get gateways --namespace istio-ingress istio-gateway -ojsonpath='{.spec.listeners[0].hostname}')"
  PODINFO_HOSTNAME="${GATEWAY_HOSTNAME/#\*/podinfo.${cluster/#eks-/}}"
  PODINFO_HOSTNAME_GLOBAL="${GATEWAY_HOSTNAME/#\*/podinfo}"

  kubectl apply --kubeconfig "${cluster}.kubeconfig" --server-side -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: podinfo-istio
spec:
  parentRefs:
  - name: istio-gateway
    namespace: istio-ingress
    sectionName: http
  hostnames:
  - "${PODINFO_HOSTNAME}"
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
    - name: podinfo-stateless
      port: 9898
EOF

  kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: istio
spec:
  controller: istio.io/ingress-controller
EOF

  kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: podinfo
spec:
  host: podinfo.default.svc.cluster.local
  trafficPolicy:
    connectionPool:
      http:
        maxRequestsPerConnection: 1
    loadBalancer:
      simple: ROUND_ROBIN
      localityLbSetting:
        enabled: true
        failover:
          - from: $(tofu -chdir="tofu" output -raw "cluster_region_eu")
            to: $(tofu -chdir="tofu" output -raw "cluster_region_us")
          - from: $(tofu -chdir="tofu" output -raw "cluster_region_us")
            to: $(tofu -chdir="tofu" output -raw "cluster_region_eu")
    outlierDetection:
      consecutive5xxErrors: 1
      interval: 1s
      baseEjectionTime: 1m
EOF

  kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: podinfo-stateless
spec:
  host: podinfo-stateless.default.svc.cluster.local
  trafficPolicy:
    connectionPool:
      http:
        maxRequestsPerConnection: 1
    loadBalancer:
      simple: ROUND_ROBIN
      localityLbSetting:
        enabled: true
        failover:
          - from: $(tofu -chdir="tofu" output -raw "cluster_region_eu")
            to: $(tofu -chdir="tofu" output -raw "cluster_region_us")
          - from: $(tofu -chdir="tofu" output -raw "cluster_region_us")
            to: $(tofu -chdir="tofu" output -raw "cluster_region_eu")
    outlierDetection:
      consecutive5xxErrors: 1
      interval: 1s
      baseEjectionTime: 1m
EOF
done

GATEWAY_HOSTNAME="$(kubectl --kubeconfig eks-eu.kubeconfig get gateways --namespace istio-ingress istio-gateway -ojsonpath='{.spec.listeners[0].hostname}')"
readonly GATEWAY_HOSTNAME
readonly PODINFO_HOSTNAME_EU="${GATEWAY_HOSTNAME/#\*/podinfo.eu}"
readonly PODINFO_HOSTNAME_US="${GATEWAY_HOSTNAME/#\*/podinfo.us}"
readonly PODINFO_HOSTNAME_GLOBAL="${GATEWAY_HOSTNAME/#\*/podinfo}"

PUBLIC_HOSTNAME_EU="$(kubectl --kubeconfig eks-eu.kubeconfig get gateways --namespace istio-ingress istio-gateway -ojsonpath='{.status.addresses[0].value}')"
readonly PUBLIC_HOSTNAME_EU
until [ -n "$(dig +short "${PUBLIC_HOSTNAME_EU}")" ]; do
  true
done
readarray -t PUBLIC_IPS_EU < <(dig +short "${PUBLIC_HOSTNAME_EU}")
readonly PUBLIC_IPS_EU

PUBLIC_HOSTNAME_US="$(kubectl --kubeconfig eks-us.kubeconfig get gateways --namespace istio-ingress istio-gateway -ojsonpath='{.status.addresses[0].value}')"
readonly PUBLIC_HOSTNAME_US
until [ -n "$(dig +short "${PUBLIC_HOSTNAME_US}")" ]; do
  true
done
readarray -t PUBLIC_IPS_US < <(dig +short "${PUBLIC_HOSTNAME_US}")
readonly PUBLIC_IPS_US

CHANGE_RESOURCE_RECORD_ID="$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$(tofu -chdir="tofu" output -raw demo_zone_id)" \
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

for hostname in "${PODINFO_HOSTNAME_EU}" "${PODINFO_HOSTNAME_US}" "${PODINFO_HOSTNAME_GLOBAL}"; do
  until [ -n "$(dig +short "${hostname}")" ]; do
    true
  done
done

echo
echo 'Testing EU...'
for _ in {1..10}; do curl -fsS "http://${PODINFO_HOSTNAME_EU}" | gojq '.message'; done
echo
echo 'Testing US...'
for _ in {1..10}; do curl -fsS "http://${PODINFO_HOSTNAME_US}" | gojq '.message'; done
echo
echo 'Testing global...'
for _ in {1..10}; do curl -fsS "http://${PODINFO_HOSTNAME_GLOBAL}" | gojq '.message'; done

echo
echo 'Testing EU stateful...'
for _ in {1..10}; do curl -fsS "http://${PODINFO_HOSTNAME_EU}/stateful" | gojq '.message'; done
echo
echo 'Testing US stateful...'
for _ in {1..10}; do curl -fsS "http://${PODINFO_HOSTNAME_US}/stateful" | gojq '.message'; done
echo
echo 'Testing global stateful...'
for _ in {1..10}; do curl -fsS "http://${PODINFO_HOSTNAME_GLOBAL}/stateful" | gojq '.message'; done

popd &>/dev/null
