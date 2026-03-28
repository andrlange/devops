# Distribution Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package the K8s DevOps stack as `installer.sh` + `stack.tgz` so colleagues can deploy it on their Apple Silicon Macs.

**Architecture:** A pre-flight `installer.sh` handles system checks, tool installation, and registry auth. It unpacks `stack.tgz` (containing `k8/` + `demos/`) and hands off to the existing `distribution/install.sh`. Multi-stack support via Lima VM name isolation. A `build-distribution.sh` script produces both deliverables.

**Tech Stack:** Bash, Lima, K3s, Helm, Docker, skopeo, crane

**Spec:** `k8/docs/superpowers/specs/2026-03-28-distribution-package-design.md`

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `installer.sh` | Pre-flight wizard: system checks, tool install, registry auth, unpack |
| `build-distribution.sh` | Build script: creates `dist/installer.sh` + `dist/stack.tgz` |
| `GETTING_STARTED.md` | English installation guide with DNS setup, troubleshooting |

### Modified Files

| File | Changes |
|------|---------|
| `k8/stack.sh` | Multi-VM detection for start/stop/status, new `deletestack` command |
| `k8/distribution/install.sh` | VM name uniqueness check, credentials.md generation, DNS A-record hint after Phase 1 |
| `k8/config.env` | Write chosen `LIMA_VM_NAME` during install |
| `.gitignore` | Add `credentials.md`, `dist/` |

---

## Task 1: installer.sh — System Prerequisites

**Files:**
- Create: `installer.sh`

- [ ] **Step 1: Create installer.sh with banner and system checks**

Create `installer.sh` in repo root with:
- Shebang, `set -euo pipefail`
- Color/logging functions (reuse pattern from `k8/distribution/lib/colors.sh`)
- Banner with version and welcome message
- System checks:
  - macOS version >= 26.0 via `sw_vers -productVersion`
  - Chip M4+ via `system_profiler SPHardwareDataType | grep Chip` — regex `Apple M([0-9]+)`, require >= 4
  - Architecture arm64 via `uname -m`
  - RAM >= 64GB via `sysctl -n hw.memsize`
  - Free disk >= 500GB via `df -g /`
- Each check prints `[OK]` or `[FAIL]` with specific reason
- Any failure = abort with summary

- [ ] **Step 2: Verify system checks work**

Run: `bash installer.sh`
Expected: All 5 checks pass with green checkmarks on your M5 Max.

- [ ] **Step 3: Commit**

```bash
git add installer.sh
git commit -m "feat(installer): add system prerequisite checks"
```

---

## Task 2: installer.sh — Tool Installation

**Files:**
- Modify: `installer.sh`

- [ ] **Step 1: Add tool check and install logic**

Add to `installer.sh`:
- Function `check_tool(name, command, min_version)` — checks if command exists, optionally checks version
- Function `install_tool(name, brew_formula)` — installs via brew
- Required tools table (brew, docker, limactl, kubectl, helm, jq, gettext, skopeo, crane, cf-cli@8)
- Optional tools table (go, argocd, velero, k9s)
- Display status table with installed/missing/version columns
- Brew check: if missing, install via official installer (requires sudo)
- Docker Desktop: `brew install --cask docker` — if just installed, prompt to start and wait for daemon
- "X required tools missing. Install automatically? [Y/n]"
- "Install optional tools? (go, argocd, velero, k9s) [y/N]"
- If user declines required tools: abort

- [ ] **Step 2: Test with all tools already installed**

Run: `bash installer.sh`
Expected: All tools show as installed, no install prompt.

- [ ] **Step 3: Test with a missing optional tool**

Run: `brew uninstall k9s 2>/dev/null; bash installer.sh`
Expected: k9s shows as missing in optional section, offered for install.
Cleanup: `brew install k9s` if desired.

- [ ] **Step 4: Commit**

```bash
git add installer.sh
git commit -m "feat(installer): add tool check and auto-installation"
```

---

## Task 3: installer.sh — Registry Authentication

**Files:**
- Modify: `installer.sh`

- [ ] **Step 1: Add registry auth flow**

Add to `installer.sh` after tool installation:
- Print registry auth banner (credentials provided by administrator)
- Prompt for username and API token (token input hidden with `read -rs`)
- Validate via curl: `curl -sf -u "<user>:<token>" "https://artifactory.cfapps.cool/v2/token?service=artifact-keeper"`
- If Docker running: also `docker login artifactory.cfapps.cool -u <user> -p <token>`
- Retry up to 3 times on failure
- Store validated credentials in memory (written to `.install-config` in Task 4)

- [ ] **Step 2: Test with valid svc-stack token**

Run: `bash installer.sh`
Enter: `svc-stack` / `<your-api-token>` (use a valid svc-stack token)
Expected: "Connected to artifactory.cfapps.cool" + docker login success.

- [ ] **Step 3: Test with invalid token**

Run: `bash installer.sh`
Enter: `svc-stack` / `invalid-token`
Expected: Retry prompt, abort after 3 failures.

- [ ] **Step 4: Commit**

```bash
git add installer.sh
git commit -m "feat(installer): add registry authentication with token validation"
```

---

## Task 4: installer.sh — Unpack & Configure

**Files:**
- Modify: `installer.sh`

- [ ] **Step 1: Add unpack and config logic**

Add to `installer.sh`:
- Ask for install directory (default: `~/devops-stack`)
- If directory exists: "Directory exists. Overwrite? [y/N]"
- Verify SHA256 checksum of `stack.tgz` (variable `EXPECTED_CHECKSUM` at top of script, populated by build-distribution.sh)
- Extract `stack.tgz` to chosen directory
- Write `.install-config` in `<dir>/k8/distribution/` with:
  ```
  REGISTRY="artifactory.cfapps.cool"
  REGISTRY_REPO="docker-local"
  REGISTRY_USER="<username>"
  REGISTRY_PASS="<api-token>"
  ```
  (chmod 600)
- Print next steps:
  ```
  Stack unpacked to ~/devops-stack

  Next steps:
    1. Set up DNS (see GETTING_STARTED.md)
    2. cd ~/devops-stack/k8/distribution && ./install.sh
  ```

- [ ] **Step 2: Verify unpack logic compiles (dry run)**

Note: Full end-to-end test deferred to Task 12 (after build-distribution.sh creates a proper bundle with embedded checksum). For now, verify the code logic by reading through the unpack function.

- [ ] **Step 3: Commit**

```bash
git add installer.sh
git commit -m "feat(installer): add unpack, checksum verification, and config writing"
```

---

## Task 5: build-distribution.sh

**Files:**
- Create: `build-distribution.sh`

- [ ] **Step 1: Create build script**

Create `build-distribution.sh` in repo root:
- Creates `dist/` output directory
- Builds `stack.tgz` from `k8/` and `demos/` with exclusions:
  ```bash
  tar czf dist/stack.tgz \
    --exclude='.git' --exclude='.DS_Store' \
    --exclude='.env' --exclude='.env.local' \
    --exclude='.install-config' --exclude='.install-state' \
    --exclude='credentials.md' \
    --exclude='.superpowers' \
    --exclude='source' --exclude='artifactory' --exclude='otel' \
    -C "$(pwd)" k8/ demos/ GETTING_STARTED.md
  ```
- Computes SHA256 of `stack.tgz`
- Copies `installer.sh` to `dist/installer.sh`, replacing `EXPECTED_CHECKSUM="PLACEHOLDER"` with actual checksum
- Makes `dist/installer.sh` executable
- Prints summary: file sizes, checksum, output path

- [ ] **Step 2: Run build and verify output**

Run: `bash build-distribution.sh`
Expected: `dist/installer.sh` and `dist/stack.tgz` created, checksum embedded.

- [ ] **Step 3: Verify checksum validation works**

Run: `cd dist && bash installer.sh` (should pass checksum check)
Then: `echo "corrupt" >> dist/stack.tgz && cd dist && bash installer.sh` (should fail checksum)

- [ ] **Step 4: Commit**

```bash
git add build-distribution.sh
git commit -m "feat: add build-distribution.sh for creating installer.sh + stack.tgz"
```

---

## Task 6: stack.sh — Multi-VM Detection

**Files:**
- Modify: `k8/stack.sh`

- [ ] **Step 1: Add VM detection functions**

Add to `k8/stack.sh` after the existing helper functions (after line ~76):

```bash
# Detect all k3s-* Lima VMs
list_k3s_vms() {
    limactl list --json 2>/dev/null | jq -r 'select(.name | startswith("k3s-")) | "\(.name)\t\(.status)"'
}

# Detect the running k3s-* VM (expect 0 or 1)
detect_running_vm() {
    limactl list --json 2>/dev/null | jq -r 'select(.name | startswith("k3s-") and .status == "Running") | .name'
}

# Read domain from a VM's install-config.
# During install, the domain is written to config.env inside the Lima VM.
# We can read it via limactl shell, or from the host's install-config if available.
vm_domain() {
    local vm_name="$1"
    # Try reading PLATFORM_DOMAIN from the VM's config.env via limactl
    if limactl list --json 2>/dev/null | jq -e --arg n "$vm_name" 'select(.name == $n and .status == "Running")' &>/dev/null; then
        limactl shell "$vm_name" grep "^PLATFORM_DOMAIN=" /mnt/k8/config.env 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown"
    else
        # VM not running — try finding config.env in known install directories
        for dir in "${HOME}/devops-stack" "${HOME}/development/devops"; do
            local cfg="${dir}/k8/config.env"
            if [[ -f "$cfg" ]]; then
                grep "^PLATFORM_DOMAIN=" "$cfg" 2>/dev/null | cut -d= -f2 | tr -d '"' && return
            fi
        done
        echo "unknown"
    fi
}

# Prompt user to select a VM if multiple exist
select_vm() {
    local vms=()
    while IFS=$'\t' read -r name status; do
        [[ -n "$name" ]] && vms+=("$name" "$status")
    done < <(list_k3s_vms)

    local count=$(( ${#vms[@]} / 2 ))
    if [[ $count -eq 0 ]]; then
        err "No k3s-* Lima VMs found."
        return 1
    elif [[ $count -eq 1 ]]; then
        echo "${vms[0]}"
        return 0
    fi

    info "Multiple stacks found:"
    for ((i=0; i<${#vms[@]}; i+=2)); do
        local idx=$(( i/2 + 1 ))
        local name="${vms[$i]}"
        local status="${vms[$((i+1))]}"
        local domain=$(vm_domain "$name")
        printf "  %d) %-20s (%s)  - %s\n" "$idx" "$name" "$status" "$domain"
    done
    echo ""
    local choice
    read -rp "Select stack [1]: " choice
    choice="${choice:-1}"
    local selected_idx=$(( (choice - 1) * 2 ))
    if [[ $selected_idx -ge 0 && $selected_idx -lt ${#vms[@]} ]]; then
        echo "${vms[$selected_idx]}"
    else
        err "Invalid selection"
        return 1
    fi
}
```

- [ ] **Step 2: Verify detection with current VM**

Run: `source k8/stack.sh; list_k3s_vms` (temporarily, or add a debug command)
Expected: Shows `k3s-server Running`

- [ ] **Step 3: Commit**

```bash
git add k8/stack.sh
git commit -m "feat(stack): add multi-VM detection functions"
```

---

## Task 7: stack.sh — Integrate Multi-VM into start/stop/status

**Files:**
- Modify: `k8/stack.sh`

- [ ] **Step 1: Modify cmd_start to use select_vm**

In `cmd_start()` (~line 86), add VM selection before the existing logic:
```bash
cmd_start() {
    header "Starting K8s DevOps Stack"

    # Multi-VM: select which stack to start
    LIMA_VM_NAME=$(select_vm) || exit 1
    KUBE_CONTEXT="k3s-${LIMA_VM_NAME}"

    # ... rest of existing cmd_start
```

- [ ] **Step 2: Modify cmd_stop to auto-detect running VM**

In `cmd_stop()`, detect the running VM instead of using config.env:
```bash
cmd_stop() {
    # Auto-detect running VM
    local running_vm
    running_vm=$(detect_running_vm)
    if [[ -z "$running_vm" ]]; then
        info "No stack is currently running."
        return 0
    fi
    LIMA_VM_NAME="$running_vm"
    KUBE_CONTEXT="k3s-${LIMA_VM_NAME}"

    # ... rest of existing cmd_stop
```

- [ ] **Step 3: Modify cmd_status similarly**

In `cmd_status()`, detect running VM. If none running, list all available VMs with their status.

- [ ] **Step 4: Test with single VM**

Run: `./k8/stack.sh status`
Expected: Auto-detects `k3s-server`, shows full status.

- [ ] **Step 5: Commit**

```bash
git add k8/stack.sh
git commit -m "feat(stack): integrate multi-VM detection into start/stop/status"
```

---

## Task 8: stack.sh — deletestack Command

**Files:**
- Modify: `k8/stack.sh`

- [ ] **Step 1: Add cmd_deletestack function**

Add new function and wire into main case statement:

```bash
cmd_deletestack() {
    header "Delete Stack"
    require_cmd limactl

    local vms=()
    while IFS=$'\t' read -r name status; do
        [[ -n "$name" ]] && vms+=("$name" "$status")
    done < <(list_k3s_vms)

    local count=$(( ${#vms[@]} / 2 ))
    if [[ $count -eq 0 ]]; then
        info "No stacks found."
        return 0
    fi

    info "Available stacks:"
    for ((i=0; i<${#vms[@]}; i+=2)); do
        local idx=$(( i/2 + 1 ))
        local name="${vms[$i]}"
        local status="${vms[$((i+1))]}"
        local domain=$(vm_domain "$name")
        printf "  %d) %-20s (%s)  - %s\n" "$idx" "$name" "$status" "$domain"
    done
    echo ""
    local choice
    read -rp "Select stack to delete [none]: " choice
    [[ -z "$choice" ]] && { info "No stack selected."; return 0; }

    local selected_idx=$(( (choice - 1) * 2 ))
    if [[ $selected_idx -lt 0 || $selected_idx -ge ${#vms[@]} ]]; then
        err "Invalid selection"
        return 1
    fi
    local target="${vms[$selected_idx]}"
    local target_status="${vms[$((selected_idx+1))]}"

    # Stop if running
    if [[ "$target_status" == "Running" ]]; then
        warn "VM '${target}' is running. It will be stopped first."
    fi

    # Safety confirmation
    echo ""
    warn "WARNING: This will permanently delete Lima VM '${target}'"
    warn "and all data inside it (K3s cluster, volumes, secrets)."
    warn "This action cannot be undone."
    echo ""
    local confirm
    read -rp "Type '${target}' to confirm deletion: " confirm
    if [[ "$confirm" != "$target" ]]; then
        info "Deletion cancelled."
        return 0
    fi

    if [[ "$target_status" == "Running" ]]; then
        info "Stopping VM '${target}'..."
        limactl stop "$target"
    fi

    info "Deleting VM '${target}'..."
    limactl delete "$target"

    # Clean up kubeconfig context
    kubectl config delete-context "k3s-${target}" 2>/dev/null || true
    kubectl config delete-cluster "k3s-${target}" 2>/dev/null || true
    kubectl config delete-user "k3s-${target}" 2>/dev/null || true

    ok "Stack '${target}' deleted."
}
```

Add to case statement (~line 1050):
```bash
deletestack) cmd_deletestack ;;
```

Update usage function to include `deletestack`.

- [ ] **Step 2: Test listing (no actual deletion)**

Run: `./k8/stack.sh deletestack`
Expected: Lists k3s-server, prompts for selection, enter empty to cancel.

- [ ] **Step 3: Commit**

```bash
git add k8/stack.sh
git commit -m "feat(stack): add deletestack command with safety confirmation"
```

---

## Task 9: install.sh — VM Name Uniqueness Check

**Files:**
- Modify: `k8/distribution/install.sh`

- [ ] **Step 1: Add VM existence check in Phase 1**

In `install.sh`, in the Phase 1 section where the Lima VM is created (~line 315), add a check BEFORE `limactl create`:

```bash
# Check if VM name already exists (prevent accidental overwrite)
if limactl list --json 2>/dev/null | jq -e --arg name "$LIMA_VM_NAME" 'select(.name == $name)' &>/dev/null; then
    log_error "Lima VM '${LIMA_VM_NAME}' already exists."
    log_error "Choose a different name or delete the existing VM with:"
    log_error "  limactl delete ${LIMA_VM_NAME}"
    log_error "  or: ./k8/stack.sh deletestack"
    exit 1
fi
```

This replaces the current logic that starts an existing VM (lines 315-324).

Also ensure the chosen VM name is written to `config.env`:
```bash
sed -i '' "s/^LIMA_VM_NAME=.*/LIMA_VM_NAME=\"${LIMA_VM_NAME}\"/" "${K8_DIR}/config.env"
```

- [ ] **Step 2: Add .gitignore entries**

Add to `.gitignore`:
```
credentials.md
dist/
```

- [ ] **Step 3: Verify check works**

Run: `LIMA_VM_NAME=k3s-server ./k8/distribution/install.sh phase 1`
Expected: Aborts with "Lima VM 'k3s-server' already exists."

- [ ] **Step 4: Commit**

```bash
git add k8/distribution/install.sh k8/config.env .gitignore
git commit -m "feat(install): add VM name uniqueness check, config.env update, gitignore"
```

---

## Task 10: install.sh — credentials.md Generation

**Files:**
- Modify: `k8/distribution/install.sh`

- [ ] **Step 1: Add credentials.md writer function**

Add a function `write_credentials()` to `install.sh` that writes/updates `credentials.md`:

```bash
write_credentials() {
    local cred_file="${SCRIPT_DIR}/../../credentials.md"
    local domain="${PLATFORM_DOMAIN:-unknown}"

    cat > "$cred_file" <<CRED_EOF
# Stack Credentials

> WARNING: Development environment only — do not use in production

Generated: $(date '+%Y-%m-%d %H:%M') | Domain: ${domain}

## Platform Access

| Service | URL | Username | Password |
|---------|-----|----------|----------|
CRED_EOF

    # Phase 1: OpenBao
    if [[ -n "${OPENBAO_ROOT_TOKEN:-}" ]]; then
        cat >> "$cred_file" <<PHASE1
## Infrastructure (Phase 1)
| Service | Details |
|---------|---------|
| OpenBao | Root Token: ${OPENBAO_ROOT_TOKEN} |
| OpenBao | Unseal Key 1: ${OPENBAO_UNSEAL_KEY_1:-} |
| OpenBao | Unseal Key 2: ${OPENBAO_UNSEAL_KEY_2:-} |
| OpenBao | Unseal Key 3: ${OPENBAO_UNSEAL_KEY_3:-} |
PHASE1
    fi

    # Phase 2: Platform services
    [[ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]] && \
        echo "| ArgoCD | https://argocd.${domain} | admin | ${ARGOCD_ADMIN_PASSWORD} |" >> "$cred_file"
    [[ -n "${GARAGE_ADMIN_KEY:-}" ]] && \
        echo "| Garage S3 | Admin Key: ${GARAGE_ADMIN_KEY} / Secret: ${GARAGE_ADMIN_SECRET:-} |" >> "$cred_file"

    # Phase 3: Monitoring
    [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]] && \
        echo "| Grafana | https://grafana.${domain} | admin | ${GRAFANA_ADMIN_PASSWORD} |" >> "$cred_file"

    # Phase 4: Services
    [[ -n "${AK_ADMIN_PASSWORD:-}" ]] && \
        echo "| artifact-keeper | https://artifactory.${domain} | admin | ${AK_ADMIN_PASSWORD} |" >> "$cred_file"

    # Phase 5: GitLab
    [[ -n "${GITLAB_ROOT_PASSWORD:-}" ]] && \
        echo "| GitLab | https://gitlab.${domain} | root | ${GITLAB_ROOT_PASSWORD} |" >> "$cred_file"

    chmod 600 "$cred_file"
}
```

Call `write_credentials` at the end of each phase function.

- [ ] **Step 2: Add DNS A-record hint after Phase 1 MetalLB deployment**

After MetalLB is deployed in Phase 1, print:
```bash
log_info ""
log_info "=============================================="
log_info "  DNS Configuration Required"
log_info "=============================================="
log_info ""
log_info "  Add these DNS records to your DNS provider:"
log_info ""
log_info "  *.${PLATFORM_DOMAIN}  →  A  192.168.64.200"
log_info "  *.${APPS_DOMAIN}     →  A  192.168.64.203"
log_info ""
log_info "=============================================="
```

- [ ] **Step 3: Commit**

```bash
git add k8/distribution/install.sh
git commit -m "feat(install): add credentials.md generation and DNS hint"
```

---

## Task 11: GETTING_STARTED.md

**Files:**
- Create: `GETTING_STARTED.md`

- [ ] **Step 1: Write GETTING_STARTED.md**

Create `GETTING_STARTED.md` in repo root with sections:

1. **Prerequisites** — M4+ Mac, 64GB RAM, 500GB disk, macOS 26.0+, credentials from administrator
2. **Quick Start** — Run `installer.sh`, then `cd <dir>/k8/distribution && ./install.sh`
3. **DNS Setup**
   - **Google Cloud DNS:** `gcloud` commands to create project, enable API, create service account with `dns.admin` role, download JSON key
   - **AWS Route 53:** `aws` commands to create IAM user, attach Route53FullAccess policy, create access key
   - **DNS A-Records:** `*.development.<domain>` → `192.168.64.200`, `*.app.<domain>` → `192.168.64.203`
4. **Installation Phases** — Table with phase 1-6 (required) + phase 7 (optional, requires Go)
5. **Post-Installation** — `stack.sh start/stop/status`, service URLs, reference to `credentials.md`
6. **Troubleshooting** — Lima VM, ImagePullBackOff, certs, OpenBao, MetalLB, common errors
7. **Updating** — Pull new images, restart deployments
8. **Multi-Stack** — Running multiple stacks, `deletestack`, testing workflow

- [ ] **Step 2: Review for completeness**

Read through, verify all URLs and commands are accurate.

- [ ] **Step 3: Commit**

```bash
git add GETTING_STARTED.md
git commit -m "docs: add GETTING_STARTED.md for stack distribution"
```

---

## Task 12: Integration Test

**Files:** All previously created/modified files

- [ ] **Step 1: Run build-distribution.sh**

```bash
bash build-distribution.sh
ls -lh dist/
```
Expected: `dist/installer.sh` (~15-20KB) and `dist/stack.tgz` (~several MB)

- [ ] **Step 2: Test installer.sh end-to-end (dry run)**

```bash
cd dist
bash installer.sh
```
Expected: System checks pass, tools detected, token validated, stack unpacked to chosen directory.

- [ ] **Step 3: Verify unpacked structure**

```bash
ls ~/devops-stack/k8/distribution/install.sh
ls ~/devops-stack/GETTING_STARTED.md
cat ~/devops-stack/k8/distribution/.install-config | head -4
```
Expected: install.sh exists, GETTING_STARTED.md exists, .install-config has registry credentials.

- [ ] **Step 4: Test stack.sh multi-VM features**

```bash
./k8/stack.sh status         # auto-detect running VM
./k8/stack.sh deletestack    # list VMs, cancel without deleting
```

- [ ] **Step 5: Clean up test directory**

```bash
rm -rf ~/devops-stack
```

- [ ] **Step 6: Final commit (if any remaining changes)**

```bash
git add installer.sh build-distribution.sh GETTING_STARTED.md k8/stack.sh k8/distribution/install.sh k8/config.env .gitignore
git commit -m "feat(distribution): complete installer.sh + build-distribution.sh + GETTING_STARTED.md"
```
