# Artifact-Keeper Upgrade Plan

**From:** `andrlange/artifact-keeper-backend:v1.1.0-rc.8-patched-arm64` + `andrlange/artifact-keeper-web:v1.1.0-rc.8-patched-arm64` (custom local fork with 3 backend + 2 web patches)

**To:** Upstream `ghcr.io/artifact-keeper/artifact-keeper:v1.1.8` + `ghcr.io/artifact-keeper/artifact-keeper-web:v1.1.3`, mirrored to `artifactory.cfapps.cool/docker-local/`

**Date:** 2026-04-27

## 1. Goal

Eliminate the local custom build of artifact-keeper. Switch to upstream releases, drop all five local patches, retire `~/development/devops/artifactory/scripts/build-containers.sh` from the operational path.

## 2. Why this is safe now

### 2.1 Patch retirement (all obsolete)

| Patch file | Concern | Status in upstream |
|---|---|---|
| `patches/backend/001-fix-token-list-revoked-filter.patch` | `token_service.rs::list_user_tokens` returned revoked tokens | ✅ Already in v1.1.8 (`backend/src/services/token_service.rs:230` — `WHERE user_id = $1 AND revoked_at IS NULL`) |
| `patches/backend/002-fix-user-tokens-list-revoked-filter.patch` | `users.rs::list_user_tokens` HTTP handler same bug | ✅ Already in v1.1.8 (`backend/src/api/handlers/users.rs:658`) |
| `patches/backend/003-add-api-token-support-for-docker-v2-token.patch` | Docker `/v2/token` endpoint did not accept API token in Basic Auth password field | ✅ Already in v1.1.8 (`oci_v2.rs:682+`); upstream version is more sophisticated — adds anonymous pull tokens, scope-restriction warnings, Bearer fallback |
| `patches/web/001-fix-permissions-target-select.patch` | Permissions admin: free-text Target field instead of repo dropdown | ✅ Already in v1.1.3 (`src/app/(app)/(admin)/permissions/page.tsx:17,118,407` — imports `repositoriesApi`, fetches repos, dynamic Target label) |
| `patches/web/002-fix-select-in-dialog-z-index.patch` | (a) Radix Select dropdowns hide behind Dialog overlays; (b) workaround removing broken `listScanConfigs` call | (a) ⚠️ Not addressed upstream — may still be needed; (b) ✅ `listScanConfigs` is back in v1.1.3 — verify it works before re-applying any workaround |

### 2.2 Backend↔Web compatibility

| Repo | Tag | Released |
|---|---|---|
| `artifact-keeper/artifact-keeper` | v1.1.8 | 2026-04-21 |
| `artifact-keeper/artifact-keeper-web` | v1.1.3 | 2026-04-20 |

- Web's `package.json` pins `@artifact-keeper/sdk: ^1.1.4` — caret matches the same 1.1.x train as backend v1.1.8
- Both repos maintained on synchronized `release/1.1.x` branches; release dates within 24h
- No breaking-change entries in either changelog between rc.8 and current tag

**Verdict:** v1.1.8 backend + v1.1.3 web are designed to run together.

## 3. Pre-flight

```bash
# 1. confirm cluster healthy
kubectl -n artifact-keeper get pods
kubectl -n artifact-keeper rollout status deploy/artifact-keeper

# 2. confirm running tag
kubectl -n artifact-keeper get deploy/artifact-keeper -o jsonpath='{.spec.template.spec.containers[*].image}'
kubectl -n artifact-keeper get deploy/artifact-keeper-web -o jsonpath='{.spec.template.spec.containers[*].image}'

# 3. take a Velero backup of the artifact-keeper namespace
velero backup create ak-pre-v118 --include-namespaces artifact-keeper --wait

# 4. db backup (in-pod pg_dump piped to host)
kubectl -n artifact-keeper exec sts/artifact-keeper-postgresql -- \
  pg_dump -U artifact_keeper -d artifact_keeper -Fc \
  > /tmp/ak-pre-v118.dump

# 5. confirm artifactory has space for two new ~500MB images
df -h on the artifactory host (or check Garage usage)
```

Stop conditions: any pod CrashLooping, Velero backup failing, or pg_dump non-zero exit.

## 4. Mirror upstream images

The deployment pulls from `artifactory.cfapps.cool/docker-local/...`. Upstream releases at `ghcr.io/artifact-keeper/...`. Mirror with skopeo (multi-arch).

```bash
# Login to local registry
skopeo login artifactory.cfapps.cool

# Backend — multi-arch (linux/amd64 + linux/arm64) → tag-suffixed per repo convention
skopeo copy --multi-arch all \
  docker://ghcr.io/artifact-keeper/artifact-keeper:v1.1.8 \
  docker://artifactory.cfapps.cool/docker-local/artifact-keeper/artifact-keeper:v1.1.8

# Web UI — multi-arch
skopeo copy --multi-arch all \
  docker://ghcr.io/artifact-keeper/artifact-keeper-web:v1.1.3 \
  docker://artifactory.cfapps.cool/docker-local/artifact-keeper/artifact-keeper-web:v1.1.3

# Optional: arch-specific aliases matching the repo naming convention
# (set-arch.sh expects "-arm64" suffixes, but the upstream multi-arch manifest
# already resolves correctly per node, so this is only needed if a values.yaml
# explicitly references the suffix)
for arch in arm64 amd64; do
  skopeo copy --override-arch=$arch --override-os=linux \
    docker://ghcr.io/artifact-keeper/artifact-keeper:v1.1.8 \
    docker://artifactory.cfapps.cool/docker-local/artifact-keeper/artifact-keeper:v1.1.8-$arch
  skopeo copy --override-arch=$arch --override-os=linux \
    docker://ghcr.io/artifact-keeper/artifact-keeper-web:v1.1.3 \
    docker://artifactory.cfapps.cool/docker-local/artifact-keeper/artifact-keeper-web:v1.1.3-$arch
done
```

Verification:

```bash
# Inspect the mirrored manifest
skopeo inspect --raw \
  docker://artifactory.cfapps.cool/docker-local/artifact-keeper/artifact-keeper:v1.1.8 \
  | jq '.manifests[] | {arch:.platform.architecture, digest:.digest}'
```

## 5. Update K8s manifests

Two image references need to change. Both live in this repo on `main`.

| File | Line | Old | New |
|---|---|---|---|
| `k8/services/artifact-keeper/artifact-keeper/deployment.yaml` | 48 | `andrlange/artifact-keeper-backend:v1.1.0-rc.8-patched-arm64` | `artifact-keeper/artifact-keeper:v1.1.8-arm64` |
| `k8/services/artifact-keeper/artifact-keeper/deployment-web.yaml` | 22 | `andrlange/artifact-keeper-web:v1.1.0-rc.8-patched-arm64` | `artifact-keeper/artifact-keeper-web:v1.1.3-arm64` |

Both prefixed with `artifactory.cfapps.cool/docker-local/`. The `set-arch.sh` script handles the `-arm64`/`-amd64` suffix swap if you later switch ARCH in `config.env`.

```bash
# Apply edits, then commit on a topic branch
git checkout -b feature/artifact-keeper-v1.1.8
$EDITOR k8/services/artifact-keeper/artifact-keeper/deployment.yaml
$EDITOR k8/services/artifact-keeper/artifact-keeper/deployment-web.yaml
git add -p
git commit -m "feat(artifact-keeper): upgrade to upstream v1.1.8 + web v1.1.3"
```

Also update the Phase 4 line in `CLAUDE.md`:

```
- **Phase 4 (Services):** Deployed — artifact-keeper Backend v1.1.8 + Web UI v1.1.3 ...
```

## 6. Rollout

```bash
# ArgoCD will pick this up if synced; otherwise direct apply
kubectl -n artifact-keeper apply -f k8/services/artifact-keeper/artifact-keeper/deployment.yaml
kubectl -n artifact-keeper apply -f k8/services/artifact-keeper/artifact-keeper/deployment-web.yaml

# Watch rollout
kubectl -n artifact-keeper rollout status deploy/artifact-keeper --timeout=5m
kubectl -n artifact-keeper rollout status deploy/artifact-keeper-web --timeout=5m

# DB migrations run on backend startup. Tail the log to confirm clean migration:
kubectl -n artifact-keeper logs -f deploy/artifact-keeper | grep -iE "migrat|error|panic"
```

## 7. Verification (golden path)

Run these against the live `https://artifactory.cfapps.cool` after rollout:

1. **UI loads** — visit the web UI, log in as admin
2. **Version banner** — settings/footer should show `1.1.8` (backend) and `1.1.3` (web)
3. **Docker login + push + pull**
   ```bash
   docker login artifactory.cfapps.cool
   docker pull alpine:3.20
   docker tag alpine:3.20 artifactory.cfapps.cool/docker-local/test-upgrade:1
   docker push artifactory.cfapps.cool/docker-local/test-upgrade:1
   docker pull artifactory.cfapps.cool/docker-local/test-upgrade:1
   ```
4. **API token auth** — patch 003 verification: create an API token, then
   ```bash
   docker login -u <user> -p <api-token> artifactory.cfapps.cool
   ```
   Should succeed (this is the v1.1.8 built-in fallback).
5. **Revoked token filter** — patches 001/002 verification:
   - Create a token, revoke it via UI
   - Listing tokens should not include the revoked one (UI + `GET /api/v1/users/{id}/tokens`)
6. **Permissions admin** — patch web 001 verification:
   - Permissions page → Add Permission → Target Type = "repository" → Target field is a dropdown of repo keys, not a free-text input
7. **Security dashboard** — patch web 002 verification:
   - Open Security page, click the repo dropdown inside the dialog
   - **Expected:** dropdown renders fully visible (z-index fix may not be needed in v1.1.3)
   - **If clipped/hidden behind dialog overlay:** apply contingency in §10
8. **Trigger scan** — Security → Scans page → trigger a scan on a repo
   - **Expected:** the `listScanConfigs` query (back in v1.1.3) works and the repo dropdown shows correct disabled-scan states

If 1–6 pass: upgrade is successful regardless of 7–8 outcome.

## 8. Rollback

If verification fails:

```bash
# Option A: revert the deployment manifests via git
git revert <upgrade-commit>
kubectl -n artifact-keeper apply -f k8/services/artifact-keeper/artifact-keeper/deployment.yaml
kubectl -n artifact-keeper apply -f k8/services/artifact-keeper/artifact-keeper/deployment-web.yaml

# Option B: imperative image rollback
kubectl -n artifact-keeper set image deploy/artifact-keeper \
  artifact-keeper=artifactory.cfapps.cool/docker-local/andrlange/artifact-keeper-backend:v1.1.0-rc.8-patched-arm64
kubectl -n artifact-keeper set image deploy/artifact-keeper-web \
  artifact-keeper-web=artifactory.cfapps.cool/docker-local/andrlange/artifact-keeper-web:v1.1.0-rc.8-patched-arm64

# Option C: full namespace restore from Velero (only if DB schema migrated and broke)
velero restore create --from-backup ak-pre-v118
```

The old patched images stay in `docker-local` indefinitely — no immediate cleanup.

## 9. Post-upgrade cleanup

After 1 week of stable operation:

1. **Archive local patches**
   ```bash
   cd ~/development/devops/artifactory/source
   mv patches patches.archived-2026-04-27
   ```
2. **Stop tracking the source repos in the working tree**
   - `~/development/devops/artifactory/source/backend` and `.../web` no longer need to follow upstream main
   - They can be removed; if kept, document them as "reference only, not used to build images"
3. **Retire `artifactory/scripts/build-containers.sh`** — leave the file but add a header note: "Superseded by direct mirror from ghcr.io/artifact-keeper as of 2026-04-27. See `k8/docs/ARTIFACT_KEEPER_UPGRADE.md`."
4. **Drop the unused `andrlange/artifact-keeper-*` images** from `docker-local` after a confirmed-stable period (use the artifact-keeper UI or API).

## 10. Contingency: web z-index workaround

Only if §7.7 verification shows Radix Select dropdowns hidden behind Dialog overlays in v1.1.3:

```bash
# Reapply just the z-index hunks of patches/web/002 to a fork branch
# Files affected:
#   src/app/(app)/(admin)/security/page.tsx              (lines ~774, ~808)
#   src/app/(app)/(admin)/security/scans/page.tsx        (lines ~456, ~498)
# Change: <SelectContent>  →  <SelectContent position="popper" className="z-[9999]">
```

Build a one-off web image:

```bash
cd ~/development/devops/artifactory/source/web
git fetch && git checkout v1.1.3 -b local/v1.1.3-zfix
# apply just the z-index hunks (NOT the listScanConfigs removal)
git apply --include='**/security/**' ../patches/web/002-fix-select-in-dialog-z-index.patch
docker buildx build --platform=linux/arm64,linux/amd64 \
  -t artifactory.cfapps.cool/docker-local/artifact-keeper/artifact-keeper-web:v1.1.3-zfix \
  --push .
```

Update `deployment-web.yaml:22` to `:v1.1.3-zfix-arm64`.

File a GitHub issue upstream against `artifact-keeper/artifact-keeper-web` so this lands in the next release and the workaround can retire.

## 11. Open question: image registry path

The upstream images publish at `ghcr.io/artifact-keeper/artifact-keeper` and `ghcr.io/artifact-keeper/artifact-keeper-web`. The proposed local mirror path is:

```
artifactory.cfapps.cool/docker-local/artifact-keeper/artifact-keeper
artifactory.cfapps.cool/docker-local/artifact-keeper/artifact-keeper-web
```

This differs from the previous `andrlange/artifact-keeper-backend` / `andrlange/artifact-keeper-web` namespace. Confirm:

- The pull secret `artifact-keeper-pull` (per `k8/config.env`) has read access to the new path. If permissions are scoped per-namespace in artifact-keeper, grant the pull-user read on the `artifact-keeper/*` namespace before rollout.
- No other deployment outside this repo references the old `andrlange/...` tags.
