# TLS Zertifikat-Reflection

## Problem

Der Stack nutzt zwei separate Ingress-Controller:

- **Traefik** fuer Platform-Services (`*.development.cfapps.cool`) — MetalLB IP `192.168.64.201`
- **Contour** fuer Korifi/CF-Apps (`*.app.cfapps.cool`) — MetalLB IP `192.168.64.203`

cert-manager stellt Let's Encrypt Wildcard-Zertifikate via DNS-01 Challenge aus. Diese Zertifikate landen als Kubernetes Secrets im `traefik` Namespace. Traefik kann mit `allowCrossNamespace: true` Secrets aus beliebigen Namespaces referenzieren — kein Problem.

Contour kann das nicht. Das Korifi Gateway im `korifi-gateway` Namespace braucht das Zertifikat als Secret im `korifi` Namespace. Ohne Loesung muesste Korifi ein eigenes Zertifikat ausstellen — entweder self-signed (unsicher) oder ein zweites Let's Encrypt Cert fuer dieselbe Domain (verschwendet Rate-Limits).

## Loesung: Kubernetes Reflector

[emberstack/kubernetes-reflector](https://github.com/emberstack/kubernetes-reflector) kopiert Secrets automatisch zwischen Namespaces. Ein einziges Let's Encrypt Zertifikat wird von cert-manager ausgestellt und vom Reflector dorthin kopiert, wo es gebraucht wird.

```
cert-manager (DNS-01)           Kubernetes Reflector            Contour Gateway
      │                               │                              │
      │  stellt aus / erneuert        │  beobachtet Annotations      │
      ▼                               ▼                              ▼
┌─────────────────────┐    ┌──────────────────────┐    ┌───────────────────────────┐
│ wildcard-apps-tls   │───▶│ wildcard-apps-tls    │◀───│ Gateway Listener          │
│ (traefik Namespace) │    │ (korifi Namespace)   │    │ https-apps                │
│                     │    │                      │    │ tls.certificateRefs:      │
│ Annotations:        │    │ Automatisch erzeugt  │    │   name: wildcard-apps-tls │
│  reflection-allowed │    │ und synchronisiert   │    │   namespace: korifi       │
│  reflection-auto-   │    │ bei jeder Aenderung  │    │                           │
│  enabled            │    │                      │    │                           │
└─────────────────────┘    └──────────────────────┘    └───────────────────────────┘
```

## Konfiguration

### Quell-Secret (traefik Namespace)

Das Wildcard-Zertifikat wird mit Reflector-Annotations versehen:

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

### Ziel

Der Reflector erstellt automatisch eine Kopie als `wildcard-apps-tls` im `korifi` Namespace. Das Korifi Gateway referenziert dieses Secret.

### ReferenceGrant

Das Gateway lebt im `korifi-gateway` Namespace, das reflektierte Secret im `korifi` Namespace. Contour erlaubt Cross-Namespace Secret-Referenzen nur mit einem expliziten `ReferenceGrant`:

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

Ohne diesen ReferenceGrant meldet das Gateway `Programmed=False` mit der Fehlermeldung: `namespace must match the Gateway's namespace or be covered by a ReferenceGrant`.

### Erneuerung

Bei Zertifikat-Erneuerung durch cert-manager (alle 60 Tage):

1. cert-manager erneuert `wildcard-apps-tls` im `traefik` Namespace
2. Reflector erkennt die Aenderung und aktualisiert die Kopie im `korifi` Namespace
3. Contour liest das aktualisierte Secret und nutzt das neue Zertifikat

Kein manueller Eingriff erforderlich.

## Zertifikat-Uebersicht

| Zertifikat | Namespace | Issuer | Genutzt von | Reflection |
|------------|-----------|--------|-------------|------------|
| `wildcard-development-tls` | traefik | letsencrypt-prod | Traefik (alle `*.development.cfapps.cool` Services) | nicht noetig |
| `wildcard-apps-tls` | traefik | letsencrypt-prod | Traefik (direkt) + Contour (via Reflection) | → korifi |

## Komponenten

| Komponente | Version | Namespace | Zweck |
|------------|---------|-----------|-------|
| cert-manager | v1.x | cert-manager | Let's Encrypt Zertifikat-Ausstellung und -Erneuerung |
| kubernetes-reflector | latest | kube-system | Cross-Namespace Secret-Synchronisation |
| Traefik | v3.x | traefik | Ingress fuer Platform-Services |
| Contour | v1.33.x | projectcontour | Gateway API Controller fuer Korifi CF-Apps |
