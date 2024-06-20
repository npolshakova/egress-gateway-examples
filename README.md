# Egress Gateway Examples

## Background on Istio resources

1. VirtualService: An Istio custom resource that defines the rules for how requests for a service are routed within the service mesh (traffic spliting, request routing, retries, timeouts, fault injections, etc.)

2. DestinationRule: An Istio custom resource that defines policies that apply to traffic intended for a service _after_ routing has occurred (load balancing, connection pool settings, outlier detection, tls settings).

3. ServiceEntry: An Istio custom resource that add additional entries to the internal service registry that Istio maintains. This is used to enable access to external services not in the mesh.

4. Gateway: An Istio custom resource configures a load balancer for HTTP/TCP traffic. This can be used to manage ingress traffic coming to the mesh and egress traffic leaving the mesh.

## Environment setup

1. Create a kind cluster

```
kind create cluster
```

2. Install Istio

```
istioctl install --set profile=minimal \
 --set "components.egressGateways[0].name=istio-egressgateway" \
 --set "components.egressGateways[0].enabled=true" \
 --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY 
```

Note: To allow all traffic (not restricted to the service registry) you can use `--set "meshConfig.outboundTrafficPolicy.mode=ALLOW_ANY"`. The drawback here is you lose Istio monitoring and control for traffic to external services. 

3. Apply example apps 

```
kubectl apply -f example-apps.yaml
```

## ServiceEntry no Egress 

Because we have Istio installed with `meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY` we can defined a ServiceEntry and still have Istio traffic control (VirtualServices, etc.) and monitoring features. 

1. Apply a ServiceEntry to an external HTTP service.

```
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: ServiceEntry
metadata:
  name: httpbin-ext
spec:
  hosts:
  - httpbin.org
  ports:
  - number: 80
    name: http
    protocol: HTTP
  resolution: DNS
  location: MESH_EXTERNAL
EOF
```

Or slightly more fun solo example (but the request isn't as pretty):

```
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: ServiceEntry
metadata:
  name: solo
spec:
  hosts:
  - docs.solo.io
  ports:
  - number: 80
    name: http
    protocol: HTTPS
  resolution: DNS
  location: MESH_EXTERNAL
EOF
```

Note: You can change the protocol to use HTTPS

2. Send some test traffic

```
 kubectl exec curl -n curl -c curl -- curl -sS http://httpbin.org/headers
```

You could also use a DestinationRule to configure TLS origination at the sidecar.  

Note: This configuration example does not enable secure egress traffic control in Istio. A malicious application can bypass the Istio sidecar proxy and access any external service without Istio control. To implement egress traffic control in a more secure way, you must direct egress traffic through an egress gateway...

## Basic Egress Gateway Setup

### HTTP (Egress, but insecure) and HTTPS (Egress, but secure)

1. Create ServiceEntry

```
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
    name: https
    protocol: HTTPS
  resolution: DNS
EOF
```

2. Send request with just the ServiceEntry

```
❯  kubectl exec curl -n curl -c curl -- curl -sS https://httpbin.org/headers
{
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    "User-Agent": "curl/7.83.1-DEV",
    "X-Amzn-Trace-Id": "Root=1-6670e51c-3fe5da0a44ed4a1651ef2789"
  }
}
```

3. Apply config

```
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
kind: DestinationRule
metadata:
  name: egressgateway-for-httpbin
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local
  subsets:
  - name: httpbin
EOF
```

Send a http request:

```
❯  kubectl exec curl -n curl -c curl -- curl -sS http://httpbin.org/headers
{
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    "User-Agent": "curl/7.83.1-DEV",
    "X-Amzn-Trace-Id": "Root=1-6670e534-0c7784dc4873c5027a1fa4a8",
    "X-B3-Sampled": "0",
    "X-B3-Spanid": "e5cb8d05eee4d954",
    "X-B3-Traceid": "356130e1abbc75f4e5cb8d05eee4d954",
    "X-Envoy-Attempt-Count": "1",
    "X-Envoy-Decorator-Operation": "httpbin.org:80/*",
    "X-Envoy-Peer-Metadata": "ChgKDkFQUF9DT05UQUlORVJTEgYaBGN1cmwKGgoKQ0xVU1RFUl9JRBIMGgpLdWJlcm5ldGVzChwKDElOU1RBTkNFX0lQUxIMGgoxMC4yNDQuMC45ChkKDUlTVElPX1ZFUlNJT04SCBoGMS4xOS4wCqwBCgZMQUJFTFMSoQEqngEKDQoDYXBwEgYaBGN1cmwKJAoZc2VjdXJpdHkuaXN0aW8uaW8vdGxzTW9kZRIHGgVpc3RpbwopCh9zZXJ2aWNlLmlzdGlvLmlvL2Nhbm9uaWNhbC1uYW1lEgYaBGN1cmwKKwojc2VydmljZS5pc3Rpby5pby9jYW5vbmljYWwtcmV2aXNpb24SBBoCdjEKDwoHdmVyc2lvbhIEGgJ2MQoaCgdNRVNIX0lEEg8aDWNsdXN0ZXIubG9jYWwKDgoETkFNRRIGGgRjdXJsChMKCU5BTUVTUEFDRRIGGgRjdXJsCjkKBU9XTkVSEjAaLmt1YmVybmV0ZXM6Ly9hcGlzL3YxL25hbWVzcGFjZXMvY3VybC9wb2RzL2N1cmwKFwoNV09SS0xPQURfTkFNRRIGGgRjdXJs",
    "X-Envoy-Peer-Metadata-Id": "sidecar~10.244.0.9~curl.curl~curl.svc.cluster.local"
  }
}
```

### HTTPS throughout: Egress and secure

Same setup as before with httpbin and ServiceEntry, but now let's use HTTPS 

```
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: https-istio-egressgateway
spec:
  selector:
    istio: egressgateway
  servers:
  - port:
      number: 443
      name: httpS
      protocol: HTTPS
    hosts:
    - httpbin.org
---
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: egressgateway-for-httpbin
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local
  subsets:
  - name: httpbin
EOF
```

### HTTPS originate at gateway

1. Use the same httpbin and ServiceEntry as before.


2. Apply a Gateway and DestinationRule  
```
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: origination-istio-egressgateway
spec:
  selector:
    istio: egressgateway
  servers:
  - port:
      number: 80
      name: https-port-for-tls-origination
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
  subsets:
  - name: httpbin
    trafficPolicy:
      loadBalancer:
        simple: ROUND_ROBIN
      portLevelSettings:
      - port:
          number: 80
        tls:
          mode: ISTIO_MUTUAL
          sni: httpbin.prg
EOF
```

3. Configure route rules to direct traffic through the egress gateway:

```
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: direct-httpbin-through-egress-gateway
spec:
  hosts:
  - httpbin
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
EOF
```

5. Define a DestinationRule to perform TLS origination for requests to `httpbin`` host:

```
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: originate-tls-for-edition-httpbin
spec:
  host: httpbin
  trafficPolicy:
    loadBalancer:
      simple: ROUND_ROBIN
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: SIMPLE # initiates HTTPS for connections to httpbin host
EOF
```

### TLS Passthrough 

TODO: not fully working?

Tecnically possible?*** This setup is useful when you want to enforce policies and monitor egress traffic while allowing the destination to manage its own TLS.

Use same ServiceEntry as before for httpbin and the same setup as the previous steps.

```
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: passthrough-istio-egressgateway
  namespace: istio-system
spec:
  selector:
    istio: egressgateway 
  servers:
  - port:
      number: 443
      name: tls
      protocol: TLS
    tls:
      mode: PASSTHROUGH
    hosts:
    - httpbin.org
---
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: passthrough-example
  namespace: istio-system
spec:
  host: external.example.com
  subsets:
  - name: httpbin
  trafficPolicy:
    tls:
      mode: DISABLE # What should this be?
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: passthrough-route-egress-gateway
  namespace: istio-system
spec:
  hosts:
  - external.example.com
  gateways:
  - istio-egressgateway
  - mesh
  tls:
  - match:
    - port: 443
      sniHosts:
      - httpbin.org
    route:
    - destination:
        host: httpbin.org
        port:
          number: 443
        subset: httpbin
---
EOF
```

### What about mTLS? 

DestinationRule can be configured to also perform mTLS orgination.

```
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
        # - httpbin
EOF
```

### Additional notes with egress gateways 

Just defining an egress Gateway in Istio doesn't provides any special treatment for the nodes on which the egress gateway service runs. The cluster administrator/cloud provider needs to deploy the egress gateways on dedicated nodes and add additional security measures to make these nodes more secure than the rest of the mesh.

Istio _cannot_ securely enforce that all egress traffic actually flows through the egress gateways. So additional rules must be put in place to ensure no traffic leaves the mesh bypassing the egress gateway. This can be done:
- Firewall to deny all traffic not coming from the egress gateway
- Kubernetes network policies can also forbid all the egress traffic not originating from the egress gateway
- Configure network to ensure application nodes can only access the Internet via a gateway by preventing allocating public IPs to pods other than gateways and configure NAT devices to drop packets not originating at the egress gateways.

See https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/#additional-security-considerations 
