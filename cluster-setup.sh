#!/bin/bash -ex

kind create cluster

istioctl install --set profile=minimal \
 --set "components.egressGateways[0].name=istio-egressgateway" \
 --set "components.egressGateways[0].enabled=true" \
 --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY \
 --set meshConfig.accessLogFile=/dev/stdout

kubectl label namespace default istio-injection=enabled

kubectl apply -f simple-curl-pod.yaml
