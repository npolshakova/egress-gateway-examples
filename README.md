# Egress Gateway Examples

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

Note: This configuration example does not enable secure egress traffic control in Istio. A malicious application can bypass the Istio sidecar proxy and access any external service without Istio control. To implement egress traffic control in a more secure way, you must direct egress traffic through an egress gateway...

## Basic Egress Gateway Setup

### HTTP 

1. Create ServiceEntry

```
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: ServiceEntry
metadata:
  name: httpbin-https
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

2. Send request

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

### HTTPS originated at sidecar (passthrough at egress)



### HTTPS to HTTP (secure in mesh, still can apply policy)

1. 

### HTTPS originate at gateway (mtls throughout, new origination at Gateway)

1. 

### Additional notes with egress gateways 

Just defining an egress Gateway in Istio doesn't provides any special treatment for the nodes on which the egress gateway service runs. The cluster administrator/cloud provider needs to deploy the egress gateways on dedicated nodes and add additional security measures to make these nodes more secure than the rest of the mesh.

Istio _cannot_ securely enforce that all egress traffic actually flows through the egress gateways. So additional rules must be put in place to ensure no traffic leaves the mesh bypassing the egress gateway. This can be done:
- Firewall to deny all traffic not coming from the egress gateway
- Kubernetes network policies can also forbid all the egress traffic not originating from the egress gateway
- Configure network to ensure application nodes can only access the Internet via a gateway by preventing allocating public IPs to pods other than gateways and configure NAT devices to drop packets not originating at the egress gateways.

See https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/#additional-security-considerations 
