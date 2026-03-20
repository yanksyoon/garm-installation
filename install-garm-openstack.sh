#!/usr/bin/env bash
# =============================================================================
# install-garm-openstack.sh
#
# Installs GARM (GitHub Actions Runner Manager) with the OpenStack provider
# from scratch through to pool creation, ready to spawn self-hosted runners.
#
# Steps performed:
#   1. Download garm, garm-cli, and garm-provider-openstack binaries
#   2. Write config.toml, openstack-provider.toml, and clouds.yaml
#   3. Start the garm daemon
#   4. Initialize garm (admin user + garm-cli profile)
#   5. Register GitHub credentials (PAT)
#   6. Register the target GitHub repository / org / enterprise
#   7. Create a runner pool with an aproxy/nft proxy bootstrap template
#
# Usage:
#   ./install-garm-openstack.sh [--config FILE] [--generate-config [FILE]]
#
#   --config FILE           Load configuration from FILE before applying defaults.
#   --generate-config FILE  Write a commented configuration template to FILE and exit.
#                           FILE defaults to ./garm-install.conf if not specified.
#
# Variable priority (highest → lowest):
#   1. Environment variables in the calling shell
#   2. Values in the --config file
#   3. Script built-in defaults
#
# Example — using a config file:
#   ./install-garm-openstack.sh --generate-config my-site.conf
#   # edit my-site.conf
#   ./install-garm-openstack.sh --config my-site.conf
#
# Example — env vars only (original behaviour, still supported):
#   ADMIN_PASSWORD=secret GITHUB_PAT=ghp_xxx REPO_OWNER=myorg \
#     REPO_NAME=myrepo ./install-garm-openstack.sh
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()     { printf '[%s] %s\n'       "$(date +'%F %T')" "$*"; }
die()     { printf '[%s] ERROR: %s\n' "$(date +'%F %T')" "$*" >&2; exit 1; }

# Catch any unexpected non-zero exit (set -E propagates ERR through functions)
trap 'die "Unexpected error at line $LINENO (exit $?)"' ERR
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Configuration file loader
#
# Reads KEY=VALUE lines from a file (shell-style, supports # comments and
# quoted values) and exports each variable into the current environment —
# but ONLY if that variable is not already set by the calling shell.
#
# This implements the correct priority: env vars > config file > defaults.
# ---------------------------------------------------------------------------
load_config() {
  local file="$1"
  local lineno=0 line var val
  while IFS= read -r line || [[ -n "$line" ]]; do
    (( lineno++ )) || true
    # Strip inline comments and leading/trailing whitespace
    line="${line%%#*}"
    line="${line#"${line%%[! ]*}"}"
    line="${line%"${line##*[! ]}"}"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)[[:space:]]*$ ]]; then
      var="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # Strip surrounding double or single quotes
      if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
      fi
      # Only set if not already present and non-empty in the calling environment.
      # An empty env var (e.g. OS_USERNAME= left over from a cloud session) is
      # treated as unset so the config file value wins over it.
      if [[ -z "${!var}" ]]; then
        export "$var=$val"
      fi
    else
      echo "[WARN] $file:${lineno}: unrecognised line, skipping: $line" >&2
    fi
  done < "$file"
}

# ---------------------------------------------------------------------------
# generate_config  [output-file]
#
# Writes a fully-commented configuration template and exits.
# ---------------------------------------------------------------------------
generate_config() {
  local out="${1:-./garm-install.conf}"
  if [[ -e "$out" ]]; then
    read -rp "File '$out' already exists. Overwrite? [y/N]: " _ow </dev/tty
    [[ "${_ow:-N}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  fi
  cat > "$out" <<'CONFIG_TEMPLATE'
# =============================================================================
# GARM OpenStack Installation — Configuration File
#
# This file is loaded by install-garm-openstack.sh when passed via --config.
# Values here are overridden by shell environment variables, and override the
# script's built-in defaults.
#
# Format: KEY=VALUE  or  KEY="value with spaces"
# Lines starting with # are comments. Inline comments are supported.
#
# Usage:
#   ./install-garm-openstack.sh --config garm-install.conf
# =============================================================================

# =============================================================================
# BINARY VERSIONS
# =============================================================================

# GARM server and CLI version to download from GitHub releases.
GARM_VERSION=v0.1.7

# OpenStack external provider version.
OPENSTACK_PROVIDER_VERSION=v0.1.3

# =============================================================================
# INSTALL LAYOUT
# =============================================================================

# Root directory for all GARM files (binaries, configs, data, logs).
INSTALL_DIR=/home/ubuntu/garm-runtime

# =============================================================================
# GARM SERVER
# =============================================================================

# IP address the GARM API listens on.
# IMPORTANT: for OpenStack deployments this must be the host's reachable IP
# on the runner network (not 127.0.0.1), because runner VMs use this address
# to call back to GARM during bootstrap.
BIND_ADDR=10.0.0.1

# TCP port the GARM API listens on.
PORT=8080

# Name for this GARM controller (used as the garm-cli profile name).
CONTROLLER_NAME=local-openstack

# GARM admin account credentials.
# ADMIN_PASSWORD is required when INIT_GARM=true.
# GARM enforces a minimum password strength (zxcvbn score >= 2).
# Use at least 10 characters with a mix of upper/lower case, digits, and symbols.
ADMIN_USERNAME=admin
ADMIN_PASSWORD=                   # REQUIRED
ADMIN_EMAIL=admin@example.com
ADMIN_FULL_NAME="Local Admin"

# =============================================================================
# BEHAVIOUR FLAGS
# =============================================================================

# Start the garm daemon after installing binaries and writing configs.
START_GARM=true

# If a garm process is already running with this config, stop it first.
STOP_EXISTING_GARM=true

# Initialize garm (create admin user) on first install.
# Set to false on re-runs once garm is already initialized.
INIT_GARM=true

# Overwrite existing config.toml / openstack-provider.toml / clouds.yaml.
# Set to true if you change any of the settings below and want them applied.
FORCE_WRITE_CONFIG=false

# =============================================================================
# OPENSTACK CREDENTIALS
# =============================================================================

# Name of the cloud entry in clouds.yaml (used by the provider binary).
OS_CLOUD_NAME=openstack

# Keystone v3 authentication endpoint.
OS_AUTH_URL=https://keystone.example.com:5000/v3     # REQUIRED

# OpenStack user credentials.
OS_USERNAME=                      # REQUIRED
OS_PASSWORD=                      # REQUIRED
OS_PROJECT_NAME=                  # REQUIRED

# Domain names for the user and project (usually "Default").
OS_USER_DOMAIN_NAME=Default
OS_PROJECT_DOMAIN_NAME=Default

# OpenStack region and endpoint interface.
OS_REGION_NAME=RegionOne          # REQUIRED — set to your actual region
OS_INTERFACE=public

# =============================================================================
# OPENSTACK INFRASTRUCTURE
# =============================================================================

# UUID of the OpenStack network runner VMs will be attached to.
# Find with: openstack network list
NETWORK_ID=                       # REQUIRED

# Security group(s) applied to runner VMs (comma-separated).
OS_SECURITY_GROUPS=default

# Set to true to suppress apt package upgrades during cloud-init
# (upgrades run before the proxy is set up and will fail noisily).
DISABLE_UPDATES_ON_BOOT=false

# =============================================================================
# EGRESS PROXY (runner VMs)
# =============================================================================

# Runner VMs have no direct internet access. All outbound HTTP/HTTPS is
# intercepted by nft DNAT rules and forwarded through a local aproxy snap,
# which proxies to this upstream HTTP/HTTPS proxy.
#
# The runner VM image must have the aproxy snap pre-installed.
EGRESS_PROXY=egress.example.internal:3128    # REQUIRED

# Port aproxy listens on inside each runner VM.
APROXY_LOCAL_PORT=8443

# IP ranges NOT redirected through the proxy (must include GARM server IP,
# egress proxy IPs, and all RFC1918 ranges).
NFT_EXCLUDE_RANGES=10.0.0.0-10.129.255.255, 10.151.0.0-10.255.255.255, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16

# =============================================================================
# GITHUB INTEGRATION
# =============================================================================

# GitHub Personal Access Token.
# Required scopes: repo, admin:repo_hook
# For org runners also: admin:org
GITHUB_PAT=                       # REQUIRED

# GitHub endpoint name (use "github.com" for public GitHub).
GITHUB_ENDPOINT=github.com

# Name and description for the stored credential in GARM.
GITHUB_CREDENTIALS_NAME=garm
GITHUB_CREDENTIALS_DESC="GitHub PAT for GARM"

# Runner scope — where runners will be available:
#   repo        a single repository  (needs REPO_OWNER + REPO_NAME)
#   org         all repos in an org  (needs ORG_NAME)
#   enterprise  GitHub Enterprise    (needs ENTERPRISE_NAME)
RUNNER_SCOPE=                     # REQUIRED: repo | org | enterprise

# --- repo scope ---
REPO_OWNER=                       # required when RUNNER_SCOPE=repo
REPO_NAME=                        # required when RUNNER_SCOPE=repo

# --- org scope ---
ORG_NAME=                         # required when RUNNER_SCOPE=org

# --- enterprise scope ---
ENTERPRISE_NAME=                  # required when RUNNER_SCOPE=enterprise

# Generate a random webhook secret when registering the repo/org.
RANDOM_WEBHOOK_SECRET=true

# =============================================================================
# RUNNER POOL
# =============================================================================

# OpenStack image ID for runner VMs.
# The image must have the aproxy snap pre-installed.
# Find with: openstack image list
POOL_IMAGE=                       # REQUIRED

# OpenStack flavor for runner VMs.
POOL_FLAVOR=shared.small

# OS type and architecture.
POOL_OS_TYPE=linux
POOL_OS_ARCH=amd64

# Maximum number of runners GARM will create in this pool.
POOL_MAX_RUNNERS=5

# Minimum number of idle runners GARM will maintain.
POOL_MIN_IDLE=1

# Comma-separated runner labels visible in GitHub Actions workflows.
POOL_TAGS=generic,ubuntu

# Prefix for runner VM names (e.g. "garm-abc123").
POOL_RUNNER_PREFIX=garm

# Minutes after which a bootstrapping runner is considered failed.
POOL_BOOTSTRAP_TIMEOUT=20
CONFIG_TEMPLATE

  echo "Configuration template written to: $out"
  echo "Edit it, then run:"
  echo "  ./install-garm-openstack.sh --config $out"
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing  (runs before variable declarations so load_config can
# inject values that the ${VAR:-default} assignments will then see)
# ---------------------------------------------------------------------------
_CONFIG_FILE=""
_args=("$@")
_i=0
while (( _i < ${#_args[@]} )); do
  case "${_args[$_i]}" in
    --config)
      _i=$(( _i + 1 ))
      (( _i < ${#_args[@]} )) || die "--config requires a file argument"
      _CONFIG_FILE="${_args[$_i]}"
      ;;
    --config=*)
      _CONFIG_FILE="${_args[$_i]#--config=}"
      ;;
    --generate-config)
      _i=$(( _i + 1 ))
      if (( _i < ${#_args[@]} )) && [[ "${_args[$_i]}" != --* ]]; then
        generate_config "${_args[$_i]}"
      else
        generate_config "./garm-install.conf"
        _i=$(( _i - 1 ))
      fi
      ;;
    --generate-config=*)
      generate_config "${_args[$_i]#--generate-config=}"
      ;;
    --help|-h)
      sed -n '/^# Usage:/,/^# =\+$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      die "Unknown argument: ${_args[$_i]}. Use --help for usage."
      ;;
  esac
  _i=$(( _i + 1 ))
done
unset _args _i

if [[ -n "$_CONFIG_FILE" ]]; then
  [[ -f "$_CONFIG_FILE" ]] || die "Config file not found: $_CONFIG_FILE"
  log "Loading configuration from: $_CONFIG_FILE"
  load_config "$_CONFIG_FILE"
else
  # Auto-detect a config file in the default location
  for _candidate in "./garm-install.conf" "${HOME}/.config/garm/install.conf"; do
    if [[ -f "$_candidate" ]]; then
      log "Auto-detected config file: $_candidate"
      load_config "$_candidate"
      break
    fi
  done
  unset _candidate
fi
unset _CONFIG_FILE

# ---------------------------------------------------------------------------
# Binary versions
# ---------------------------------------------------------------------------
GARM_VERSION="${GARM_VERSION:-v0.1.7}"
OPENSTACK_PROVIDER_VERSION="${OPENSTACK_PROVIDER_VERSION:-v0.1.3}"

# ---------------------------------------------------------------------------
# Install layout
# ---------------------------------------------------------------------------
INSTALL_DIR="${INSTALL_DIR:-/home/ubuntu/garm-runtime}"
BIN_DIR="$INSTALL_DIR/bin"
ETC_DIR="$INSTALL_DIR/etc"
DATA_DIR="$INSTALL_DIR/data"
LOG_DIR="$INSTALL_DIR/logs"
PROVIDER_DIR="$INSTALL_DIR/providers.d/openstack"

GARM_BIN="$BIN_DIR/garm"
GARM_CLI_BIN="$BIN_DIR/garm-cli"
PROVIDER_BIN="$PROVIDER_DIR/garm-provider-openstack"
GARM_CONFIG="$ETC_DIR/config.toml"
PROVIDER_CONFIG="$ETC_DIR/openstack-provider.toml"
CLOUDS_CONFIG="$ETC_DIR/clouds.yaml"

# ---------------------------------------------------------------------------
# GARM server settings
# ---------------------------------------------------------------------------
# BIND_ADDR: IP the API listens on AND the address runners use to call back.
# Set this to the host's reachable IP (not 127.0.0.1) if runners run on
# separate VMs (the typical OpenStack case).
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
PORT="${PORT:-8080}"

CONTROLLER_NAME="${CONTROLLER_NAME:-local-openstack}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_FULL_NAME="${ADMIN_FULL_NAME:-Local Admin}"
# REQUIRED when INIT_GARM=true
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

# ---------------------------------------------------------------------------
# Behaviour flags
# ---------------------------------------------------------------------------
START_GARM="${START_GARM:-true}"
STOP_EXISTING_GARM="${STOP_EXISTING_GARM:-true}"
# Set to true on first install; false if garm is already initialized
INIT_GARM="${INIT_GARM:-true}"
# Set to true to overwrite existing config files
FORCE_WRITE_CONFIG="${FORCE_WRITE_CONFIG:-false}"

# ---------------------------------------------------------------------------
# OpenStack credentials & provider settings
# ---------------------------------------------------------------------------
OS_CLOUD_NAME="${OS_CLOUD_NAME:-openstack}"
OS_AUTH_URL="${OS_AUTH_URL:-https://openstack.example.com:5000/v3}"
OS_USERNAME="${OS_USERNAME:-replace-user}"
OS_PASSWORD="${OS_PASSWORD:-replace-password}"
OS_PROJECT_NAME="${OS_PROJECT_NAME:-replace-project}"
OS_USER_DOMAIN_NAME="${OS_USER_DOMAIN_NAME:-Default}"
OS_PROJECT_DOMAIN_NAME="${OS_PROJECT_DOMAIN_NAME:-Default}"
OS_REGION_NAME="${OS_REGION_NAME:-RegionOne}"
OS_INTERFACE="${OS_INTERFACE:-public}"

# OpenStack network the runner VMs will be attached to
NETWORK_ID="${NETWORK_ID:-00000000-0000-0000-0000-000000000000}"
# Comma-separated security group names to apply to runner VMs
OS_SECURITY_GROUPS="${OS_SECURITY_GROUPS:-default}"
# Set to true to suppress apt upgrades that run before the proxy is ready
DISABLE_UPDATES_ON_BOOT="${DISABLE_UPDATES_ON_BOOT:-false}"

# ---------------------------------------------------------------------------
# GitHub integration
# ---------------------------------------------------------------------------
# REQUIRED: a GitHub PAT with repo and admin:org scopes
GITHUB_PAT="${GITHUB_PAT:-}"
GITHUB_ENDPOINT="${GITHUB_ENDPOINT:-github.com}"
GITHUB_CREDENTIALS_NAME="${GITHUB_CREDENTIALS_NAME:-garm}"
GITHUB_CREDENTIALS_DESC="${GITHUB_CREDENTIALS_DESC:-GitHub PAT for GARM}"

# Runner scope: "repo", "org", or "enterprise"
RUNNER_SCOPE="${RUNNER_SCOPE:-}"

# repo scope: both required
REPO_OWNER="${REPO_OWNER:-}"
REPO_NAME="${REPO_NAME:-}"

# org scope: org name (if unset, falls back to REPO_OWNER)
ORG_NAME="${ORG_NAME:-}"

# enterprise scope: enterprise slug
ENTERPRISE_NAME="${ENTERPRISE_NAME:-}"

# Generate a random webhook secret when registering
RANDOM_WEBHOOK_SECRET="${RANDOM_WEBHOOK_SECRET:-true}"

# ---------------------------------------------------------------------------
# Runner pool settings
# ---------------------------------------------------------------------------
# OpenStack image ID — must have the aproxy snap pre-installed
POOL_IMAGE="${POOL_IMAGE:-00000000-0000-0000-0000-000000000000}"
POOL_FLAVOR="${POOL_FLAVOR:-shared.small}"
POOL_OS_TYPE="${POOL_OS_TYPE:-linux}"
POOL_OS_ARCH="${POOL_OS_ARCH:-amd64}"
POOL_MAX_RUNNERS="${POOL_MAX_RUNNERS:-5}"
POOL_MIN_IDLE="${POOL_MIN_IDLE:-1}"
POOL_TAGS="${POOL_TAGS:-generic,ubuntu}"
POOL_RUNNER_PREFIX="${POOL_RUNNER_PREFIX:-garm}"
POOL_BOOTSTRAP_TIMEOUT="${POOL_BOOTSTRAP_TIMEOUT:-20}"

# ---------------------------------------------------------------------------
# Proxy settings (applied inside runner VMs at bootstrap time)
# ---------------------------------------------------------------------------
# The upstream HTTP proxy runner VMs forward traffic to.
# The runner image must have the aproxy snap installed.
EGRESS_PROXY="${EGRESS_PROXY:-egress.example.internal:3128}"

# Port aproxy listens on inside each runner VM.
APROXY_LOCAL_PORT="${APROXY_LOCAL_PORT:-8443}"

# nft: private IP ranges NOT redirected through the proxy.
# Must cover the GARM server IP, egress proxy IPs, and all RFC1918 ranges
# so that callbacks to GARM and egress proxy traffic are not intercepted.
NFT_EXCLUDE_RANGES="${NFT_EXCLUDE_RANGES:-10.0.0.0-10.129.255.255, 10.151.0.0-10.255.255.255, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16}"

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
TMP_WORK_DIR=""
SCOPE_ID=""   # ID of the registered repo / org / enterprise used for pool creation

# ===========================================================================
# Helper functions
# ===========================================================================

rand_alnum()      { (set +o pipefail; tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"); }
download_release() { curl -fsSL --max-time 120 "$1" -o "$2"; }

# ---------------------------------------------------------------------------
# prompt_var VAR_NAME "Human label" is_secret placeholder
#
# Prompts the user to enter a value for VAR_NAME if:
#   - the variable is currently empty, OR
#   - its value equals the known placeholder (i.e. the default was never changed)
#
# is_secret=true  → uses `read -s` so the input is not echoed
# placeholder     → the default placeholder string to detect as "not set"
#
# Non-secret vars show the current value as the default (press Enter to accept).
# ---------------------------------------------------------------------------
prompt_var() {
  local var_name="$1"
  local label="$2"
  local is_secret="${3:-false}"
  local placeholder="${4:-}"

  # Safely read the current value (handle unset under set -u)
  local current_val="${!var_name:-}"

  # Already set to a real (non-placeholder) value — nothing to do
  if [[ -n "$current_val" && "$current_val" != "$placeholder" ]]; then
    return 0
  fi

  local input=""
  while true; do
    if [[ "$is_secret" == "true" ]]; then
      read -rsp "  ${label}: " input </dev/tty
      echo >&2
    else
      # Show the current value as the default so the user can press Enter to accept
      if [[ -n "$current_val" ]]; then
        read -rp "  ${label} [${current_val}]: " input </dev/tty
      else
        read -rp "  ${label}: " input </dev/tty
      fi
    fi

    # User pressed Enter with no input — accept the existing default if it is not a placeholder
    if [[ -z "$input" ]]; then
      if [[ -n "$current_val" && "$current_val" != "$placeholder" ]]; then
        break
      fi
      echo "  ✗ This value is required, please enter a value." >&2
      continue
    fi

    printf -v "$var_name" '%s' "$input"
    break
  done
}

# ---------------------------------------------------------------------------
# Interactively collect every required input that has not been provided via
# environment variable. Groups inputs by section for readability.
# Called once at the start of main() before any work is done.
# ---------------------------------------------------------------------------
prompt_required_inputs() {
  # Skip prompts if stdin is not a terminal (piped / CI environment).
  # Bug fix: check stdin only (! -t 0), not both — if only stdout is redirected,
  # stdin is still interactive and prompts must fire. If stdin is piped, read
  # would immediately return empty causing an infinite required-value loop.
  if [[ ! -t 0 ]]; then
    return 0
  fi

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║          GARM OpenStack Installation — Configuration         ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  Pre-set variables are shown in [brackets]. Press Enter to accept."
  echo "  All values can also be supplied as environment variables."
  echo ""

  # ── GARM server ──────────────────────────────────────────────────────────
  echo "── GARM Server ─────────────────────────────────────────────────"
  echo "  The IP address runners will use to reach the GARM API."
  echo "  Must be the host's reachable IP on the OpenStack network, not 127.0.0.1."
  prompt_var BIND_ADDR      "GARM server bind/callback IP"      false "127.0.0.1"
  # Only ask for admin password when we will actually call garm init.
  # On re-runs with INIT_GARM=false the existing garm-cli token is reused.
  if [[ "${INIT_GARM:-true}" == "true" ]]; then
    prompt_var ADMIN_PASSWORD "Admin password (GARM UI/API login)" true  ""
  fi
  echo ""

  # ── OpenStack credentials ─────────────────────────────────────────────
  echo "── OpenStack Credentials ────────────────────────────────────────"
  prompt_var OS_AUTH_URL          "Keystone auth URL"           false "https://openstack.example.com:5000/v3"
  prompt_var OS_USERNAME          "OpenStack username"          false "replace-user"
  prompt_var OS_PASSWORD          "OpenStack password"          true  "replace-password"
  prompt_var OS_PROJECT_NAME      "OpenStack project name"      false "replace-project"
  prompt_var OS_REGION_NAME       "OpenStack region"            false ""
  echo ""

  # ── OpenStack infrastructure ──────────────────────────────────────────
  echo "── OpenStack Infrastructure ─────────────────────────────────────"
  echo "  Run: openstack network list"
  prompt_var NETWORK_ID           "Runner VM network ID (UUID)" false "00000000-0000-0000-0000-000000000000"
  echo "  Run: openstack image list"
  prompt_var POOL_IMAGE           "Runner VM image ID (UUID, must have aproxy snap)" \
                                                                false "00000000-0000-0000-0000-000000000000"
  echo ""

  # ── Egress proxy ─────────────────────────────────────────────────────
  echo "── Egress Proxy (for runner VMs) ────────────────────────────────"
  echo "  The upstream HTTP proxy that runner VMs forward traffic through."
  prompt_var EGRESS_PROXY         "Egress proxy (host:port)"    false "egress.example.internal:3128"
  echo ""

  # ── GitHub ────────────────────────────────────────────────────────────
  echo "── GitHub ───────────────────────────────────────────────────────"
  echo "  GitHub PAT requires scopes: repo, admin:repo_hook (and admin:org for orgs)."
  echo "  Leave blank if '${GITHUB_CREDENTIALS_NAME}' credentials already exist in GARM."
  # PAT is optional here — add_github_credentials() will die if it's empty
  # and the named credential doesn't already exist in the DB.
  if [[ -z "${GITHUB_PAT:-}" ]]; then
    local _pat=""
    read -rsp "  GitHub Personal Access Token (press Enter to skip): " _pat </dev/tty
    echo >&2
    [[ -n "$_pat" ]] && GITHUB_PAT="$_pat"
  fi

  # Prompt for runner scope if not already set
  if [[ -z "${RUNNER_SCOPE:-}" ]]; then
    echo ""
    echo "  Runner scope — where will these runners be available?"
    echo "    1) repo       — a single repository"
    echo "    2) org        — all repositories in an organisation"
    echo "    3) enterprise — all repositories in a GitHub Enterprise"
    local scope_choice=""
    while true; do
      read -rp "  Choose scope [1/2/3]: " scope_choice </dev/tty
      case "$scope_choice" in
        1) RUNNER_SCOPE="repo"        ; break ;;
        2) RUNNER_SCOPE="org"         ; break ;;
        3) RUNNER_SCOPE="enterprise"  ; break ;;
        *) echo "  Please enter 1, 2, or 3." ;;
      esac
    done
  fi

  case "$RUNNER_SCOPE" in
    repo)
      prompt_var REPO_OWNER "Repository owner (user or org)" false ""
      prompt_var REPO_NAME  "Repository name"                false ""
      ;;
    org)
      prompt_var ORG_NAME   "Organisation name"              false ""
      ;;
    enterprise)
      prompt_var ENTERPRISE_NAME "Enterprise slug"           false ""
      ;;
    *)
      die "RUNNER_SCOPE must be 'repo', 'org', or 'enterprise' (got: '${RUNNER_SCOPE}')"
      ;;
  esac
  echo ""

  # ── Summary ──────────────────────────────────────────────────────────
  echo "── Configuration Summary ────────────────────────────────────────"
  printf "  %-30s %s\n" "GARM bind/callback IP:"    "$BIND_ADDR:$PORT"
  printf "  %-30s %s\n" "OpenStack auth URL:"        "$OS_AUTH_URL"
  printf "  %-30s %s\n" "OpenStack user/project:"   "${OS_USERNAME} / ${OS_PROJECT_NAME}"
  printf "  %-30s %s\n" "OpenStack region:"          "$OS_REGION_NAME"
  printf "  %-30s %s\n" "Network ID:"                "$NETWORK_ID"
  printf "  %-30s %s\n" "Pool image ID:"             "$POOL_IMAGE"
  printf "  %-30s %s\n" "Egress proxy:"              "$EGRESS_PROXY"
  printf "  %-30s %s\n" "Runner scope:"              "$RUNNER_SCOPE"
  case "$RUNNER_SCOPE" in
    repo)       printf "  %-30s %s\n" "GitHub repository:" "${REPO_OWNER}/${REPO_NAME}" ;;
    org)        printf "  %-30s %s\n" "GitHub org:"        "$ORG_NAME" ;;
    enterprise) printf "  %-30s %s\n" "GitHub enterprise:" "$ENTERPRISE_NAME" ;;
  esac
  printf "  %-30s %s\n" "Install directory:"         "$INSTALL_DIR"
  echo ""
  read -rp "  Proceed with installation? [Y/n]: " confirm </dev/tty
  case "${confirm:-Y}" in
    [Yy]*|"") ;;
    *) echo "Aborted."; exit 0 ;;
  esac
  echo ""
}

install_dependencies() {
  local deps=(curl tar jq)
  local missing=()
  for dep in "${deps[@]}"; do
    has_cmd "$dep" || missing+=("$dep")
  done
  (( ${#missing[@]} == 0 )) && return 0
  log "Installing missing system packages: ${missing[*]}"
  if has_cmd sudo; then
    sudo apt-get update -y -qq
    sudo apt-get install -y -qq "${missing[@]}"
  else
    apt-get update -y -qq
    apt-get install -y -qq "${missing[@]}"
  fi
}

# ---------------------------------------------------------------------------
write_configs() {
  if [[ -f "$GARM_CONFIG" && "$FORCE_WRITE_CONFIG" != "true" ]]; then
    log "Config already exists — skipping write (set FORCE_WRITE_CONFIG=true to overwrite)"
    return 0
  fi

  local jwt_secret passphrase
  jwt_secret="$(rand_alnum 48)"
  passphrase="$(rand_alnum 32)"

  # Build the security groups TOML array from a comma-separated string
  local sg_toml="["
  IFS=',' read -ra sg_list <<< "$OS_SECURITY_GROUPS"
  for sg in "${sg_list[@]}"; do
    sg="$(echo "$sg" | xargs)"
    sg_toml+="\"${sg}\", "
  done
  sg_toml="${sg_toml%, }]"

  log "Writing $GARM_CONFIG"
  cat > "$GARM_CONFIG" <<TOML
callback_url = "http://${BIND_ADDR}:${PORT}/api/v1/callbacks"
metadata_url = "http://${BIND_ADDR}:${PORT}/api/v1/metadata"
webhook_url  = "http://${BIND_ADDR}:${PORT}/webhooks"

[default]
enable_webhook_management = true

[logging]
enable_log_streamer = true
log_format = "text"
log_level  = "info"
log_source = false

[metrics]
enable       = true
disable_auth = false

[jwt_auth]
secret       = "${jwt_secret}"
time_to_live = "8760h"

[apiserver]
bind    = "${BIND_ADDR}"
port    = ${PORT}
use_tls = false
  [apiserver.webui]
  enable = true

[database]
backend    = "sqlite3"
passphrase = "${passphrase}"
  [database.sqlite3]
  db_file              = "${DATA_DIR}/garm.db"
  busy_timeout_seconds = 5

[[provider]]
name          = "openstack_external"
description   = "OpenStack external provider"
provider_type = "external"
disable_jit_config = false
  [provider.external]
  provider_executable = "${PROVIDER_BIN}"
  config_file         = "${PROVIDER_CONFIG}"
TOML

  log "Writing $PROVIDER_CONFIG"
  cat > "$PROVIDER_CONFIG" <<TOML
cloud                   = "${OS_CLOUD_NAME}"
default_storage_backend = ""
default_security_groups = ${sg_toml}
network_id              = "${NETWORK_ID}"
boot_from_volume        = false
root_disk_size          = 30
use_config_drive        = false
disable_updates_on_boot = ${DISABLE_UPDATES_ON_BOOT}

[credentials]
clouds        = "${CLOUDS_CONFIG}"
public_clouds = ""
secure_clouds = ""
TOML

  log "Writing $CLOUDS_CONFIG"
  cat > "$CLOUDS_CONFIG" <<YAML
clouds:
  ${OS_CLOUD_NAME}:
    auth:
      auth_url:            "${OS_AUTH_URL}"
      username:            "${OS_USERNAME}"
      password:            "${OS_PASSWORD}"
      project_name:        "${OS_PROJECT_NAME}"
      user_domain_name:    "${OS_USER_DOMAIN_NAME}"
      project_domain_name: "${OS_PROJECT_DOMAIN_NAME}"
    region_name:           "${OS_REGION_NAME}"
    interface:             "${OS_INTERFACE}"
    identity_api_version:  3
YAML
  chmod 600 "$CLOUDS_CONFIG"
  log "Config files written."
}

# ---------------------------------------------------------------------------
start_garm() {
  local existing_pid
  existing_pid="$(ps -ef | awk -v cfg="$GARM_CONFIG" '$0 ~ /garm -config/ && $0 ~ cfg && !/awk/ {print $2; exit}')"
  if [[ -n "${existing_pid:-}" ]]; then
    if [[ "$STOP_EXISTING_GARM" == "true" ]]; then
      log "Stopping existing garm (PID $existing_pid)"
      kill "$existing_pid"
      # Wait until the process is fully gone before starting the new one
      local waited=0
      while ps -p "$existing_pid" >/dev/null 2>&1; do
        sleep 1
        (( waited++ )) || true
        (( waited >= 15 )) && die "Timed out waiting for existing garm (PID $existing_pid) to stop"
      done
    else
      log "Existing garm detected (PID $existing_pid) — leaving as-is (STOP_EXISTING_GARM=false)"
      return 0
    fi
  fi
  log "Starting garm..."
  nohup "$GARM_BIN" -config "$GARM_CONFIG" >> "$LOG_DIR/garm.log" 2>&1 &
  local new_pid=$!

  # Bug fix: don't rely on a fixed sleep — poll until the HTTP API responds,
  # falling back to a process-exists check if the API never comes up.
  log "Waiting for garm API to be ready on http://${BIND_ADDR}:${PORT}..."
  local attempts=0
  local max_attempts=30  # 30 × 1s = 30s max
  while true; do
    if ! ps -p "$new_pid" >/dev/null 2>&1; then
      die "garm process (PID $new_pid) exited unexpectedly. Check $LOG_DIR/garm.log"
    fi
    # Any HTTP response (even 401 Unauthorized) means the server is up.
    # Drop -f so curl returns 0 for all HTTP status codes; only fails on
    # connection errors (no server listening) or timeout.
    if curl -s -o /dev/null --max-time 2 "http://${BIND_ADDR}:${PORT}/api/v1/metadata" 2>/dev/null; then
      break
    fi
    (( attempts++ )) || true
    if (( attempts >= max_attempts )); then
      die "garm API did not respond after ${max_attempts}s. Check $LOG_DIR/garm.log"
    fi
    sleep 1
  done
  log "garm started and API is ready (PID $new_pid)"
}

# ---------------------------------------------------------------------------
init_garm() {
  [[ "$INIT_GARM" == "true" ]] || return 0
  [[ -n "$ADMIN_PASSWORD" ]] || die "INIT_GARM=true requires ADMIN_PASSWORD to be set"

  log "Initializing garm controller..."

  # Use the REST API directly so init works non-interactively in all environments.
  # garm-cli init opens /dev/tty for a confirm-password prompt even when
  # --password is supplied, which breaks headless/CI runs.
  local payload resp http_code
  payload=$(jq -n \
    --arg u  "$ADMIN_USERNAME" \
    --arg p  "$ADMIN_PASSWORD" \
    --arg e  "$ADMIN_EMAIL" \
    --arg fn "$ADMIN_FULL_NAME" \
    --arg mu "http://${BIND_ADDR}:${PORT}/api/v1/metadata" \
    --arg cu "http://${BIND_ADDR}:${PORT}/api/v1/callbacks" \
    --arg wu "http://${BIND_ADDR}:${PORT}/webhooks" \
    '{username:$u,password:$p,email:$e,full_name:$fn,metadata_url:$mu,callback_url:$cu,webhook_url:$wu}')

  resp=$(curl -s -w '\n__HTTP_CODE__%{http_code}' \
    -X POST "http://${BIND_ADDR}:${PORT}/api/v1/first-run" \
    -H 'Content-Type: application/json' \
    -d "$payload")
  http_code="${resp##*__HTTP_CODE__}"
  resp="${resp%__HTTP_CODE__*}"

  case "$http_code" in
    200|201)
      log "garm controller initialized."
      ;;
    409)
      die "garm is already initialized. Re-run with INIT_GARM=false to skip this step."
      ;;
    400)
      if echo "$resp" | grep -qi "too weak"; then
        die "garm init failed: password is too weak. Use a stronger password (>=10 chars, mixed case, digits and symbols)."
      fi
      die "garm init failed (HTTP 400): $resp"
      ;;
    000)
      die "garm API is not reachable at http://${BIND_ADDR}:${PORT}. Check BIND_ADDR and that garm is running."
      ;;
    *)
      die "garm init failed (HTTP ${http_code}): $resp"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Ensure garm-cli is pointed at the correct manager profile before any
# API calls. Falls back to adding the profile if it doesn't exist yet.
ensure_cli_profile() {
  # Bug fix: don't suppress stderr — if profile list itself fails (e.g. bad
  # token), we need to see the error. Use a temp var to capture output cleanly.
  local profile_list
  profile_list="$("$GARM_CLI_BIN" profile list 2>&1)" || true

  if echo "$profile_list" | grep -q "$CONTROLLER_NAME"; then
    "$GARM_CLI_BIN" profile switch "$CONTROLLER_NAME" >/dev/null
    # Verify the active profile can actually reach the API with a live token
    if ! "$GARM_CLI_BIN" github credentials list >/dev/null 2>&1; then
      log "Existing profile token is expired or invalid — refreshing login..."
      [[ -n "$ADMIN_PASSWORD" ]] || die "Profile token is invalid and ADMIN_PASSWORD is not set. Cannot refresh."
      "$GARM_CLI_BIN" profile login \
        --username="$ADMIN_USERNAME" \
        --password="$ADMIN_PASSWORD"
    fi
    return 0
  fi

  [[ -n "$ADMIN_PASSWORD" ]] || die "No garm-cli profile for '${CONTROLLER_NAME}'. Set ADMIN_PASSWORD or log in manually."
  log "No profile found — adding profile for ${ADMIN_USERNAME}..."
  "$GARM_CLI_BIN" profile add \
    --name="$CONTROLLER_NAME" \
    --url="http://${BIND_ADDR}:${PORT}" \
    --username="$ADMIN_USERNAME" \
    --password="$ADMIN_PASSWORD"
  "$GARM_CLI_BIN" profile switch "$CONTROLLER_NAME" >/dev/null
}

# ---------------------------------------------------------------------------
add_github_credentials() {
  if "$GARM_CLI_BIN" github credentials list --format json 2>/dev/null \
      | jq -e --arg n "$GITHUB_CREDENTIALS_NAME" '.[] | select(.name == $n)' >/dev/null 2>&1; then
    log "GitHub credentials '${GITHUB_CREDENTIALS_NAME}' already registered, skipping."
    return 0
  fi

  [[ -n "$GITHUB_PAT" ]] || die "GITHUB_PAT must be set to register GitHub credentials"

  log "Adding GitHub credentials '${GITHUB_CREDENTIALS_NAME}'..."
  "$GARM_CLI_BIN" github credentials add \
    --name="$GITHUB_CREDENTIALS_NAME" \
    --description="$GITHUB_CREDENTIALS_DESC" \
    --endpoint="$GITHUB_ENDPOINT" \
    --auth-type="pat" \
    --pat-oauth-token="$GITHUB_PAT"
  log "GitHub credentials added."
}

# ---------------------------------------------------------------------------
add_repository() {
  [[ -n "$REPO_OWNER" ]] || die "REPO_OWNER must be set"
  [[ -n "$REPO_NAME"  ]] || die "REPO_NAME must be set"

  local existing
  existing="$("$GARM_CLI_BIN" repository list --format json 2>/dev/null \
    | jq -r --arg o "$REPO_OWNER" --arg n "$REPO_NAME" \
        '.[] | select(.owner == $o and .name == $n) | .id' || true)"

  if [[ -n "$existing" ]]; then
    log "Repository ${REPO_OWNER}/${REPO_NAME} already registered (ID: ${existing}), skipping."
    SCOPE_ID="$existing"
    return 0
  fi

  log "Registering repository ${REPO_OWNER}/${REPO_NAME}..."
  local webhook_flag=""
  [[ "$RANDOM_WEBHOOK_SECRET" == "true" ]] && webhook_flag="--random-webhook-secret"

  SCOPE_ID="$("$GARM_CLI_BIN" repository add \
    --owner="$REPO_OWNER" \
    --name="$REPO_NAME" \
    --credentials="$GITHUB_CREDENTIALS_NAME" \
    ${webhook_flag} \
    --format json | jq -r '.id')"
  log "Repository registered (ID: ${SCOPE_ID})"
}

# ---------------------------------------------------------------------------
add_organization() {
  [[ -n "$ORG_NAME" ]] || die "ORG_NAME must be set for org scope"

  local existing
  existing="$("$GARM_CLI_BIN" organization list --format json 2>/dev/null \
    | jq -r --arg n "$ORG_NAME" '.[] | select(.name == $n) | .id' || true)"

  if [[ -n "$existing" ]]; then
    log "Organisation '${ORG_NAME}' already registered (ID: ${existing}), skipping."
    SCOPE_ID="$existing"
    return 0
  fi

  log "Registering organisation '${ORG_NAME}'..."
  local webhook_flag=""
  [[ "$RANDOM_WEBHOOK_SECRET" == "true" ]] && webhook_flag="--random-webhook-secret"

  SCOPE_ID="$("$GARM_CLI_BIN" organization add \
    --name="$ORG_NAME" \
    --credentials="$GITHUB_CREDENTIALS_NAME" \
    ${webhook_flag} \
    --format json | jq -r '.id')"
  log "Organisation registered (ID: ${SCOPE_ID})"
}

# ---------------------------------------------------------------------------
add_enterprise() {
  [[ -n "$ENTERPRISE_NAME" ]] || die "ENTERPRISE_NAME must be set for enterprise scope"

  local existing
  existing="$("$GARM_CLI_BIN" enterprise list --format json 2>/dev/null \
    | jq -r --arg n "$ENTERPRISE_NAME" '.[] | select(.name == $n) | .id' || true)"

  if [[ -n "$existing" ]]; then
    log "Enterprise '${ENTERPRISE_NAME}' already registered (ID: ${existing}), skipping."
    SCOPE_ID="$existing"
    return 0
  fi

  log "Registering enterprise '${ENTERPRISE_NAME}'..."
  SCOPE_ID="$("$GARM_CLI_BIN" enterprise add \
    --name="$ENTERPRISE_NAME" \
    --credentials="$GITHUB_CREDENTIALS_NAME" \
    --format json | jq -r '.id')"
  log "Enterprise registered (ID: ${SCOPE_ID})"
}

# ---------------------------------------------------------------------------
# Registers the repo / org / enterprise based on RUNNER_SCOPE
# ---------------------------------------------------------------------------
register_github_target() {
  case "$RUNNER_SCOPE" in
    repo)       add_repository ;;
    org)        add_organization ;;
    enterprise) add_enterprise ;;
    *)          die "RUNNER_SCOPE must be 'repo', 'org', or 'enterprise' (got: '${RUNNER_SCOPE}')" ;;
  esac
}

# ---------------------------------------------------------------------------
# Build the runner bootstrap script as a base64-encoded string.
#
# The resulting script is embedded in the pool's runner_install_template
# extra-spec. GARM renders Go template variables ({{ .Variable }}) per-runner
# before injecting the script into cloud-init user-data.
#
# Design:
#   1. Configure the runner VM's local aproxy snap to forward to EGRESS_PROXY
#   2. Install nft DNAT rules redirecting outbound HTTP/HTTPS through local
#      aproxy (127.0.0.1:APROXY_LOCAL_PORT), NOT the GARM server — port 8443
#      is not open on the GARM server's security group
#   3. Standard GARM runner install: download tarball, install dependencies,
#      fetch JIT credentials from GARM metadata API, set up systemd service
# ---------------------------------------------------------------------------
build_runner_install_template_b64() {
  local exclude="${NFT_EXCLUDE_RANGES}"
  local proxy="${EGRESS_PROXY}"
  local port="${APROXY_LOCAL_PORT}"

  # Write template to a temp file so the heredoc is not confused by the
  # inner NFTEOF heredoc marker or Go template braces.
  local tmp_tpl
  tmp_tpl="$(mktemp)"
  # Register in the global trap so it's cleaned up on any exit
  TMP_WORK_DIR="${TMP_WORK_DIR:-}"
  trap '[[ -n "${TMP_WORK_DIR:-}" ]] && rm -rf "${TMP_WORK_DIR}"; rm -f "${tmp_tpl:-}"' EXIT

  cat > "$tmp_tpl" <<TEMPLATE_EOF
#!/bin/bash

set -e
set -o pipefail

CALLBACK_URL="{{ .CallbackURL }}"
METADATA_URL="{{ .MetadataURL }}"
BEARER_TOKEN="{{ .CallbackToken }}"
RUN_HOME="/home/{{ .RunnerUsername }}/actions-runner"

# ---------------------------------------------------------------------------
# Step 1: Configure local aproxy to forward through the egress proxy.
# Must run before any outbound network call (including runner binary download).
# ---------------------------------------------------------------------------
sudo snap set aproxy listen=:${port} proxy=${proxy}

# ---------------------------------------------------------------------------
# Step 2: Install nft DNAT rules that transparently redirect outbound
# HTTP/HTTPS traffic through the local aproxy.
#
# Private/overlay ranges in the exclusion list are NOT redirected, ensuring
# that calls to the GARM server and the egress proxy itself are not looped.
# ---------------------------------------------------------------------------
sudo nft -f - <<'NFTEOF'
table ip aproxy {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		ip daddr != { ${exclude} } tcp dport { 80, 443, 5000, 8774, 9696, 9292 } counter dnat to 127.0.0.1:${port}
	}

	chain output {
		type nat hook output priority dstnat; policy accept;
		ip daddr != { ${exclude} } tcp dport { 80, 443, 5000, 8774, 9696, 9292 } counter dnat to 127.0.0.1:${port}
	}
}
NFTEOF

# ---------------------------------------------------------------------------
# Step 3: Standard GARM runner install flow
# ---------------------------------------------------------------------------
if [ -z "\$METADATA_URL" ]; then
	echo "no token is available and METADATA_URL is not set"
	exit 1
fi

function call() {
	PAYLOAD="\$1"
	[[ \$CALLBACK_URL =~ ^(.*)/status(/)?$ ]] || CALLBACK_URL="\${CALLBACK_URL}/status"
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
		-X POST -d "\${PAYLOAD}" \
		-H 'Accept: application/json' \
		-H "Authorization: Bearer \${BEARER_TOKEN}" \
		"\${CALLBACK_URL}" || echo "failed to call home: exit code (\$?)"
}

function systemInfo() {
	if [ -f "/etc/os-release" ]; then
		. /etc/os-release
	fi
	OS_NAME=\${NAME:-""}
	OS_VERSION=\${VERSION_ID:-""}
	AGENT_ID=\${1:-null}
	[[ \$CALLBACK_URL =~ ^(.*)/status(/)?$ ]] && CALLBACK_URL="\${BASH_REMATCH[1]}" || true
	SYSINFO_URL="\${CALLBACK_URL}/system_info/"
	PAYLOAD="{\"os_name\": \"\$OS_NAME\", \"os_version\": \"\$OS_VERSION\", \"agent_id\": \$AGENT_ID}"
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
		-X POST -d "\${PAYLOAD}" \
		-H 'Accept: application/json' \
		-H "Authorization: Bearer \${BEARER_TOKEN}" \
		"\${SYSINFO_URL}" || true
}

function sendStatus() {
	call "{\"status\": \"installing\", \"message\": \"\$1\"}"
}

function success() {
	local MSG="\$1"
	local ID=\${2:-null}
	call "{\"status\": \"idle\", \"message\": \"\$MSG\", \"agent_id\": \$ID}"
}

function fail() {
	call "{\"status\": \"failed\", \"message\": \"\$1\"}"
	exit 1
}

function downloadAndExtractRunner() {
	sendStatus "downloading tools from {{ .DownloadURL }}"
	local TEMP_TOKEN=""
	if [ ! -z "{{ .TempDownloadToken }}" ]; then
		TEMP_TOKEN="Authorization: Bearer {{ .TempDownloadToken }}"
	fi
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -L \
		-H "\${TEMP_TOKEN}" \
		-o "/home/{{ .RunnerUsername }}/{{ .FileName }}" \
		"{{ .DownloadURL }}" || fail "failed to download tools"
	mkdir -p "\$RUN_HOME" || fail "failed to create actions-runner folder"
	sendStatus "extracting runner"
	tar xf "/home/{{ .RunnerUsername }}/{{ .FileName }}" -C "\$RUN_HOME"/ || fail "failed to extract runner"
	chown {{ .RunnerUsername }}:{{ .RunnerUsername }} -R "\$RUN_HOME"/ || fail "failed to change owner"
}

if [ ! -d "\$RUN_HOME" ]; then
	downloadAndExtractRunner
	sendStatus "installing dependencies"
	cd "\$RUN_HOME"
	sudo ./bin/installdependencies.sh || fail "failed to install dependencies"
else
	sendStatus "using cached runner found in \$RUN_HOME"
	cd "\$RUN_HOME"
fi

sendStatus "configuring runner"

function getRunnerFile() {
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
		-X GET \
		-H 'Accept: application/json' \
		-H "Authorization: Bearer \${BEARER_TOKEN}" \
		"\${METADATA_URL}/\$1" -o "\$2"
}

sendStatus "downloading JIT credentials"
getRunnerFile "credentials/runner"               "\${RUN_HOME}/.runner"                || fail "failed to get runner file"
getRunnerFile "credentials/credentials"           "\${RUN_HOME}/.credentials"           || fail "failed to get credentials file"
getRunnerFile "credentials/credentials_rsaparams" "\${RUN_HOME}/.credentials_rsaparams" || fail "failed to get credentials_rsaparams file"
getRunnerFile "system/service-name"               "\${RUN_HOME}/.service"               || fail "failed to get service name file"
sed -i 's/\$/.service/' "\${RUN_HOME}/.service"

SVC_NAME=\$(cat "\${RUN_HOME}/.service")

sendStatus "generating systemd unit file"
getRunnerFile "systemd/unit-file?runAsUser={{ .RunnerUsername }}" "\$SVC_NAME" || fail "failed to get service file"
sudo mv "\$SVC_NAME" /etc/systemd/system/  || fail "failed to move service file"
sudo chown root:root /etc/systemd/system/"\$SVC_NAME" || fail "failed to change owner"
if [ -e "/sys/fs/selinux" ]; then
	sudo chcon -h system_u:object_r:systemd_unit_file_t:s0 /etc/systemd/system/"\$SVC_NAME" || fail "failed to change selinux context"
fi

sendStatus "enabling runner service"
cp "\$RUN_HOME"/bin/runsvc.sh "\$RUN_HOME"/ || fail "failed to copy runsvc.sh"
sudo systemctl daemon-reload    || fail "failed to reload systemd"
sudo systemctl enable "\$SVC_NAME"

if [ -e "/sys/fs/selinux" ]; then
	sudo chcon -R -h user_u:object_r:bin_t:s0 /home/{{ .RunnerUsername }}/ || fail "failed to change selinux context"
fi

AGENT_ID=""
if [ -f "\$RUN_HOME/env.sh" ]; then
	pushd "\$RUN_HOME"
	source env.sh
	popd
fi
sudo systemctl start "\$SVC_NAME" || fail "failed to start service"
systemInfo \$AGENT_ID
success "runner successfully installed" \$AGENT_ID
TEMPLATE_EOF

  base64 -w0 "$tmp_tpl"
  rm -f "$tmp_tpl"
}

# ---------------------------------------------------------------------------
create_pool() {
  [[ -n "${SCOPE_ID:-}" ]] || die "SCOPE_ID is not set — register_github_target() must run first"

  # Build the --repo/--org/--enterprise flag for pool add
  local scope_flag
  case "$RUNNER_SCOPE" in
    repo)       scope_flag="--repo=$SCOPE_ID" ;;
    org)        scope_flag="--org=$SCOPE_ID" ;;
    enterprise) scope_flag="--enterprise=$SCOPE_ID" ;;
  esac

  # Idempotent: skip if a pool with the same image+flavor already exists in this scope
  local existing
  existing="$("$GARM_CLI_BIN" pool list $scope_flag --format json 2>/dev/null \
    | jq -r --arg img "$POOL_IMAGE" --arg flv "$POOL_FLAVOR" \
        '.[] | select(.image == $img and .flavor == $flv) | .id' || true)"
  if [[ -n "$existing" ]]; then
    log "Pool for image '${POOL_IMAGE}' / flavor '${POOL_FLAVOR}' already exists (ID: ${existing}), skipping."
    return 0
  fi

  log "Building runner install template (aproxy + nft + runner install)..."
  local template_b64
  template_b64="$(build_runner_install_template_b64)"

  log "Creating runner pool (scope: ${RUNNER_SCOPE})..."
  "$GARM_CLI_BIN" pool add \
    $scope_flag \
    --provider-name="openstack_external" \
    --image="$POOL_IMAGE" \
    --flavor="$POOL_FLAVOR" \
    --os-type="$POOL_OS_TYPE" \
    --os-arch="$POOL_OS_ARCH" \
    --max-runners="$POOL_MAX_RUNNERS" \
    --min-idle-runners="$POOL_MIN_IDLE" \
    --tags="$POOL_TAGS" \
    --runner-prefix="$POOL_RUNNER_PREFIX" \
    --runner-bootstrap-timeout="$POOL_BOOTSTRAP_TIMEOUT" \
    --extra-specs="{\"runner_install_template\": \"${template_b64}\"}" \
    --enabled
  log "Pool created."
}

# ===========================================================================
# Main
# ===========================================================================
main() {
  prompt_required_inputs

  log "=== GARM OpenStack install (garm ${GARM_VERSION}, provider ${OPENSTACK_PROVIDER_VERSION}) ==="

  install_dependencies

  mkdir -p "$BIN_DIR" "$ETC_DIR" "$DATA_DIR" "$LOG_DIR" "$PROVIDER_DIR"

  TMP_WORK_DIR="$(mktemp -d)"
  trap '[[ -n "${TMP_WORK_DIR:-}" ]] && rm -rf "${TMP_WORK_DIR}"' EXIT

  # -- Download binaries ----------------------------------------------------
  log "Downloading garm ${GARM_VERSION}..."
  download_release \
    "https://github.com/cloudbase/garm/releases/download/${GARM_VERSION}/garm-linux-amd64.tgz" \
    "$TMP_WORK_DIR/garm.tgz"
  tar -xzf "$TMP_WORK_DIR/garm.tgz" -C "$BIN_DIR"

  log "Downloading garm-cli ${GARM_VERSION}..."
  download_release \
    "https://github.com/cloudbase/garm/releases/download/${GARM_VERSION}/garm-cli-linux-amd64.tgz" \
    "$TMP_WORK_DIR/garm-cli.tgz"
  tar -xzf "$TMP_WORK_DIR/garm-cli.tgz" -C "$BIN_DIR"

  log "Downloading garm-provider-openstack ${OPENSTACK_PROVIDER_VERSION}..."
  download_release \
    "https://github.com/cloudbase/garm-provider-openstack/releases/download/${OPENSTACK_PROVIDER_VERSION}/garm-provider-openstack-linux-amd64.tgz" \
    "$TMP_WORK_DIR/provider.tgz"
  tar -xzf "$TMP_WORK_DIR/provider.tgz" -C "$TMP_WORK_DIR"
  install -m 0755 "$TMP_WORK_DIR/garm-provider-openstack" "$PROVIDER_BIN"

  chmod +x "$GARM_BIN" "$GARM_CLI_BIN"

  # -- Write config files ---------------------------------------------------
  write_configs

  # -- Start daemon ---------------------------------------------------------
  if [[ "$START_GARM" == "true" ]]; then
    start_garm
  else
    log "START_GARM=false — skipping daemon start"
  fi

  # -- Initialize garm (first run only) -------------------------------------
  init_garm

  # -- Configure via garm-cli -----------------------------------------------
  ensure_cli_profile
  add_github_credentials
  register_github_target
  create_pool

  log ""
  log "=== Installation complete ==="
  log "  GARM API:      http://${BIND_ADDR}:${PORT}"
  log "  Config:        $GARM_CONFIG"
  log "  Provider cfg:  $PROVIDER_CONFIG"
  log "  Cloud creds:   $CLOUDS_CONFIG"
  log "  Logs:          $LOG_DIR/garm.log"
  log ""
  log "  Check runner status:"
  log "    $GARM_CLI_BIN runner list --all"
}

main "$@"
