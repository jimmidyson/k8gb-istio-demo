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

if [ ! -f root-key.pem ]; then
  openssl genrsa -out root-key.pem 4096
fi
if [ ! -f root-ca.conf ]; then
  cat <<EOF >root-ca.conf
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
if [ ! -f root-cert.csr ]; then
  openssl req -sha256 -new -key root-key.pem -config root-ca.conf -out root-cert.csr
fi
if [ ! -f root-cert.pem ]; then
  openssl x509 -req -sha256 -days 3650 -signkey root-key.pem \
    -extensions req_ext -extfile root-ca.conf \
    -in root-cert.csr -out root-cert.pem
fi

kubectl create namespace istio-system --dry-run=client -oyaml |
  kubectl label --dry-run=client -oyaml --local -f - topology.istio.io/network=network-eu |
  kubectl --kubeconfig eks-eu.kubeconfig apply --server-side -f -
kubectl create namespace istio-system --dry-run=client -oyaml |
  kubectl label --dry-run=client -oyaml --local -f - topology.istio.io/network=network-eu |
  kubectl --kubeconfig eks-us.kubeconfig apply --server-side -f -

for cluster in eks-eu eks-us; do
  if [ ! -f "${cluster}-ca-key.pem" ]; then
    openssl genrsa -out "${cluster}-ca-key.pem" 4096
  fi
  if [ ! -f "${cluster}-intermediate.conf" ]; then
    cat <<EOF >"${cluster}-intermediate.conf"
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
  if [ ! -f "${cluster}-ca-csr.pem" ]; then
    openssl req -sha256 -new -config "${cluster}-intermediate.conf" -key "${cluster}-ca-key.pem" -out "${cluster}-ca-csr.pem"
  fi
  if [ ! -f "${cluster}-ca-cert.pem" ]; then
    openssl x509 -req -sha256 -days 3650 \
      -CA root-cert.pem -CAkey root-key.pem -CAcreateserial \
      -extensions req_ext -extfile "${cluster}-intermediate.conf" \
      -in "${cluster}-ca-csr.pem" -out "${cluster}-ca-cert.pem"
  fi
  if [ ! -f "${cluster}-cert-chain.pem" ]; then
    cat "${cluster}-ca-cert.pem" root-cert.pem >"${cluster}-cert-chain.pem"
  fi

  kubectl create secret generic cacerts --dry-run=client -oyaml \
    --from-file=ca-cert.pem="${cluster}-ca-cert.pem" \
    --from-file=ca-key.pem="${cluster}-ca-key.pem" \
    --from-file=root-cert.pem \
    --from-file=cert-chain.pem="${cluster}-cert-chain.pem" |
    kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -n istio-system -f -
done

istioctl install --kubeconfig eks-eu.kubeconfig -y -f <(
  cat <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  meshConfig:
    accessLogFile: /dev/stdout
  values:
    global:
      meshID: global-mesh
      multiCluster:
        clusterName: eks-eu
      network: network-eu
EOF
)

istioctl install --kubeconfig eks-eu.kubeconfig -y -f <(
  cat <<EOF
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
          topology.istio.io/network: network-eu
        enabled: true
        k8s:
          env:
            # traffic through this gateway should be routed inside the network
            - name: ISTIO_META_REQUESTED_NETWORK_VIEW
              value: network-eu
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
      network: network-eu
EOF
)

cat <<EOF | kubectl --kubeconfig eks-eu.kubeconfig apply --server-side --namespace istio-system -f -
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

istioctl install --kubeconfig eks-us.kubeconfig -y -f <(
  cat <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  meshConfig:
    accessLogFile: /dev/stdout
  values:
    global:
      meshID: global-mesh
      multiCluster:
        clusterName: eks-us
      network: network-us
EOF
)

istioctl install --kubeconfig eks-us.kubeconfig -y -f <(
  cat <<EOF
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
          topology.istio.io/network: network-us
        enabled: true
        k8s:
          env:
            # traffic through this gateway should be routed inside the network
            - name: ISTIO_META_REQUESTED_NETWORK_VIEW
              value: network-us
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
      network: network-us
EOF
)

cat <<EOF | kubectl --kubeconfig eks-us.kubeconfig apply --server-side --namespace istio-system -f -
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

istioctl --kubeconfig eks-eu.kubeconfig create-remote-secret \
  --name=eks-eu |
  kubectl --kubeconfig eks-us.kubeconfig apply --server-side -f -

istioctl --kubeconfig eks-us.kubeconfig create-remote-secret \
  --name=eks-us |
  kubectl --kubeconfig eks-eu.kubeconfig apply --server-side -f -

popd &>/dev/null
