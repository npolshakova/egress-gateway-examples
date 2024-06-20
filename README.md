# Egress Gateway Examples

## Background on Istio resources

1. VirtualService: An Istio custom resource that defines the rules for how requests for a service are routed within the service mesh (traffic spliting, request routing, retries, timeouts, fault injections, etc.)

2. DestinationRule: An Istio custom resource that defines policies that apply to traffic intended for a service _after_ routing has occurred (load balancing, connection pool settings, outlier detection, tls settings).

3. ServiceEntry: An Istio custom resource that add additional entries to the internal service registry that Istio maintains. This is used to enable access to external services not in the mesh.

4. Gateway: An Istio custom resource configures a load balancer for HTTP/TCP traffic. This can be used to manage ingress traffic coming to the mesh and egress traffic leaving the mesh.

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

3. Apply example apps 

```shell
kubectl apply -f example-apps.yaml
```

## ServiceEntry no Egress 

Because we have Istio installed with `meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY` we can defined a ServiceEntry and still have Istio traffic control (VirtualServices, etc.) and monitoring features. 

1. Create ServiceEntry to an external service (https://httpbin.org/)

```yaml
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: ServiceEntry
metadata:
  name: httpbin-with-egress
spec:
  hosts:
  - httpbin.org
  ports:
  - number: 80
    name: http-port
    protocol: HTTP
  - number: 443
    name: tls
    protocol: TLS
  resolution: DNS
EOF
```

2. Send an HTTP request with just the ServiceEntry

```shell
kubectl exec curl -n curl -c curl -- curl -sS http://httpbin.org/headers
```

And see the `X-Envoy-Peer-Metadata-Id` is set to the envoy sidecar id: 

```json
{
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    "User-Agent": "curl/7.83.1-DEV",
    "X-Amzn-Trace-Id": "Root=1-66748394-059ea3a4078cc9b25550b4f0",
    "X-Envoy-Attempt-Count": "1",
    "X-Envoy-Decorator-Operation": "httpbin.org:80/*",
    "X-Envoy-Peer-Metadata": "ChgKDkFQUF9DT05UQUlORVJTEgYaBGN1cmwKGgoKQ0xVU1RFUl9JRBIMGgpLdWJlcm5ldGVzChwKDElOU1RBTkNFX0lQUxIMGgoxMC4yNDQuMC44ChkKDUlTVElPX1ZFUlNJT04SCBoGMS4yMi4xCqwBCgZMQUJFTFMSoQEqngEKDQoDYXBwEgYaBGN1cmwKJAoZc2VjdXJpdHkuaXN0aW8uaW8vdGxzTW9kZRIHGgVpc3RpbwopCh9zZXJ2aWNlLmlzdGlvLmlvL2Nhbm9uaWNhbC1uYW1lEgYaBGN1cmwKKwojc2VydmljZS5pc3Rpby5pby9jYW5vbmljYWwtcmV2aXNpb24SBBoCdjEKDwoHdmVyc2lvbhIEGgJ2MQoaCgdNRVNIX0lEEg8aDWNsdXN0ZXIubG9jYWwKDgoETkFNRRIGGgRjdXJsChMKCU5BTUVTUEFDRRIGGgRjdXJsCjkKBU9XTkVSEjAaLmt1YmVybmV0ZXM6Ly9hcGlzL3YxL25hbWVzcGFjZXMvY3VybC9wb2RzL2N1cmwKFwoNV09SS0xPQURfTkFNRRIGGgRjdXJs",
    "X-Envoy-Peer-Metadata-Id": "sidecar~10.244.0.8~curl.curl~curl.svc.cluster.local"
  }
}
```

You could also use a DestinationRule to configure TLS origination at the sidecar.  

Note: This configuration example does not enable secure egress traffic control in Istio. A malicious application can bypass the Istio sidecar proxy and access any external service without Istio control. To implement egress traffic control in a more secure way, you must direct egress traffic through an egress gateway...

## Basic Egress Gateway Setup

### HTTP (Egress, but insecure) and HTTPS (Egress, but secure)

1. Apply config

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
      weight: 100
  - match:
    - gateways:
      - istio-egressgateway
      port: 80
    route:
    - destination:
        host: httpbin.org
        port:
          number: 80
      weight: 100
EOF
```

2. Send a http request as before:

```shell
 kubectl exec curl -n curl -c curl -- curl -sS http://httpbin.org/headers -v
```

```json
❯  kubectl exec curl -n curl -c curl -- curl -sS http://httpbin.org/headers
{
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    "User-Agent": "curl/7.83.1-DEV",
    "X-Amzn-Trace-Id": "Root=1-66749cec-43439da96886030229341615",
    "X-B3-Parentspanid": "ec464d39b856dc0e",
    "X-B3-Sampled": "0",
    "X-B3-Spanid": "3f2f2c89b87b9308",
    "X-B3-Traceid": "5d6717bdef5bd9bcec464d39b856dc0e",
    "X-Envoy-Attempt-Count": "1",
    "X-Envoy-Decorator-Operation": "httpbin.org:80/*",
    "X-Envoy-Internal": "true",
    "X-Envoy-Peer-Metadata": "ChoKCkNMVVNURVJfSUQSDBoKS3ViZXJuZXRlcwocCgxJTlNUQU5DRV9JUFMSDBoKMTAuMjQ0LjAuNgoZCg1JU1RJT19WRVJTSU9OEggaBjEuMTkuMAqYAwoGTEFCRUxTEo0DKooDChwKA2FwcBIVGhNpc3Rpby1lZ3Jlc3NnYXRld2F5ChMKBWNoYXJ0EgoaCGdhdGV3YXlzChQKCGhlcml0YWdlEggaBlRpbGxlcgo2CilpbnN0YWxsLm9wZXJhdG9yLmlzdGlvLmlvL293bmluZy1yZXNvdXJjZRIJGgd1bmtub3duChgKBWlzdGlvEg8aDWVncmVzc2dhdGV3YXkKGQoMaXN0aW8uaW8vcmV2EgkaB2RlZmF1bHQKLwobb3BlcmF0b3IuaXN0aW8uaW8vY29tcG9uZW50EhAaDkVncmVzc0dhdGV3YXlzChIKB3JlbGVhc2USBxoFaXN0aW8KOAofc2VydmljZS5pc3Rpby5pby9jYW5vbmljYWwtbmFtZRIVGhNpc3Rpby1lZ3Jlc3NnYXRld2F5Ci8KI3NlcnZpY2UuaXN0aW8uaW8vY2Fub25pY2FsLXJldmlzaW9uEggaBmxhdGVzdAoiChdzaWRlY2FyLmlzdGlvLmlvL2luamVjdBIHGgVmYWxzZQoaCgdNRVNIX0lEEg8aDWNsdXN0ZXIubG9jYWwKLgoETkFNRRImGiRpc3Rpby1lZ3Jlc3NnYXRld2F5LTU3YzQ0Zjk5YmMtdzlrbnMKGwoJTkFNRVNQQUNFEg4aDGlzdGlvLXN5c3RlbQpcCgVPV05FUhJTGlFrdWJlcm5ldGVzOi8vYXBpcy9hcHBzL3YxL25hbWVzcGFjZXMvaXN0aW8tc3lzdGVtL2RlcGxveW1lbnRzL2lzdGlvLWVncmVzc2dhdGV3YXkKJgoNV09SS0xPQURfTkFNRRIV* Connection #0 to host httpbin.org left intact
GhNpc3Rpby1lZ3Jlc3NnYXRld2F5",
    "X-Envoy-Peer-Metadata-Id": "router~10.244.0.6~istio-egressgateway-57c44f99bc-w9kns.istio-system~istio-system.svc.cluster.local"
  }
}
```

Notice now the `X-Envoy-Peer-Metadata-Id` has the egressgateway id. 

3. Check the request went through the egress gateway. 

```shell
kubectl logs -l istio=egressgateway -c istio-proxy -n istio-system | tail
```

```
[2024-06-20T21:19:40.721Z] "GET /headers HTTP/2" 200 - via_upstream - "-" 0 1619 689 81 "10.244.0.8" "curl/7.83.1-DEV" "0192212c-94e1-412f-9a5a-1b3273e82eaf" "httpbin.org" "18.211.234.122:80" outbound|80||httpbin.org 10.244.0.6:60186 10.244.0.6:8080 10.244.0.8:50860 - -
```

This shows up because when we installed Istio, we included this config to enable the access logs to be output:
```shell
 --set meshConfig.accessLogFile=/dev/stdout
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

### TLS origination at egress gateway

# TODO: debug

1. Use the same httpbin ServiceEntry as before, but now let's get have the egress gateway do some TLS. In order to configure the TLS traffic policy, we'll need a new resource- a `DestinationRule. Apply the Gateway, VirtualService and two DestinationRule:


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
      name: https-port-for-tls-origination
      protocol: TLS
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
  subsets:
  - name: httpbin
    trafficPolicy:
      portLevelSettings:
      - port:
          number: 80
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
        subset: httpbin
        port:
          number: 80
      weight: 100
  - match:
    - gateways:
      - istio-egressgateway
      port: 80
    route:
    - destination:
        host: httpbin.org
        port:
          number: 443
      weight: 100
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
        mode: SIMPLE # initiates HTTPS for connections to httpbin
EOF
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
