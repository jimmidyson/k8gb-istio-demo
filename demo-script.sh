#!/usr/bin/env bash

# First we'll look at a traditional ingress.

# Let's hit the global endpoint and see what we get returned.
for _ in {1..10}; do curl -fsS podinfo.envoy.kubecon-na-2023.dkp2demo.com | gojq .message; done

# Back to the slides...
: test "${PRESENTATION_MODE}" == "1" && sleep 5

# What happens in case of a failure? To simulate that, let's scale down the deployment.
kubectl --kubeconfig eks-eu.kubeconfig scale deployments podinfo-stateless --replicas=0

# And hit the global endpoint again.
for _ in {1..10}; do curl -fsS podinfo.envoy.kubecon-na-2023.dkp2demo.com | gojq .message; done

# Scaling it back up - it does recover!
kubectl --kubeconfig eks-eu.kubeconfig scale deployments podinfo-stateless --replicas=1

for _ in {1..10}; do curl -fsS podinfo.envoy.kubecon-na-2023.dkp2demo.com | gojq .message; done

# Back to the slides...
: test "${PRESENTATION_MODE}" == "1" && sleep 5

# What happens when we hit a stateful endpoint only deployed in one region?
for _ in {1..10}; do curl -fsS podinfo.envoy.kubecon-na-2023.dkp2demo.com/stateful | gojq .message; done

# Back to the slides...
: test "${PRESENTATION_MODE}" == "1" && sleep 5

# Now with istio...

# Let's hit the istio ingress global endpoint.
for _ in {1..10}; do curl -fsS podinfo.istio.kubecon-na-2023.dkp2demo.com | gojq .message; done

# Again, we want to see what happens in case of a failure so to simulate that, let's scale down the deployment.
kubectl --kubeconfig eks-eu.kubeconfig scale deployments podinfo-stateless --replicas=0

# Let's hit the istio ingress global endpoint.
for _ in {1..10}; do curl -fsS podinfo.istio.kubecon-na-2023.dkp2demo.com | gojq .message; done

# And scale it back up to show it does recover and returns to load balancing.
kubectl --kubeconfig eks-eu.kubeconfig scale deployments podinfo-stateless --replicas=1

for _ in {1..10}; do curl -fsS podinfo.istio.kubecon-na-2023.dkp2demo.com | gojq .message; done

# And what about stateful workloads?
for _ in {1..10}; do curl -fsS podinfo.istio.kubecon-na-2023.dkp2demo.com/stateful | gojq .message; done

# So why do we need anything more?
# What happens if we lose a region completely, including ingress?
# Let's scale down the istio ingress to see.
kubectl --kubeconfig eks-eu.kubeconfig scale deployments -n istio-ingress istio-gateway-istio --replicas=0

# Wait for a short while...
: sleep 10

for _ in {1..10}; do curl -fsSm 1 podinfo.istio.kubecon-na-2023.dkp2demo.com | gojq .message; done

# And scale it back up (to make the demo re-runnable!).
kubectl --kubeconfig eks-eu.kubeconfig scale deployments -n istio-ingress istio-gateway-istio --replicas=1

# So can we do better?

# We can! With k8gb added to the mix.

# Back to the slides...
: test "${PRESENTATION_MODE}" == "1" && sleep 5

# First let's look at gslb resource.
kubectl neat get -- --kubeconfig eks-eu.kubeconfig gslb podinfo

# And the dnsendpoints for zone delegation.
kubectl neat get -- --kubeconfig eks-eu.kubeconfig dnsendpoints -n k8gb-system k8gb-ns-extdns

kubectl neat get -- --kubeconfig eks-us.kubeconfig dnsendpoints -n k8gb-system k8gb-ns-extdns

# And the dnsendpoints for the actual service endpoints.
kubectl neat get -- --kubeconfig eks-eu.kubeconfig dnsendpoints podinfo

kubectl neat get -- --kubeconfig eks-us.kubeconfig dnsendpoints podinfo

# With the load-balancing strategy of roundRobin we have the existing behaviour.
aws ssm start-session --target="$(kubectl neat get -ojson -- --kubeconfig eks-eu.kubeconfig nodes | gojq -r '.items[0].spec.providerID | scan("i-.*$")')" --region=eu-west-1 --document-name 'AWS-StartNonInteractiveCommand' --parameters '{"command": ["bash -ec \"for _ in {1..10}; do curl -fsS http://podinfo.k8gb.kubecon-na-2023.dkp2demo.com | jq .message; done\""]}'

# Other load balancing strategies available:
#
# Round-robin
# Weighted round-robin
# Failover
# Geoip
#
# Let's try out the geoip strategy by changing the strategy in the gslb resource.
kubectl --kubeconfig eks-eu.kubeconfig patch gslb podinfo --type=json -p '[{"op": "add", "path": "/spec/strategy/type", "value": "geoip" }]'

kubectl --kubeconfig eks-us.kubeconfig patch gslb podinfo --type=json -p '[{"op": "add", "path": "/spec/strategy/type", "value": "geoip" }]'

# Notice how the calls from different client regions send requests to different servers, even for the same address.
# First for a client in Europe.
aws ssm start-session --target="$(kubectl neat get -ojson -- --kubeconfig eks-eu.kubeconfig nodes | gojq -r '.items[0].spec.providerID | scan("i-.*$")')" --region=eu-west-1 --document-name 'AWS-StartNonInteractiveCommand' --parameters '{"command": ["bash -ec \"for _ in {1..10}; do curl -fsS http://podinfo.k8gb.kubecon-na-2023.dkp2demo.com | jq .message; done\""]}'

# And then for a client in the USA.
aws ssm start-session --target="$(kubectl neat get -ojson -- --kubeconfig eks-us.kubeconfig nodes | gojq -r '.items[0].spec.providerID | scan("i-.*$")')" --region=us-west-2 --document-name 'AWS-StartNonInteractiveCommand' --parameters '{"command": ["bash -ec \"for _ in {1..10}; do curl -fsS http://podinfo.k8gb.kubecon-na-2023.dkp2demo.com | jq .message; done\""]}'

# It does this by returning different DNS records depending on the client's location.
# In Europe...
aws ssm start-session --target="$(kubectl neat get -ojson -- --kubeconfig eks-eu.kubeconfig nodes | gojq -r '.items[0].spec.providerID | scan("i-.*$")')" --region=eu-west-1 --document-name 'AWS-StartNonInteractiveCommand' --parameters '{"command": ["dig +short podinfo.k8gb.kubecon-na-2023.dkp2demo.com"]}'

# And in the USA.
aws ssm start-session --target="$(kubectl neat get -ojson -- --kubeconfig eks-us.kubeconfig nodes | gojq -r '.items[0].spec.providerID | scan("i-.*$")')" --region=us-west-2 --document-name 'AWS-StartNonInteractiveCommand' --parameters '{"command": ["dig +short podinfo.k8gb.kubecon-na-2023.dkp2demo.com"]}'

# Resetting the load-balancing strategy (again to make the demo re-runnable!).
kubectl --kubeconfig eks-eu.kubeconfig patch gslb podinfo --type=json -p '[{"op": "add", "path": "/spec/strategy/type", "value": "roundRobin" }]'

kubectl --kubeconfig eks-us.kubeconfig patch gslb podinfo --type=json -p '[{"op": "add", "path": "/spec/strategy/type", "value": "roundRobin" }]'

# That's all folks!

: test "${PRESENTATION_MODE}" == "1" && sleep 5
