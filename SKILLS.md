# GARM Operations Skillsfile

Operational reference for GARM (GitHub Actions Runner Manager) v0.1.7
on OpenStack (prodstack7).

---

## Environment

| Resource | Value |
|---|---|
| GARM API | `http://10.152.117.27:8080` |
| Install directory | `/home/ubuntu/garm-runtime` |
| Config | `/home/ubuntu/garm-runtime/etc/config.toml` |
| Log | `/home/ubuntu/garm-runtime/logs/garm.log` |
| Database | `/home/ubuntu/garm-runtime/data/garm.db` |
| OpenStack network | `net_stg-ps7-github-runner-test-arm64` (`6e15baa6-254f-4961-bb83-c71378810dcc`) |
| Runner image | `auto-sync/ubuntu-noble-24.04-arm64` (`ef75be5c-69f7-41a6-8baf-6c2887b1d7d7`) |
| Runner flavor | `shared.small.arm64` |
| Security group | `github-runner-image-builder-v1` |
| Egress proxy | `egress.ps7.internal:3128` |
| GitHub repo | `yanksyoon/workflowtriggertest` |
| Pool ID | `f8e7c17d-1eee-4b34-886f-724a814a17d7` |
| Repo ID | `b0faf425-ca55-4453-b96a-84791792f347` |
| Credentials ID | `1` (name: `garm`, PAT) |

Binaries:
```
/home/ubuntu/garm-runtime/bin/garm          # server
/home/ubuntu/garm-runtime/bin/garm-cli      # CLI client
/home/ubuntu/garm-runtime/providers.d/openstack/garm-provider-openstack
```

---

## Starting and Stopping GARM

### Check if GARM is running

```bash
pgrep -a -f "garm -config"
# or
curl -s http://10.152.117.27:8080/api/v1/meta | jq .
```

### Start GARM

```bash
cd /home/ubuntu/garm-runtime
nohup ./bin/garm -config etc/config.toml >> logs/garm.log 2>&1 &
echo "GARM PID: $!"
```

Verify it is ready:
```bash
curl -sf http://10.152.117.27:8080/api/v1/meta && echo "OK"
```

### Stop GARM

```bash
GARM_PID=$(pgrep -f "garm -config")
kill "$GARM_PID"
```

### Restart GARM

```bash
GARM_PID=$(pgrep -f "garm -config") && kill "$GARM_PID"
sleep 2
cd /home/ubuntu/garm-runtime
nohup ./bin/garm -config etc/config.toml >> logs/garm.log 2>&1 &
```

### View logs

```bash
tail -f /home/ubuntu/garm-runtime/logs/garm.log
```

---

## Managing Runners

### List all runners

```bash
/home/ubuntu/garm-runtime/bin/garm-cli runner list --all
```

### Watch runner status (live)

```bash
watch /home/ubuntu/garm-runtime/bin/garm-cli runner list --all
```

### Show a runner's details

```bash
/home/ubuntu/garm-runtime/bin/garm-cli runner show <RUNNER_NAME>
```

### Delete a stuck runner

GARM will automatically create a replacement to maintain `min-idle-runners`.

```bash
/home/ubuntu/garm-runtime/bin/garm-cli runner delete <RUNNER_NAME>
```

### Get a runner's OpenStack console log

Useful for diagnosing bootstrap failures:

```bash
PROVIDER_ID=$(/home/ubuntu/garm-runtime/bin/garm-cli runner show <RUNNER_NAME> \
  --format json | jq -r '.provider_id')
source /home/ubuntu/garm-installation/openstack_creds
openstack console log show "$PROVIDER_ID" | tail -80
```

---

## Managing Pools

### List all pools

```bash
/home/ubuntu/garm-runtime/bin/garm-cli pool list --all
```

### Show pool details (including extra-specs / install template)

```bash
/home/ubuntu/garm-runtime/bin/garm-cli pool show f8e7c17d-1eee-4b34-886f-724a814a17d7
```

### Update pool settings

```bash
# Change max/min runners
/home/ubuntu/garm-runtime/bin/garm-cli pool update f8e7c17d-1eee-4b34-886f-724a814a17d7 \
  --max-runners=10 \
  --min-idle-runners=2

# Disable a pool (stops creating new runners)
/home/ubuntu/garm-runtime/bin/garm-cli pool update f8e7c17d-1eee-4b34-886f-724a814a17d7 \
  --enabled=false

# Re-enable
/home/ubuntu/garm-runtime/bin/garm-cli pool update f8e7c17d-1eee-4b34-886f-724a814a17d7 \
  --enabled=true
```

### Update the runner install template

The template configures aproxy + nft rules, then runs the standard GARM runner install.

```bash
# Edit the template source
nano /tmp/install_runner_template.sh

# Re-encode and apply to the pool
TEMPLATE_B64=$(base64 -w0 /tmp/install_runner_template.sh)
echo "{\"runner_install_template\": \"$TEMPLATE_B64\"}" > /tmp/es.json
/home/ubuntu/garm-runtime/bin/garm-cli pool update \
  f8e7c17d-1eee-4b34-886f-724a814a17d7 \
  --extra-specs-file /tmp/es.json
```

Decode the current template from a pool to inspect or save it:
```bash
/home/ubuntu/garm-runtime/bin/garm-cli pool show f8e7c17d-1eee-4b34-886f-724a814a17d7 \
  --format json \
  | jq -r '.extra_specs | fromjson | .runner_install_template' \
  | base64 -d
```

### Create a new pool

```bash
REPO_ID="b0faf425-ca55-4453-b96a-84791792f347"

/home/ubuntu/garm-runtime/bin/garm-cli pool create \
  --repo "$REPO_ID" \
  --provider-name openstack_external \
  --image ef75be5c-69f7-41a6-8baf-6c2887b1d7d7 \
  --flavor shared.small.arm64 \
  --os-type linux \
  --os-arch arm64 \
  --max-runners 5 \
  --min-idle-runners 1 \
  --tags generic,ubuntu \
  --extra-specs-file /tmp/es.json   # omit if no custom template needed
```

### Delete a pool

A pool must have zero runners before it can be deleted. Disable it first,
then delete all its runners, then delete the pool.

```bash
POOL_ID="f8e7c17d-1eee-4b34-886f-724a814a17d7"

# Disable and set min-idle to 0 so no new runners are created
/home/ubuntu/garm-runtime/bin/garm-cli pool update "$POOL_ID" \
  --enabled=false --min-idle-runners=0

# Delete each runner in the pool
for runner in $(/home/ubuntu/garm-runtime/bin/garm-cli runner list --all \
    --format json | jq -r ".[] | select(.pool_id==\"$POOL_ID\") | .name"); do
  /home/ubuntu/garm-runtime/bin/garm-cli runner delete "$runner"
done

/home/ubuntu/garm-runtime/bin/garm-cli pool delete "$POOL_ID"
```

---

## GitHub Integration

### List registered credentials

```bash
/home/ubuntu/garm-runtime/bin/garm-cli github credentials list
```

### Rotate / update a GitHub PAT

```bash
/home/ubuntu/garm-runtime/bin/garm-cli github credentials update 1 \
  --pat-oauth-token="ghp_NEW_TOKEN_HERE"
```

### List registered repositories

```bash
/home/ubuntu/garm-runtime/bin/garm-cli repository list
```

### Show repository details

```bash
/home/ubuntu/garm-runtime/bin/garm-cli repository show b0faf425-ca55-4453-b96a-84791792f347
```

### Show webhook URL (needed in GitHub repo settings)

```bash
/home/ubuntu/garm-runtime/bin/garm-cli controller show
# Use the "Controller Webhook URL" value
```

Configure in GitHub: **Settings → Webhooks → Add webhook**
- Payload URL: the controller webhook URL
- Content type: `application/json`
- Events: `Workflow jobs`

---

## Re-running / Upgrading

The installer is idempotent. Common re-run patterns:

```bash
cd /home/ubuntu/garm-installation

# Re-apply config changes only (no re-init, no restart)
INIT_GARM=false STOP_EXISTING_GARM=false FORCE_WRITE_CONFIG=true \
  bash install-garm-openstack.sh --config garm-install.conf

# Full re-install with new binary version
GARM_VERSION=v0.1.8 INIT_GARM=false FORCE_WRITE_CONFIG=false \
  bash install-garm-openstack.sh --config garm-install.conf

# Fresh install (wipe DB first — loses all state)
GARM_PID=$(pgrep -f "garm -config") && kill "$GARM_PID"
rm -f /home/ubuntu/garm-runtime/data/garm.db*
bash install-garm-openstack.sh --config garm-install.conf
```

> **Note:** `unset OS_USERNAME OS_PASSWORD OS_PROJECT_NAME OS_AUTH_URL OS_REGION_NAME
> OS_INTERFACE OS_PROJECT_DOMAIN_NAME OS_USER_DOMAIN_NAME OS_IDENTITY_API_VERSION`
> before running the installer if these variables are exported (but empty) in your
> shell — a fixed version of the installer handles this automatically.

---

## Troubleshooting

### GARM API not responding

```bash
tail -50 /home/ubuntu/garm-runtime/logs/garm.log
```

Common causes: wrong `BIND_ADDR`, port already in use, corrupted DB.

### Runner stuck at `pending` / `installing`

1. Get the runner's OpenStack VM ID and check its console log (see [Managing Runners](#managing-runners)).
2. Common causes:

| Console log symptom | Cause | Fix |
|---|---|---|
| `curl: (28) Failed to connect to github.com` | Proxy / nft not working | Check `EGRESS_PROXY` and nft rules |
| `apt` errors about unreachable mirrors | `package_upgrade` runs before proxy | Non-blocking; set `DISABLE_UPDATES_ON_BOOT=true` |
| `no token is available and METADATA_URL is not set` | Template variables not rendered | Check extra-specs are applied to pool |
| No output after cloud-init | cloud-init error | Check full console log for init failures |

### SSH into a runner VM for debugging

Runner VMs are on the `10.151.114.0/24` subnet. The GARM host can reach them
directly (L3 routing is in place).

**Step 1 — Enable SSH key injection** (one-time setup, or set in `garm-install.conf`):

```bash
# Generate a dedicated debug keypair if you don't have one
ssh-keygen -t ed25519 -C "garm-runner-debug" -f /home/ubuntu/garm-runner-debug-key -N ""
```

Set `DEBUG_SSH_PUBLIC_KEY` in `garm-install.conf`:
```
DEBUG_SSH_PUBLIC_KEY=/home/ubuntu/garm-runner-debug-key.pub
```

Or inject the key into an existing pool immediately via `pre_install_scripts`:

```bash
PUBKEY=$(cat /home/ubuntu/garm-runner-debug-key.pub)
SCRIPT_B64=$(printf '#!/bin/bash\nset -e\nmkdir -p /home/ubuntu/.ssh\nprintf "%%s\n" "%s" >> /home/ubuntu/.ssh/authorized_keys\nchown -R ubuntu:ubuntu /home/ubuntu/.ssh\nchmod 700 /home/ubuntu/.ssh\nchmod 600 /home/ubuntu/.ssh/authorized_keys\n' "$PUBKEY" | base64 -w0)

EXISTING_TEMPLATE=$(/home/ubuntu/garm-runtime/bin/garm-cli pool show f8e7c17d-1eee-4b34-886f-724a814a17d7 \
  --format=json | jq -r '.extra_specs.runner_install_template')

/home/ubuntu/garm-runtime/bin/garm-cli pool update f8e7c17d-1eee-4b34-886f-724a814a17d7 \
  --extra-specs="{\"runner_install_template\": \"${EXISTING_TEMPLATE}\", \
                  \"pre_install_scripts\": {\"00-inject-debug-ssh-key\": \"${SCRIPT_B64}\"}}"
```

**Step 2 — Get the runner IP**:

```bash
source /home/ubuntu/garm-installation/openstack_creds
openstack server list --format=table -c Name -c Networks | grep garm-
```

**Step 3 — SSH in** (wait ~2 min after VM appears ACTIVE for cloud-init to finish):

```bash
ssh -i /home/ubuntu/garm-runner-debug-key ubuntu@<RUNNER_IP>
```

**Step 4 — Useful commands on the runner**:

```bash
# Check cloud-init progress
sudo cloud-init status --long

# Watch the runner install script output
sudo cat /var/log/cloud-init-output.log

# Check aproxy
snap services aproxy
sudo nft list table ip aproxy

# Check runner service
systemctl status 'actions.runner.*'
sudo journalctl -u 'actions.runner.*' -f

# Test proxy
curl -v https://github.com 2>&1 | grep -E "Connected|SSL"

# Test GARM callback reachability
curl -v --max-time 5 http://10.152.117.27:8080/api/v1/metadata/v1/ 2>&1 | tail -5
```

**Remove the debug key when done** (to avoid leaving it in production runners):

```bash
/home/ubuntu/garm-runtime/bin/garm-cli pool update f8e7c17d-1eee-4b34-886f-724a814a17d7 \
  --extra-specs="{\"runner_install_template\": \"${EXISTING_TEMPLATE}\"}"
```

Or set `DEBUG_SSH_PUBLIC_KEY=` (empty) in `garm-install.conf` and re-run the installer
with `FORCE_WRITE_CONFIG=false` (pool update only).

### Verify proxy inside a runner VM

```bash
# SSH into runner VM (if accessible), then:
snap services aproxy
sudo nft list table ip aproxy
curl -v https://github.com 2>&1 | grep -E "Connected|SSL"
```

### garm-cli profile token expired

```bash
/home/ubuntu/garm-runtime/bin/garm-cli profile login \
  --username=admin \
  --password=<ADMIN_PASSWORD>
```

Or set `ADMIN_PASSWORD` in `garm-install.conf` and re-run the installer with
`INIT_GARM=false` — it refreshes the token automatically.

### Check OpenStack VM status

```bash
source /home/ubuntu/garm-installation/openstack_creds
openstack server list
openstack server show <PROVIDER_ID>
```
