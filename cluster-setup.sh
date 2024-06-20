#!/bin/bash -ex

kind create cluster

istioctl install --set profile=minimal \
 --set "components.egressGateways[0].name=istio-egressgateway" \
 --set "components.egressGateways[0].enabled=true" \
 --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY 

 kubectl apply -f example-apps.yaml

 