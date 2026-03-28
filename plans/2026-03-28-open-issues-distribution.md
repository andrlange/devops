# Distribution Package — Open Issues

**Date:** 2026-03-28
**Context:** After testing the distribution installer end-to-end on a fresh k3s-test VM

---

## Summary

The installer.sh pre-flight, tool installation, registry auth, and unpack work correctly.
The install.sh Iteration Zero, Phase 1 (Foundation), Phase 2 (Platform), and Phase 3 (Monitoring)
run through but several services fail to start because:

1. **43 YAML files** have hardcoded `cfapps.cool` domains that need parametrization
2. **OpenBao secrets** for Garage S3 are not bootstrapped automatically
3. **Garage ConfigMap** has placeholder tokens and hardcoded values

---

## Issue 1: Hardcoded Domains in 43 YAML Files

All IngressRoutes, ConfigMaps, and some Helm values.yaml files reference `development.cfapps.cool`
or `app.cfapps.cool` instead of using the configured `$PLATFORM_DOMAIN` / `$APPS_DOMAIN`.

**Fix:** After Iteration Zero writes `.install-config`, run a domain substitution pass across
all YAML files in `k8/`:

```bash
# Replace domains in all manifests
find "${K8_DIR}" -name "*.yaml" -o -name "*.yml" -o -name "*.toml" | while read -r f; do
  sed -i '' \
    -e "s/development\.cfapps\.cool/${PLATFORM_DOMAIN}/g" \
    -e "s/app\.cfapps\.cool/${APPS_DOMAIN}/g" \
    "$f"
done
```

This should run once after Iteration Zero, before Phase 1 starts.

**Files affected:** IngressRoutes, ConfigMaps (Garage, Alloy), Helm values.yaml (Grafana, Traefik),
GitLab CE manifests, Korifi configs, Service Broker configs.

---

## Issue 2: Missing OpenBao Secrets for Garage S3

The automated OpenBao bootstrap (Phase 1.3) currently stores only:
- `secret/k8s/registry` (registry pull credentials)
- `secret/dns/google-cloud` or `secret/dns/aws` (DNS provider)
- `secret/grafana/admin` (Grafana password)

But the following secrets are also needed and currently NOT bootstrapped:

| OpenBao Path | Needed By | Content |
|---|---|---|
| `secret/garage/admin` | Garage S3 Manager | access_key, secret_key |
| `secret/garage/admin-token` | CF Service Broker | token |
| `secret/garage/loki` | Loki | access_key, secret_key |
| `secret/garage/mimir` | Mimir | access_key, secret_key |
| `secret/garage/tempo` | Tempo | access_key, secret_key |
| `secret/garage/velero` | Velero | access_key, secret_key |
| `secret/garage/artifacts` | artifact-keeper | access_key, secret_key |
| `secret/artifact-keeper/postgres` | artifact-keeper | username, password, database |
| `secret/artifact-keeper/meilisearch` | artifact-keeper (Meilisearch) | master_key |
| `secret/artifact-keeper/app` | artifact-keeper Backend | jwt_secret, admin_password, migration_encryption_key |
| `secret/gitlab/admin` | GitLab CE | root_password |
| `secret/gitlab/runner` | GitLab Runner | token (created during Phase 5) |

**Fix:** The install.sh must:
1. After Garage is deployed (Phase 2.3), initialize Garage via its admin API:
   - Generate admin token, store in OpenBao
   - Create S3 API keys for loki, mimir, tempo, velero, artifacts
   - Store each in OpenBao
2. Before Phase 4 (artifact-keeper), generate and store:
   - PostgreSQL credentials
   - Meilisearch master key
   - JWT secret + admin password + migration key
3. Before Phase 5 (GitLab), generate and store:
   - GitLab root password

These should all use `generate_password` and be stored both in OpenBao and in `credentials.md`.

---

## Issue 3: Garage ConfigMap Hardcoded Values

File: `k8/platform/garage/configmap.yaml`

Problems:
- `rpc_secret` is hardcoded (should be generated per installation)
- `admin_token` is `GARAGE_ADMIN_TOKEN_PLACEHOLDER` (needs actual token)
- `root_domain` references `cfapps.cool` (covered by Issue 1)

**Fix:** Generate `rpc_secret` and `admin_token` during Phase 2.3, patch the ConfigMap,
and restart Garage.

---

## Issue 4: Contour IP for Apps Domain

File: `k8/distribution/install.sh` line ~1360

The Contour/Envoy LoadBalancer IP annotation is derived from `METALLB_IP_RANGE` variables
that are only set during Phase 1 MetalLB step. Phase 6 (Korifi) needs these variables
available. They should be stored in `.install-config` or derived from config.env.

---

## Priority Order

1. **Domain substitution** (Issue 1) — blocks everything, do first
2. **Garage bootstrap** (Issues 2+3) — blocks Phase 2 completion and all services using S3
3. **OpenBao secrets for remaining services** (Issue 2) — blocks Phases 3-5
4. **Contour IP** (Issue 4) — only affects Phase 6 (optional)

---

## What Works Today

- installer.sh: system checks, tool install, registry auth, unpack — all working
- install.sh: Iteration Zero config gathering — working
- install.sh: Phase 1 Foundation — working (Lima VM, K3s, OpenBao, ESO, MetalLB, Traefik, cert-manager)
- install.sh: Phase 2 Platform — partially (ArgoCD, Portainer work; Garage, Technitium, Velero need fixes)
- stack.sh: multi-VM detection, start/stop/status, deletestack — working
- build-distribution.sh: creates installer.sh + stack.tgz — working
- GETTING_STARTED.md: complete
- credentials.md: generated but incomplete (needs more secrets)
