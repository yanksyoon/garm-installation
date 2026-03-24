# GARM on OpenStack — Runbook

## Overview

GARM (GitHub Actions Runner Manager) manages ephemeral GitHub self-hosted runners on
OpenStack. Each runner VM is created on demand, installs the GitHub Actions runner agent
via cloud-init, registers with GitHub, and is destroyed after completing a job.

Runner VMs have **no direct internet access**. All outbound HTTP/HTTPS traffic is
transparently proxied through a local `aproxy` snap instance on the runner, which
forwards to the egress proxy at `egress.ps7.internal:3128`.

---

## Architecture

```
Runner VM (10.151.122.x)
  └─ curl / apt / runner agent
       │  (port 80/443 outbound to non-RFC1918)
       ▼
  nft DNAT → 127.0.0.1:8443
       │
       ▼
  aproxy snap (listening :8443)
       │
       ▼
  egress.ps7.internal:3128  (10.151.41.5/6/7)
       │
       ▼
  Internet (GitHub, apt mirrors, etc.)

GARM server (10.151.122.254)
  ├─ garm daemon  → port 8080  (callback / metadata API for runners)
  └─ aproxy snap  → port 8443  (proxy for GARM server's own outbound traffic)
```

**Key point:** runner VMs redirect traffic to their *own* local aproxy (127.0.0.1:8443),
not to the GARM server's aproxy. The GARM server's security group only permits ingress on
ports 22, 8080, and ICMP — port 8443 is not open to runner VMs.

---

## File Layout

```
/home/ubuntu/garm-runtime/
├── bin/
│   ├── garm            # GARM server binary
│   └── garm-cli        # CLI client
├── data/
│   └── garm.db         # SQLite database
├── etc/
│   ├── config.toml             # Main GARM config
│   ├── openstack-provider.toml # OpenStack provider config
│   └── clouds.yaml             # OpenStack credentials
├── logs/               # Log output
├── providers.d/
│   └── openstack/
│       └── garm-provider-openstack  # External provider binary
└── RUNBOOK.md          # This file
```

---

## Prerequisites

### OpenStack resources

| Resource | Value |
|---|---|
| Network ID | `647cc12c-dd1a-4dc9-8e29-a29a5d0b22a7` |
| Security group | `github-runner-v1` |
| Runner image | `bbff14d0-0db4-4eee-b368-8b83483508e5` (`github-runner-test-image-noble-x64`) |
| Flavor | `shared.small` |

The runner image must have the `aproxy` snap pre-installed and enabled. The snap
does **not** set up nft rules automatically — those are applied by the install
template at bootstrap time.

### Security group rules (`github-runner-v1`)

Runner VMs need unrestricted IPv4 egress to reach:
- `egress.ps7.internal` (10.151.41.x) on port 3128 — egress proxy
- `10.151.122.254:8080` — GARM callback/metadata API

The GARM server uses the same security group. Its relevant ingress rules:
- TCP 22 (SSH)
- TCP 8080 (GARM API, used by runner bootstrap scripts)
- ICMP

> **Note:** Port 8443 on the GARM server is NOT open to runner VMs. This is why
> nft rules on runners must point to `127.0.0.1:8443` (local aproxy), not to
> `10.151.122.254:8443`.

---

## Starting GARM

```bash
cd /home/ubuntu/garm-runtime
./bin/garm --config etc/config.toml
```

GARM listens on `0.0.0.0:8080`. Check it is running:

```bash
./bin/garm-cli login -u admin http://10.151.122.254:8080
./bin/garm-cli runner list --all
```

---

## Pool Configuration

### Existing pool

| Field | Value |
|---|---|
| Pool ID | `282dc959-3fa1-4860-8553-d6605ae0e7e0` |
| Belongs to | `yanksyoon/workflowtriggertest` (repo) |
| Max runners | 5 |
| Min idle runners | 1 |
| Bootstrap timeout | 20 min |
| Tags | `generic`, `ubuntu` |

### Runner install template (`extra_specs`)

The pool has a custom `runner_install_template` in its extra-specs. This template is a
Go-templated bash script that is base64-encoded and stored in the pool's extra-specs JSON.

The template does two things before the standard runner install:

1. **Configures aproxy** on the runner VM:
   ```bash
   sudo snap set aproxy listen=:8443 proxy=egress.ps7.internal:3128
   ```

2. **Sets up nft DNAT rules** to transparently redirect outbound HTTP/HTTPS through
   the local aproxy:
   ```bash
   sudo nft -f - <<'NFTEOF'
   table ip aproxy {
       chain prerouting {
           type nat hook prerouting priority dstnat; policy accept;
           ip daddr != { 10.0.0.0-10.129.255.255, 10.151.0.0-10.255.255.255,
                         127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }
           tcp dport { 80, 443, 5000, 8774, 9696, 9292 }
           counter dnat to 127.0.0.1:8443
       }
       chain output {
           type nat hook output priority dstnat; policy accept;
           ip daddr != { 10.0.0.0-10.129.255.255, 10.151.0.0-10.255.255.255,
                         127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }
           tcp dport { 80, 443, 5000, 8774, 9696, 9292 }
           counter dnat to 127.0.0.1:8443
       }
   }
   NFTEOF
   ```

   The excluded address ranges (RFC1918 + 10.151.x.x) ensure that traffic to the
   GARM server (10.151.122.254) and the egress proxy (10.151.41.x) is NOT redirected.

After proxy setup, the template follows the standard GARM runner install flow:
downloads the runner binary from GitHub, extracts it, installs dependencies, fetches
JIT credentials from the GARM metadata URL, generates a systemd unit, and starts the
runner service.

### Updating the install template

The source template is at `/tmp/install_runner_template.sh`. To update it:

```bash
cd /home/ubuntu/garm-runtime

# Edit the template
nano /tmp/install_runner_template.sh

# Re-encode and apply
TEMPLATE_B64=$(base64 -w0 /tmp/install_runner_template.sh)
echo "{\"runner_install_template\": \"$TEMPLATE_B64\"}" > /tmp/es.json
./bin/garm-cli pool update 282dc959-3fa1-4860-8553-d6605ae0e7e0 --extra-specs-file /tmp/es.json
```

### Creating a new pool

```bash
./bin/garm-cli pool create \
  --repo <REPO_ID> \
  --provider-name openstack_external \
  --image bbff14d0-0db4-4eee-b368-8b83483508e5 \
  --flavor shared.small \
  --os-type linux \
  --os-arch amd64 \
  --max-runners 5 \
  --min-idle-runners 1 \
  --tags generic,ubuntu \
  --extra-specs-file /tmp/es.json
```

---

## Troubleshooting

### Runner stuck at "pending"

Check the OpenStack console log:

```bash
# Get the VM's provider ID from garm-cli
./bin/garm-cli runner show <RUNNER_NAME>

# View console log
openstack --os-cloud openstack console log show <PROVIDER_ID>
```

Common causes:

| Symptom | Cause | Fix |
|---|---|---|
| `curl: (28) Failed to connect to github.com` for 2+ minutes | nft rules pointing to GARM server port 8443 (blocked by security group) | Ensure nft rules DNAT to `127.0.0.1:8443`, not `10.151.122.254:8443` |
| `E: Failed to fetch http://security.ubuntu.com` (apt errors) | `package_upgrade` runs before nft is set up | Expected / non-blocking. Set `disable_updates_on_boot = true` in `openstack-provider.toml` to suppress |
| Runner never calls back to GARM | Script exited early due to `set -e` failure | Check console log for errors before the curl progress output |
| `no token is available and METADATA_URL is not set` | Template variable not rendered | Confirm extra-specs are applied to the pool |

### Verify proxy is working on a runner

If you can SSH into the runner VM:

```bash
# Check aproxy is running
snap services aproxy

# Check nft rules are applied
sudo nft list table ip aproxy

# Test proxy manually
curl -v https://github.com 2>&1 | grep -E "Connected|SSL"
```

### SSH into a runner VM for debugging

Runner VMs are on `10.151.114.0/24` and are directly reachable from the GARM host.

**Enable SSH key injection via `garm-install.conf`** (persisted across reinstalls):

```
DEBUG_SSH_PUBLIC_KEY=/home/ubuntu/garm-runner-debug-key.pub
```

When set, the install script encodes a `pre_install_script` into the pool's
`extra_specs` that appends the public key to `/home/ubuntu/.ssh/authorized_keys`
on every runner VM before the runner agent is installed.

**Generate a dedicated debug keypair** (one-time):

```bash
ssh-keygen -t ed25519 -C "garm-runner-debug" \
  -f /home/ubuntu/garm-runner-debug-key -N ""
```

**Inject into an existing pool immediately** (without re-running the installer):

```bash
PUBKEY=$(cat /home/ubuntu/garm-runner-debug-key.pub)
SCRIPT_B64=$(printf '#!/bin/bash\nset -e\nmkdir -p /home/ubuntu/.ssh\nprintf "%%s\n" "%s" >> /home/ubuntu/.ssh/authorized_keys\nchown -R ubuntu:ubuntu /home/ubuntu/.ssh\nchmod 700 /home/ubuntu/.ssh\nchmod 600 /home/ubuntu/.ssh/authorized_keys\n' \
  "$PUBKEY" | base64 -w0)

TEMPLATE=$(/home/ubuntu/garm-runtime/bin/garm-cli pool show f8e7c17d-1eee-4b34-886f-724a814a17d7 \
  --format=json | jq -r '.extra_specs.runner_install_template')

/home/ubuntu/garm-runtime/bin/garm-cli pool update f8e7c17d-1eee-4b34-886f-724a814a17d7 \
  --extra-specs="{\"runner_install_template\": \"${TEMPLATE}\", \
                  \"pre_install_scripts\": {\"00-inject-debug-ssh-key\": \"${SCRIPT_B64}\"}}"
```

**SSH into a runner** (wait ~2 min after VM becomes ACTIVE):

```bash
source /home/ubuntu/garm-installation/openstack_creds
RUNNER_IP=$(openstack server list --format=json \
  | jq -r '.[] | select(.Name | startswith("garm-")) | .Networks | to_entries[0].value[0]')
ssh -i /home/ubuntu/garm-runner-debug-key ubuntu@"$RUNNER_IP"
```

**Remove the debug key for production** — set `DEBUG_SSH_PUBLIC_KEY=` (empty) in
`garm-install.conf` and update the pool extra-specs to remove `pre_install_scripts`:

```bash
TEMPLATE=$(/home/ubuntu/garm-runtime/bin/garm-cli pool show f8e7c17d-1eee-4b34-886f-724a814a17d7 \
  --format=json | jq -r '.extra_specs.runner_install_template')

/home/ubuntu/garm-runtime/bin/garm-cli pool update f8e7c17d-1eee-4b34-886f-724a814a17d7 \
  --extra-specs="{\"runner_install_template\": \"${TEMPLATE}\"}"
```

### Manually trigger a new runner

```bash
cd /home/ubuntu/garm-runtime

# Delete a stuck runner (GARM will create a replacement to maintain min-idle)
./bin/garm-cli runner delete <RUNNER_NAME>

# Watch for new runner
watch ./bin/garm-cli runner list --all
```

---

## GARM Template Variables Reference

These Go template variables are available in `runner_install_template`:

| Variable | Description | Example |
|---|---|---|
| `{{ .CallbackURL }}` | GARM callback endpoint | `http://10.151.122.254:8080/api/v1/callbacks` |
| `{{ .MetadataURL }}` | GARM metadata endpoint | `http://10.151.122.254:8080/api/v1/metadata` |
| `{{ .CallbackToken }}` | Per-runner JWT bearer token | (unique per runner) |
| `{{ .RunnerUsername }}` | OS user for the runner | `runner` |
| `{{ .DownloadURL }}` | GitHub runner tarball URL | `https://github.com/actions/runner/releases/...` |
| `{{ .FileName }}` | Tarball filename | `actions-runner-linux-x64-2.332.0.tar.gz` |
| `{{ .TempDownloadToken }}` | Optional GitHub token for private runner downloads | (empty string if not set) |
| `{{- if .UseJITConfig }}` | Conditional: true when JIT config is used | — |

Cloud-init runs the rendered template as:
```bash
su -l -c /install_runner.sh runner
```

---

## Known Limitations

- **`package_upgrade: true`** in the default cloud-init config runs before nft rules
  are in place, so apt upgrades fail at boot. This is cosmetic noise — the runner
  install itself succeeds. To suppress: set `disable_updates_on_boot = true` in
  `openstack-provider.toml` (the install script does this by default via
  `DISABLE_UPDATES_ON_BOOT=true` in `garm-install.conf`).

- The `runner_install_template` source file at `/tmp/install_runner_template.sh` is
  not persisted across reboots of the GARM server. Keep a copy elsewhere or re-derive
  it by base64-decoding the pool's extra-specs:
  ```bash
  /home/ubuntu/garm-runtime/bin/garm-cli pool show f8e7c17d-1eee-4b34-886f-724a814a17d7 \
    --format json | jq -r '.extra_specs.runner_install_template' | base64 -d
  ```

- **SSH key injection via `pre_install_scripts`** leaves the debug key in place for
  the lifetime of the pool. Remove it for production deployments (see
  [SSH into a runner VM for debugging](#ssh-into-a-runner-vm-for-debugging)).

- **`use_config_drive = true`** is required. Without it cloud-init cannot find its
  datasource on this network (the Nova metadata service at `169.254.169.254` is not
  reachable), so the entire runner bootstrap script never runs.
