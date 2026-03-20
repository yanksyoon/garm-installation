# install-garm-openstack.sh

A single-script installer for [GARM](https://github.com/cloudbase/garm) (GitHub Actions
Runner Manager) on OpenStack. Takes the installation from zero to a fully configured
runner pool in one step, including proxy setup for environments without direct internet
access.

---

## What it does

1. Downloads `garm`, `garm-cli`, and `garm-provider-openstack` from GitHub Releases
2. Writes `config.toml`, `openstack-provider.toml`, and `clouds.yaml`
3. Starts the GARM daemon
4. Initialises GARM (creates the admin user and saves a `garm-cli` profile)
5. Registers GitHub credentials (Personal Access Token)
6. Registers the target repository, organisation, or enterprise
7. Creates a runner pool with an aproxy + nft bootstrap template so runner VMs
   can reach the internet through an egress proxy

---

## Requirements

| Requirement | Notes |
|---|---|
| Ubuntu host | The machine running GARM |
| `curl`, `tar`, `jq` | Installed automatically if missing (requires `apt-get`) |
| OpenStack project | Credentials with permission to create/delete instances |
| OpenStack network | A network UUID to attach runner VMs to |
| Runner VM image | A pre-built image with the `aproxy` snap installed |
| Egress proxy | An HTTP/HTTPS proxy runner VMs route internet traffic through |
| GitHub PAT | A token with `repo` and `admin:repo_hook` scopes (add `admin:org` for org runners) |

### Runner VM image

The image used for runner VMs **must have the `aproxy` snap pre-installed**.  
Runner VMs have no direct internet access; all outbound HTTP/HTTPS is transparently
redirected by `nft` DNAT rules to the local `aproxy` instance, which forwards to the
configured egress proxy.

---

## Quick start

### 1. Generate a configuration file

```bash
./install-garm-openstack.sh --generate-config garm-install.conf
```

This writes a fully commented template to `garm-install.conf`. Fill in the required
values (marked `# REQUIRED`) and adjust the defaults as needed.

### 2. Run the installer

```bash
./install-garm-openstack.sh --config garm-install.conf
```

The script prompts interactively for any required values still missing from the config
file. Non-interactive (CI) runs are supported — see [Non-interactive use](#non-interactive-use).

### 3. Verify

```bash
/home/ubuntu/garm-runtime/bin/garm-cli runner list --all
```

A runner should appear with status `idle` within a few minutes.

---

## Usage

```
./install-garm-openstack.sh [--config FILE] [--generate-config [FILE]]

  --config FILE           Load configuration from FILE.
  --generate-config FILE  Write a config template to FILE and exit.
                          FILE defaults to ./garm-install.conf.
  --help                  Show this help.
```

The script also **auto-detects** a config file at `./garm-install.conf` or
`~/.config/garm/install.conf` when `--config` is not specified.

### Variable priority

When the same variable is set in multiple places, the highest-priority source wins:

```
Shell environment variable   ← highest (always wins)
        ↓ only if unset
Config file value
        ↓ only if unset
Script built-in default
```

This means you can override any config file value at runtime without editing the file:

```bash
POOL_MAX_RUNNERS=10 ./install-garm-openstack.sh --config garm-install.conf
```

---

## Configuration reference

### Binaries

| Variable | Default | Description |
|---|---|---|
| `GARM_VERSION` | `v0.1.7` | GARM release to download |
| `OPENSTACK_PROVIDER_VERSION` | `v0.1.3` | OpenStack provider release to download |

### Install layout

| Variable | Default | Description |
|---|---|---|
| `INSTALL_DIR` | `/home/ubuntu/garm-runtime` | Root for all GARM files |

Directory structure under `INSTALL_DIR`:

```
bin/                        garm, garm-cli
etc/                        config.toml, openstack-provider.toml, clouds.yaml
data/                       garm.db (SQLite database)
logs/                       garm.log
providers.d/openstack/      garm-provider-openstack
```

### GARM server

| Variable | Default | Required | Description |
|---|---|---|---|
| `BIND_ADDR` | `127.0.0.1` | **Yes** | IP the API listens on. Must be the host's reachable IP on the runner network — runner VMs use this address to call back during bootstrap |
| `PORT` | `8080` | No | TCP port for the GARM API |
| `CONTROLLER_NAME` | `local-openstack` | No | Name used for the `garm-cli` profile |
| `ADMIN_USERNAME` | `admin` | No | GARM admin username |
| `ADMIN_PASSWORD` | *(empty)* | **Yes** | GARM admin password |
| `ADMIN_EMAIL` | `admin@example.com` | No | Admin email address |
| `ADMIN_FULL_NAME` | `Local Admin` | No | Admin display name |

### Behaviour flags

| Variable | Default | Description |
|---|---|---|
| `START_GARM` | `true` | Start the GARM daemon after install |
| `STOP_EXISTING_GARM` | `true` | Stop a running GARM instance before starting the new one |
| `INIT_GARM` | `true` | Create the admin user (first install). Set to `false` on re-runs |
| `FORCE_WRITE_CONFIG` | `false` | Overwrite existing `config.toml` / `openstack-provider.toml` / `clouds.yaml` |

### OpenStack credentials

| Variable | Default | Required | Description |
|---|---|---|---|
| `OS_AUTH_URL` | *(placeholder)* | **Yes** | Keystone v3 auth endpoint |
| `OS_USERNAME` | *(empty)* | **Yes** | OpenStack username |
| `OS_PASSWORD` | *(empty)* | **Yes** | OpenStack password |
| `OS_PROJECT_NAME` | *(empty)* | **Yes** | OpenStack project |
| `OS_REGION_NAME` | `RegionOne` | **Yes** | OpenStack region (change if not `RegionOne`) |
| `OS_CLOUD_NAME` | `openstack` | No | Cloud name in `clouds.yaml` |
| `OS_USER_DOMAIN_NAME` | `Default` | No | User domain |
| `OS_PROJECT_DOMAIN_NAME` | `Default` | No | Project domain |
| `OS_INTERFACE` | `public` | No | Endpoint interface |

### OpenStack infrastructure

| Variable | Default | Required | Description |
|---|---|---|---|
| `NETWORK_ID` | *(empty)* | **Yes** | UUID of the network runner VMs attach to. Find with `openstack network list` |
| `OS_SECURITY_GROUPS` | `default` | No | Comma-separated security group names for runner VMs |
| `DISABLE_UPDATES_ON_BOOT` | `false` | No | Suppress `apt upgrade` in cloud-init (runs before proxy is ready, causing noisy failures) |

### Egress proxy

Runner VMs have no direct internet access. The script configures each runner VM to
redirect outbound HTTP/HTTPS through a local `aproxy` snap instance, which forwards to
the upstream proxy.

| Variable | Default | Required | Description |
|---|---|---|---|
| `EGRESS_PROXY` | *(placeholder)* | **Yes** | Upstream HTTP/HTTPS proxy (`host:port`) |
| `APROXY_LOCAL_PORT` | `8443` | No | Port `aproxy` listens on inside runner VMs |
| `NFT_EXCLUDE_RANGES` | `10.0.0.0-10.129.255.255, 10.151.0.0-10.255.255.255, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16` | No | IP ranges bypassing the proxy. Must include the GARM server IP, the egress proxy IPs, and all RFC1918 ranges |

### GitHub integration

| Variable | Default | Required | Description |
|---|---|---|---|
| `GITHUB_PAT` | *(empty)* | **Yes** | GitHub Personal Access Token |
| `RUNNER_SCOPE` | *(empty)* | **Yes** | `repo`, `org`, or `enterprise` |
| `REPO_OWNER` | *(empty)* | **Yes** *(repo scope)* | Repository owner (user or org) |
| `REPO_NAME` | *(empty)* | **Yes** *(repo scope)* | Repository name |
| `ORG_NAME` | *(empty)* | **Yes** *(org scope)* | GitHub organisation name |
| `ENTERPRISE_NAME` | *(empty)* | **Yes** *(enterprise scope)* | GitHub Enterprise slug |
| `GITHUB_ENDPOINT` | `github.com` | No | GitHub endpoint (change for GHES) |
| `GITHUB_CREDENTIALS_NAME` | `garm` | No | Name for stored credentials in GARM |
| `GITHUB_CREDENTIALS_DESC` | `GitHub PAT for GARM` | No | Credential description |
| `RANDOM_WEBHOOK_SECRET` | `true` | No | Generate a random webhook secret |

### Runner pool

| Variable | Default | Description |
|---|---|---|
| `POOL_IMAGE` | *(empty — **required**)* | OpenStack image UUID. Find with `openstack image list` |
| `POOL_FLAVOR` | `shared.small` | OpenStack flavor for runner VMs |
| `POOL_OS_TYPE` | `linux` | OS type |
| `POOL_OS_ARCH` | `amd64` | CPU architecture |
| `POOL_MAX_RUNNERS` | `5` | Maximum runners in the pool |
| `POOL_MIN_IDLE` | `1` | Minimum idle runners GARM maintains |
| `POOL_TAGS` | `generic,ubuntu` | Comma-separated runner labels (used in `runs-on:`) |
| `POOL_RUNNER_PREFIX` | `garm` | Prefix for runner VM names |
| `POOL_BOOTSTRAP_TIMEOUT` | `20` | Minutes before a bootstrapping runner is considered failed |

---

## Runner scopes

The `RUNNER_SCOPE` variable controls which GitHub resource the runner pool belongs to.

### Repository runners

Runners available only to a single repository.

```ini
RUNNER_SCOPE=repo
REPO_OWNER=myorg       # GitHub username or organisation
REPO_NAME=myrepo
```

Required GitHub PAT scopes: `repo`, `admin:repo_hook`

### Organisation runners

Runners available to all repositories in an organisation.

```ini
RUNNER_SCOPE=org
ORG_NAME=myorg
```

Required GitHub PAT scopes: `repo`, `admin:repo_hook`, `admin:org`

### Enterprise runners

Runners available across a GitHub Enterprise.

```ini
RUNNER_SCOPE=enterprise
ENTERPRISE_NAME=my-enterprise-slug
```

---

## Re-running the script

The script is designed to be idempotent — safe to re-run. Each step checks whether it
has already been done before acting:

| Step | Idempotency behaviour |
|---|---|
| Binary download | Always re-downloads (upgrades binaries if version changed) |
| Config files | Skipped if they exist — set `FORCE_WRITE_CONFIG=true` to overwrite |
| GARM daemon | Restarts if running — set `STOP_EXISTING_GARM=false` to leave it |
| GARM init | Set `INIT_GARM=false` once GARM is already initialised |
| GitHub credentials | Skipped if a credential with the same name already exists |
| Repository/org/enterprise | Skipped if already registered |
| Pool | Skipped if a pool with the same image + flavor already exists |

Typical re-run flags:

```bash
INIT_GARM=false FORCE_WRITE_CONFIG=false \
  ./install-garm-openstack.sh --config garm-install.conf
```

---

## Non-interactive use

When `stdin` is not a terminal (CI pipelines, scripts), interactive prompts are
suppressed automatically. All required variables must be supplied via environment
variables or the config file, otherwise the script exits with a clear error.

```bash
# CI example — env vars inline
ADMIN_PASSWORD="$SECRET_ADMIN_PW" \
GITHUB_PAT="$SECRET_GH_PAT" \
./install-garm-openstack.sh --config garm-install.conf
```

---

## Troubleshooting

### GARM API not ready

```
ERROR: garm API did not respond after 30s. Check .../logs/garm.log
```

GARM failed to start. Check the log:

```bash
tail -50 /home/ubuntu/garm-runtime/logs/garm.log
```

Common causes: wrong `BIND_ADDR`, port already in use, bad `config.toml`.

### Init fails — already initialised

```
ERROR: garm is already initialized. Re-run with INIT_GARM=false to skip this step.
```

Set `INIT_GARM=false` in your config file or as an env var and re-run.

### Runner stuck at `pending` / `installing`

Check the OpenStack console log for the VM:

```bash
PROVIDER_ID=$(garm-cli runner show <runner-name> | awk '/Provider ID/{print $NF}')
openstack console log show "$PROVIDER_ID" | tail -80
```

Common causes:

| Symptom in log | Cause | Fix |
|---|---|---|
| `curl: (28) Failed to connect to github.com` for 2+ minutes | nft rules or aproxy not configured correctly | Check `EGRESS_PROXY` and `NFT_EXCLUDE_RANGES` |
| `apt` errors about unreachable mirrors | Expected — apt runs before proxy is set up | Non-blocking; set `DISABLE_UPDATES_ON_BOOT=true` to suppress |
| No runner install output at all | cloud-init failed early | Check full console log for cloud-init errors |

### Profile token expired

```
ERROR: Profile token is invalid and ADMIN_PASSWORD is not set. Cannot refresh.
```

Set `ADMIN_PASSWORD` and re-run. The script will call `garm-cli profile login`
automatically to refresh the bearer token.

---

## Files written

| Path | Description |
|---|---|
| `$INSTALL_DIR/etc/config.toml` | GARM main config (JWT secret, DB, API, provider) |
| `$INSTALL_DIR/etc/openstack-provider.toml` | OpenStack provider config (network, flavor, security groups) |
| `$INSTALL_DIR/etc/clouds.yaml` | OpenStack credentials (`chmod 600`) |
| `$INSTALL_DIR/logs/garm.log` | GARM daemon stdout/stderr |
| `$INSTALL_DIR/data/garm.db` | SQLite database |
| `~/.local/share/garm-cli/config.toml` | `garm-cli` profile (bearer token) |
