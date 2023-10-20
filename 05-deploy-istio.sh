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

  kubectl create namespace istio-system --dry-run=client -oyaml |
    kubectl label --dry-run=client -oyaml --local -f - topology.istio.io/network="network-${cluster/#eks-/}" |
    kubectl --kubeconfig "${cluster}.kubeconfig" apply --server-side -f -

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
  read -ra deployment_names < <(kubectl --kubeconfig "${cluster}.kubeconfig" get deployments -oname)
  kubectl --kubeconfig "${cluster}.kubeconfig" rollout restart "${deployment_names[@]}"

  kubectl create namespace istio-ingress --dry-run=client -oyaml |
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
  - name: default
    hostname: "*.istio.kubecon-na-2023.$(tofu -chdir="tofu" output -raw route53_zone_name)"
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
EOF

  kubectl --kubeconfig "${cluster}.kubeconfig" wait -n istio-ingress --for=condition=programmed gateways.gateway.networking.k8s.io istio-gateway

  GATEWAY_HOSTNAME="$(kubectl --kubeconfig "${cluster}.kubeconfig" get gateways --namespace istio-ingress istio-gateway -ojsonpath='{.spec.listeners[0].hostname}')"
  PODINFO_HOSTNAME="${GATEWAY_HOSTNAME/#\*/podinfo.${cluster/#eks-/}}"
  PODINFO_HOSTNAME_GLOBAL="${GATEWAY_HOSTNAME/#\*/podinfo.global}"

  kubectl apply --kubeconfig "${cluster}.kubeconfig" --server-side -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: podinfo-istio
spec:
  parentRefs:
  - name: istio-gateway
    namespace: istio-ingress
  hostnames:
  - "${PODINFO_HOSTNAME}"
  - "${PODINFO_HOSTNAME_GLOBAL}"
  rules:
  - backendRefs:
    - name: podinfo
      port: 9898
EOF
done

popd &>/dev/null
