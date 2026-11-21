# PE Lab — Provisioning Wizard

A self-contained, one-shot wizard that provisions Puppet Enterprise (PE) nodes and
installs PE via **peadm**. It supports running PE in Docker containers (all-in-one on
this host, or on a provisioned cloud VM) and directly on cloud VMs.

The wizard is **modular**: `pelab.sh` is the entry point and sources logical modules
from `./lib/`. The original monolithic `setup.sh` is preserved untouched as a reference.

---

## Quick start

```bash
# As root (writes /etc/hosts, uses /root paths)
cd /root/pelab
./pelab.sh
```

The wizard is interactive and remembers your choices between runs in
`setup_wizard_defaults.json`. If anything fails, re-run it — it cleans up and retries.

> **Note:** `./setup.sh` is the original single-file version and behaves identically.
> `./pelab.sh` is the modular equivalent. Use either.

---

## Requirements

- Run as **root / sudo** (writes `/etc/hosts`, uses `/root` paths).
- Internet access on first run (installs `curl`, `jq`, `bolt`, `git`, `ssh-keyscan`,
  and — for cloud runs — `terraform`; also installs the `peadm` Bolt module).
- For **GCP**: a GCP account with compute access. The wizard handles one-shot auth
  (login + ADC + project) on a brand-new jump host.
- For **Docker localhost**: Docker is auto-installed (`docker.io`) and started if missing.

---

## SSH key (required)

You need an **SSH key-pair** to access every provisioned node (VMs and containers).
This distribution ships one: `id_ed25519` (private) + `id_ed25519.pub` (public).

- The **private key** (`id_ed25519`) stays on the host you run the wizard from. It is
  used by Bolt for all connections. Keep it private and `chmod 600` it.
- The **public key** (`id_ed25519.pub`) is baked into the Terraform metadata **and**
  pushed to every node, so you can SSH in as `ssh_user` (default `root`) without a
  password.

You can **use the shipped key-pair** or **generate your own** — the wizard asks for
"Path to SSH PRIVATE key" and, if the file doesn't exist, offers to generate a new
RSA-4096 key-pair on the spot. Either way, the key must be present on the host you
run the wizard from.

> The private key must be readable by the user running the wizard. If you run as
> root, place it under `/root` (e.g. `/root/pelab/id_ed25519`).

---

## Deployment options

The wizard first asks for a **target deployment** (provider), then a **runtime**.

### Providers

| Provider | Status | Notes |
|---|---|---|
| `local` | **Active** | Docker all-in-one on **this host** — no cloud, no terraform, no sizing questions. PE containers run directly here. |
| `gcp` | **Active** | Google Cloud Platform. Full auth + terraform + provisioning. |
| `aws` | Coming soon | Scaffold only. |
| `azure` | Coming soon | Scaffold only. |

### Runtime (for cloud providers)

| Runtime | Description |
|---|---|
| `vm` | Provision VMs directly on the cloud provider. |
| `docker` | Run Docker containers on a single provisioned cloud VM (the "Docker host"). |

**Docker topology is always "separate"** — one container per Puppet role, all on the
single Docker-host VM. Containers are never split across multiple Docker hosts.

The Docker-host VM can be assigned a **static internal IP** for stability across
rebuilds.  When you pick Docker-on-cloud, the wizard asks for it one time,
pre-filling a suggestion derived from **that environment's** GCP subnet
(`lib/terraform.sh` sets `network_ip` from the saved `docker_host_static_ip`).
Enter `auto`/`none` (or blank) to use an **ephemeral** internal IP — GCP
auto-assigns, which is safe for any subnet/region and doesn't require knowing a
free address.  Pinning a static IP keeps the address stable instead of GCP
reassigning an ephemeral one when the VM is destroyed/recreated (which used to
surface as `docker_host_ip` in `setup_wizard_defaults.json` changing after every
build).  Only the container SSH/ports change; container-internal `172.x`
addresses are irrelevant to the wizard (it reaches containers via `host:port`).

Before `terraform apply`, the wizard **scans the GCP project** for the chosen
static IP (reserved addresses + instance network IPs, excluding the Docker-host
being replaced) and warns/aborts if it's already in use — so you find out
immediately instead of after a long SSH wait.  If `terraform apply` itself still
fails, the wizard now **stops** (it no longer proceeds to wait for SSH on an IP
that was never created).

---

## Topologies (installation type)

| Type | Nodes | Notes |
|---|---|---|
| `STANDARD` | 1 primary | Single-node, no replica. PostgreSQL co-located on the primary. |
| `LARGE` | primary + 2 compilers + HAProxy (+ replica if DR) | PostgreSQL co-located on primary/replica (peadm "Large"). |
| `XL` | primary + PDB + 2 compilers + HAProxy (+ replica/PDB if DR) | Separate PDB node. |

**Disaster Recovery (DR)** is offered for LARGE/XL and adds a primary-replica pair.

### HAProxy / nodepool compiler pool (LARGE/XL)

For LARGE and XL the HAProxy **fronts Puppet agent traffic on `:8140`** (the
Puppetserver API port).  Its backend round-robins across the **primary + every
compiler** (`compiler0`, `compiler1`) on `:8140` (plus the replica when DR is
enabled).  Agents are pointed at the **nodepool address** — for VM/cloud that is
the load-balancer address supplied as `compiler_pool_address`; for Docker it is the
HAProxy container FQDN.  That same address is injected into `params.json`
`dns_alt_names`, so the nodepool is in the server certificate SAN and TLS
verification succeeds regardless of which compiler serves the request:

```
agent  →  nodepool (DNS / /etc/hosts)  →  HAProxy :8140  →  round-robin  →  compiler0 / compiler1 (or primary)
```

On Docker the wizard also pins every node's FQDN → container IP into each
container's `/etc/hosts` so the nodepool address resolves inside the containers.
STANDARD has no HAProxy and no compilers, so this does not apply.

---

## Sizes

### VM runtime

| Size | GCP | AWS | Azure |
|---|---|---|---|
| Small | e2-custom-2-4096 | t3.medium | Standard_B2s |
| Medium | e2-custom-6-8192 | t3.large | Standard_B4ms |
| Large | e2-custom-8-12288 | m5.xlarge | Standard_D4s_v3 |

### Docker runtime (min = Large; Small/Medium not offered)

| Size | GCP | AWS | Azure | vCPU / RAM |
|---|---|---|---|---|
| Large | e2-custom-16-32768 | m5.2xlarge | Standard_D8s_v3 | 16 vCPU / 32 GB |
| XL | e2-custom-32-65536 | m5.4xlarge | Standard_E16s_v5 | 32 vCPU / 64 GB |
| XXL | e2-custom-32-131072 | m5.8xlarge | Standard_E32s_v5 | 32 vCPU / 128 GB |

> **Heavy topologies need XXL.** The single Docker host runs *every* container, so
> a LARGE-with-DR run (6 containers) on a smaller host can exhaust resources
> (`Connection closed by port 22`). Use **XXL** for LARGE/XL with DR.

---

## Add-ons

### Local git (gitnano) on the master

A lightweight control-repo manager (bare git repo + HTTP API + SSH loopback for r10k)
installed on `core0` after the PE install. When enabled, r10k is auto-wired to it and
the r10k prompts are skipped.

- Bare repo: `/opt/gitnano/repos/control-repo.git`
- Live worktree: `/var/www/production`
- API: `http://<core0>:5000` (Bearer token shown at the end)
- r10k remote: `gitnano@<core0>:/opt/gitnano/repos/control-repo.git`

### Hieranano (Hiera/eyaml UI) on the master

A web UI for browsing/editing Hiera YAML and eyaml in the control-repo. Always
installed and running on `core0`.

- URL: `https://<core0>:5525/?token=<token>`  (self-signed; `http://<core0>:5526` fallback)
- Runs as systemd services (`hieranano.service` HTTPS on :5525, `hieranano-http.service` HTTP on :5526), survives container restarts.

### OpenAINano (PE AI ↔ Ollama bridge) on the master

A Flask bridge (port 5001) that translates PE's AI infra-assistant to a local
Ollama instance. Installed on `core0` by default.

- URL: `http://<core0>:5001`
- Bridges to local Ollama: `http://127.0.0.1:11434`
- Runs as a systemd service (`openainano.service`), survives container restarts.
- **Ollama is installed on the master automatically** (port 11434).
- A local model is not powerful enough, so you must authenticate and pull a
  **cloud model**:
  ```
  ollama login
  ollama run <cloud-model>   # e.g. the model chosen in the wizard
  ```
  The wizard prints these instructions after install.

### Reponano (local apt/yum package repo) on the master

A local apt/yum package repo manager (Flask, port 3864) installed on `core0` by
default.  Offline nodes point their package manager at it instead of the internet.

- URL: `http://<core0>:3864`
- Storage: `/var/www/reponano`  (`<distro>/<ver>/<arch>`)
- Runs as a systemd service (`reponano.service`), survives container restarts.
- Sync a package: `curl -X POST http://<core0>:3864/sync -H 'Content-Type: application/json' -d '{"pkg":"sl","distro":"ubuntu","ver":"noble"}'`
- Client toggle on a node: `/root/reponano_client.sh <reponano-host> [distro] [ver] [arch]`  (`--restore` to go back online)
- Full offline pull: `/root/reponano_full_sync.sh [repo-ip] [port] [distro] [ver] [arch]`

### Forgenano (local Puppet Forge / module mirror) on the master

A local Puppet Forge (Flask, port 6157) installed on `core0` by default.  Offline
nodes install modules from it instead of the public Forge.

- URL: `http://<core0>:6157`
- Storage: `/var/lib/puppet_localforge`  (`<owner>-<name>-<version>.tar.gz`)
- Runs as a systemd service (`forgenano.service`), survives container restarts.
- Add a module: `curl -X POST http://<core0>:6157/v3/modules -H 'X-API-KEY: <admin-key>' -H 'Content-Type: application/json' -d '{"module":"puppetlabs-stdlib"}'`
- Populate: `/root/forgenano_populate.sh`   |   Workflow: `/root/forgenano_local.sh`

On install, forgenano also runs a **Puppetfile sync** (`/root/forgenano_sync.sh`):
it ensures **PDK** is present on the master (needed for `pdk build`), reads the
control-repo Puppetfile, mirrors every `mod 'owner-name'` into the local forge
(skipping `:git`/`:path`/`:svn`/`:hg` sources), then rewrites the Puppetfile's
`forge` line to `http://<core0>:6157` and commits it so r10k uses the local
forge.  A **Forge token** is prompted for (blank = public modules only; provide
one to mirror premium modules).

### Full offline build

If you answer **Y** to the wizard's *"Full offline build?"* question (asked first,
so it gates the add-on prompts), the wizard makes the lab runnable **without
internet** after install:

- **Y** — the wizard **enables reponano, forgenano, scanano and openainano**
  (all required to support offline) and **skips their individual prompts**
  (configurable values use the saved defaults).  It also does the pull + switch
  below.
- **N** — the wizard keeps asking each add-on's install prompt as normal, and
  does **not** pull the packages/modules or change the repo/Puppetfile.

When Y, the offline steps are:

1. **Reponano** pulls the full package manifest (`/root/reponano_full_sync.sh`)
   into the local repo — every package in the manifest plus its direct
   dependencies (`deps=false`; the full recursive closure on a complete Ubuntu
   repo is impractically large).  The manifest covers the nano add-on deps,
   PE/agent packages, `pdk`, and common tools (edit the `PACKAGES=(…)` list in
   the script to match your lab).
2. **Forgenano** pulls the full module catalog (`/root/forgenano_populate.sh`)
   into the local forge, in addition to the control-repo Puppetfile sync.
3. **Forgenano → Reponano package closure** — after forgenano populates the
   module catalog, `/root/reponano_forgenano_sync.sh` asks forgenano's
   `/admin/inspect_all` which OS packages its built modules declare (it scans
each module's `.pp` files for `package { 'name': }` resources), then feeds each
   into reponano `deps=false`.  So if a module manages `grafana`, the `grafana`
   OS package is also pulled into reponano and Puppet can install it offline.
   (Runs *before* the apt switch so the master can still download.)
4. **Reponano client switch** — the master and every client node get
   `/root/reponano_client.sh` and are pointed at the master reponano
   (`http://<core0>:3864/repo/…`), so their apt no longer needs the internet.
5. **Puppetfile** already points at the master forgenano (local forge) from the
   sync, so r10k installs modules locally.

After this, the lab can run fully offline.  Use `/root/reponano_client.sh --restore`
on any node to switch it back to the online apt sources.

> **Note — full-offline dependency caveat.**  reponano can only download a
> package (and its direct deps) that the master's apt can resolve at sync time.
> Packages not in a base Ubuntu image's sources — e.g. `pdk` (apt.puppet.com
> `puppet-tools`) and the `pe-*` PE packages (the master's internal `pe_repo`) —
> are only pulled if those repos are configured on the master before the full
> sync/forgenano closure.  The forgenano→reponano closure captures the OS
> packages Puppet modules declare (e.g. `glusterfs-server`, `freeipmi`), which
> are the common "offline circular" case; add any extra repos to the master's
> sources before the wizard runs if you need those packages offline too.

### Scanano (CVE-enabled vulnerability scan bridge) on the master

A Nessus-API mimic (Flask, HTTPS port 9000) installed on `core0` by default.  It
runs nmap scans with the vulners script and exports results as Nessus XML.

- URL: `https://<core0>:9000`
- Runs as a systemd service (`scanano.service`), survives container restarts.
- Test: `curl -k https://<core0>:9000/scans`
- API token: (generated at install; see helper output)

### Configurable values (with defaults)

**Ports are fixed defaults** (not prompted) and are chosen so they don't overlap.
Only the non-port values below are asked about in the wizard (press Enter to
accept).  Values are persisted in `setup_wizard_defaults.json` and applied to the
installer before it runs on the master.

| Add-on | Value | Default |
|---|---|---|
| gitnano | API port | `5000` |
| hieranano | port | `5525` |
| hieranano | HTTP fallback port | `5526` |
| openainano | port | `5001` |
| openainano | Ollama model | `minimax-m2.5:cloud` |
| reponano | port | `3864` |
| reponano | full offline build | `false` (Y pulls all packages + modules, switches repo/forge to local) |
| forgenano | port | `6157` |
| forgenano | admin key | (generated at install) |
| forgenano | Forge token | blank (public modules only; provide one for premium) |
| scanano | port | `9000` |
| scanano | API token | (generated at install) |

### PE-install / base-OS / peadm values

| Key | Meaning | Default |
|---|---|---|
| `base_os` | the one OS choice; drives `pe_platform` + (Docker) `docker_base` | `ubuntu-24.04` |
| `pe_version` | PE version to install (`latest` or e.g. `2026.0.0`) | `latest` |
| `pe_platform` | PE tarball platform (derived from `base_os`) | `ubuntu-24.04-amd64` |
| `pe_tarball_path` | local PE tarball (`.tar.gz` **or** `.tar`); blank = download | blank |
| `custom_image` | GCP VM image for VM nodes + the Docker-host VM | `ubuntu-2404` |
| `docker_base` | container base OS (derived from `base_os`) | `ubuntu:24.04` |
| `docker_image` | Docker image the containers use; blank = build `pe-lab-base:<ver>` | blank |
| `peadm_module_dir` | local/custom peadm module path (skip fetching the latest) | blank |

---

## Offline PE tarball

Install PE without downloading the installer by giving a local tarball when
prompted ("Local PE tarball path (offline; empty to download)").

- Name it `puppet-enterprise-<version>-<platform>.tar.gz` — **or point at an
  uncompressed `.tar`** (the wizard gzips it during staging).
- If `pe_version` is `latest`, the version is derived from the tarball filename.
- The tarball is **validated before upload** (gzip integrity + a full `tar -t`
  listing), so a **truncated/incomplete download fails fast** with a clear error
  instead of deep inside `peadm::install`.
- If the version is newer than peadm knows (`2025.11`), the wizard sets
  `permit_unsafe_versions` automatically.

---

## Pre-release / experimental PE builds

You can install a **pre-release / internal PE build** (e.g. a `2026.0.0-rc`
tarball).  Three things must line up: the **PE tarball's platform**, the **node OS**
(VM image *or* Docker base image), and **peadm**.

### 1. Pick the OS once — "Base Operating System"
The wizard asks for a base OS that sets both the PE platform and (for Docker) the
container base:
```
ubuntu-24.04 | PE ubuntu-24.04-amd64 | Docker ubuntu:24.04
ubuntu-26.04 | PE ubuntu-26.04-amd64 | Docker ubuntu:26.04
el-8         | PE el-8-x86_64        | Docker rockylinux:8   (RHEL 8)
el-9         | PE el-9-x86_64        | Docker rockylinux:9   (RHEL 9)
```

> **Supported base OSes: Ubuntu 24.04 / 26.04 and RHEL 8 / 9 (el-8 / el-9).**
> These are the only choices in the menu.

- Writes `base_os`, `pe_platform`, and (for Docker) `docker_base` to
  `setup_wizard_defaults.json`.
- **VM** nodes use `custom_image` (GCP image, e.g. `ubuntu-2604`).
- **Docker** nodes use `docker_base` — the image is built `FROM` it.

### 2. Point at the (complete) tarball
- `pe_tarball_path` = `puppet-enterprise-<ver>-<platform>.tar.gz` (or `.tar`).
- Staged as `puppet-enterprise-<pe_version>-<pe_platform>.tar.gz`, auto-gzipped if
  needed, and validated (see above).
- `pe_version` must use peadm's format (`YYYY.M.P`, e.g. `2026.0.0`).
- `pe_platform` must equal the node OS — peadm **detects the target OS** and looks
  for exactly `puppet-enterprise-<version>-<detected-platform>.tar.gz`.

### 3. peadm handling — and where
| What | Where | Notes |
|---|---|---|
| `permit_unsafe_versions` | `lib/artefacts.sh` → `generate_params_json` | auto-set `true` when `pe_version > peadm_newest` so peadm accepts an unknown version |
| `peadm_newest` | `lib/common.sh` | the newest PE version peadm knows (currently `2025.11`) |
| `peadm_module_dir` | `lib/deps.sh` → `ensure_peadm_module` | if set, installs that local peadm module into Bolt's modulepath (`~/.puppetlabs/bolt/modules/peadm`) instead of fetching the latest; keeps existing deps |
| peadm invoked | `lib/peadm.sh` | `bolt plan run peadm::install --params @params.json` |

### Docker base image (multi-OS, `lib/docker.sh`)
The Dockerfile is **multi-OS**: it detects `apt`/`dnf`/`yum`/`zypper` at build time,
so the same Dockerfile builds on **Ubuntu and RHEL/CentOS/Rocky/Alma**.  `docker_base` is pinned into the Dockerfile's `FROM` on every run
(`ensure_dockerfile`), and the image is tagged `pe-lab-base:<os-version>`.  The
wizard builds it when `docker_image` is blank (or a local `pe-lab-base:*` tag) and
skips the build if the image already exists (e.g. after the Docker host is
recreated).

### Module-mirror build tooling — PDK (`ensure_pdk.sh`)
forgenano packages mirrored modules with `pdk build`, so PDK must be on the master.
`ensure_pdk.sh` installs it from `apt.puppet.com/puppet-tools`; because
apt.puppet.com only publishes repos for specific codenames, it **falls back**
(node codename → `noble` → `jammy`) so brand-new codenames (e.g. Ubuntu
`resolute`/26.04) work.

---

## Modular structure

```
pelab.sh                  Entry point: sources ./lib/*.sh, then runs the wizard
lib/
  common.sh               Globals, colour palette, all tui_* UI functions
  defaults.sh             load_defaults / save_defaults
  helpers.sh              build_fqdn, git_remote_host/port, docker_roles,
                          docker_ssh_port, docker_expose_ports, dh_ssh
  deps.sh                 install_dependencies, ensure_peadm_module,
                          install_provider_cli, check_gcp_auth, configure_ssh_key
  terraform.sh            generate_terraform_gcp/aws/azure
  artefacts.sh            generate_params_json, generate_inventory_yaml
  gcp.sh                  tf_run, gcp_ensure_auth, gcp_verify_compute,
                          gcp_import_firewall, gcp_get_token, gcp_destroy_existing
  docker.sh               docker_ensure_auth, ensure_docker_local,
                          ensure_dockerfile, docker_destroy_existing, build_docker_image
  embedded.sh             ensure_gitnano_script, ensure_hieranano_script,
                          ensure_openainano_script, ensure_ollama_script,
                          ensure_reponano_script,
                          ensure_reponano_full_sync_script,
                          ensure_reponano_forgenano_sync_script,
                          ensure_forgenano_script, ensure_scanano_script
                          (the embedded gitnano.sh / hieranano.sh / openainano.sh /
                          install_ollama.sh / reponano.sh / forgenano.sh / scanano.sh heredocs)
  gitnano.sh              set_gitnano_known_hosts, install_gitnano,
                          ensure_control_repo, install_hieranano, install_openainano,
                          install_reponano, install_forgenano, install_scanano
  docker_provision.sh     docker_provision, generate_docker_artefacts,
                          docker_provision_cloud
  installagent.sh         install_installagent (deploys /root/installagent.sh to every node)
  prep.sh                 wait_for_ssh, bootstrap_ssh_trust, pre_install_prep,
                          configure_haproxy
  peadm.sh                run_peadm_install, maybe_create_peadm_user
  access.sh               print_console_access (helper.md generation)
```

---

## Files in this distribution

| File / dir | Purpose |
|---|---|
| `pelab.sh` | Modular entry point (recommended). |
| `setup.sh` | Original monolithic version (reference, untouched). |
| `lib/` | All modules sourced by `pelab.sh`. |
| `setup_wizard_defaults.json` | Saved wizard choices (regenerated each run). |
| `suite-license.lic` | PE license uploaded to the primary. |
| `id_ed25519` / `.pub` | SSH keypair used for all connections. |
| `haproxy-bolt-project/` | Bolt project with the HAProxy plan (LARGE/XL). |
| `control-repo/` | Seed control-repo used by gitnano. |
| `openainano.sh` | PE AI ↔ Ollama bridge installer (embedded, written on demand). |
| `install_ollama.sh` | Installs Ollama on the master and prints `ollama login` + `ollama run <cloud-model>` instructions (embedded, written on demand). |
| `reponano.sh` | Local apt/yum package repo installer (embedded, written on demand). |
| `reponano_full_sync.sh` | Pulls the full package manifest (with deps) into reponano for a fully-offline build (embedded, written on demand). |
| `reponano_forgenano_sync.sh` | Closes the offline loop: asks forgenano which OS packages its built modules declare and syncs them into reponano (embedded, written on demand). |
| `forgenano.sh` | Local Puppet Forge / module mirror installer (embedded, written on demand). |
| `forgenano_sync.sh` | Mirrors the control-repo Puppetfile modules into forgenano and points the Puppetfile at the local forge (embedded, written on demand). |
| `scanano.sh` | CVE-enabled vuln scan bridge installer (embedded, written on demand). |
| `installagent.sh` | Standalone node agent (re)installer, deployed to `/root` on every node. |
| `ensure_pdk.sh` | Installs PDK on the master (required by forgenano's `pdk build`), with a codename fallback (embedded, written on demand). |
| `forgenano_populate.sh` | Mirrors the built-in + control-repo Puppetfile module catalog into forgenano (embedded, written on demand). |
| `docker/Dockerfile` | Multi-OS systemd base image (generated on demand; `FROM` pinned to `docker_base`). |

Everything else (terraform config, `params.json`, `inventory.yaml`, `gitnano.sh`,
`hieranano.sh`, `openainano.sh`, `install_ollama.sh`, `reponano.sh`, `reponano_full_sync.sh`, `forgenano.sh`, `forgenano_sync.sh`, `scanano.sh`,
`installagent.sh`, `helper.md`, the Docker image, etc.) is **generated automatically**
on each run.

---

## Access reference

At the end of a successful run the wizard prints how to reach the PE console and
connect agents, and writes a full reference to **`helper.md`** in the script directory
(including restart behavior and the static-IP caveat for Docker-on-cloud).

---

## Helper menu

Run `./pelab.sh helper` (or `./pelab.sh upgrade`) to operate on an **already-built**
PE environment — no infrastructure is provisioned; each helper builds the
inventory/params and runs the relevant peadm plan (or installer) against your
existing nodes.  Each helper appends an audit record to `helper.md`.

| Helper | What it does |
|---|---|
| `upgrade` | Upgrade PE to a new version (`peadm::upgrade`); supports a **specific installer source** (serve a local tarball over HTTP as `pe_installer_source`). |
| `add-compiler` | Add + provision compiler(s) to an existing cluster (`peadm::add_compilers`). |
| `add-replica` | Add/provision a DR primary replica (`peadm::add_replica`). |
| `backup` | Back up the primary (`peadm::backup`). |
| `restore` | Restore the primary from a backup (`peadm::restore`). |
| `backup-ca` | Back up the PE CA / certs (`peadm::backup_ca`). |
| `restore-ca` | Restore the PE CA / certs (`peadm::restore_ca`). |
| `dr-test` | Test DR: promote replica to primary, verify, fail back (`puppet infrastructure promote replica`); takes a safety `peadm::backup` first. |
| `swing-migrate` | Build a parallel infra + swing traffic to it (provision → backup → restore). |
| `swing-migrate-peadm` | Same as swing-migrate but via `peadm::migrate` (one plan). |
| `openainano` | (Re)install the PE AI ↔ Ollama bridge on the master (also installs Ollama). |
| `reponano` | (Re)install the local apt/yum package repo on the master. |
| `forgenano` | (Re)install the local Puppet Forge / module mirror on the master. |
| `scanano` | (Re)install the CVE-enabled vuln scan bridge on the master. |
| `ssh-keys` | Print SSH-key requirements for the target nodes. |
| `hosts-sync` | Push this environment's `/etc/hosts` entries (Docker-host IP → container/FQDN) from the wizard host to other nodes you want to reach, so they resolve the env too. Idempotent. |

---

## Troubleshooting

- **`puppet code deploy` fails with `invalid or unknown remote ssh hostkey`** (gitnano):
  set `r10k_known_hosts` on `puppet_enterprise::profile::master` and run
  `puppet agent -t` on the master. Regenerate with `ssh-keyscan -t ed25519 <core0>`.
- **`puppet code deploy` fails with `remote rejected authentication`** (gitnano):
  the r10k key doesn't match gitnano's authorized_keys. Regenerate:
  `sudo -u gitnano ssh-keygen -y -f /etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa > /opt/gitnano/.ssh/authorized_keys`.
- **SSH login refused with `System is booting up`**: remove the nologin file:
  `rm -f /run/nologin /etc/nologin`.
- **Docker host SSH drops (`Connection closed by port 22`)**: resource exhaustion —
  use a larger size (XXL for LARGE/XL with DR).
- **GCP `ACCESS_TOKEN_SCOPE_INSUFFICIENT`**: the wizard forces terraform to use the
  ADC file (`gcloud auth application-default login --scopes=cloud-platform`).
