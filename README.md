# Egress Gateway Examples

## Background on Istio resources

1. ServiceEntry: An Istio custom resource that adds additional entries to the internal service registry that Istio maintains. This is used to enable access to external services not in the mesh.

2. Gateway: An Istio custom resource that configures a load balancer for HTTP/TCP traffic. This can be used to manage ingress traffic coming into the mesh and egress traffic leaving the mesh.

3. VirtualService: An Istio custom resource that defines the rules for how requests for a service are routed within the service mesh (traffic spliting, request routing, retries, timeouts, fault injections, etc.)

4. DestinationRule: An Istio custom resource that defines policies that apply to traffic intended for a service _after_ routing has occurred (load balancing, connection pool settings, outlier detection, tls settings).

## Environment setup

1. Create a kind cluster

```shell
kind create cluster
```

2. Install Istio

```shell
istioctl install --set profile=minimal \
 --set "components.egressGateways[0].name=istio-egressgateway" \
 --set "components.egressGateways[0].enabled=true" \
 --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY \
 --set meshConfig.accessLogFile=/dev/stdout
```

Note: To allow all traffic (not restricted to the service registry) you can use `--set "meshConfig.outboundTrafficPolicy.mode=ALLOW_ANY"`. The drawback here is you lose Istio monitoring and control for traffic to external services. 

3. Inject the default namespace

```shell
kubectl label namespace default istio-injection=enabled
```

4. Add a curl pod with an Istio sidecar that we'll send requests from 

```shell
kubectl apply -f simple-curl-pod.yaml
```

## ServiceEntry no Egress Gateway

Because we have Istio installed with `meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY` we can define a ServiceEntry and still have Istio traffic control (VirtualServices, etc.) and monitoring features. 

1. Create a ServiceEntry to an external service (http://httpbin.org/)

```yaml
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: ServiceEntry
metadata:
  name: httpbin
spec:
  hosts:
  - httpbin.org
  ports:
  - number: 80
    name: http-port
    protocol: HTTP
  - number: 443
    name: https-port
    protocol: HTTPS
  resolution: DNS
EOF
```

2. Send an HTTP request with just the ServiceEntry

```shell
kubectl exec curl -c curl -- curl -sS http://httpbin.org/headers
```

And see the `X-Envoy-Peer-Metadata-Id` is set to the envoy sidecar id: 

```json
{
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    "User-Agent": "curl/7.83.1-DEV",
    "X-Amzn-Trace-Id": "Root=1-6675d2e5-5a8cf34f1b08829c1201f79f",
    "X-Envoy-Attempt-Count": "1",
    "X-Envoy-Decorator-Operation": "httpbin.org:80/*",
    "X-Envoy-Peer-Metadata": "ChgKDkFQUF9DT05UQUlORVJTEgYaBGN1cmwKGgoKQ0xVU1RFUl9JRBIMGgpLdWJlcm5ldGVzChwKDElOU1RBTkNFX0lQUxIMGgoxMC4yNDQuMC43ChkKDUlTVElPX1ZFUlNJT04SCBoGMS4yMi4xCqwBCgZMQUJFTFMSoQEqngEKDQoDYXBwEgYaBGN1cmwKJAoZc2VjdXJpdHkuaXN0aW8uaW8vdGxzTW9kZRIHGgVpc3RpbwopCh9zZXJ2aWNlLmlzdGlvLmlvL2Nhbm9uaWNhbC1uYW1lEgYaBGN1cmwKKwojc2VydmljZS5pc3Rpby5pby9jYW5vbmljYWwtcmV2aXNpb24SBBoCdjEKDwoHdmVyc2lvbhIEGgJ2MQoaCgdNRVNIX0lEEg8aDWNsdXN0ZXIubG9jYWwKDgoETkFNRRIGGgRjdXJsChYKCU5BTUVTUEFDRRIJGgdkZWZhdWx0CjwKBU9XTkVSEjMaMWt1YmVybmV0ZXM6Ly9hcGlzL3YxL25hbWVzcGFjZXMvZGVmYXVsdC9wb2RzL2N1cmwKFwoNV09SS0xPQURfTkFNRRIGGgRjdXJs",
    "X-Envoy-Peer-Metadata-Id": "sidecar~10.244.0.7~curl.default~default.svc.cluster.local"
  }
}
```

You could also use a DestinationRule to configure TLS origination at the sidecar.

Note: This configuration example does not enable secure egress traffic control in Istio. A malicious application can bypass the Istio sidecar proxy and access any external service without Istio control. To implement egress traffic control in a more secure way, you must direct egress traffic through an egress gateway...

## Basic Egress Gateway Setup

### HTTP through Egress Gateway (still insecure)

1. Create a Gateway resource using the istio-egressgateway Service's http2 port
and a VirtualService which directs traffic to `httpbin.org:80` from within the mesh to route through the Gateway

```yaml
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: istio-egressgateway
spec:
  selector:
    istio: egressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - httpbin.org
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: direct-httpbin-through-egress-gateway
spec:
  hosts:
  - httpbin.org
  gateways:
  - istio-egressgateway
  - mesh
  http:
  - match:
    - gateways:
      - mesh
      port: 80
    route:
    - destination:
        host: istio-egressgateway.istio-system.svc.cluster.local
        port:
          number: 80
  - match:
    - gateways:
      - istio-egressgateway
      port: 80
    route:
    - destination:
        host: httpbin.org
        port:
          number: 80
EOF
```

2. Send an http request as before:

```shell
kubectl exec curl -c curl -- curl -sS http://httpbin.org/headers
```

```json
{
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    "User-Agent": "curl/7.83.1-DEV",
    "X-Amzn-Trace-Id": "Root=1-6675d350-6d4cd9361993604b163b3e07",
    "X-Envoy-Attempt-Count": "1",
    "X-Envoy-Decorator-Operation": "httpbin.org:80/*",
    "X-Envoy-Internal": "true",
    "X-Envoy-Peer-Metadata": "ChoKCkNMVVNURVJfSUQSDBoKS3ViZXJuZXRlcwocCgxJTlNUQU5DRV9JUFMSDBoKMTAuMjQ0LjAuNgoZCg1JU1RJT19WRVJTSU9OEggaBjEuMjIuMQqYAwoGTEFCRUxTEo0DKooDChwKA2FwcBIVGhNpc3Rpby1lZ3Jlc3NnYXRld2F5ChMKBWNoYXJ0EgoaCGdhdGV3YXlzChQKCGhlcml0YWdlEggaBlRpbGxlcgo2CilpbnN0YWxsLm9wZXJhdG9yLmlzdGlvLmlvL293bmluZy1yZXNvdXJjZRIJGgd1bmtub3duChgKBWlzdGlvEg8aDWVncmVzc2dhdGV3YXkKGQoMaXN0aW8uaW8vcmV2EgkaB2RlZmF1bHQKLwobb3BlcmF0b3IuaXN0aW8uaW8vY29tcG9uZW50EhAaDkVncmVzc0dhdGV3YXlzChIKB3JlbGVhc2USBxoFaXN0aW8KOAofc2VydmljZS5pc3Rpby5pby9jYW5vbmljYWwtbmFtZRIVGhNpc3Rpby1lZ3Jlc3NnYXRld2F5Ci8KI3NlcnZpY2UuaXN0aW8uaW8vY2Fub25pY2FsLXJldmlzaW9uEggaBmxhdGVzdAoiChdzaWRlY2FyLmlzdGlvLmlvL2luamVjdBIHGgVmYWxzZQoaCgdNRVNIX0lEEg8aDWNsdXN0ZXIubG9jYWwKLgoETkFNRRImGiRpc3Rpby1lZ3Jlc3NnYXRld2F5LTc1YzU0NTdjNTYtaHRwdnoKGwoJTkFNRVNQQUNFEg4aDGlzdGlvLXN5c3RlbQpcCgVPV05FUhJTGlFrdWJlcm5ldGVzOi8vYXBpcy9hcHBzL3YxL25hbWVzcGFjZXMvaXN0aW8tc3lzdGVtL2RlcGxveW1lbnRzL2lzdGlvLWVncmVzc2dhdGV3YXkKJgoNV09SS0xPQURfTkFNRRIVGhNpc3Rpby1lZ3Jlc3NnYXRld2F5",
    "X-Envoy-Peer-Metadata-Id": "router~10.244.0.6~istio-egressgateway-75c5457c56-htpvz.istio-system~istio-system.svc.cluster.local"
  }
}
```

Notice now the `X-Envoy-Peer-Metadata-Id` has the egressgateway id. 

3. Check that the request went through the egress gateway. 

```shell
kubectl logs -l istio=egressgateway -c istio-proxy -n istio-system | tail
```

```
[2024-06-21T19:24:00.453Z] "GET /headers HTTP/2" 200 - via_upstream - "-" 0 1450 57 57 "10.244.0.7" "curl/7.83.1-DEV" "51ed62d9-1da8-4250-9923-df406ca9fd57" "httpbin.org" "3.213.1.197:80" outbound|80||httpbin.org 10.244.0.6:41144 10.244.0.6:8080 10.244.0.7:55490 - -
```

This shows up because when we installed Istio, we included this config to enable the access logs to be output:
```shell
 --set meshConfig.accessLogFile=/dev/stdout
```


### HTTPS through Egress Gateway, with TLS Origination at the Gateway

1. Modify the VirtualService to send requests to httpbin.org on the HTTPS port and
add a DestinationRule to originate the HTTPS request:

```yaml
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: direct-httpbin-through-egress-gateway
spec:
  hosts:
  - httpbin.org
  gateways:
  - istio-egressgateway
  - mesh
  http:
  - match:
    - gateways:
      - mesh
      port: 80
    route:
    - destination:
        host: istio-egressgateway.istio-system.svc.cluster.local
        port:
          number: 80
  - match:
    - gateways:
      - istio-egressgateway
      port: 80
    route:
    - destination:
        host: httpbin.org
        port:
          number: 443 # now uses HTTPS port
---
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: originate-tls-for-httpbin
spec:
  host: httpbin.org
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: SIMPLE # initiates HTTPS for connections to httpbin.org
EOF
```

2. Send the http request to httpbin

```shell
kubectl exec curl -c curl -- curl -sS http://httpbin.org/headers
```
```json
{
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    "User-Agent": "curl/7.83.1-DEV",
    "X-Amzn-Trace-Id": "Root=1-6675d568-566cac51199005a375004a53",
    "X-Envoy-Attempt-Count": "1",
    "X-Envoy-Decorator-Operation": "httpbin.org:443/*",
    "X-Envoy-Internal": "true",
    "X-Envoy-Peer-Metadata": "ChoKCkNMVVNURVJfSUQSDBoKS3ViZXJuZXRlcwocCgxJTlNUQU5DRV9JUFMSDBoKMTAuMjQ0LjAuNgoZCg1JU1RJT19WRVJTSU9OEggaBjEuMjIuMQqYAwoGTEFCRUxTEo0DKooDChwKA2FwcBIVGhNpc3Rpby1lZ3Jlc3NnYXRld2F5ChMKBWNoYXJ0EgoaCGdhdGV3YXlzChQKCGhlcml0YWdlEggaBlRpbGxlcgo2CilpbnN0YWxsLm9wZXJhdG9yLmlzdGlvLmlvL293bmluZy1yZXNvdXJjZRIJGgd1bmtub3duChgKBWlzdGlvEg8aDWVncmVzc2dhdGV3YXkKGQoMaXN0aW8uaW8vcmV2EgkaB2RlZmF1bHQKLwobb3BlcmF0b3IuaXN0aW8uaW8vY29tcG9uZW50EhAaDkVncmVzc0dhdGV3YXlzChIKB3JlbGVhc2USBxoFaXN0aW8KOAofc2VydmljZS5pc3Rpby5pby9jYW5vbmljYWwtbmFtZRIVGhNpc3Rpby1lZ3Jlc3NnYXRld2F5Ci8KI3NlcnZpY2UuaXN0aW8uaW8vY2Fub25pY2FsLXJldmlzaW9uEggaBmxhdGVzdAoiChdzaWRlY2FyLmlzdGlvLmlvL2luamVjdBIHGgVmYWxzZQoaCgdNRVNIX0lEEg8aDWNsdXN0ZXIubG9jYWwKLgoETkFNRRImGiRpc3Rpby1lZ3Jlc3NnYXRld2F5LTc1YzU0NTdjNTYtaHRwdnoKGwoJTkFNRVNQQUNFEg4aDGlzdGlvLXN5c3RlbQpcCgVPV05FUhJTGlFrdWJlcm5ldGVzOi8vYXBpcy9hcHBzL3YxL25hbWVzcGFjZXMvaXN0aW8tc3lzdGVtL2RlcGxveW1lbnRzL2lzdGlvLWVncmVzc2dhdGV3YXkKJgoNV09SS0xPQURfTkFNRRIVGhNpc3Rpby1lZ3Jlc3NnYXRld2F5",
    "X-Envoy-Peer-Metadata-Id": "router~10.244.0.6~istio-egressgateway-75c5457c56-htpvz.istio-system~istio-system.svc.cluster.local"
  }
}
```

Notice that although we sent an HTTP request, now the `X-Envoy-Decorator-Operation` has httpbin.org's HTTPS port 443; the gateway is initializing an HTTPS request.

3. The egress gateway logs will confirm the same thing, showing `outbound|443||httpbin.org`.
```shell
kubectl logs -l istio=egressgateway -c istio-proxy -n istio-system | tail
```

```shell
[2024-06-21T19:32:56.681Z] "GET /headers HTTP/2" 200 - via_upstream - "-" 0 1451 111 111 "10.244.0.7" "curl/7.83.1-DEV" "1f00a5df-5e92-4753-8c52-248de5c3d73a" "httpbin.org" "3.213.1.197:443" outbound|443||httpbin.org 10.244.0.6:57676 10.244.0.6:8080 10.244.0.7:34850 - -
```

### HTTPS through Egress Gateway, with TLS Origination at the Gateway and mTLS Between the Sidecar and the Gateway

Now let's ensure the requests use mTLS within our mesh.

1. Let's modify our Gateway to use the istio-egressgateway Service's https port and to expect mTLS connections from the sidecar.
We'll also need to add a new DestinationRule such that the sidecar's requests sent to the Gateway use mTLS.
Lastly, we'll modify the VirtualService to use the new Gateway port:

```yaml
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: istio-egressgateway
spec:
  selector:
    istio: egressgateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    hosts:
    - httpbin.org
    tls:
      mode: ISTIO_MUTUAL
---
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: egressgateway-for-httpbin
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: ISTIO_MUTUAL
        sni: httpbin.org
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: direct-httpbin-through-egress-gateway
spec:
  hosts:
  - httpbin.org
  gateways:
  - istio-egressgateway
  - mesh
  http:
  - match:
    - gateways:
      - mesh
      port: 80
    route:
    - destination:
        host: istio-egressgateway.istio-system.svc.cluster.local
        port:
          number: 443 # new Gateway port
  - match:
    - gateways:
      - istio-egressgateway
      port: 443
    route:
    - destination:
        host: httpbin.org
        port:
          number: 443 # new Gateway port
EOF
```

2. Send the http request as usual

```shell
kubectl exec curl -c curl -- curl -sS http://httpbin.org/headers
```
```json
{
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    "User-Agent": "curl/7.83.1-DEV",
    "X-Amzn-Trace-Id": "Root=1-6675d989-5e57f58417d2719545a04c90",
    "X-Envoy-Attempt-Count": "1",
    "X-Envoy-Decorator-Operation": "httpbin.org:443/*",
    "X-Envoy-Internal": "true",
    "X-Envoy-Peer-Metadata": "ChoKCkNMVVNURVJfSUQSDBoKS3ViZXJuZXRlcwocCgxJTlNUQU5DRV9JUFMSDBoKMTAuMjQ0LjAuNgoZCg1JU1RJT19WRVJTSU9OEggaBjEuMjIuMQqYAwoGTEFCRUxTEo0DKooDChwKA2FwcBIVGhNpc3Rpby1lZ3Jlc3NnYXRld2F5ChMKBWNoYXJ0EgoaCGdhdGV3YXlzChQKCGhlcml0YWdlEggaBlRpbGxlcgo2CilpbnN0YWxsLm9wZXJhdG9yLmlzdGlvLmlvL293bmluZy1yZXNvdXJjZRIJGgd1bmtub3duChgKBWlzdGlvEg8aDWVncmVzc2dhdGV3YXkKGQoMaXN0aW8uaW8vcmV2EgkaB2RlZmF1bHQKLwobb3BlcmF0b3IuaXN0aW8uaW8vY29tcG9uZW50EhAaDkVncmVzc0dhdGV3YXlzChIKB3JlbGVhc2USBxoFaXN0aW8KOAofc2VydmljZS5pc3Rpby5pby9jYW5vbmljYWwtbmFtZRIVGhNpc3Rpby1lZ3Jlc3NnYXRld2F5Ci8KI3NlcnZpY2UuaXN0aW8uaW8vY2Fub25pY2FsLXJldmlzaW9uEggaBmxhdGVzdAoiChdzaWRlY2FyLmlzdGlvLmlvL2luamVjdBIHGgVmYWxzZQoaCgdNRVNIX0lEEg8aDWNsdXN0ZXIubG9jYWwKLgoETkFNRRImGiRpc3Rpby1lZ3Jlc3NnYXRld2F5LTc1YzU0NTdjNTYtaHRwdnoKGwoJTkFNRVNQQUNFEg4aDGlzdGlvLXN5c3RlbQpcCgVPV05FUhJTGlFrdWJlcm5ldGVzOi8vYXBpcy9hcHBzL3YxL25hbWVzcGFjZXMvaXN0aW8tc3lzdGVtL2RlcGxveW1lbnRzL2lzdGlvLWVncmVzc2dhdGV3YXkKJgoNV09SS0xPQURfTkFNRRIVGhNpc3Rpby1lZ3Jlc3NnYXRld2F5",
    "X-Envoy-Peer-Metadata-Id": "router~10.244.0.6~istio-egressgateway-75c5457c56-htpvz.istio-system~istio-system.svc.cluster.local",
    "X-Forwarded-Client-Cert": "By=spiffe://cluster.local/ns/istio-system/sa/istio-egressgateway-service-account;Hash=b21b1cb5b1a2f41340db0509416c2696583ee01cbc1d2eab03c751de6fa919ca;Cert=\"-----BEGIN%20CERTIFICATE-----%0AMIIDQTCCAimgAwIBAgIRAPzFQCbCkEgxE6EDj%2Fpe6Q8wDQYJKoZIhvcNAQELBQAw%0AGDEWMBQGA1UEChMNY2x1c3Rlci5sb2NhbDAeFw0yNDA2MjExOTE5NTFaFw0yNDA2%0AMjIxOTIxNTFaMAAwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDAgVN0%0AK5kAlS0R8i%2FLmk7sjgYsG%2BOnGY0ROePILtRfJ2WIfckAc7H85fuzT9RGfwj%2FYKXR%0AnlsfU%2FxDSwy9yzku%2BBPVeVIVatREL4Z7O84yOs08XLg5qSXC7%2FEF2F9SprutAFEc%0ARRudA2akNWg3qS8y%2BXy3DB7qyrZCuLMdw5nD3AhNNKO3IaCsobvlk0hBitaaIdcQ%0A1fM8JAlUvyyfyDonJbh1LdJAf5niz%2Bfoy8l6nBiiCziepEQPRPy5Oo1lmT9xaZ%2Fk%0ANa8ttHgkPJ3XgDNfGZ35rE%2BORl6dLPkMtH6cIfeHNCe2Y4IkOqQhr9U3iBQ3e%2BNz%0AXZKCOojgp8QvfalXAgMBAAGjgZ0wgZowDgYDVR0PAQH%2FBAQDAgWgMB0GA1UdJQQW%0AMBQGCCsGAQUFBwMBBggrBgEFBQcDAjAMBgNVHRMBAf8EAjAAMB8GA1UdIwQYMBaA%0AFHUIC2J4JbEEqfaRQUobgn%2FKRRa4MDoGA1UdEQEB%2FwQwMC6GLHNwaWZmZTovL2Ns%0AdXN0ZXIubG9jYWwvbnMvZGVmYXVsdC9zYS9kZWZhdWx0MA0GCSqGSIb3DQEBCwUA%0AA4IBAQARWfTTstiFOLS14G3Bd8nY6S42KLdcJ9LDdXwYnrKq8V%2FgxpoqJzs4o%2FS4%0AWIcAgRn0K5l%2FFealGYn2axXuISDs%2BPxy4DQ8XrrQsWzTIcIzBK5VkJ10w8kzWbV9%0AO13Du%2BJ%2Bad8HPCJkaHuQADqlpjVVHhCJ%2Bd1JO2gAqmeHMSwPJqzEnfIp3woLNxAg%0AIfp5cgwQheDYeJCvti9WmeHvBrYfCWS0J69XH%2FE%2F3fK1MLdPaxM8aH12yDKymgIl%0AG9RL96gulMWuC7qn2rpw%2F2OFzf3%2FQAfgpqlBKw%2BTSENU5xom4HuFO1OhXcVlo7aJ%0ANJCOO2IEHwPz9rzAickyr9%2Blkuv9%0A-----END%20CERTIFICATE-----%0A\";Subject=\"\";URI=spiffe://cluster.local/ns/default/sa/default"
  }
}
```

Notice now an `X-Forwarded-Client-Cert` header appears because the sidecar to egress gateway connection is secured with mTLS.

3. You can examine the egress gateway logs as usual. The request is now going to the egress gateway's IP on its https targetPort 8443.

```shell
kubectl logs -l istio=egressgateway -c istio-proxy -n istio-system | tail
```
```
[2024-06-21T19:50:33.667Z] "GET /headers HTTP/1.1" 200 - via_upstream - "-" 0 2997 109 108 "10.244.0.7" "curl/7.83.1-DEV" "0db0a05e-6c1e-4a8a-b932-0f582340d36e" "httpbin.org" "3.211.196.247:443" outbound|443||httpbin.org 10.244.0.6:42264 10.244.0.6:8443 10.244.0.7:54554 httpbin.org -
```

```shell
kubectl get pod -n istio-system -l app=istio-egressgateway -owide
```
```
NAME                                   READY   STATUS    RESTARTS   AGE   IP           NODE                 NOMINATED NODE   READINESS GATES
istio-egressgateway-75c5457c56-htpvz   1/1     Running   0          33m   10.244.0.6   kind-control-plane   <none>           <none>
```

### HTTPS throughout via PASSTHROUGH: Egress and secure

This setup is useful when you want to enforce policies and monitor egress traffic while allowing the destination to manage its own TLS.

1. Use the same setup as before with httpbin ServiceEntry, but now let's use HTTPS in the Gateway:

```yaml
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: istio-egressgateway
spec:
  selector:
    istio: egressgateway
  servers:
  - port:
      number: 443 # Now use the TLS port
      name: tls 
      protocol: TLS
    hosts:
    - httpbin.org
    tls: # Set the TLS mode here
      mode: PASSTHROUGH
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: direct-httpbin-through-egress-gateway
spec:
  hosts:
  - httpbin.org
  gateways:
  - mesh
  - istio-egressgateway
  tls:
  - match:
    - gateways:
      - mesh
      port: 443 # Use the TLS port here 
      sniHosts: # Specify the SNI for validation and routing at the egress gateway
      - httpbin.org
    route:
    - destination:
        host: istio-egressgateway.istio-system.svc.cluster.local
        port:
          number: 443
  - match:
    - gateways:
      - istio-egressgateway
      port: 443
      sniHosts:
      - httpbin.org
    route:
    - destination:
        host: httpbin.org
        port:
          number: 443
      weight: 100
EOF
```

2. Send a request using https:

```shell
❯ kubectl exec curl -n curl -c curl -- curl -sSL -o /dev/null -D - https://httpbin.org/headers
HTTP/2 200
date: Thu, 20 Jun 2024 21:39:23 GMT
content-type: application/json
content-length: 177
server: gunicorn/19.9.0
access-control-allow-origin: *
access-control-allow-credentials: true
```

3. Check the egress gateway logs to make sure we're going through the gateway:
```shell
kubectl logs -l istio=egressgateway -c istio-proxy -n istio-system -f
```

You should see `outbound|443` which indicates we are using the TLS port.

```shell
[2024-06-20T21:39:23.441Z] "- - -" 0 - - - "-" 940 5946 217 - "-" "-" "-" "-" "18.211.234.122:443" outbound|443||httpbin.org 10.244.0.6:56320 10.244.0.6:8443 10.244.0.8:35674 httpbin.org -
```

### What about mTLS? 

DestinationRule can be configured to also perform mTLS orgination.

```yaml
kubectl apply -n istio-system -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: originate-mtls-for-httpbin
spec:
  host: httpbin
  trafficPolicy:
    loadBalancer:
      simple: ROUND_ROBIN
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: MUTUAL
        credentialName: client-credential # this must match the secret created earlier to hold client certs
        sni: httpbin 
        # subjectAltNames: # can be enabled if the certificate was generated with SAN
        # - httpbin.org
EOF
```

### Additional notes with egress gateways 

Just defining an egress Gateway in Istio doesn't provides any special treatment for the nodes on which the egress gateway service runs. The cluster administrator/cloud provider needs to deploy the egress gateways on dedicated nodes and add additional security measures to make these nodes more secure than the rest of the mesh.

Istio _cannot_ securely enforce that all egress traffic actually flows through the egress gateways. So additional rules must be put in place to ensure no traffic leaves the mesh bypassing the egress gateway. This can be done:
- Firewall to deny all traffic not coming from the egress gateway
- Kubernetes network policies can also forbid all the egress traffic not originating from the egress gateway
- Configure network to ensure application nodes can only access the Internet via a gateway by preventing allocating public IPs to pods other than gateways and configure NAT devices to drop packets not originating at the egress gateways.

See https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/#additional-security-considerations 
