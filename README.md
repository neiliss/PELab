# PE Lab — Puppet Enterprise Lab Testing Provisioning Wizard (Multiple AI Uses to write code, use is provided as-is and no warranty in any manner is provided, use with caution in your lab as you see fit!)

A self-contained, one-shot wizard that provisions Puppet Enterprise (PE) nodes and
installs PE via **peadm**. It supports running PE in Docker containers (all-in-one on
a host, or on a provisioned cloud VM - Currently Supports GCP will be expanded to AWS and Azure) and directly on cloud VMs.

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

---

## Requirements

- Run as **root / sudo** (writes `/etc/hosts`, uses `/root` paths).
- Internet access on first run (installs `curl`, `jq`, `bolt`, `git`, `ssh-keyscan`,
  and — for cloud runs — `terraform`; also installs the `peadm` Bolt module).
- For **GCP**: a GCP account with compute access. The wizard handles one-shot auth
  (login + ADC + project) on a brand-new jump host.
- For **Docker localhost**: Docker is auto-installed (`docker.io`) and started if missing.

---

## SSH key (required for all and will be required on your external node if not AIO)

You need an **SSH key-pair** to access every provisioned node (VMs and containers).
This distribution ships one: `id_ed25519` (private) + `id_ed25519.pub` (public) for demo purposes only.

- The **private key** (`id_ed25519`) stays on the host you run the wizard from. It is
  used by Bolt for all connections. Keep it private and `chmod 600` it.
- The **public key** (`id_ed25519.pub`) is baked into the Terraform metadata **and**
  pushed to every node, so you can SSH in as `ssh_user` (default `root`) without a
  password.

  **NB! You will require this public key on your target nodes for access**

You can **use the shipped key-pair** or **generate your own** — the wizard asks for
"Path to SSH PRIVATE key" and, if the file doesn't exist, offers to generate a new
RSA-4096 key-pair on the spot. Either way, the key must be present on the host you
run the wizard from and the public key on the host you target.

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

---

## Topologies (installation type)

| Type | Nodes | Notes |
|---|---|---|
| `STANDARD` | 1 primary | Single-node, no replica. PostgreSQL co-located on the primary. |
| `LARGE` | primary + 2 compilers + HAProxy (+ replica if DR) | PostgreSQL co-located on primary/replica (peadm "Large"). |
| `XL` | primary + PDB + 2 compilers + HAProxy (+ replica/PDB if DR) | Separate PDB node. |

**Disaster Recovery (DR)** is offered for LARGE/XL and adds a primary-replica pair.

---

## Sizes

### VM runtime

| Size | GCP | AWS | Azure |
|---|---|---|---|
| Small | e2-custom-2-4096 | t3.medium | Standard_B2s |
| Medium | e2-custom-6-8192 | t3.large | Standard_B4ms |
| Large | e2-custom-8-12288 | m5.xlarge | Standard_D4s_v3 |

### Docker runtime (min = Large; Small/Medium not offered)

| Size | GCP | AWS | Azure | Notes |
|---|---|---|---|---|
| Large | e2-custom-8-12288 | m5.xlarge | Standard_D4s_v3 | Docker min recommended |
| XL | e2-custom-16-32768 | m5.2xlarge | Standard_D8s_v3 | |
| XXL | e2-custom-32-65536 | m5.4xlarge | Standard_E16s_v5 | One host runs all containers |

> **Heavy topologies need XXL.** A LARGE-with-DR run (6 containers) on a Large
> (8 vCPU/12 GB) Docker host can exhaust resources (`Connection closed by port 22`).
> Use **XXL** for LARGE/XL with DR.

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

- URL: `http://<core0>:5525/?token=<token>`
- Runs as a systemd service (`hieranano.service`), survives container restarts.

---

## Offline PE tarball

To install PE without downloading the installer, drop a tarball on the host and give
its path when prompted ("Local PE tarball path (offline; empty to download)").

- The tarball must be named `puppet-enterprise-<version>-<platform>.tar.gz`
  (e.g. `puppet-enterprise-2025.11.0-ubuntu-24.04-amd64.tar.gz`).
- If the PE version is `latest`, the version is **derived from the tarball filename**
  so they always match.
- If the version is newer than peadm knows about (currently `2025.11`), the wizard
  automatically sets `permit_unsafe_versions` so peadm accepts it.

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
  embedded.sh             ensure_gitnano_script, ensure_hieranano_script
                          (the embedded gitnano.sh / hieranano.sh heredocs)
  gitnano.sh              set_gitnano_known_hosts, install_gitnano,
                          ensure_control_repo, install_hieranano
  docker_provision.sh     docker_provision, generate_docker_artefacts,
                          docker_provision_cloud
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

Everything else (terraform config, `params.json`, `inventory.yaml`, `gitnano.sh`,
`hieranano.sh`, `helper.md`, the Docker image, etc.) is **generated automatically**
on each run.

---

## Access reference

At the end of a successful run the wizard prints how to reach the PE console and
connect agents, and writes a full reference to **`helper.md`** in the script directory
(including restart behavior and the static-IP caveat for Docker-on-cloud).

---

## Troubleshooting

- **Access issues with remote nodes: Check the private and public access keys (on the remote should have the public key in authorized_hosts) as this is the likely cause**
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
