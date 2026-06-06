# Plane B Remote Runbook — vault (OpenBao) + artifactory (artifact-keeper)

> **You are a Claude Code agent running ON the remote Plane B server.** Execute this runbook with
> full agency, but follow the **safety gates** exactly and **STOP + report** at each checkpoint.
> A human relays your reports to the planning session (Plane A) and relays back any go/no-go.

## How to run

- **Interactive:** open Claude Code in `/home/deploy`, then: *"Follow `planeb-remote-runbook.md` starting at Phase 0. Stop at each REPORT gate."*
- **Headless (one phase at a time):** `claude -p "Follow planeb-remote-runbook.md, do Phase 0 only, then print the REPORT block."`
- Do **not** run all phases unattended. Stop at every `🚦 REPORT` and wait for go/no-go.

## Who/where

- **Host user:** `deploy` (has **sudo**). If your user can't run `docker` directly, prefix with `sudo`
  (e.g. `sudo docker compose ...`). Detect once: `docker ps >/dev/null 2>&1 || echo "use sudo"`.
- **Scope — ONLY these two directories. Touch NOTHING else on this server:**
  - `/home/deploy/vault/` — OpenBao stack
  - `/home/deploy/artifactory/` — artifact-keeper (this is the container **registry** that Plane A pulls from)
- If a `docker-compose*.yml` inside either folder contains an **LGTM / mimir / loki / tempo / grafana**
  monitoring stack, align those image tags too (see target table). If there is **no** such stack, skip it —
  do not introduce one.

## Overriding constraints (read first)

1. **Do not break anything.** Every change is backup-first and reversible. If a verification fails, **roll
   back that stack** and STOP — do not continue to the next phase.
2. **artifactory = the pull-source for Plane A.** While the artifact-keeper app is down, *nothing* elsewhere
   can pull images. Treat Phase 3 as a **maintenance window**, do it **LAST**, and keep the rollback image ready.
3. **Pin everything** (no `:latest`). Use the exact tags in the target table.
4. **Preserve data + config:** named volumes, `.env` files, secrets, TLS/cert material, storage backends and
   bind mounts must be retained as-is. Only image **tags** (and, in Phase 3, the search backend) change.
5. **Discover, don't assume.** This runbook was authored without seeing your exact files. Inspect the real
   compose/service/.env layout and adapt; apply the *targets and verification criteria*, not blind diffs.

## Target versions

| Component | Current (expected) | **Target** | Notes |
|---|---|---|---|
| **vault/ — OpenBao** | `openbao/openbao:2.5.1` | `openbao/openbao:2.5.4` | match Plane A in-cluster |
| **vault/ — PostgreSQL** | `postgres:18` | `postgres:18.4` | latest 18 patch |
| **vault/ — nginx** | `nginx:alpine` | `nginx:1.30.2-alpine` | pin |
| **vault/ — certbot** | `certbot/certbot:latest` | `certbot/certbot:v5.6.0` | pin (note the **`v`** prefix) |
| **otel-collector (either stack)** | `otel/opentelemetry-collector-contrib:0.120.0` | `:0.153.0` | **audit pipeline config** (see Phase 1c) |
| **Embedded LGTM — Mimir** | `grafana/mimir:2.15.0` | `grafana/mimir:3.1.0` | **MAJOR 2→3 — blue/green, see Phase 2b** |
| **Embedded LGTM — Loki** | `grafana/loki:3.4.2` | `grafana/loki:3.7.2` | |
| **Embedded LGTM — Tempo** | `grafana/tempo:2.7.2` | `grafana/tempo:2.10.5` | |
| **Embedded LGTM — Grafana** | `grafana/grafana:11.5.2` | `grafana/grafana:12.4.3` | **11→12 removes AngularJS — audit dashboards** |
| **artifactory — supporting (pg/nginx/certbot/collector)** | as above | same targets as above | |
| **artifactory — artifact-keeper backend** | `…artifact-keeper-backend:v1.1.0-rc.8-patched` | `ghcr.io/artifact-keeper/artifact-keeper-backend:1.2.0` | **official** image (patches are upstream now); multi-arch |
| **artifactory — artifact-keeper web** | `…artifact-keeper-web:v1.1.0-rc.8-patched` | `ghcr.io/artifact-keeper/artifact-keeper-web:1.2.0` | official, multi-arch |
| **artifactory — search backend** | `getmeili/meilisearch:v1.39.0` | `opensearchproject/opensearch:2.19.5` | **Meilisearch is REMOVED in 1.2.0 → replace with OpenSearch** |

All target tags verified to exist upstream (multi-arch where relevant), so the server's architecture pulls
the correct variant automatically.

---

## Phase 0 — Pre-flight (discovery + backups)

```bash
cd /home/deploy
DOCKER="docker"; docker ps >/dev/null 2>&1 || DOCKER="sudo docker"
$DOCKER --version; $DOCKER compose version; uname -m   # note arch
```

**0a. Discover** both stacks (do NOT change anything yet):
```bash
for s in vault artifactory; do
  echo "===== $s ====="; ls -la /home/deploy/$s
  echo "--- compose files ---"; ls /home/deploy/$s/docker-compose*.yml 2>/dev/null
  echo "--- images referenced ---"; grep -rnE "image:" /home/deploy/$s/*.yml /home/deploy/$s/**/*.yml 2>/dev/null
  echo "--- running containers ---"; (cd /home/deploy/$s && $DOCKER compose ps 2>/dev/null)
  echo "--- .env keys (names only, NO values) ---"; [ -f /home/deploy/$s/.env ] && grep -oE "^[A-Z_]+=" /home/deploy/$s/.env
done
```
Note especially, for artifactory: the **storage backend** (filesystem vs s3 — look for `STORAGE_BACKEND`,
`S3_*` keys), the **search** service (meilisearch), and the **current artifact-keeper version/image source**.

**0b. Back up** each stack (use its own script if present; otherwise snapshot compose+env+volumes):
```bash
for s in vault artifactory; do
  cd /home/deploy/$s
  if [ -x scripts/backup.sh ]; then ./scripts/backup.sh; else
     ts=$(date +%Y%m%d-%H%M%S)
     tar czf /home/deploy/${s}-config-${ts}.tgz docker-compose*.yml .env* 2>/dev/null
     echo "config backed up to /home/deploy/${s}-config-${ts}.tgz (named volumes NOT in this tar — see note)"
  fi
done
```
> For artifactory specifically: ensure the **PostgreSQL data** and the **registry blob storage** are backed up
> (DB dump + volume/bind-mount copy) before Phase 3 — that is the irreplaceable state.

### 🚦 REPORT 0 — paste this back to the planner
```
PHASE 0 REPORT
- arch: <x86_64|aarch64>   docker: <ver>   compose: <ver>   sudo-needed: <yes/no>
- vault: compose files=<list>; images=<list with current tags>; LGTM present=<yes/no>; running=<ps summary>
- artifactory: compose files=<list>; images=<list>; AK backend image+tag=<...>; search=<meili?>; STORAGE_BACKEND=<filesystem/s3/unset>; LGTM present=<yes/no>; running=<ps summary>
- backups: vault=<path/result>; artifactory config+DB+blobs=<paths/result>
- questions/anomalies: <...>
```
**STOP. Wait for go/no-go before Phase 1.**

---

## Phase 1 — vault stack (OpenBao)

OpenBao is a stateful, possibly **sealed** service — handle like Plane A's Wave 4.

**1a.** In `/home/deploy/vault/`, edit the compose file(s): set the pinned tags from the table
(`openbao 2.5.4`, `postgres 18.4`, `nginx 1.30.2-alpine`, `certbot v5.6.0`, collector `0.153.0` if present).
Change **only** the image tags. Keep all volumes/env/ports/mounts.

**1b.** Roll one service group at a time, postgres first if it's a dependency:
```bash
cd /home/deploy/vault
$DOCKER compose pull
$DOCKER compose up -d
$DOCKER compose ps
```

**1c. otel-collector 0.120→0.153 audit (if present):** 0.153 spans 33 minor releases. Before/after `up`,
check the collector starts cleanly and isn't rejecting config:
```bash
$DOCKER compose logs --since 3m <collector-service> | grep -iE "error|invalid|unknown|deprecat|failed" | head
```
If it crash-loops on config, the usual causes are renamed/removed receiver/processor/exporter keys — fix the
named key per the log, or temporarily pin the collector back to `0.120.0` and report it (don't block OpenBao on it).

**1d. Verify:**
- OpenBao: container healthy; if it auto-unseals, status is unsealed; otherwise **unseal it** with the existing
  keys. `bao status` (or via the API) shows `Sealed=false`, correct version `2.5.4`.
- PostgreSQL `18.4` up; OpenBao connects (no auth/DB errors in logs).
- TLS endpoint (nginx) serves OpenBao UI/API over HTTPS as before.

### 🚦 REPORT 1 — vault
```
PHASE 1 REPORT
- images now: openbao=<>, postgres=<>, nginx=<>, certbot=<>, collector=<>
- openbao: sealed=<false>, version=<2.5.4>, health=<ok>
- postgres: <ok>   tls/nginx: <ok>   collector: <ok|pinned-back|n/a>
- rollback used? <no|details>
```
**STOP. Wait for go/no-go.** (If anything failed: `docker compose down` and restore the pre-Phase-1 tags + `up -d`, then report.)

---

## Phase 2 — artifactory: supporting images + embedded LGTM

Do the **lower-risk** parts of the artifactory stack here; the artifact-keeper **app** itself is Phase 3.

**2a. Supporting images:** in `/home/deploy/artifactory/`, bump `postgres → 18.4`, `nginx → 1.30.2-alpine`,
`certbot → v5.6.0`, collector `→ 0.153.0` (if present). **Do NOT touch the artifact-keeper backend/web image
or the search service yet.** You can apply these together with Phase 3 if you prefer a single restart — but if
you do them now, only restart the affected supporting containers:
```bash
cd /home/deploy/artifactory
$DOCKER compose pull postgres nginx certbot <collector>   # only the services you changed
$DOCKER compose up -d postgres nginx certbot <collector>
```

**2b. Embedded LGTM / Mimir 2→3 (only if this folder runs one):**
- Loki `3.7.2`, Tempo `2.10.5`, Grafana `12.4.3` are normal tag bumps.
- **Mimir `2.15 → 3.1` is a MAJOR upgrade — do blue/green, not in-place**, to avoid losing TSDB/blocks:
  1. Stand up a **second** Mimir service (`mimir-v3`) on the new image, pointed at the **same** object/bucket
     storage (read path) but writing to a new prefix, or run it read-only against existing blocks first.
  2. Point Grafana's Mimir datasource at `mimir-v3`; confirm dashboards/queries return data.
  3. Cut writes (remote_write / collector exporter) over to `mimir-v3`.
  4. Once stable, retire the old `mimir` 2.15 service.
  - Mimir 3 moves config to a ConfigMap-style default and makes **MQE** the default query engine — keep your
    existing config file mounted and set `configStorageType` appropriately if you externalize config.
  - If this is a throwaway/dev monitoring stack and metric history is **not** worth the blue/green effort,
    an in-place bump is acceptable **only with explicit go-ahead** — report and ask first.
- **Grafana 11→12 removes AngularJS.** Before cutting over, in Grafana check
  *Administration → Plugins/Dashboards* for Angular-deprecation warnings; note any dashboard/panel that uses a
  legacy Angular plugin so it can be migrated. Don't delete dashboards.

**2c. Verify:** Grafana `12.4.3` loads; all datasources (Mimir/Loki/Tempo) **health-check OK**; recent metrics,
logs, and traces are queryable; no panel render errors.

### 🚦 REPORT 2 — artifactory supporting + LGTM
```
PHASE 2 REPORT
- supporting images now: postgres=<>, nginx=<>, certbot=<>, collector=<>
- LGTM present=<yes/no>; if yes: loki=<>, tempo=<>, grafana=<>, mimir=<old+new during blue/green>
- mimir migration: <blue/green done | read-OK, writes cut | in-place (approved) | n/a>
- grafana datasources health: <mimir/loki/tempo = ok>; angular-deprecation findings: <list/none>
- rollback used? <no|details>
```
**STOP. Wait for go/no-go before the artifact-keeper app upgrade.**

---

## Phase 3 — artifact-keeper app: rc.8-patched → 1.2.0  ⚠️ MAINTENANCE WINDOW (do LAST)

> While this is down, **Plane A and everything else cannot pull images.** Have the rollback image (the current
> rc.8-patched) ready. Confirm Phase 0 backups (DB + blob storage) are good before starting.

**Lessons already learned on Plane A (Wave 7) — bake these in, don't rediscover:**

1. **Use the OFFICIAL images** `ghcr.io/artifact-keeper/artifact-keeper-{backend,web}:1.2.0` (multi-arch). The
   custom `…rc.8-patched` patches are all upstream in 1.2.0 — drop the custom image. (Sanity-check: nothing in
   your `.env`/compose depends on a patch behavior that 1.2.0 lacks — none known.)
2. **Search backend swap — Meilisearch is REMOVED in 1.2.0.** Replace the `meilisearch` service with an
   **OpenSearch** single node:
   - image `opensearchproject/opensearch:2.19.5`
   - env: `discovery.type=single-node`, `DISABLE_SECURITY_PLUGIN=true` (no creds, internal only),
     `OPENSEARCH_JAVA_OPTS=-Xms1g -Xmx1g` (raise if the box has RAM; OpenSearch is JVM-heavy — check free RAM).
   - persist its data dir to a named volume.
   - remove the old meilisearch service + its volume **after** a successful cutover (keep until verified).
3. **artifact-keeper env contract changed in 1.2.0 — update the backend service env:**
   - `MEILISEARCH_URL` / `MEILI_*` → **`OPENSEARCH_URL`** (e.g. `http://opensearch:9200`)
   - `S3_ACCESS_KEY` → **`S3_ACCESS_KEY_ID`**, `S3_SECRET_KEY` → **`S3_SECRET_ACCESS_KEY`** (only if this
     server uses an S3 backend)
   - **`STORAGE_BACKEND`** now defaults to `filesystem` and is **required to be explicit**. Set it to whatever
     this server currently uses (from Phase 0 discovery): `filesystem` (keep existing bind/volume path) or `s3`.
     **Do not silently switch backends** — that would orphan existing blobs.
4. **Migration null-decode bug — you MUST hop through 1.1.9.** A direct rc.8(`schema v71`) → 1.2.0 upgrade
   crash-loops with `decoding column 0: unexpected null` (the 1.2.0 `migration_repair` assumes a v1.1.9 schema).
   Sequence:
   1. First set the backend image to **`ghcr.io/artifact-keeper/artifact-keeper-backend:1.1.9`**, `up -d`,
      wait until it's healthy (it applies migrations 72–75; search disabled is fine for this hop).
   2. Then set it to **`1.2.0`**, `up -d`. 1.2.0's repair now finds the 1.1.9 checksums, rewrites, and applies
      the rest. (A *fresh* install would not need this hop — but this server is rc.8, so it does.)

**3a.** Edit `/home/deploy/artifactory/` compose: replace meilisearch→opensearch service, update backend env
keys, set web image to `…-web:1.2.0`, and set backend image to **`1.1.9`** for the first hop.
```bash
cd /home/deploy/artifactory
$DOCKER compose pull opensearch artifact-keeper-backend artifact-keeper-web   # adapt service names
$DOCKER compose up -d opensearch
# wait for opensearch green/yellow:
until curl -sf http://localhost:9200/_cluster/health >/dev/null 2>&1 || \
      $DOCKER compose exec -T opensearch curl -sf http://localhost:9200/_cluster/health >/dev/null 2>&1; do
  echo "waiting for opensearch..."; sleep 3; done
$DOCKER compose up -d <backend>   # at image 1.1.9
$DOCKER compose logs -f --since 1m <backend>   # watch migrations 72-75 apply; wait for healthy
```

**3b. Hop to 1.2.0:**
```bash
# set backend image tag to 1.2.0 in compose, then:
$DOCKER compose up -d <backend> <web>
$DOCKER compose logs -f --since 1m <backend>   # repair + migrations to v113; wait for healthy
```

**3c. Reindex search** (1.2.0 auto-reindexes on first start if the index is empty; otherwise trigger it):
```bash
# via API (admin creds): POST /api/v1/admin/search/reindex   (or /api/admin/reindex on older routes)
```

**3d. Verify (all must pass before declaring success):**
- backend `/health` 200; web UI 200; version shows 1.2.0.
- **A docker pull from Plane A works** (this is the whole point): from a Plane A host,
  `crane manifest <registry>/docker-local/<some-existing-keeper-tag>` resolves, and a `docker pull` succeeds.
- search returns results (UI search or `GET /api/v1/...?q=`); artifact count looks right vs Phase 0.
- storage backend unchanged: existing image tags still pull (blobs intact).
- OpenSearch container healthy; meilisearch container stopped/removed (only after the above pass).

### 🚦 REPORT 3 — artifact-keeper
```
PHASE 3 REPORT
- backend image: <ghcr…:1.2.0>   web: <…:1.2.0>   search: opensearch 2.19.5 (meili removed=<yes/no>)
- migration: hop 1.1.9 applied=<yes>, 1.2.0 healthy=<yes>, final schema/health=<ok>
- STORAGE_BACKEND=<filesystem/s3> (unchanged from Phase 0)
- pull test from Plane A: <ok/fail + detail>
- search/reindex: <ok, N artifacts>
- rollback used? <no | restored rc.8-patched + meili, detail>
- downtime window: <start–end>
```

---

## Rollback (any phase)

1. `cd /home/deploy/<stack>`
2. Restore the previous compose/.env (from the Phase-0 tar or `scripts/backup.sh` output).
3. `docker compose up -d` with the **old** image tags.
4. For artifact-keeper: roll the backend image back to `…rc.8-patched`, restore the meilisearch service, and
   restore the DB dump **only if** the 1.1.9/1.2.0 migrations ran and you must go back (schema is forward-migrated;
   going back requires the pre-upgrade DB backup).
5. Verify health, then report what happened.

## Final report (after all phases pass)
```
PLANE B COMPLETE
- vault: openbao 2.5.4 / pg 18.4 / nginx 1.30.2 / certbot v5.6.0  — healthy
- artifactory: AK 1.2.0 + OpenSearch 2.19.5, supporting images pinned, (LGTM aligned if present) — healthy
- pull-source verified from Plane A; downtime <window>; backups retained at <paths>
- anything deferred/anomalous: <...>
```
