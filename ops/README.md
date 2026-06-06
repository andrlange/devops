# ops/ — Lima VM lifecycle (backup · delete · restore)

Host-side (macOS / Apple Silicon) scripts to snapshot, tear down, and restore the
entire stack by operating on the **Lima VM** that runs K3s. Because the whole
stack — K3s plus every PersistentVolume — lives inside the VM's single `disk`
file, backing up the VM directory captures *everything* in one shot.

These read `k8/config.env` for `LIMA_VM_NAME` (default `k3s-server`).

## Scripts

| Script | What it does |
|---|---|
| `backup_full.sh` | Stops the VM (for consistency), clones the VM disk + config, Lima SSH keys, and host config (`k8/config.env`, `k8/.env.local`) into a timestamped backup, restarts the VM if it was running. |
| `delete_full.sh` | Fully deletes the VM (stack + all in-VM data) **and keeps backups**, so you can run the installer from scratch. Refuses unless a backup exists (`--force` to override). |
| `restore_full.sh` | **Refuses if a VM already exists**; otherwise clones a backup back into place, restores keys/config if missing, starts the VM, regenerates the kubeconfig. |

## How the backup works

- **Engine:** APFS `cp -c` clonefile — near-instant and copy-on-write, so a
  backup of the 72 GB (sparse) disk takes seconds and shares blocks with the
  live VM until they diverge. Runtime sockets/pids/logs are skipped.
- **Constraint:** the backup location must be on the **same APFS volume** as
  `~/.lima` (the scripts error clearly if it isn't).
- **Location:** `~/lima-stack-backups/<vm-name>/<timestamp>/`, with a `latest`
  symlink. Override with `STACK_BACKUP_DIR=/path`.

Layout of one backup:

```
<timestamp>/
├── vm/            # cloned ~/.lima/<vm> (disk, lima.yaml, cidata.iso, vz-*, …)
├── lima-config/   # Lima shared SSH keys (user, user.pub, networks.yaml)
├── host-config/   # k8/config.env, k8/.env.local
└── manifest.txt   # vm name, date, lima version, disk size, mount path, …
```

## Typical workflow — test a from-scratch install

```bash
ops/backup_full.sh                 # snapshot current working stack
ops/delete_full.sh                 # tear the VM down (backups kept)
bash installer.sh                  # run the installer from scratch and test
# …if you want the old stack back:
ops/restore_full.sh                # restore the latest backup, exactly as it was
```

Restore a specific point in time:

```bash
ops/restore_full.sh 20260606-201500
# or an explicit path:
ops/restore_full.sh ~/lima-stack-backups/k3s-server/20260606-201500
```

## Notes & caveats

- **Same-Mac, same-volume** by design. To move a backup off-machine, copy the
  timestamped directory to an external drive yourself (it stops being a CoW
  clone once on another filesystem).
- A clone on the same physical disk is *not* disaster-recovery — it shares the
  underlying drive with the live VM. It is built for the delete-→-reinstall-→-restore
  test cycle, not for surviving a disk failure.
- `restore_full.sh` keeps existing `~/.lima/_config` keys and existing
  `k8/config.env` / `k8/.env.local` rather than overwriting them.
- The VM remembers the host path it mounts (`k8/`); restore warns if that path
  no longer exists on the machine.
- OpenBao unseal keys are **not** part of these backups — keep them in your
  password manager (see the root `CLAUDE.md`).
