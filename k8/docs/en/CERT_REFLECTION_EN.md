# TLS Certificate Reflection

## Problem

The stack uses two separate ingress controllers:

- **Traefik** for platform services (`*.development.cfapps.cool`) — MetalLB IP `192.168.64.201`
- **Contour** for Korifi/CF apps (`*.app.cfapps.cool`) — MetalLB IP `192.168.64.203`

cert-manager issues Let's Encrypt wildcard certificates via DNS-01 challenge. These certificates are stored as Kubernetes Secrets in the `traefik` namespace. Traefik can reference secrets from any namespace with `allowCrossNamespace: true` — no problem.

Contour cannot do this. The Korifi Gateway in the `korifi-gateway` namespace needs the certificate as a Secret in the `korifi` namespace. Without a solution, Korifi would have to issue its own certificate — either self-signed (insecure) or a second Let's Encrypt cert for the same domain (wastes rate limits).

## Solution: Kubernetes Reflector

[emberstack/kubernetes-reflector](https://github.com/emberstack/kubernetes-reflector) automatically copies Secrets between namespaces. A single Let's Encrypt certificate is issued by cert-manager and copied by the Reflector to wherever it is needed.

```
cert-manager (DNS-01)           Kubernetes Reflector            Contour Gateway
      │                               │                              │
      │  issues / renews              │  watches annotations         │
      ▼                               ▼                              ▼
┌─────────────────────┐    ┌──────────────────────┐    ┌───────────────────────────┐
│ wildcard-apps-tls   │───▶│ wildcard-apps-tls    │◀───│ Gateway Listener          │
│ (traefik namespace) │    │ (korifi namespace)   │    │ https-apps                │
│                     │    │                      │    │ tls.certificateRefs:      │
│ Annotations:        │    │ Automatically        │    │   name: wildcard-apps-tls │
│  reflection-allowed │    │ created and          │    │   namespace: korifi       │
│  reflection-auto-   │    │ synchronized on      │    │                           │
│  enabled            │    │ every change         │    │                           │
└─────────────────────┘    └──────────────────────┘    └───────────────────────────┘
```

## Configuration

### Source Secret (traefik namespace)

The wildcard certificate is annotated with Reflector annotations:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: wildcard-apps-tls
  namespace: traefik
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "korifi"
    reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
    reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "korifi"
type: kubernetes.io/tls
```

### Target

The Reflector automatically creates a copy as `wildcard-apps-tls` in the `korifi` namespace. The Korifi Gateway references this Secret.

### ReferenceGrant

The Gateway lives in the `korifi-gateway` namespace, while the reflected Secret is in the `korifi` namespace. Contour only allows cross-namespace Secret references with an explicit `ReferenceGrant`:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-cert-ref
  namespace: korifi
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: Gateway
    namespace: korifi-gateway
  to:
  - group: ""
    kind: Secret
```

Without this ReferenceGrant, the Gateway reports `Programmed=False` with the error message: `namespace must match the Gateway's namespace or be covered by a ReferenceGrant`.

### Renewal

When the certificate is renewed by cert-manager (every 60 days):

1. cert-manager renews `wildcard-apps-tls` in the `traefik` namespace
2. The Reflector detects the change and updates the copy in the `korifi` namespace
3. Contour reads the updated Secret and uses the new certificate

No manual intervention required.

## Certificate Overview

| Certificate | Namespace | Issuer | Used by | Reflection |
|------------|-----------|--------|---------|------------|
| `wildcard-development-tls` | traefik | letsencrypt-prod | Traefik (all `*.development.cfapps.cool` services) | not needed |
| `wildcard-apps-tls` | traefik | letsencrypt-prod | Traefik (directly) + Contour (via reflection) | → korifi |

## Components

| Component | Version | Namespace | Purpose |
|-----------|---------|-----------|---------|
| cert-manager | v1.x | cert-manager | Let's Encrypt certificate issuance and renewal |
| kubernetes-reflector | latest | kube-system | Cross-namespace Secret synchronization |
| Traefik | v3.x | traefik | Ingress for platform services |
| Contour | v1.33.x | projectcontour | Gateway API controller for Korifi CF apps |
