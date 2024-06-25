# Speak Egress and Exit: A Look at Securing Traffic Out of the Mesh with Istio

Though Istio can send traffic to an external IP address, hostname, or internal DNS entry directly, this doesn’t limit which services can access external endpoints. Egress gateways enforce policies across an organization and provide a centralized point for monitoring, controlling, and shaping outbound traffic. 

Let's walk through some common egress scenarios! 

<img src=meme.jpg>

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

<img src=no-egress.png>

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

<img src=no-egress-secure.png>

## Basic Egress Gateway Setup

### HTTP through Egress Gateway (still insecure)

<img src=egress-not-secure.png>

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

<img src=egress-tls-origination.png>

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

<img src=mtls-egress-tls-origination.png>

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
  name: mtls-to-gateway
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

### HTTPS throughout via PASSTHROUGH at Gateway

<img src=passthrough-egress.png>

This setup is useful when you want to enforce policies and monitor egress traffic while allowing the destination to manage its own TLS.

1. Modify the Gateway to use PASSTHROUGH instead of terminating the HTTPS connection from the sidecar. This also means we'll need to delete the DestinationRule so that the sidecar will not attempt an mTLS connection with the gateway. As such, we'll need to send an https request from the curl pod ourselves, which means the VirtualService will need a `tls` block instead of an `http` one:

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
  tls: # changed to tls
  - match:
    - gateways:
      - mesh
      port: 443 # now the https port, since we'll send an https request
      sniHosts: # specify the SNI for validation and routing at the egress gateway
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
EOF
kubectl delete destinationrule mtls-to-gateway
```

2. Send a request using https:

```shell
kubectl exec curl -c curl -- curl -sS https://httpbin.org/headers
```
```
curl: (35) error:1408F10B:SSL routines:ssl3_get_record:wrong version number
command terminated with exit code 35
```

3. Uh oh, we got an SSL error! Why? Because we still have a DestinationRule that does TLS Origination at the gateway. This means our request is double-encrypted.
Let's delete that DestinationRule:
```shell
kubectl delete destinationrule originate-tls-for-httpbin
```

4. Now let's try the https request again:
```shell
kubectl exec curl -c curl -- curl -sS https://httpbin.org/headers
```

```json
{
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    "User-Agent": "curl/7.83.1-DEV",
    "X-Amzn-Trace-Id": "Root=1-6675ef13-625b4c8e616be9c53ab44950"
  }
}
```

5. Encrypted requests will not add the headers, so we'll need to check the egress gateway logs to make sure we're going through the gateway:
```shell
kubectl logs -l istio=egressgateway -c istio-proxy -n istio-system | tail
```

```shell
[2024-06-21T21:22:27.560Z] "- - -" 0 - - - "-" 940 5946 156 - "-" "-" "-" "-" "18.211.234.122:443" outbound|443||httpbin.org 10.244.0.6:50356 10.244.0.6:8443 10.244.0.7:51628 httpbin.org -
```

### HTTP through Egress Gateway, with mTLS Between the Sidecar and the Gateway

Let's say we currently have a setup that supports [HTTPS through Egress Gateway, with TLS Origination at the Gateway and mTLS Between the Sidecar and the Gateway](https://github.com/npolshakova/egress-gateway-examples?tab=readme-ov-file#https-through-egress-gateway-with-tls-origination-at-the-gateway-and-mtls-between-the-sidecar-and-the-gateway)

It could be that our external service only supports HTTP requests, but we still want the request to be secured with mTLS within our mesh.

1. Let's modify the VirtualService to again send requests to httpbin.org on the HTTP port. Then all we have to do is delete the
DestinationRule that originates the HTTPS request:

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
          number: 443
  - match:
    - gateways:
      - istio-egressgateway
      port: 443
    route:
    - destination:
        host: httpbin.org
        port:
          number: 80 # back to HTTP port
EOF
kubectl delete destinationrule originate-tls-for-httpbin
```

In essence, we have undone the changes made in the [step to add TLS origination at the gateway](https://github.com/npolshakova/egress-gateway-examples?tab=readme-ov-file#https-through-egress-gateway-with-tls-origination-at-the-gateway).

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
    "X-Amzn-Trace-Id": "Root=1-6679e51f-31ee47906ad67ef039afb7bf",
    "X-B3-Parentspanid": "c68e5a144b4f0193",
    "X-B3-Sampled": "0",
    "X-B3-Spanid": "deb64d4724fb2ba7",
    "X-B3-Traceid": "bc38aa25bd4d029cc68e5a144b4f0193",
    "X-Envoy-Attempt-Count": "1",
    "X-Envoy-Decorator-Operation": "httpbin.org:80/*",
    "X-Envoy-Internal": "true",
    "X-Envoy-Peer-Metadata": "ChoKCkNMVVNURVJfSUQSDBoKS3ViZXJuZXRlcwocCgxJTlNUQU5DRV9JUFMSDBoKMTAuMjQ0LjAuNgoZCg1JU1RJT19WRVJTSU9OEggaBjEuMTkuMwqYAwoGTEFCRUxTEo0DKooDChwKA2FwcBIVGhNpc3Rpby1lZ3Jlc3NnYXRld2F5ChMKBWNoYXJ0EgoaCGdhdGV3YXlzChQKCGhlcml0YWdlEggaBlRpbGxlcgo2CilpbnN0YWxsLm9wZXJhdG9yLmlzdGlvLmlvL293bmluZy1yZXNvdXJjZRIJGgd1bmtub3duChgKBWlzdGlvEg8aDWVncmVzc2dhdGV3YXkKGQoMaXN0aW8uaW8vcmV2EgkaB2RlZmF1bHQKLwobb3BlcmF0b3IuaXN0aW8uaW8vY29tcG9uZW50EhAaDkVncmVzc0dhdGV3YXlzChIKB3JlbGVhc2USBxoFaXN0aW8KOAofc2VydmljZS5pc3Rpby5pby9jYW5vbmljYWwtbmFtZRIVGhNpc3Rpby1lZ3Jlc3NnYXRld2F5Ci8KI3NlcnZpY2UuaXN0aW8uaW8vY2Fub25pY2FsLXJldmlzaW9uEggaBmxhdGVzdAoiChdzaWRlY2FyLmlzdGlvLmlvL2luamVjdBIHGgVmYWxzZQoaCgdNRVNIX0lEEg8aDWNsdXN0ZXIubG9jYWwKLgoETkFNRRImGiRpc3Rpby1lZ3Jlc3NnYXRld2F5LTY2NDZmODc5YjgtZGZ4N3YKGwoJTkFNRVNQQUNFEg4aDGlzdGlvLXN5c3RlbQpcCgVPV05FUhJTGlFrdWJlcm5ldGVzOi8vYXBpcy9hcHBzL3YxL25hbWVzcGFjZXMvaXN0aW8tc3lzdGVtL2RlcGxveW1lbnRzL2lzdGlvLWVncmVzc2dhdGV3YXkKJgoNV09SS0xPQURfTkFNRRIVGhNpc3Rpby1lZ3Jlc3NnYXRld2F5",
    "X-Envoy-Peer-Metadata-Id": "router~10.244.0.6~istio-egressgateway-6646f879b8-dfx7v.istio-system~istio-system.svc.cluster.local",
    "X-Forwarded-Client-Cert": "By=spiffe://cluster.local/ns/istio-system/sa/istio-egressgateway-service-account;Hash=c207a3ae62f457284f557a63adad6f393852824c2875df3716e7da01af08ea0d;Cert=\"-----BEGIN%20CERTIFICATE-----%0AMIIDQDCCAiigAwIBAgIQYGgrZz9HXZUDAuGQrjfutTANBgkqhkiG9w0BAQsFADAY%0AMRYwFAYDVQQKEw1jbHVzdGVyLmxvY2FsMB4XDTI0MDYyNDIwMTA1M1oXDTI0MDYy%0ANTIwMTI1M1owADCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAOuREo8N%0Ape0SCJ0qSjzIo%2BeT1%2F8vRcDAfw%2FxrhtUzdxON2uK%2FTgVH3KmFIjozexvrhmiBZTJ%0AY4sSfo6YAsjQUveFQNf14ww%2BX4Un9OOgp1BVmOmSyQhqOuB%2FaMxkVeCHMb7RdSUm%0A8MTG1pYhub02tMIt3HCNmxTO9YqFPd9w3rSfTvUMVZvzog4wn7zNDa9GCQjgY3Ac%0AC1zsyXv5ajxOY4%2B6VKnsdwLIG09td%2B1lFFeEUIkv3U4rNAljA%2BXLUgx7uB8zSNVm%0AHfdq6A2ByyGAml%2BX2rKPdg6uUlaNjAZlggRuctm%2BAnD8e3WurI8bZR4s58eGrKCW%0AMKu1RI7FyWJ87MkCAwEAAaOBnTCBmjAOBgNVHQ8BAf8EBAMCBaAwHQYDVR0lBBYw%0AFAYIKwYBBQUHAwEGCCsGAQUFBwMCMAwGA1UdEwEB%2FwQCMAAwHwYDVR0jBBgwFoAU%0A7HNYUItjVIQYFHfoVzZXJeAb98EwOgYDVR0RAQH%2FBDAwLoYsc3BpZmZlOi8vY2x1%0Ac3Rlci5sb2NhbC9ucy9kZWZhdWx0L3NhL2RlZmF1bHQwDQYJKoZIhvcNAQELBQAD%0AggEBAGBEO2IZCi96on5%2F%2FQ8bf7Ph5J%2BLyi3sLZPd%2Fhf2yGVJjoyeZ4Cpvd0uRFK6%0ASqPX%2Bq7ZQVK%2FWWsYXwXlZFstMYJUX4dRTB20afvLkaVFZY%2FaZ6bkhCbeDvqUBhZm%0A9cvqpuQbyplE7vDmJq2AIGTgdzqJ1GhUChnk5G1EbjgesVW7Dxw%2FAyMSoB8dtOhf%0AvYgJYyNM9eTAAHBP86Y0kdhQVxqHD3v9z1aPQImkz0te93iq3klSMWn8wIPkvyR2%0AYBfU5Mo5RklNO8weycygG%2FClkK9nMdpFXUEyOszSckhAKbDwH5K5P29S5REeW7jE%0AGCWbEjt9TxDJcpiDheFXFP%2BeJSI%3D%0A-----END%20CERTIFICATE-----%0A\";Subject=\"\";URI=spiffe://cluster.local/ns/default/sa/default"
  }
}
```

The `X-Forwarded-Client-Cert` header still shows that the sidecar to egress gateway connection is secured with mTLS, but the `X-Envoy-Decorator-Operation` header is back to showing that our request was sent to httpbin.org's HTTP port.

3. You can examine the changes in the egress gateway logs as well.

```shell
kubectl logs -l istio=egressgateway -c istio-proxy -n istio-system | tail
```
```
[2024-06-24T21:29:03.272Z] "GET /headers HTTP/1.1" 200 - via_upstream - "-" 0 3157 67 67 "10.244.0.7" "curl/7.83.1-DEV" "a925dde7-a7ac-4e1b-b33d-0b5c4403b791" "httpbin.org" "44.195.190.188:80" outbound|80||httpbin.org 10.244.0.6:56744 10.244.0.6:8443 10.244.0.7:57726 httpbin.org -
```

### What About mTLS to the External Service?

<img src=mtls-egress.png>

A DestinationRule can be configured to also perform mTLS orgination. In order to set this up, you will need to:
- Generate client and server certificates
- Deploy an external service that supports the mutual TLS protocol
- Redeploy the egress gateway with the needed mutual TLS certs

See the [Istio docs](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/#perform-mutual-tls-origination-with-an-egress-gateway) for instructions on how to get this running.

The DestinationRule that will perform mTLS origination will look like this: 

```yaml
kubectl apply -n istio-system -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: originate-mtls-for-httpbin
spec:
  host: httpbin.org
  trafficPolicy:
    loadBalancer:
      simple: ROUND_ROBIN
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: MUTUAL
        credentialName: client-credential # this must match the secret created to hold client certs
        sni: httpbin.org
        # subjectAltNames: # can be enabled if the certificate was generated with SAN
        # - httpbin.org
EOF
```

### What about ExternalName Kubernetes Services? 

<img src=externalname-svc.png>

The Kubernetes Service supports `ExternalName` service types which let you create a local DNS alias to an external service. 

Note: You'll need to reinstall Istio from the previous example with `--set "meshConfig.outboundTrafficPolicy.mode=ALLOW_ANY"` to allow the ExternalName to work. 

```
kubectl apply -f - <<EOF
kind: Service
apiVersion: v1
metadata:
  name: external-name-httpbin
spec:
  type: ExternalName
  externalName: httpbin.org
  ports:
  - name: http
    protocol: TCP
    port: 80
  - name: https-port
    port: 443
    protocol: TCP
EOF
```

Then curl 
```
kubectl exec curl -c curl -- curl -sS http://external-name-httpbin.default/headers
```

You will need to configure the TLS mode to not be Istio’s mutual TLS. The external services are not part of an Istio service mesh so they cannot use Istio mTLS. You can still perform TLS origination with Istio DestinationRules or you can disable Istio's mTLS if the workload already uses TLS.


### Unsupported Configurations

It's worth noting that not all possible configurations are supported by Istio.

For example, Istio does not support TLS termination at the sidecar (https://github.com/istio/istio/issues/37160). Without terminating the HTTPS connection, attempting mTLS between the sidecar and the egress gateway would result in double encryption. Therefore, an HTTPS request from the client app itself (not its sidecar) which enforces mTLS within the mesh is not supported.

### Additional notes with egress gateways 

Just defining an egress Gateway in Istio doesn't provide any special treatment for the nodes on which the egress gateway service runs. The cluster administrator/cloud provider needs to deploy the egress gateways on dedicated nodes and add additional security measures to make these nodes more secure than the rest of the mesh.

Istio _cannot_ securely enforce that all egress traffic actually flows through the egress gateways. So additional rules must be put in place to ensure no traffic leaves the mesh bypassing the egress gateway. This can be done with:
- a Firewall to deny all traffic not coming from the egress gateway
- Kubernetes network policies to forbid all the egress traffic not originating from the egress gateway
- network configuration to ensure application nodes can only access the Internet via a gateway by preventing allocating public IPs to pods other than gateways and configuring NAT devices to drop packets not originating at the egress gateways

See the [Istio docs](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/#additional-security-considerations) for more details and an example using a Kubernetes network policy.
