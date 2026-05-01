#!/usr/bin/env bash
set -Eeuo pipefail

BASE_PORT="${NEMOCLAW_DEMO_BASE_PORT:-18789}"
DEFAULT_COUNT="${NEMOCLAW_DEMO_COUNT:-5}"
DEFAULT_PROVIDER="${NEMOCLAW_PROVIDER:-custom}"
DEFAULT_MODEL="${NEMOCLAW_MODEL:-aws/anthropic/bedrock-claude-opus-4-6}"
DEFAULT_MAX_TOKENS="${NEMOCLAW_MAX_TOKENS:-16384}"
NVIDIA_BASE_URL="${NEMOCLAW_NVIDIA_BASE_URL:-${NVIDIA_BASE_URL:-https://inference-api.nvidia.com/v1}}"
POLICY_TIER="${NEMOCLAW_POLICY_TIER:-balanced}"
DASHBOARD_MODE="github-pages"
TUNNEL_CREATE_DELAY="${NEMOCLAW_DEMO_TUNNEL_CREATE_DELAY:-10}"
TUNNEL_MAX_ATTEMPTS="${NEMOCLAW_DEMO_TUNNEL_MAX_ATTEMPTS:-5}"
TEMPLATE_SANDBOX="${NEMOCLAW_DEMO_TEMPLATE_SANDBOX:-exec-template}"
TEMPLATE_SNAPSHOT_NAME="${NEMOCLAW_DEMO_TEMPLATE_SNAPSHOT_NAME:-exec-demo-template}"
DEMO_DIR="${NEMOCLAW_DEMO_DIR:-$HOME/.nemoclaw/exec-demo}"
TUNNEL_DIR="$DEMO_DIR/tunnels"
ONBOARD_LOG_DIR="$DEMO_DIR/onboard-logs"
LINKS_FILE="$DEMO_DIR/links.txt"
PID_FILE="$TUNNEL_DIR/cloudflared.pids"
FORWARD_PID_FILE="$TUNNEL_DIR/openshell-forward.pids"
SECRETS_FILE="${NEMOCLAW_DEMO_SECRETS_FILE:-$DEMO_DIR/secrets.tsv}"
ENV_CACHE_FILE="${NEMOCLAW_DEMO_ENV_CACHE_FILE:-$DEMO_DIR/env.tsv}"
TEMPLATE_META_FILE="$DEMO_DIR/template.meta"
GITHUB_REPO_INPUT="${NEMOCLAW_DEMO_GITHUB_REPO_URL:-${NEMOCLAW_DEMO_GITHUB_DASHBOARD_REPO:-}}"
GITHUB_PAGES_BASE_URL=""
GITHUB_DASHBOARD_REPO=""
GITHUB_REPO_SLUG=""
GITHUB_DASHBOARD_BRANCH="${NEMOCLAW_DEMO_GITHUB_DASHBOARD_BRANCH:-main}"
GITHUB_DASHBOARD_PAGES_DIR="${NEMOCLAW_DEMO_GITHUB_DASHBOARD_PAGES_DIR:-docs}"
GITHUB_DASHBOARD_AUTHOR_NAME="${NEMOCLAW_DEMO_GITHUB_AUTHOR_NAME:-NemoClaw Demo}"
GITHUB_DASHBOARD_AUTHOR_EMAIL="${NEMOCLAW_DEMO_GITHUB_AUTHOR_EMAIL:-nemoclaw-demo@example.invalid}"
GITHUB_PROVIDER_NAME="github"
GITHUB_TOKEN_VALUE=""
FAST_CLONE_POLICY_FILE="${NEMOCLAW_DEMO_FAST_CLONE_POLICY_FILE:-$DEMO_DIR/fast-clone-policy.yaml}"
FAST_CLONE_POLICY_PRESETS=""
FAST_CLONE_POLICY_READY=0
BOOTSTRAP_BIN_DIR="$DEMO_DIR/bin"
NEMOCLAW_SOURCE_DIR="${NEMOCLAW_SOURCE_DIR:-$HOME/.nemoclaw/source}"
NEMOCLAW_INSTALL_REF="${NEMOCLAW_INSTALL_TAG:-}"
SUDO_KEEPALIVE_PID=""

log() {
  printf '[nemoclaw-demo] %s\n' "$*"
}

warn() {
  printf '[nemoclaw-demo] warning: %s\n' "$*" >&2
}

die() {
  printf '[nemoclaw-demo] error: %s\n' "$*" >&2
  exit 1
}

cleanup_on_exit() {
  if [ -n "${SUDO_KEEPALIVE_PID:-}" ]; then
    kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup_on_exit EXIT

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_truthy() {
  case "${1:-}" in
    1|true|True|TRUE|yes|Yes|YES|y|Y|on|On|ON) return 0 ;;
    *) return 1 ;;
  esac
}

demo_noninteractive() {
  is_truthy "${NEMOCLAW_DEMO_NONINTERACTIVE:-0}"
}

use_template() {
  case "${NEMOCLAW_DEMO_USE_TEMPLATE:-1}" in
    0|false|False|FALSE|no|No|NO|off|Off|OFF) return 1 ;;
    *) return 0 ;;
  esac
}

refresh_template() {
  is_truthy "${NEMOCLAW_DEMO_REFRESH_TEMPLATE:-0}"
}

bootstrap_path() {
  export PATH="$BOOTSTRAP_BIN_DIR:$HOME/.local/bin:/usr/local/bin:$PATH"
}

clear_stale_bootstrap_wrappers() {
  rm -f "$BOOTSTRAP_BIN_DIR/docker"
}

require_tty() {
  if [ ! -t 0 ]; then
    die "this script prompts for secrets and must be run from an interactive terminal"
  fi
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "$prompt [$default]: " value
  printf '%s' "${value:-$default}"
}

prompt_secret() {
  local prompt="$1"
  local value
  read -r -p "$prompt" value
  printf '%s' "$value"
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-Y}"
  local suffix answer
  if [ "$default" = "Y" ]; then
    suffix='[Y/n]'
  else
    suffix='[y/N]'
  fi
  read -r -p "$prompt $suffix: " answer
  answer="${answer:-$default}"
  case "${answer,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

read_saved_secret() {
  local key="$1"
  [ -f "$SECRETS_FILE" ] || return 0
  awk -F '\t' -v k="$key" '$1 == k { value = $2 } END { if (value != "") print value }' "$SECRETS_FILE"
}

save_secret() {
  local key="$1"
  local value="$2"
  local dir tmp
  [ -n "$value" ] || return 0
  dir="$(dirname "$SECRETS_FILE")"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  tmp="$SECRETS_FILE.tmp.$$"
  if [ -f "$SECRETS_FILE" ]; then
    awk -F '\t' -v k="$key" '$1 != k { print }' "$SECRETS_FILE" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$SECRETS_FILE"
}

delete_saved_secret() {
  local key="$1"
  local tmp
  [ -f "$SECRETS_FILE" ] || return 0
  tmp="$SECRETS_FILE.tmp.$$"
  awk -F '\t' -v k="$key" '$1 != k { print }' "$SECRETS_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$SECRETS_FILE"
}

read_cached_env() {
  local key="$1"
  [ -f "$ENV_CACHE_FILE" ] || return 0
  awk -F '\t' -v k="$key" '$1 == k { value = $2 } END { if (value != "") print value }' "$ENV_CACHE_FILE"
}

save_cached_env() {
  local key="$1"
  local value="$2"
  local dir tmp
  [ -n "$value" ] || return 0
  dir="$(dirname "$ENV_CACHE_FILE")"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  tmp="$ENV_CACHE_FILE.tmp.$$"
  if [ -f "$ENV_CACHE_FILE" ]; then
    awk -F '\t' -v k="$key" '$1 != k { print }' "$ENV_CACHE_FILE" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_CACHE_FILE"
}

default_secret_for_env() {
  local key="$1"
  local value="${NEMOCLAW_PROVIDER_KEY:-}"
  if [ -z "$value" ]; then
    value="${!key:-}"
  fi
  if [ -z "$value" ]; then
    value="$(read_saved_secret "$key")"
  fi
  printf '%s' "$value"
}

default_llm_api_key() {
  local value
  value="$(default_secret_for_env "$CRED_ENV")"
  if [ -z "$value" ] && [ "$PROVIDER" = "custom" ] && [ "$ENDPOINT_URL" = "$NVIDIA_BASE_URL" ]; then
    value="${NVIDIA_INFERENCE_API_KEY:-}"
  fi
  if [ -z "$value" ] && [ "$PROVIDER" = "custom" ] && [ "$ENDPOINT_URL" = "$NVIDIA_BASE_URL" ]; then
    value="${NVIDIA_API_KEY:-}"
  fi
  if [ -z "$value" ] && [ "$PROVIDER" = "custom" ] && [ "$ENDPOINT_URL" = "$NVIDIA_BASE_URL" ]; then
    value="$(read_saved_secret NVIDIA_INFERENCE_API_KEY)"
  fi
  if [ -z "$value" ] && [ "$PROVIDER" = "custom" ] && [ "$ENDPOINT_URL" = "$NVIDIA_BASE_URL" ]; then
    value="$(read_saved_secret NVIDIA_API_KEY)"
  fi
  printf '%s' "$value"
}

save_llm_api_key() {
  save_secret "$CRED_ENV" "$LLM_API_KEY"
  if [ "$PROVIDER" = "custom" ] && [ "$ENDPOINT_URL" = "$NVIDIA_BASE_URL" ]; then
    save_secret NVIDIA_INFERENCE_API_KEY "$LLM_API_KEY"
  fi
  export "$CRED_ENV=$LLM_API_KEY"
  export NEMOCLAW_PROVIDER_KEY="$LLM_API_KEY"
}

default_github_repo_input() {
  local value="$GITHUB_REPO_INPUT"
  if [ -z "$value" ]; then
    value="$(read_cached_env NEMOCLAW_DEMO_GITHUB_REPO_URL)"
  fi
  if [ -z "$value" ]; then
    value="$(read_saved_secret NEMOCLAW_DEMO_GITHUB_REPO_URL)"
  fi
  printf '%s' "$value"
}

remember_github_repo_input() {
  GITHUB_REPO_INPUT="$1"
  save_cached_env NEMOCLAW_DEMO_GITHUB_REPO_URL "$GITHUB_REPO_INPUT"
  save_secret NEMOCLAW_DEMO_GITHUB_REPO_URL "$GITHUB_REPO_INPUT"
  export NEMOCLAW_DEMO_GITHUB_REPO_URL="$GITHUB_REPO_INPUT"
}

prompt_key_value() {
  local key="$1"
  local default_value="$2"
  local required="${3:-1}"
  local value

  if [ -n "$default_value" ]; then
    if [ "$required" = "1" ]; then
      value="$(prompt_secret "$key (saved/env found; press Enter to use it, paste new to override): ")"
      printf '%s' "${value:-$default_value}"
    else
      value="$(prompt_secret "$key (saved/env found; press Enter to use it, paste new to override, type skip to disable): ")"
      case "${value,,}" in
        skip|none|no|disable|disabled)
          printf ''
          ;;
        *)
          printf '%s' "${value:-$default_value}"
          ;;
      esac
    fi
    return
  fi

  if [ "$required" = "1" ]; then
    while true; do
      value="$(prompt_secret "$key (no saved/env key found; paste key): ")"
      if [ -n "$value" ]; then
        printf '%s' "$value"
        return
      fi
      warn "$key is required; paste it once and it will be remembered for future runs"
    done
  else
    prompt_secret "$key (press Enter to skip): "
  fi
}

prompt_key_value_labeled() {
  local label="$1"
  local default_value="$2"
  local required="${3:-1}"
  local value

  if [ -n "$default_value" ]; then
    if [ "$required" = "1" ]; then
      value="$(prompt_secret "$label (saved/env found; press Enter to use it, paste new to override): ")"
      printf '%s' "${value:-$default_value}"
    else
      value="$(prompt_secret "$label (saved/env found; press Enter to use it, paste new to override, type skip to disable): ")"
      case "${value,,}" in
        skip|none|no|disable|disabled) printf '' ;;
        *) printf '%s' "${value:-$default_value}" ;;
      esac
    fi
    return
  fi

  if [ "$required" = "1" ]; then
    while true; do
      value="$(prompt_secret "$label (no saved/env key found; paste key): ")"
      if [ -n "$value" ]; then
        printf '%s' "$value"
        return
      fi
      warn "$label is required; paste it once and it will be remembered for future runs"
    done
  else
    prompt_secret "$label (press Enter to skip): "
  fi
}

need_command() {
  local cmd="$1"
  local hint="$2"
  if ! command_exists "$cmd"; then
    die "$cmd is required. $hint"
  fi
}

need_sudo() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    return 0
  fi
  command_exists sudo || die "sudo is required to install missing system dependencies. Install sudo, run as root, or preinstall dependencies."
  sudo -v
  if [ -z "$SUDO_KEEPALIVE_PID" ]; then
    while true; do
      sudo -n true >/dev/null 2>&1 || exit 0
      sleep 60
    done &
    SUDO_KEEPALIVE_PID="$!"
  fi
}

run_sudo() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  else
    need_sudo
    sudo "$@"
  fi
}

apt_install() {
  command_exists apt-get || die "automatic dependency installation currently supports Ubuntu/Debian VMs with apt-get. Preinstall dependencies and rerun."
  need_sudo
  run_sudo apt-get update
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ensure_base_packages() {
  local missing=0
  local cmd
  for cmd in curl git gpg grep awk sed tee tar gzip ps nohup seq tail shasum python3; do
    if ! command_exists "$cmd"; then
      missing=1
      break
    fi
  done
  if ! command_exists ss && ! command_exists lsof; then
    missing=1
  fi

  if [ "$missing" = "0" ]; then
    return
  fi

  log "installing base system packages"
  apt_install \
    ca-certificates \
    curl \
    git \
    gnupg \
    lsb-release \
    procps \
    iproute2 \
    lsof \
    coreutils \
    grep \
    gawk \
    sed \
    tar \
    gzip \
    xz-utils \
    build-essential \
    perl \
    libdigest-sha-perl \
    python3
}

node_version_ok() {
  command_exists node || return 1
  local version major minor
  version="$(node -v 2>/dev/null | sed 's/^v//')"
  major="${version%%.*}"
  version="${version#*.}"
  minor="${version%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] || return 1
  [[ "$minor" =~ ^[0-9]+$ ]] || return 1
  if [ "$major" -gt 22 ]; then
    return 0
  fi
  [ "$major" -eq 22 ] && [ "$minor" -ge 16 ]
}

install_nodejs() {
  if node_version_ok && command_exists npm; then
    return
  fi

  log "installing Node.js 22 and npm"
  apt_install ca-certificates curl gnupg
  local setup_script="$DEMO_DIR/nodesource_setup_22.sh"
  curl -fsSL https://deb.nodesource.com/setup_22.x -o "$setup_script"
  run_sudo bash "$setup_script"
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

  node_version_ok || die "Node.js 22.16 or newer is required after installation"
  command_exists npm || die "npm was not found after installing Node.js"
}

docker_repo_id() {
  local id=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"
  fi
  case "$id" in
    ubuntu|debian) printf '%s' "$id" ;;
    *) die "automatic Docker installation supports Ubuntu/Debian. Preinstall Docker and rerun." ;;
  esac
}

docker_repo_codename() {
  local codename=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-}"
  fi
  [ -n "$codename" ] || codename="$(lsb_release -cs 2>/dev/null || true)"
  [ -n "$codename" ] || die "could not determine OS codename for Docker apt repo"
  printf '%s' "$codename"
}

install_docker() {
  if command_exists docker; then
    return
  fi

  log "installing Docker Engine"
  apt_install ca-certificates curl gnupg lsb-release
  local id codename arch keyring source_file
  id="$(docker_repo_id)"
  codename="$(docker_repo_codename)"
  arch="$(dpkg --print-architecture)"
  keyring="/etc/apt/keyrings/docker.asc"
  source_file="/etc/apt/sources.list.d/docker.list"

  run_sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$id/gpg" -o "$DEMO_DIR/docker.asc"
  run_sudo install -m 0644 "$DEMO_DIR/docker.asc" "$keyring"
  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' "$arch" "$keyring" "$id" "$codename" \
    | run_sudo tee "$source_file" >/dev/null
  run_sudo apt-get update
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
}

start_docker_service() {
  if command_exists systemctl; then
    run_sudo systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  if ! docker info >/dev/null 2>&1 && command_exists service; then
    run_sudo service docker start >/dev/null 2>&1 || true
  fi
}

install_docker_wrapper() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    return 1
  fi
  local docker_path
  docker_path="$(command -v docker 2>/dev/null || true)"
  [ -n "$docker_path" ] || return 1
  case "$docker_path" in
    "$BOOTSTRAP_BIN_DIR"/*) docker_path="/usr/bin/docker" ;;
  esac
  if ! run_sudo "$docker_path" info >/dev/null 2>&1; then
    return 1
  fi

  log "Docker requires sudo in this shell; installing a temporary docker wrapper for this run"
  mkdir -p "$BOOTSTRAP_BIN_DIR"
  {
    printf '#!/usr/bin/env sh\n'
    printf 'exec sudo %s "$@"\n' "$docker_path"
  } > "$BOOTSTRAP_BIN_DIR/docker"
  chmod 755 "$BOOTSTRAP_BIN_DIR/docker"
  bootstrap_path
}

ensure_docker_access() {
  if docker info >/dev/null 2>&1; then
    return
  fi

  start_docker_service
  if docker info >/dev/null 2>&1; then
    return
  fi

  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    local docker_user
    docker_user="${SUDO_USER:-${USER:-$(id -un)}}"
    run_sudo usermod -aG docker "$docker_user" >/dev/null 2>&1 || true
    install_docker_wrapper || true
  fi

  docker info >/dev/null 2>&1 || die "Docker is installed but not reachable. Log out/in for docker group membership, or rerun with a user that can access Docker."
}

install_cloudflared() {
  if command_exists cloudflared; then
    return
  fi

  log "installing cloudflared"
  local arch asset tmp
  case "$(uname -m)" in
    x86_64|amd64) asset="cloudflared-linux-amd64" ;;
    aarch64|arm64) asset="cloudflared-linux-arm64" ;;
    *) die "unsupported architecture for cloudflared: $(uname -m)" ;;
  esac
  tmp="$DEMO_DIR/$asset"
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/$asset" -o "$tmp"
  chmod 755 "$tmp"
  run_sudo install -m 0755 "$tmp" /usr/local/bin/cloudflared
  bootstrap_path
}

resolve_nemoclaw_ref() {
  if [ -n "$NEMOCLAW_INSTALL_REF" ]; then
    printf '%s' "$NEMOCLAW_INSTALL_REF"
    return
  fi
  local ref
  ref="$(git ls-remote --tags --refs https://github.com/NVIDIA/NemoClaw.git 'refs/tags/v*' \
    | sed -E 's#.*refs/tags/(v[0-9][^[:space:]]*)#\1#' \
    | sort -V \
    | tail -1)"
  printf '%s' "${ref:-main}"
}

semver_gte() {
  local IFS=.
  local -a left right
  local i l r
  read -r -a left <<<"$1"
  read -r -a right <<<"$2"
  for i in 0 1 2; do
    l="${left[$i]:-0}"
    r="${right[$i]:-0}"
    if ((l > r)); then
      return 0
    fi
    if ((l < r)); then
      return 1
    fi
  done
  return 0
}

nemoclaw_available() {
  command_exists nemoclaw && nemoclaw --version >/dev/null 2>&1
}

openshell_supported() {
  command_exists openshell || return 1
  local version
  version="$(openshell --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  [ -n "$version" ] || return 1
  semver_gte "$version" "0.0.32" && semver_gte "0.0.36" "$version"
}

patch_nemoclaw_dockerfile_workspace_fix() {
  local source_dir="$1"
  local dockerfile="$source_dir/Dockerfile"
  [ -f "$dockerfile" ] || return 0

  python3 - "$dockerfile" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text()
state_dirs = "logs credentials sandbox agents extensions workspace skills hooks identity devices canvas cron memory telegram flows media plugin-runtime-deps"
replacement = f'''RUN for dir in {state_dirs}; do \\
        mkdir -p "/sandbox/.openclaw-data/$dir"; \\
        if [ -L "/sandbox/.openclaw/$dir" ]; then true; \\
        elif [ -e "/sandbox/.openclaw/$dir" ]; then \\
            cp -a "/sandbox/.openclaw/$dir/." "/sandbox/.openclaw-data/$dir/" 2>/dev/null || true; \\
            rm -rf "/sandbox/.openclaw/$dir"; \\
            ln -s "/sandbox/.openclaw-data/$dir" "/sandbox/.openclaw/$dir"; \\
        else \\
            ln -s "/sandbox/.openclaw-data/$dir" "/sandbox/.openclaw/$dir"; \\
        fi; \\
        chown -R sandbox:sandbox "/sandbox/.openclaw-data/$dir"; \\
    done \\
    && if [ -e /sandbox/.openclaw-data/workspace/media ] && [ ! -L /sandbox/.openclaw-data/workspace/media ]; then \\
        rm -rf /sandbox/.openclaw-data/workspace/media; \\
    fi \\
    && ln -sfn /sandbox/.openclaw-data/media /sandbox/.openclaw-data/workspace/media'''

pattern = re.compile(
    r'RUN mkdir -p /sandbox/\\.openclaw-data/logs \\\\\n'
    r'(?:.*?\n)+?'
    r'    && ln -sfn /sandbox/\\.openclaw-data/media /sandbox/\\.openclaw-data/workspace/media',
    re.MULTILINE,
)

if f"for dir in {state_dirs}; do" not in src:
    new, count = pattern.subn(replacement, src, count=1)
    if count:
        path.write_text(new)
        print(f"[nemoclaw-demo] patched NemoClaw Dockerfile full writable state-dir symlinks in {path}")
PY

  if ! grep -q 'for dir in logs credentials sandbox agents extensions workspace' "$dockerfile" \
      && grep -q '/sandbox/.openclaw-data/workspace/media' "$dockerfile" \
      && ! grep -q '^[[:space:]]*/sandbox/.openclaw-data/workspace \\$' "$dockerfile"; then
    log "patching NemoClaw Dockerfile workspace/media compatibility fix in $dockerfile"
    sed -i '\|/sandbox/.openclaw-data/sandbox \\|a\        /sandbox/.openclaw-data/workspace \\' "$dockerfile"
  fi
}

patch_nemoclaw_fast_clone_support() {
  local source_dir="$1"
  [ -d "$source_dir" ] || return 0

  python3 - "$source_dir" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

PATCHES = {
    root / "src" / "nemoclaw.ts": {
        "base": (
            '  const basePolicy = path.join(ROOT, "nemoclaw-blueprint", "policies", "openclaw-sandbox.yaml");\n'
            "  const openshellBin = getOpenshellBinary();\n\n"
        ),
        "base_new": (
            "  const fastClonePolicy = process.env.NEMOCLAW_FAST_CLONE_POLICY;\n"
            "  const basePolicy = fastClonePolicy\n"
            "    ? path.resolve(fastClonePolicy)\n"
            '    : path.join(ROOT, "nemoclaw-blueprint", "policies", "openclaw-sandbox.yaml");\n'
            '  const fastClonePolicyPresets = (process.env.NEMOCLAW_FAST_CLONE_POLICY_PRESETS || "")\n'
            '    .split(",")\n'
            "    .map((preset: string) => preset.trim())\n"
            "    .filter(Boolean);\n"
            "  const fastCloneEnvArgs: string[] = [];\n"
            "  const addFastCloneEnv = (name: string, value: string | undefined) => {\n"
            "    if (value) fastCloneEnvArgs.push(`${name}=${value}`);\n"
            "  };\n"
            "  const openshellBin = getOpenshellBinary();\n\n"
            "  if (fastClonePolicy && !fs.existsSync(basePolicy)) {\n"
            "    console.error(`  Fast clone policy file not found: ${basePolicy}`);\n"
            "    process.exit(1);\n"
            "  }\n"
            '  addFastCloneEnv("CHAT_UI_URL", process.env.NEMOCLAW_FAST_CLONE_CHAT_UI_URL);\n'
            '  addFastCloneEnv("NEMOCLAW_DASHBOARD_PORT", process.env.NEMOCLAW_FAST_CLONE_DASHBOARD_PORT);\n'
            '  addFastCloneEnv("NEMOCLAW_PROXY_HOST", process.env.NEMOCLAW_PROXY_HOST);\n'
            '  addFastCloneEnv("NEMOCLAW_PROXY_PORT", process.env.NEMOCLAW_PROXY_PORT);\n'
            '  addFastCloneEnv("BRAVE_API_KEY", process.env.BRAVE_API_KEY);\n\n'
        ),
        "cmd": (
            '    "--auto-providers",\n'
            '    "--",\n'
            '    "nemoclaw-start",\n'
        ),
        "cmd_new": (
            '    "--auto-providers",\n'
            '    "--",\n'
            '    "env",\n'
            "    ...fastCloneEnvArgs,\n"
            '    "nemoclaw-start",\n'
        ),
        "policy": "    policies: [],",
        "policy_new": "    policies: fastClonePolicyPresets,",
    },
    root / "dist" / "nemoclaw.js": {
        "base": (
            '    const basePolicy = path.join(ROOT, "nemoclaw-blueprint", "policies", "openclaw-sandbox.yaml");\n'
            "    const openshellBin = getOpenshellBinary();\n"
        ),
        "base_new": (
            "    const fastClonePolicy = process.env.NEMOCLAW_FAST_CLONE_POLICY;\n"
            "    const basePolicy = fastClonePolicy\n"
            "        ? path.resolve(fastClonePolicy)\n"
            '        : path.join(ROOT, "nemoclaw-blueprint", "policies", "openclaw-sandbox.yaml");\n'
            '    const fastClonePolicyPresets = (process.env.NEMOCLAW_FAST_CLONE_POLICY_PRESETS || "")\n'
            '        .split(",")\n'
            "        .map((preset) => preset.trim())\n"
            "        .filter(Boolean);\n"
            "    const fastCloneEnvArgs = [];\n"
            "    const addFastCloneEnv = (name, value) => {\n"
            "        if (value)\n"
            "            fastCloneEnvArgs.push(`${name}=${value}`);\n"
            "    };\n"
            "    const openshellBin = getOpenshellBinary();\n"
            "    if (fastClonePolicy && !fs.existsSync(basePolicy)) {\n"
            "        console.error(`  Fast clone policy file not found: ${basePolicy}`);\n"
            "        process.exit(1);\n"
            "    }\n"
            '    addFastCloneEnv("CHAT_UI_URL", process.env.NEMOCLAW_FAST_CLONE_CHAT_UI_URL);\n'
            '    addFastCloneEnv("NEMOCLAW_DASHBOARD_PORT", process.env.NEMOCLAW_FAST_CLONE_DASHBOARD_PORT);\n'
            '    addFastCloneEnv("NEMOCLAW_PROXY_HOST", process.env.NEMOCLAW_PROXY_HOST);\n'
            '    addFastCloneEnv("NEMOCLAW_PROXY_PORT", process.env.NEMOCLAW_PROXY_PORT);\n'
            '    addFastCloneEnv("BRAVE_API_KEY", process.env.BRAVE_API_KEY);\n'
        ),
        "cmd": (
            '        "--auto-providers",\n'
            '        "--",\n'
            '        "nemoclaw-start",\n'
        ),
        "cmd_new": (
            '        "--auto-providers",\n'
            '        "--",\n'
            '        "env",\n'
            "        ...fastCloneEnvArgs,\n"
            '        "nemoclaw-start",\n'
        ),
        "policy": "        policies: [],",
        "policy_new": "        policies: fastClonePolicyPresets,",
    },
}

for path, patch in PATCHES.items():
    if not path.exists():
        continue
    src = path.read_text()
    if "NEMOCLAW_FAST_CLONE_CHAT_UI_URL" in src:
        continue
    for key, replacement_key in (("base", "base_new"), ("cmd", "cmd_new"), ("policy", "policy_new")):
        old = patch[key]
        new = patch[replacement_key]
        if old not in src:
            raise SystemExit(f"Could not patch {path}: pattern '{key}' not found")
        src = src.replace(old, new, 1)
    path.write_text(src)
    print(f"[nemoclaw-demo] patched NemoClaw fast clone support in {path}")
PY
}

patch_nemoclaw_extra_provider_support() {
  local source_dir="$1"
  [ -d "$source_dir" ] || return 0

  python3 - "$source_dir" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

patches = [
    {
        "path": root / "src" / "lib" / "onboard.ts",
        "marker": "NEMOCLAW_EXTRA_PROVIDER_NAMES",
        "replacements": [
            (
                '  const messagingProviders = upsertMessagingProviders(messagingTokenDefs);\n'
                '  for (const p of messagingProviders) {\n'
                '    createArgs.push("--provider", p);\n'
                '  }\n\n'
                '  console.log(`  Creating sandbox',
                '  const messagingProviders = upsertMessagingProviders(messagingTokenDefs);\n'
                '  for (const p of messagingProviders) {\n'
                '    createArgs.push("--provider", p);\n'
                '  }\n'
                '  const extraProviderNames = (process.env.NEMOCLAW_EXTRA_PROVIDER_NAMES || "")\n'
                '    .split(",")\n'
                '    .map((name: string) => name.trim())\n'
                '    .filter(Boolean);\n'
                '  for (const p of extraProviderNames) {\n'
                '    createArgs.push("--provider", p);\n'
                '  }\n\n'
                '  console.log(`  Creating sandbox',
            ),
            (
                '  const sandboxEnv = buildSubprocessEnv();\n',
                '  const extraProviderCredentialEnv = Object.fromEntries(\n'
                '    (process.env.NEMOCLAW_EXTRA_PROVIDER_CREDENTIAL_ENVS || "")\n'
                '      .split(",")\n'
                '      .map((key: string) => key.trim())\n'
                '      .filter((key: string) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(key) && !!process.env[key])\n'
                '      .map((key: string) => [key, process.env[key] as string]),\n'
                '  );\n'
                '  const sandboxEnv = buildSubprocessEnv(extraProviderCredentialEnv);\n',
            ),
        ],
    },
    {
        "path": root / "dist" / "lib" / "onboard.js",
        "marker": "NEMOCLAW_EXTRA_PROVIDER_NAMES",
        "replacements": [
            (
                '    const messagingProviders = upsertMessagingProviders(messagingTokenDefs);\n'
                '    for (const p of messagingProviders) {\n'
                '        createArgs.push("--provider", p);\n'
                '    }\n'
                '    console.log(`  Creating sandbox',
                '    const messagingProviders = upsertMessagingProviders(messagingTokenDefs);\n'
                '    for (const p of messagingProviders) {\n'
                '        createArgs.push("--provider", p);\n'
                '    }\n'
                '    const extraProviderNames = (process.env.NEMOCLAW_EXTRA_PROVIDER_NAMES || "")\n'
                '        .split(",")\n'
                '        .map((name) => name.trim())\n'
                '        .filter(Boolean);\n'
                '    for (const p of extraProviderNames) {\n'
                '        createArgs.push("--provider", p);\n'
                '    }\n'
                '    console.log(`  Creating sandbox',
            ),
            (
                '    const sandboxEnv = buildSubprocessEnv();\n',
                '    const extraProviderCredentialEnv = Object.fromEntries((process.env.NEMOCLAW_EXTRA_PROVIDER_CREDENTIAL_ENVS || "")\n'
                '        .split(",")\n'
                '        .map((key) => key.trim())\n'
                '        .filter((key) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(key) && !!process.env[key])\n'
                '        .map((key) => [key, process.env[key]]));\n'
                '    const sandboxEnv = buildSubprocessEnv(extraProviderCredentialEnv);\n',
            ),
        ],
    },
    {
        "path": root / "src" / "nemoclaw.ts",
        "marker": "NEMOCLAW_FAST_CLONE_EXTRA_PROVIDER_NAMES",
        "replacements": [
            (
                '  const fromImage = resolveSrcPodImage(srcName);\n',
                '  const fastCloneExtraProviderNames = (\n'
                '    process.env.NEMOCLAW_FAST_CLONE_EXTRA_PROVIDER_NAMES ||\n'
                '    process.env.NEMOCLAW_EXTRA_PROVIDER_NAMES ||\n'
                '    ""\n'
                '  )\n'
                '    .split(",")\n'
                '    .map((name: string) => name.trim())\n'
                '    .filter(Boolean);\n'
                '  const fastCloneProviderArgs = fastCloneExtraProviderNames.flatMap((name: string) => [\n'
                '    "--provider",\n'
                '    name,\n'
                '  ]);\n\n'
                '  const fromImage = resolveSrcPodImage(srcName);\n',
            ),
            (
                '    "--policy",\n'
                '    basePolicy,\n'
                '    "--auto-providers",\n',
                '    "--policy",\n'
                '    basePolicy,\n'
                '    ...fastCloneProviderArgs,\n'
                '    "--auto-providers",\n',
            ),
        ],
    },
    {
        "path": root / "dist" / "nemoclaw.js",
        "marker": "NEMOCLAW_FAST_CLONE_EXTRA_PROVIDER_NAMES",
        "replacements": [
            (
                '    const fromImage = resolveSrcPodImage(srcName);\n',
                '    const fastCloneExtraProviderNames = (process.env.NEMOCLAW_FAST_CLONE_EXTRA_PROVIDER_NAMES ||\n'
                '        process.env.NEMOCLAW_EXTRA_PROVIDER_NAMES ||\n'
                '        "")\n'
                '        .split(",")\n'
                '        .map((name) => name.trim())\n'
                '        .filter(Boolean);\n'
                '    const fastCloneProviderArgs = fastCloneExtraProviderNames.flatMap((name) => [\n'
                '        "--provider",\n'
                '        name,\n'
                '    ]);\n'
                '    const fromImage = resolveSrcPodImage(srcName);\n',
            ),
            (
                '        "--policy",\n'
                '        basePolicy,\n'
                '        "--auto-providers",\n',
                '        "--policy",\n'
                '        basePolicy,\n'
                '        ...fastCloneProviderArgs,\n'
                '        "--auto-providers",\n',
            ),
        ],
    },
]

for patch in patches:
    path = patch["path"]
    if not path.exists():
        continue
    src = path.read_text()
    if patch["marker"] in src:
        continue
    for old, new in patch["replacements"]:
        if old not in src:
            raise SystemExit(f"Could not patch {path}: extra-provider pattern not found")
        src = src.replace(old, new, 1)
    path.write_text(src)
    print(f"[nemoclaw-demo] patched NemoClaw extra provider support in {path}")
PY
}

patch_nemoclaw_nvidia_inference_endpoint() {
  local source_dir="$1"
  [ -d "$source_dir" ] || return 0

  python3 - "$source_dir" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
files = [
    root / "src" / "lib" / "onboard-providers.ts",
    root / "dist" / "lib" / "onboard-providers.js",
]

for path in files:
    if not path.exists():
        continue
    src = path.read_text()
    changed = False

    old_endpoint = 'const BUILD_ENDPOINT_URL = "https://integrate.api.nvidia.com/v1";'
    new_endpoint = (
        'const BUILD_ENDPOINT_URL = process.env.NEMOCLAW_NVIDIA_BASE_URL || '
        '"https://inference-api.nvidia.com/v1";'
    )
    if old_endpoint in src:
        src = src.replace(old_endpoint, new_endpoint, 1)
        changed = True

    old_ts = (
        '  if (baseUrl && type === "openai") {\n'
        '    args.push("--config", `OPENAI_BASE_URL=${baseUrl}`);\n'
        '  } else if (baseUrl && type === "anthropic") {\n'
        '    args.push("--config", `ANTHROPIC_BASE_URL=${baseUrl}`);\n'
        '  }\n'
    )
    new_ts = (
        '  if (baseUrl && type === "openai") {\n'
        '    args.push("--config", `OPENAI_BASE_URL=${baseUrl}`);\n'
        '  } else if (baseUrl && type === "anthropic") {\n'
        '    args.push("--config", `ANTHROPIC_BASE_URL=${baseUrl}`);\n'
        '  } else if (baseUrl && type === "nvidia") {\n'
        '    args.push("--config", `NVIDIA_BASE_URL=${baseUrl}`);\n'
        '  }\n'
    )
    old_js = (
        '    if (baseUrl && type === "openai") {\n'
        '        args.push("--config", `OPENAI_BASE_URL=${baseUrl}`);\n'
        '    }\n'
        '    else if (baseUrl && type === "anthropic") {\n'
        '        args.push("--config", `ANTHROPIC_BASE_URL=${baseUrl}`);\n'
        '    }\n'
    )
    new_js = (
        '    if (baseUrl && type === "openai") {\n'
        '        args.push("--config", `OPENAI_BASE_URL=${baseUrl}`);\n'
        '    }\n'
        '    else if (baseUrl && type === "anthropic") {\n'
        '        args.push("--config", `ANTHROPIC_BASE_URL=${baseUrl}`);\n'
        '    }\n'
        '    else if (baseUrl && type === "nvidia") {\n'
        '        args.push("--config", `NVIDIA_BASE_URL=${baseUrl}`);\n'
        '    }\n'
    )
    if old_ts in src:
        src = src.replace(old_ts, new_ts, 1)
        changed = True
    elif old_js in src:
        src = src.replace(old_js, new_js, 1)
        changed = True

    if changed:
        path.write_text(src)
        print(f"[nemoclaw-demo] patched NemoClaw NVIDIA inference endpoint support in {path}")
PY
}

patch_nemoclaw_source_tree() {
  local source_dir="$1"
  patch_nemoclaw_dockerfile_workspace_fix "$source_dir"
  patch_nemoclaw_fast_clone_support "$source_dir"
  patch_nemoclaw_extra_provider_support "$source_dir"
  patch_nemoclaw_nvidia_inference_endpoint "$source_dir"
}

patch_installed_nemoclaw_sources() {
  patch_nemoclaw_source_tree "$NEMOCLAW_SOURCE_DIR"

  if command_exists npm; then
    npm list -g nemoclaw --parseable --depth=0 2>/dev/null \
      | while IFS= read -r source_dir; do
          patch_nemoclaw_source_tree "$source_dir"
        done
  fi

  if command_exists nemoclaw; then
    local cli real source_dir
    cli="$(command -v nemoclaw)"
    real="$(readlink -f "$cli" 2>/dev/null || printf '%s' "$cli")"
    source_dir="$(dirname "$(dirname "$real")")"
    patch_nemoclaw_source_tree "$source_dir"
  fi
}

install_nemoclaw_and_openshell() {
  if nemoclaw_available && openshell_supported; then
    patch_installed_nemoclaw_sources
    return
  fi

  install_nodejs
  local ref="$1"
  log "installing NemoClaw CLI from NVIDIA/NemoClaw@$ref"
  if [ ! -d "$NEMOCLAW_SOURCE_DIR/.git" ]; then
    rm -rf "$NEMOCLAW_SOURCE_DIR"
    mkdir -p "$(dirname "$NEMOCLAW_SOURCE_DIR")"
    git clone --depth 1 --branch "$ref" https://github.com/NVIDIA/NemoClaw.git "$NEMOCLAW_SOURCE_DIR"
  else
    git -C "$NEMOCLAW_SOURCE_DIR" fetch --depth 1 origin "$ref"
    git -C "$NEMOCLAW_SOURCE_DIR" checkout --detach FETCH_HEAD
  fi
  git -C "$NEMOCLAW_SOURCE_DIR" fetch --depth 1 origin 'refs/tags/v*:refs/tags/v*' >/dev/null 2>&1 || true
  patch_nemoclaw_source_tree "$NEMOCLAW_SOURCE_DIR"

  log "building NemoClaw CLI"
  (
    cd "$NEMOCLAW_SOURCE_DIR"
    export NEMOCLAW_INSTALLING=1
    npm install --ignore-scripts
    npm run --if-present build:cli
    cd nemoclaw
    npm install --ignore-scripts
    npm run build
  )

  mkdir -p "$HOME/.local/bin"
  ln -sf "$NEMOCLAW_SOURCE_DIR/bin/nemoclaw.js" "$HOME/.local/bin/nemoclaw"
  chmod 755 "$NEMOCLAW_SOURCE_DIR/bin/nemoclaw.js"
  bootstrap_path

  log "installing NemoClaw-pinned OpenShell CLI"
  NEMOCLAW_NON_INTERACTIVE=1 bash "$NEMOCLAW_SOURCE_DIR/scripts/install-openshell.sh"
  bootstrap_path
}

ensure_prereqs() {
  mkdir -p "$BOOTSTRAP_BIN_DIR" "$DEMO_DIR"
  clear_stale_bootstrap_wrappers
  bootstrap_path
  if [ "${NEMOCLAW_DEMO_INSTALL_DEPS:-1}" != "0" ]; then
    ensure_base_packages
    install_nodejs
    install_docker
    ensure_docker_access
    install_cloudflared
    install_nemoclaw_and_openshell "$(resolve_nemoclaw_ref)"
  fi

  bootstrap_path
  need_command curl "Install curl, then rerun this script."
  need_command grep "Install grep, then rerun this script."
  need_command awk "Install awk, then rerun this script."
  need_command sed "Install sed, then rerun this script."
  need_command tee "Install tee, then rerun this script."
  need_command docker "Install Docker, make sure your user can run docker, then rerun this script."
  need_command cloudflared "Install cloudflared, then rerun this script."
  need_command nemoclaw "Install NemoClaw, then rerun this script."
  need_command openshell "Install the NemoClaw-pinned OpenShell CLI, then rerun this script."

  patch_installed_nemoclaw_sources
  ensure_docker_access
}

prompt_clean_slate() {
  case "${NEMOCLAW_DEMO_CLEAN_SLATE:-Y}" in
    0|false|False|no|No)
      CLEAN_SLATE=0
      log "clean-slate cleanup disabled by NEMOCLAW_DEMO_CLEAN_SLATE=0"
      return
      ;;
    force|always)
      CLEAN_SLATE=1
      log "clean-slate cleanup forced by NEMOCLAW_DEMO_CLEAN_SLATE=${NEMOCLAW_DEMO_CLEAN_SLATE}"
      return
      ;;
  esac

  if demo_noninteractive; then
    CLEAN_SLATE=1
    log "clean-slate cleanup enabled by non-interactive mode"
    return
  fi

  if prompt_yes_no "Clean up existing NemoClaw sandboxes, OpenShell forwards, and Cloudflare demo tunnels first? This deletes existing sandbox workspace state." "Y"; then
    CLEAN_SLATE=1
  else
    CLEAN_SLATE=0
    warn "skipping clean-slate cleanup; existing sandboxes or forwards may share state or occupy ports"
  fi
}

normalize_provider() {
  local raw="${1,,}"
  case "$raw" in
    openai) printf 'openai' ;;
    nvidia|build|cloud) printf 'build' ;;
    anthropic) printf 'anthropic' ;;
    gemini|google) printf 'gemini' ;;
    custom|openai-compatible|compatible) printf 'custom' ;;
    anthropiccompatible|anthropic-compatible|compatible-anthropic) printf 'anthropicCompatible' ;;
    *) die "unsupported provider '$1'. Supported: openai, build, anthropic, gemini, custom, anthropicCompatible" ;;
  esac
}

normalize_base_url() {
  local value="$1"
  value="${value%/}"
  printf '%s' "$value"
}

configure_github_dashboard_repo() {
  local raw="$1"
  local parsed
  parsed="$(python3 - "$raw" 2>&1 <<'PY'
import re
import sys
from urllib.parse import urlparse

raw = sys.argv[1].strip()
if not raw:
    raise SystemExit("GitHub repo URL is required")

owner = repo = None

ssh_match = re.match(r"^git@github\.com:([^/]+)/(.+?)(?:\.git)?/?$", raw)
if ssh_match:
    owner, repo = ssh_match.groups()
else:
    if re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?/?$", raw):
        owner, repo = raw.rstrip("/").split("/", 1)
        repo = repo.removesuffix(".git")
    else:
        parsed = urlparse(raw)
        if parsed.scheme in ("http", "https", "ssh") and parsed.netloc in ("github.com", "www.github.com"):
            parts = [p for p in parsed.path.strip("/").split("/") if p]
            if len(parts) >= 2:
                owner, repo = parts[0], parts[1].removesuffix(".git")

if not owner or not repo:
    raise SystemExit("Use a GitHub repo link like https://github.com/<owner>/nemoclaw-demo")

if repo != "nemoclaw-demo":
    raise SystemExit(f"Expected repo name nemoclaw-demo, got {repo}")

for value, label in ((owner, "owner"), (repo, "repo")):
    if not re.match(r"^[A-Za-z0-9_.-]+$", value):
        raise SystemExit(f"Invalid GitHub {label}: {value}")

clone_url = f"https://github.com/{owner}/{repo}.git"
pages_url = f"https://{owner}.github.io/{repo}"
slug = f"{owner}/{repo}"
print("\t".join([clone_url, pages_url, slug]))
PY
)" || die "$parsed"

  IFS=$'\t' read -r GITHUB_DASHBOARD_REPO GITHUB_PAGES_BASE_URL GITHUB_REPO_SLUG <<< "$parsed"
}

dashboard_url_for_sandbox() {
  local sandbox="$1"
  if [ "$DASHBOARD_MODE" = "github-pages" ]; then
    printf '%s/%s/' "$(normalize_base_url "$GITHUB_PAGES_BASE_URL")" "$sandbox"
  else
    printf ''
  fi
}

credential_env_for_provider() {
  case "$1" in
    openai) printf 'OPENAI_API_KEY' ;;
    build) printf 'NVIDIA_API_KEY' ;;
    anthropic) printf 'ANTHROPIC_API_KEY' ;;
    gemini) printf 'GEMINI_API_KEY' ;;
    custom) printf 'COMPATIBLE_API_KEY' ;;
    anthropicCompatible) printf 'COMPATIBLE_ANTHROPIC_API_KEY' ;;
    *) die "no credential env mapping for provider '$1'" ;;
  esac
}

prompt_count() {
  local count
  while true; do
    count="$(prompt_default 'Number of executive sandboxes' "$DEFAULT_COUNT")"
    if valid_exec_count "$count"; then
      printf '%s' "$count"
      return
    fi
    warn "enter an integer from 1 to 50"
  done
}

valid_exec_count() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 50 ]
}

validate_max_tokens() {
  [[ "$DEFAULT_MAX_TOKENS" =~ ^[0-9]+$ ]] && [ "$DEFAULT_MAX_TOKENS" -ge 1024 ] || die "NEMOCLAW_MAX_TOKENS must be an integer >= 1024"
}

load_inputs_noninteractive() {
  validate_max_tokens
  EXEC_COUNT="$DEFAULT_COUNT"
  valid_exec_count "$EXEC_COUNT" || die "NEMOCLAW_DEMO_COUNT must be an integer from 1 to 50"

  PROVIDER="$(normalize_provider "$DEFAULT_PROVIDER")"
  MODEL="$DEFAULT_MODEL"
  CRED_ENV="$(credential_env_for_provider "$PROVIDER")"

  if [ "$PROVIDER" = "custom" ] || [ "$PROVIDER" = "anthropicCompatible" ]; then
    ENDPOINT_URL="${NEMOCLAW_ENDPOINT_URL:-}"
    if [ "$PROVIDER" = "custom" ] && [ -z "$ENDPOINT_URL" ]; then
      ENDPOINT_URL="$NVIDIA_BASE_URL"
    fi
    [ -n "$ENDPOINT_URL" ] || die "NEMOCLAW_ENDPOINT_URL is required for provider '$PROVIDER' in non-interactive mode"
  elif [ "$PROVIDER" = "build" ]; then
    ENDPOINT_URL="$NVIDIA_BASE_URL"
  else
    ENDPOINT_URL="${NEMOCLAW_ENDPOINT_URL:-}"
  fi

  LLM_API_KEY="$(default_llm_api_key)"
  [ -n "$LLM_API_KEY" ] || die "set NEMOCLAW_PROVIDER_KEY or $CRED_ENV for non-interactive mode"
  save_llm_api_key

  BRAVE_KEY="${BRAVE_API_KEY:-$(read_saved_secret BRAVE_API_KEY)}"
  if [ -n "$BRAVE_KEY" ]; then
    save_secret BRAVE_API_KEY "$BRAVE_KEY"
    export BRAVE_API_KEY="$BRAVE_KEY"
  fi

  GITHUB_REPO_INPUT="$(default_github_repo_input)"
  configure_github_dashboard_repo "$GITHUB_REPO_INPUT"
  remember_github_repo_input "$GITHUB_REPO_INPUT"

  GITHUB_TOKEN_VALUE="${GITHUB_TOKEN:-$(read_saved_secret GITHUB_TOKEN)}"
  [ -n "$GITHUB_TOKEN_VALUE" ] || die "set GITHUB_TOKEN for non-interactive GitHub Pages dashboard publishing"
  if [ -n "$GITHUB_TOKEN_VALUE" ]; then
    save_secret GITHUB_TOKEN "$GITHUB_TOKEN_VALUE"
    export GITHUB_TOKEN="$GITHUB_TOKEN_VALUE"
  fi

  log "using non-interactive inputs: count=$EXEC_COUNT provider=$PROVIDER model=$MODEL brave_search=$([ -n "$BRAVE_KEY" ] && printf enabled || printf disabled) dashboard=$DASHBOARD_MODE"
  log "using model max output tokens $DEFAULT_MAX_TOKENS"
}

prompt_inputs() {
  if demo_noninteractive; then
    load_inputs_noninteractive
    return
  fi

  validate_max_tokens
  EXEC_COUNT="$(prompt_count)"
  PROVIDER="custom"
  MODEL="$(prompt_default 'NVIDIA model endpoint' "$DEFAULT_MODEL")"
  CRED_ENV="$(credential_env_for_provider "$PROVIDER")"
  ENDPOINT_URL="$NVIDIA_BASE_URL"

  local existing_key
  existing_key="$(default_llm_api_key)"
  LLM_API_KEY="$(prompt_key_value_labeled 'NVIDIA inference API key' "$existing_key" 1)"
  [ -n "$LLM_API_KEY" ] || die "NVIDIA inference API key is required"
  save_llm_api_key

  local existing_brave
  existing_brave="${BRAVE_API_KEY:-$(read_saved_secret BRAVE_API_KEY)}"
  BRAVE_KEY="$(prompt_key_value BRAVE_API_KEY "$existing_brave" 0)"
  if [ -n "$BRAVE_KEY" ]; then
    save_secret BRAVE_API_KEY "$BRAVE_KEY"
    export BRAVE_API_KEY="$BRAVE_KEY"
  else
    delete_saved_secret BRAVE_API_KEY
    unset BRAVE_API_KEY || true
  fi

  GITHUB_REPO_INPUT="$(prompt_default 'GitHub dashboard repo URL' "$(default_github_repo_input)")"
  configure_github_dashboard_repo "$GITHUB_REPO_INPUT"
  remember_github_repo_input "$GITHUB_REPO_INPUT"

  local existing_github
  existing_github="${GITHUB_TOKEN:-$(read_saved_secret GITHUB_TOKEN)}"
  GITHUB_TOKEN_VALUE="$(prompt_key_value GITHUB_TOKEN "$existing_github" 1)"
  [ -n "$GITHUB_TOKEN_VALUE" ] || die "GITHUB_TOKEN is required for GitHub Pages dashboard publishing"
  save_secret GITHUB_TOKEN "$GITHUB_TOKEN_VALUE"
  export GITHUB_TOKEN="$GITHUB_TOKEN_VALUE"
  log "using NVIDIA inference endpoint $ENDPOINT_URL with model $MODEL"
  log "using model max output tokens $DEFAULT_MAX_TOKENS"
  log "using GitHub dashboard repo $GITHUB_REPO_SLUG (Pages: $GITHUB_PAGES_BASE_URL)"
}

stop_pid_file_tunnels() {
  if [ -f "$PID_FILE" ]; then
    while IFS= read -r pid; do
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1 || true
      fi
    done < "$PID_FILE"
    : > "$PID_FILE"
  fi
}

stop_pid_file_forwards() {
  if [ -f "$FORWARD_PID_FILE" ]; then
    while IFS= read -r pid; do
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1 || true
      fi
    done < "$FORWARD_PID_FILE"
    : > "$FORWARD_PID_FILE"
  fi
}

stop_cloudflared_quick_tunnels() {
  command -v ps >/dev/null 2>&1 || return 0
  ps -eo pid=,args= \
    | awk '/cloudflared/ && / tunnel / && /--url[= ]http:\/\/127[.]0[.]0[.]1:/ { print $1 }' \
    | while IFS= read -r pid; do
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1; then
          log "stopping existing Cloudflare quick tunnel pid $pid"
          kill "$pid" >/dev/null 2>&1 || true
        fi
      done
}

stop_foreground_forwards() {
  command -v ps >/dev/null 2>&1 || return 0
  ps -eo pid=,args= \
    | awk '
        /openshell/ && /forward start/ && /127[.]0[.]0[.]1:/ { print $1; next }
        /ssh / && /openshell ssh-proxy/ && /-L 127[.]0[.]0[.]1:/ { print $1; next }
      ' \
    | while IFS= read -r pid; do
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1; then
          log "stopping existing foreground OpenShell forward pid $pid"
          kill "$pid" >/dev/null 2>&1 || true
        fi
      done
}

stop_existing_forwards() {
  local forwards
  forwards="$(openshell forward list 2>/dev/null | awk 'NR > 1 && $3 ~ /^[0-9]+$/ { print $1, $3, $4 }' || true)"
  [ -n "$forwards" ] || return 0

  while read -r name port pid; do
        [ -n "$port" ] || continue
        log "stopping existing OpenShell forward $name on port $port"
        openshell forward stop "$port" "$name" >/dev/null 2>&1 \
          || openshell forward stop "$port" >/dev/null 2>&1 \
          || true
        if [[ "${pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1; then
          kill "$pid" >/dev/null 2>&1 || true
        fi
      done <<< "$forwards"
}

list_nemoclaw_sandboxes() {
  nemoclaw list 2>/dev/null \
    | awk '/^    [A-Za-z0-9_.-]+([[:space:]]+\*)?[[:space:]]*$/ { print $1 }' \
    || true
}

destroy_existing_nemoclaw_sandboxes() {
  local sandbox
  local sandboxes
  sandboxes="$(list_nemoclaw_sandboxes || true)"
  [ -n "$sandboxes" ] || return 0

  while IFS= read -r sandbox; do
        [ -n "$sandbox" ] || continue
        if use_template && ! refresh_template && [ "$sandbox" = "$TEMPLATE_SANDBOX" ]; then
          log "preserving reusable template sandbox $TEMPLATE_SANDBOX"
          continue
        fi
        log "destroying existing NemoClaw sandbox $sandbox"
        NEMOCLAW_NON_INTERACTIVE=1 nemoclaw "$sandbox" destroy --yes >/dev/null 2>&1 \
          || warn "could not destroy NemoClaw sandbox $sandbox; trying OpenShell cleanup next"
      done <<< "$sandboxes"
}

delete_remaining_openshell_sandboxes() {
  local sandboxes
  sandboxes="$(openshell sandbox list -g nemoclaw 2>/dev/null | awk 'NR > 1 { print $1 }' || true)"
  [ -n "$sandboxes" ] || return 0

  while IFS= read -r sandbox; do
        [ -n "$sandbox" ] || continue
        if use_template && ! refresh_template && [ "$sandbox" = "$TEMPLATE_SANDBOX" ]; then
          log "preserving reusable template sandbox $TEMPLATE_SANDBOX"
          continue
        fi
        log "deleting remaining OpenShell sandbox $sandbox"
        openshell sandbox delete -g nemoclaw "$sandbox" >/dev/null 2>&1 \
          || warn "could not delete remaining OpenShell sandbox $sandbox"
      done <<< "$sandboxes"
}

wait_for_deleted_executive_resources() {
  command_exists docker || return 0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'openshell-cluster-nemoclaw' || return 0

  local attempt remaining
  for attempt in $(seq 1 90); do
    remaining="$(
      {
        docker exec openshell-cluster-nemoclaw kubectl get sandbox -n openshell -o name 2>/dev/null || true
        docker exec openshell-cluster-nemoclaw kubectl get pods -n openshell -o name 2>/dev/null || true
        docker exec openshell-cluster-nemoclaw kubectl get pvc -n openshell -o name 2>/dev/null || true
      } | awk '
        /\/exec-[0-9][0-9]$/ { print; next }
        /\/workspace-exec-[0-9][0-9]$/ { print; next }
      ' | sort -u
    )"

    [ -z "$remaining" ] && return 0
    if [ "$attempt" = "1" ]; then
      log "waiting for old executive sandbox Kubernetes resources to finish deleting"
    fi
    sleep 2
  done

  warn "old executive sandbox Kubernetes resources still exist after cleanup"
  printf '%s\n' "$remaining" >&2
  die "timed out waiting for old executive sandbox resources to delete"
}

clean_existing_state() {
  [ "$CLEAN_SLATE" = "1" ] || return 0

  log "cleaning existing NemoClaw/OpenShell state"
  nemoclaw tunnel stop >/dev/null 2>&1 || true
  stop_pid_file_tunnels
  stop_pid_file_forwards
  stop_cloudflared_quick_tunnels
  stop_foreground_forwards
  stop_existing_forwards
  destroy_existing_nemoclaw_sandboxes
  delete_remaining_openshell_sandboxes
  stop_existing_forwards
  wait_for_deleted_executive_resources
}

used_forward_ports() {
  openshell forward list 2>/dev/null | awk 'NR > 1 && $3 ~ /^[0-9]+$/ { print $3 }' || true
}

host_port_is_listening() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
    return
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi
  return 1
}

port_is_used() {
  local needle="$1"
  local p
  for p in "${ASSIGNED_PORTS[@]:-}"; do
    [ "$p" = "$needle" ] && return 0
  done
  if printf '%s\n' "$EXISTING_PORTS" | grep -qx "$needle"; then
    return 0
  fi
  if host_port_is_listening "$needle"; then
    return 0
  fi
  return 1
}

allocate_port() {
  local result_var="$1"
  local candidate="$2"
  while port_is_used "$candidate"; do
    candidate="$((candidate + 1))"
  done
  ASSIGNED_PORTS+=("$candidate")
  printf -v "$result_var" '%s' "$candidate"
}

prepare_dirs() {
  mkdir -p "$TUNNEL_DIR" "$ONBOARD_LOG_DIR" "$BOOTSTRAP_BIN_DIR"
}

reset_demo_files() {
  rm -f "$TUNNEL_DIR"/exec-*.env "$TUNNEL_DIR"/*.log
  rm -f "$TUNNEL_DIR/last-cloudflare-start-at"
  : > "$PID_FILE"
  : > "$FORWARD_PID_FILE"
  : > "$LINKS_FILE"
}

wait_for_tunnel_rate_limit() {
  local state_file="$TUNNEL_DIR/last-cloudflare-start-at"
  local last now wait_for
  [[ "$TUNNEL_CREATE_DELAY" =~ ^[0-9]+$ ]] || TUNNEL_CREATE_DELAY=10
  [ "$TUNNEL_CREATE_DELAY" -gt 0 ] || return 0

  last="$(cat "$state_file" 2>/dev/null || printf '0')"
  now="$(date +%s)"
  if [[ "$last" =~ ^[0-9]+$ ]] && [ "$last" -gt 0 ]; then
    wait_for="$((last + TUNNEL_CREATE_DELAY - now))"
    if [ "$wait_for" -gt 0 ]; then
      warn "waiting ${wait_for}s before requesting the next Cloudflare quick tunnel"
      sleep "$wait_for"
    fi
  fi
  date +%s > "$state_file"
}

start_tunnel() {
  local name="$1"
  local port="$2"
  local log_file="$TUNNEL_DIR/$name.log"
  local metrics_port="$((20242 + port - BASE_PORT))"
  while host_port_is_listening "$metrics_port"; do
    metrics_port="$((metrics_port + 1))"
  done

  [[ "$TUNNEL_MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || TUNNEL_MAX_ATTEMPTS=5
  [ "$TUNNEL_MAX_ATTEMPTS" -gt 0 ] || TUNNEL_MAX_ATTEMPTS=5

  local attempt backoff pid url
  backoff=10
  for attempt in $(seq 1 "$TUNNEL_MAX_ATTEMPTS"); do
    wait_for_tunnel_rate_limit
    rm -f "$log_file"
    nohup cloudflared tunnel --metrics "127.0.0.1:$metrics_port" --url "http://127.0.0.1:$port" > "$log_file" 2>&1 &
    pid="$!"
    printf '%s\n' "$pid" >> "$PID_FILE"

    url=""
    for _ in $(seq 1 45); do
      url="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$log_file" | tail -1 || true)"
      if [ -n "$url" ]; then
        printf '%s' "$url"
        return
      fi
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    kill "$pid" >/dev/null 2>&1 || true
    if [ "$attempt" -lt "$TUNNEL_MAX_ATTEMPTS" ]; then
      if grep -Eq '429 Too Many Requests|error code: 1015|Too Many Requests' "$log_file" 2>/dev/null; then
        warn "Cloudflare rate-limited quick tunnel $name on attempt $attempt; retrying in ${backoff}s"
      else
        warn "Cloudflare did not return a quick tunnel URL for $name on attempt $attempt; retrying in ${backoff}s"
      fi
      sleep "$backoff"
      backoff="$((backoff * 2))"
    fi
  done

  tail -80 "$log_file" >&2 || true
  die "Cloudflare did not return a quick tunnel URL for $name after $TUNNEL_MAX_ATTEMPTS attempt(s)"
}

patch_sandbox_config() {
  local sandbox="$1"
  local origin="$2"
  local port="$3"

  docker exec -i openshell-cluster-nemoclaw kubectl exec -i -n openshell "$sandbox" -- /bin/sh -s -- "$origin" "$port" "$DEFAULT_MAX_TOKENS" <<'REMOTE'
set -eu
origin="$1"
port="$2"
max_tokens="$3"
python3 - "$origin" "$port" "$max_tokens" <<'PY'
import hashlib
import json
import os
import sys

origin = sys.argv[1]
port = sys.argv[2]
max_tokens = int(sys.argv[3])
config_path = "/sandbox/.openclaw/openclaw.json"
hash_path = "/sandbox/.openclaw/.config-hash"

os.chmod(config_path, 0o644)
os.chmod(hash_path, 0o644)
with open(config_path, "r", encoding="utf-8") as f:
    config = json.load(f)

gateway = config.setdefault("gateway", {})
gateway.setdefault("auth", {})
gateway.setdefault("controlUi", {})["allowedOrigins"] = [
    origin,
    f"http://127.0.0.1:{port}",
    f"http://localhost:{port}",
]

providers = config.setdefault("models", {}).setdefault("providers", {})
if "openai" in providers:
    providers["openai"]["api"] = "openai-completions"

for provider in providers.values():
    for model in provider.get("models", []):
        model["maxTokens"] = max_tokens

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
with open(config_path, "rb") as f:
    digest = hashlib.sha256(f.read()).hexdigest()
with open(hash_path, "w", encoding="utf-8") as f:
    f.write(f"{digest}  {config_path}\n")
os.chmod(config_path, 0o444)
os.chmod(hash_path, 0o444)
PY
REMOTE
}

restart_gateway() {
  local sandbox="$1"
  docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$sandbox" -- /bin/sh -lc 'kill -USR1 "$(pidof openclaw-gateway)"' >/dev/null 2>&1 || true
}

repair_openclaw_state_symlinks() {
  local sandbox="$1"

  docker exec -i openshell-cluster-nemoclaw kubectl exec -i -n openshell "$sandbox" -- /bin/sh -s <<'REMOTE'
set -eu
config_dir=/sandbox/.openclaw
data_dir=/sandbox/.openclaw-data
for dir in agents extensions workspace skills hooks identity devices canvas cron memory telegram flows credentials logs sandbox media plugin-runtime-deps; do
  data_path="$data_dir/$dir"
  link_path="$config_dir/$dir"

  mkdir -p "$data_path"
  chattr -i "$config_dir" "$link_path" 2>/dev/null || true

  if [ -L "$link_path" ]; then
    chown -R sandbox:sandbox "$data_path" 2>/dev/null || true
    continue
  fi

  if [ -e "$link_path" ]; then
    cp -a "$link_path/." "$data_path/" 2>/dev/null || true
    rm -rf "$link_path"
  fi
  ln -s "$data_path" "$link_path"
  chown -R sandbox:sandbox "$data_path" 2>/dev/null || true
done

if [ -e "$data_dir/workspace/media" ] && [ ! -L "$data_dir/workspace/media" ]; then
  rm -rf "$data_dir/workspace/media"
fi
ln -sfn "$data_dir/media" "$data_dir/workspace/media"
REMOTE
}

create_base_snapshot() {
  local sandbox="$1"
  local snapshot_name="$2"
  local log_file="$ONBOARD_LOG_DIR/${sandbox}-snapshot.log"

  log "snapshotting $sandbox for fast clone creation"
  sandbox_is_live "$sandbox" || die "cannot snapshot $sandbox because it is not running; see $ONBOARD_LOG_DIR/${sandbox}.log"
  repair_openclaw_state_symlinks "$sandbox"
  nemoclaw "$sandbox" snapshot create --name "$snapshot_name" 2>&1 | tee "$log_file"
  snapshot_exists "$sandbox" "$snapshot_name" || die "snapshot '$snapshot_name' was not created for $sandbox; see $log_file"
}

policy_presets_for_tier() {
  if [ -n "${NEMOCLAW_DEMO_FAST_CLONE_POLICY_PRESETS:-}" ]; then
    printf '%s' "$NEMOCLAW_DEMO_FAST_CLONE_POLICY_PRESETS"
    return
  fi

  case "$POLICY_TIER" in
    restricted) printf '' ;;
    balanced) printf 'npm,pypi,huggingface,brew,brave' ;;
    open) printf 'npm,pypi,huggingface,brew,brave,slack,discord,telegram,jira,outlook' ;;
    *)
      die "cannot infer fast-clone policy presets for NEMOCLAW_POLICY_TIER='$POLICY_TIER'; set NEMOCLAW_DEMO_FAST_CLONE_POLICY_PRESETS"
      ;;
  esac
}

resolve_nemoclaw_root() {
  local bin real root candidate npm_root npm_prefix policy_path

  for candidate in \
    "$NEMOCLAW_SOURCE_DIR" \
    "$HOME/NemoClaw" \
    "$HOME/nemoclaw"; do
    [ -n "$candidate" ] || continue
    candidate="$(readlink -f "$candidate" 2>/dev/null || printf '%s\n' "$candidate")"
    if [ -f "$candidate/nemoclaw-blueprint/policies/openclaw-sandbox.yaml" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  bin="$(command -v nemoclaw 2>/dev/null || true)"
  if [ -n "$bin" ]; then
    real="$(readlink -f "$bin" 2>/dev/null || printf '%s\n' "$bin")"
    root="$(cd "$(dirname "$real")/.." 2>/dev/null && pwd -P || true)"
    if [ -n "$root" ] && [ -f "$root/nemoclaw-blueprint/policies/openclaw-sandbox.yaml" ]; then
      printf '%s\n' "$root"
      return 0
    fi

    # ~/.local/bin/nemoclaw may be a wrapper that execs the real npm shim.
    candidate="$(sed -n 's/.*exec "\([^"]*\/bin\/nemoclaw\)".*/\1/p' "$bin" 2>/dev/null | head -n 1 || true)"
    if [ -n "$candidate" ]; then
      real="$(readlink -f "$candidate" 2>/dev/null || printf '%s\n' "$candidate")"
      root="$(cd "$(dirname "$real")/.." 2>/dev/null && pwd -P || true)"
      if [ -n "$root" ] && [ -f "$root/nemoclaw-blueprint/policies/openclaw-sandbox.yaml" ]; then
        printf '%s\n' "$root"
        return 0
      fi
    fi
  fi

  npm_root="$(npm root -g 2>/dev/null || true)"
  npm_prefix="$(npm prefix -g 2>/dev/null || true)"
  for candidate in \
    "${npm_root:+$npm_root/nemoclaw}" \
    "${npm_prefix:+$npm_prefix/lib/node_modules/nemoclaw}"; do
    [ -n "$candidate" ] || continue
    candidate="$(readlink -f "$candidate" 2>/dev/null || printf '%s\n' "$candidate")"
    if [ -f "$candidate/nemoclaw-blueprint/policies/openclaw-sandbox.yaml" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  policy_path="$(find "$HOME" -maxdepth 4 -path '*/nemoclaw-blueprint/policies/openclaw-sandbox.yaml' -print -quit 2>/dev/null || true)"
  if [ -n "$policy_path" ]; then
    root="${policy_path%/nemoclaw-blueprint/policies/openclaw-sandbox.yaml}"
    printf '%s\n' "$root"
    return 0
  fi

  return 1
}

append_preset_network_policy_entries() {
  local preset_file="$1"
  awk '
    /^network_policies:[[:space:]]*$/ { in_network_policies = 1; next }
    in_network_policies { print }
  ' "$preset_file"
}

prepare_fast_clone_policy() {
  local root base presets_csv preset preset_file

  if [ "$FAST_CLONE_POLICY_READY" = "1" ] && [ -s "$FAST_CLONE_POLICY_FILE" ]; then
    return
  fi

  root="$(resolve_nemoclaw_root)" || die "could not locate NemoClaw source tree for fast-clone policy generation"
  base="$root/nemoclaw-blueprint/policies/openclaw-sandbox.yaml"
  [ -f "$base" ] || die "base OpenClaw sandbox policy not found: $base"

  presets_csv="$(policy_presets_for_tier)"
  FAST_CLONE_POLICY_PRESETS="$presets_csv"

  cp "$base" "$FAST_CLONE_POLICY_FILE"
  if [ -n "$presets_csv" ]; then
    IFS=',' read -r -a presets <<< "$presets_csv"
    for preset in "${presets[@]}"; do
      preset="${preset//[[:space:]]/}"
      [ -n "$preset" ] || continue
      preset_file="$root/nemoclaw-blueprint/policies/presets/$preset.yaml"
      [ -f "$preset_file" ] || die "policy preset not found: $preset_file"
      printf '\n' >> "$FAST_CLONE_POLICY_FILE"
      append_preset_network_policy_entries "$preset_file" >> "$FAST_CLONE_POLICY_FILE"
    done
  fi
  chmod 600 "$FAST_CLONE_POLICY_FILE"
  FAST_CLONE_POLICY_READY=1
  log "prepared fast-clone policy with presets: ${FAST_CLONE_POLICY_PRESETS:-none}"
}

clone_sandbox_from_snapshot() {
  local source_sandbox="$1"
  local snapshot_name="$2"
  local target_sandbox="$3"
  local ui_port="$4"
  local log_file="$ONBOARD_LOG_DIR/${target_sandbox}-clone.log"

  prepare_fast_clone_policy
  log "creating $target_sandbox from $source_sandbox snapshot without rebuilding the image"
  env \
    NEMOCLAW_NON_INTERACTIVE=1 \
    NEMOCLAW_FAST_CLONE_POLICY="$FAST_CLONE_POLICY_FILE" \
    NEMOCLAW_FAST_CLONE_POLICY_PRESETS="$FAST_CLONE_POLICY_PRESETS" \
    NEMOCLAW_FAST_CLONE_CHAT_UI_URL="http://127.0.0.1:$ui_port" \
    NEMOCLAW_FAST_CLONE_DASHBOARD_PORT="$ui_port" \
    NEMOCLAW_FAST_CLONE_EXTRA_PROVIDER_NAMES="$GITHUB_PROVIDER_NAME" \
    GITHUB_TOKEN="$GITHUB_TOKEN_VALUE" \
    BRAVE_API_KEY="$BRAVE_KEY" \
    nemoclaw "$source_sandbox" snapshot restore "$snapshot_name" --to "$target_sandbox" 2>&1 | tee "$log_file"
}

sandbox_is_live() {
  local sandbox="$1"
  openshell sandbox list -g nemoclaw 2>/dev/null \
    | awk -v sandbox="$sandbox" 'NR > 1 && $1 == sandbox { found = 1 } END { exit found ? 0 : 1 }'
}

snapshot_exists() {
  local sandbox="$1"
  local snapshot_name="$2"
  nemoclaw "$sandbox" snapshot list 2>/dev/null \
    | awk -v name="$snapshot_name" '$2 == name { found = 1 } END { exit found ? 0 : 1 }'
}

template_signature() {
  printf 'provider=%s\n' "$PROVIDER"
  printf 'model=%s\n' "$MODEL"
  printf 'endpoint=%s\n' "$ENDPOINT_URL"
  printf 'policy_tier=%s\n' "$POLICY_TIER"
  printf 'max_tokens=%s\n' "$DEFAULT_MAX_TOKENS"
  printf 'template_sandbox=%s\n' "$TEMPLATE_SANDBOX"
  printf 'template_snapshot=%s\n' "$TEMPLATE_SNAPSHOT_NAME"
}

template_meta_matches() {
  [ -f "$TEMPLATE_META_FILE" ] || return 1
  [ "$(template_signature)" = "$(cat "$TEMPLATE_META_FILE")" ]
}

write_template_meta() {
  template_signature > "$TEMPLATE_META_FILE"
  chmod 600 "$TEMPLATE_META_FILE"
}

gateway_provider_settings() {
  case "$PROVIDER" in
    openai)
      GATEWAY_PROVIDER_NAME="openai-api"
      GATEWAY_PROVIDER_TYPE="openai"
      GATEWAY_PROVIDER_BASE_URL="https://api.openai.com/v1"
      ;;
    build)
      GATEWAY_PROVIDER_NAME="nvidia-prod"
      GATEWAY_PROVIDER_TYPE="nvidia"
      GATEWAY_PROVIDER_BASE_URL="$NVIDIA_BASE_URL"
      ;;
    anthropic)
      GATEWAY_PROVIDER_NAME="anthropic-prod"
      GATEWAY_PROVIDER_TYPE="anthropic"
      GATEWAY_PROVIDER_BASE_URL="https://api.anthropic.com"
      ;;
    gemini)
      GATEWAY_PROVIDER_NAME="gemini-api"
      GATEWAY_PROVIDER_TYPE="openai"
      GATEWAY_PROVIDER_BASE_URL="https://generativelanguage.googleapis.com/v1beta/openai/"
      ;;
    custom)
      GATEWAY_PROVIDER_NAME="compatible-endpoint"
      GATEWAY_PROVIDER_TYPE="openai"
      GATEWAY_PROVIDER_BASE_URL="$ENDPOINT_URL"
      ;;
    anthropicCompatible)
      GATEWAY_PROVIDER_NAME="compatible-anthropic-endpoint"
      GATEWAY_PROVIDER_TYPE="anthropic"
      GATEWAY_PROVIDER_BASE_URL="$ENDPOINT_URL"
      ;;
    *)
      die "unsupported provider '$PROVIDER'"
      ;;
  esac
}

configure_gateway_inference() {
  gateway_provider_settings

  local action
  local -a provider_args
  if openshell -g nemoclaw provider get "$GATEWAY_PROVIDER_NAME" >/dev/null 2>&1; then
    action="update"
    provider_args=(provider update "$GATEWAY_PROVIDER_NAME" --credential "$CRED_ENV")
  else
    action="create"
    provider_args=(provider create --name "$GATEWAY_PROVIDER_NAME" --type "$GATEWAY_PROVIDER_TYPE" --credential "$CRED_ENV")
  fi

  if [ -n "$GATEWAY_PROVIDER_BASE_URL" ]; then
    case "$GATEWAY_PROVIDER_TYPE" in
      openai) provider_args+=(--config "OPENAI_BASE_URL=$GATEWAY_PROVIDER_BASE_URL") ;;
      anthropic) provider_args+=(--config "ANTHROPIC_BASE_URL=$GATEWAY_PROVIDER_BASE_URL") ;;
      nvidia) provider_args+=(--config "NVIDIA_BASE_URL=$GATEWAY_PROVIDER_BASE_URL") ;;
    esac
  fi

  log "${action} gateway inference provider $GATEWAY_PROVIDER_NAME"
  env "$CRED_ENV=$LLM_API_KEY" openshell -g nemoclaw "${provider_args[@]}" >/dev/null
  openshell -g nemoclaw inference set --provider "$GATEWAY_PROVIDER_NAME" --model "$MODEL" --timeout 180 --no-verify >/dev/null
}

configure_github_provider() {
  [ "$DASHBOARD_MODE" = "github-pages" ] || return 0
  [ -n "$GITHUB_TOKEN_VALUE" ] || return 0

  local action
  local -a provider_args
  if openshell -g nemoclaw provider get "$GITHUB_PROVIDER_NAME" >/dev/null 2>&1; then
    action="update"
    provider_args=(provider update "$GITHUB_PROVIDER_NAME" --credential GITHUB_TOKEN)
  else
    action="create"
    provider_args=(provider create --name "$GITHUB_PROVIDER_NAME" --type github --credential GITHUB_TOKEN)
  fi

  log "${action} gateway GitHub provider $GITHUB_PROVIDER_NAME"
  env GITHUB_TOKEN="$GITHUB_TOKEN_VALUE" openshell -g nemoclaw "${provider_args[@]}" >/dev/null
}

destroy_template_sandbox() {
  log "refreshing reusable template sandbox $TEMPLATE_SANDBOX"
  NEMOCLAW_NON_INTERACTIVE=1 nemoclaw "$TEMPLATE_SANDBOX" destroy --yes >/dev/null 2>&1 || true
  openshell sandbox delete -g nemoclaw "$TEMPLATE_SANDBOX" >/dev/null 2>&1 || true
}

template_is_usable() {
  use_template || return 1
  refresh_template && return 1
  sandbox_is_live "$TEMPLATE_SANDBOX" || return 1
  snapshot_exists "$TEMPLATE_SANDBOX" "$TEMPLATE_SNAPSHOT_NAME" || return 1
  template_meta_matches || return 1
}

ensure_template_available() {
  use_template || return 1

  if template_is_usable; then
    log "reusing template sandbox $TEMPLATE_SANDBOX and snapshot $TEMPLATE_SNAPSHOT_NAME"
    configure_gateway_inference
    configure_github_provider
    return 0
  fi

  if refresh_template; then
    destroy_template_sandbox
  elif sandbox_is_live "$TEMPLATE_SANDBOX"; then
    if template_meta_matches || [ ! -f "$TEMPLATE_META_FILE" ]; then
      log "adopting existing template sandbox $TEMPLATE_SANDBOX"
      if ! snapshot_exists "$TEMPLATE_SANDBOX" "$TEMPLATE_SNAPSHOT_NAME"; then
        create_base_snapshot "$TEMPLATE_SANDBOX" "$TEMPLATE_SNAPSHOT_NAME"
      fi
      snapshot_exists "$TEMPLATE_SANDBOX" "$TEMPLATE_SNAPSHOT_NAME" || die "template snapshot '$TEMPLATE_SNAPSHOT_NAME' is missing after adopting $TEMPLATE_SANDBOX"
      write_template_meta
      configure_gateway_inference
      configure_github_provider
      return 0
    fi
    warn "template sandbox $TEMPLATE_SANDBOX exists but was created for different inputs; rebuilding it"
    destroy_template_sandbox
  fi

  local template_port template_url
  allocate_port template_port "$BASE_PORT"
  template_url="http://127.0.0.1:$template_port"

  log "building reusable template sandbox $TEMPLATE_SANDBOX once; future runs can clone from it"
  run_onboard "$TEMPLATE_SANDBOX" "$template_port" "$template_url"
  sandbox_is_live "$TEMPLATE_SANDBOX" || die "template sandbox $TEMPLATE_SANDBOX was not created; see $ONBOARD_LOG_DIR/${TEMPLATE_SANDBOX}.log"
  create_base_snapshot "$TEMPLATE_SANDBOX" "$TEMPLATE_SNAPSHOT_NAME"
  snapshot_exists "$TEMPLATE_SANDBOX" "$TEMPLATE_SNAPSHOT_NAME" || die "template snapshot '$TEMPLATE_SNAPSHOT_NAME' is missing after onboarding $TEMPLATE_SANDBOX"
  write_template_meta
  openshell forward stop "$template_port" "$TEMPLATE_SANDBOX" >/dev/null 2>&1 || true
  configure_gateway_inference
  configure_github_provider
  return 0
}

start_forward() {
  local sandbox="$1"
  local port="$2"
  local expect_http="${3:-0}"
  local log_file="$ONBOARD_LOG_DIR/${sandbox}-forward-${port}.log"
  local code pid

  if host_port_is_listening "$port"; then
    if [ "$expect_http" = "http" ]; then
      code="$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null || true)"
      case "$code" in
        2??|3??|4??)
          log "local forward for $sandbox on 127.0.0.1:$port is already serving HTTP"
          return
          ;;
      esac
    fi
  fi

  if openshell forward list -g nemoclaw 2>/dev/null \
      | awk -v sandbox="$sandbox" -v port="$port" 'NR > 1 && $1 == sandbox && $3 == port && $0 ~ /running/ { found = 1 } END { exit found ? 0 : 1 }'; then
    if [ "$expect_http" = "http" ]; then
      code="$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null || true)"
      case "$code" in
        2??|3??|4??)
          log "local forward for $sandbox on 127.0.0.1:$port is already running"
          return
          ;;
      esac
      warn "local forward for $sandbox on 127.0.0.1:$port is listed as running but did not answer HTTP; restarting it"
      openshell forward stop "$port" "$sandbox" >/dev/null 2>&1 || true
    else
      log "local forward for $sandbox on 127.0.0.1:$port is already running"
      return
    fi
  fi

  log "starting local forward for $sandbox on 127.0.0.1:$port"
  openshell forward stop "$port" "$sandbox" >/dev/null 2>&1 || true
  rm -f "$log_file"
  nohup setsid openshell -g nemoclaw forward start "127.0.0.1:$port" "$sandbox" > "$log_file" 2>&1 < /dev/null &
  pid="$!"
  printf '%s\n' "$pid" >> "$FORWARD_PID_FILE"
  for _ in $(seq 1 20); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      sed -n '1,120p' "$log_file" >&2 || true
      die "OpenShell forward for $sandbox on port $port exited during startup"
    fi
    if grep -q 'Forwarding port' "$log_file" 2>/dev/null; then
      break
    fi
    sleep 0.5
  done
  sed -n '1,80p' "$log_file"
}

update_registry_dashboard_port() {
  local sandbox="$1"
  local port="$2"

  python3 - "$sandbox" "$port" <<'PY'
import json
import os
import sys

sandbox = sys.argv[1]
port = int(sys.argv[2])
path = os.path.expanduser("~/.nemoclaw/sandboxes.json")

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    sys.exit(0)

entry = data.get("sandboxes", {}).get(sandbox)
if not isinstance(entry, dict):
    sys.exit(0)

entry["dashboardPort"] = port
tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
}

configure_dashboard_git_access() {
  local sandbox="$1"
  local dashboard_url="$2"
  [ "$DASHBOARD_MODE" = "github-pages" ] || return 0

  docker exec -i openshell-cluster-nemoclaw kubectl exec -i -n openshell "$sandbox" -- /bin/sh -s -- \
    "$sandbox" \
    "$dashboard_url" \
    "$GITHUB_DASHBOARD_REPO" \
    "$GITHUB_DASHBOARD_BRANCH" \
    "$GITHUB_DASHBOARD_PAGES_DIR" \
    "$GITHUB_DASHBOARD_AUTHOR_NAME" \
    "$GITHUB_DASHBOARD_AUTHOR_EMAIL" <<'REMOTE'
set -eu
sandbox="$1"
dashboard_url="$2"
repo_url="$3"
branch="$4"
pages_dir="$5"
author_name="$6"
author_email="$7"

demo_dir=/sandbox/.nemoclaw-demo
git_cred_dir=/sandbox/.nemoclaw
workspace=/sandbox/.openclaw/workspace
cred_file="$git_cred_dir/git-credentials"
mkdir -p "$demo_dir" "$git_cred_dir" "$workspace"

python3 - "$demo_dir/dashboard.env" \
  "$sandbox" \
  "$dashboard_url" \
  "$repo_url" \
  "$branch" \
  "$pages_dir" \
  "$author_name" \
  "$author_email" \
  "$workspace/production-risk-dashboard" \
  "$workspace/github-pages-dashboard" <<'PY'
import shlex
import sys

path = sys.argv[1]
keys = [
    "EXEC_SANDBOX",
    "DASHBOARD_URL",
    "DASHBOARD_REPO_URL",
    "DASHBOARD_REPO_BRANCH",
    "DASHBOARD_PAGES_DIR",
    "DASHBOARD_GIT_AUTHOR_NAME",
    "DASHBOARD_GIT_AUTHOR_EMAIL",
    "DASHBOARD_OUTPUT_DIR",
    "DASHBOARD_REPO_DIR",
]
with open(path, "w", encoding="utf-8") as f:
    for key, value in zip(keys, sys.argv[2:]):
        f.write(f"{key}={shlex.quote(value)}\n")
PY

rm -f "$workspace/DASHBOARD_INSTRUCTIONS.md"
python3 - "$workspace/AGENTS.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(0)

start = "<!-- NEMOCLAW_EXEC_DEMO_DASHBOARD_START -->"
end = "<!-- NEMOCLAW_EXEC_DEMO_DASHBOARD_END -->"
text = path.read_text(encoding="utf-8")
while start in text and end in text:
    before, rest = text.split(start, 1)
    _, after = rest.split(end, 1)
    text = before.rstrip() + "\n\n" + after.lstrip()
path.write_text(text.rstrip() + "\n", encoding="utf-8")
PY

rm -f "$workspace/publish_dashboard.sh" "$demo_dir/github-token" "$demo_dir/git-askpass.sh"
rm -f "$demo_dir/git-credentials" "$demo_dir/git-credentials.lock"

repo_host="$(printf '%s\n' "$repo_url" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://([^/]+)/.*#\1#')"
[ -n "$repo_host" ] || repo_host=github.com
printf 'https://x-access-token:openshell%%3Aresolve%%3Aenv%%3AGITHUB_TOKEN@%s\n' "$repo_host" > "$cred_file"
for gitconfig in /sandbox/.gitconfig /tmp/.gitconfig; do
  touch "$gitconfig"
  git config --file "$gitconfig" user.name "$author_name"
  git config --file "$gitconfig" user.email "$author_email"
  git config --file "$gitconfig" credential.helper "store --file $cred_file"
  git config --file "$gitconfig" credential.useHttpPath false
  git config --file "$gitconfig" --add safe.directory "$workspace/github-pages-dashboard" 2>/dev/null || true
done
chmod 700 "$demo_dir" "$git_cred_dir"
chmod 600 "$demo_dir/dashboard.env" /sandbox/.gitconfig /tmp/.gitconfig "$cred_file" 2>/dev/null || true
chown -R sandbox:sandbox "$demo_dir" 2>/dev/null || true
chown -R sandbox:sandbox "$git_cred_dir" 2>/dev/null || true
chown sandbox:sandbox /sandbox/.gitconfig /tmp/.gitconfig 2>/dev/null || true
REMOTE
}

configure_github_publish_policy() {
  local sandbox="$1"
  [ "$DASHBOARD_MODE" = "github-pages" ] || return 0

  log "configuring GitHub publishing policy for $sandbox"
  openshell policy update -g nemoclaw "$sandbox" --remove-endpoint github.com:443 --wait --timeout 90 >/dev/null 2>&1 || true
  openshell policy update -g nemoclaw "$sandbox" --remove-endpoint api.github.com:443 --wait --timeout 90 >/dev/null 2>&1 || true
  openshell policy update -g nemoclaw "$sandbox" \
    --add-endpoint github.com:443:full:rest:enforce \
    --binary /usr/bin/git \
    --binary /usr/lib/git-core/git-remote-http \
    --binary /usr/lib/git-core/git-remote-https \
    --binary /usr/bin/gh \
    --binary /usr/bin/curl \
    --rule-name github_publish \
    --wait --timeout 90 >/dev/null
  openshell policy update -g nemoclaw "$sandbox" \
    --add-endpoint api.github.com:443:full:rest:enforce \
    --binary /usr/bin/gh \
    --binary /usr/bin/curl \
    --rule-name github_api \
    --wait --timeout 90 >/dev/null
}

run_onboard() {
  local sandbox="$1"
  local port="$2"
  local url="$3"
  local log_file="$ONBOARD_LOG_DIR/${sandbox}.log"

  log "onboarding $sandbox on local port $port"
  env \
    NEMOCLAW_NON_INTERACTIVE=1 \
    NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
    NEMOCLAW_PROVIDER="$PROVIDER" \
    NEMOCLAW_MODEL="$MODEL" \
    NEMOCLAW_PROVIDER_KEY="$LLM_API_KEY" \
    "$CRED_ENV=$LLM_API_KEY" \
    BRAVE_API_KEY="$BRAVE_KEY" \
    NEMOCLAW_ENDPOINT_URL="$ENDPOINT_URL" \
    NEMOCLAW_NVIDIA_BASE_URL="$NVIDIA_BASE_URL" \
    NVIDIA_BASE_URL="$NVIDIA_BASE_URL" \
    NEMOCLAW_MAX_TOKENS="$DEFAULT_MAX_TOKENS" \
    NEMOCLAW_PREFERRED_API=openai-completions \
    NEMOCLAW_EXTRA_PROVIDER_NAMES="$GITHUB_PROVIDER_NAME" \
    NEMOCLAW_EXTRA_PROVIDER_CREDENTIAL_ENVS=GITHUB_TOKEN \
    GITHUB_TOKEN="$GITHUB_TOKEN_VALUE" \
    NEMOCLAW_POLICY_TIER="$POLICY_TIER" \
    CHAT_UI_URL="$url" \
    nemoclaw onboard --non-interactive --fresh --recreate-sandbox --name "$sandbox" --control-ui-port "$port" \
    2>&1 | tee "$log_file"
}

collect_link() {
  local sandbox="$1"
  local url="$2"
  local dashboard_url="$3"
  local token
  token="$(nemoclaw "$sandbox" gateway-token --quiet | sed -n '1p')"
  [ -n "$token" ] || die "could not retrieve gateway token for $sandbox"
  {
    printf '%s\n' "$sandbox"
    printf '  OpenClaw UI: %s/#token=%s\n' "$url" "$token"
    if [ -n "$dashboard_url" ]; then
      printf '  Dashboard:   %s\n' "$dashboard_url"
    fi
    printf '\n'
  } | tee -a "$LINKS_FILE"
}

main() {
  if ! demo_noninteractive; then
    require_tty
  fi
  prepare_dirs
  ensure_prereqs
  prompt_clean_slate
  clean_existing_state
  reset_demo_files
  prompt_inputs

  EXISTING_PORTS="$(used_forward_ports)"
  ASSIGNED_PORTS=()
  TEMPLATE_READY=0
  if ensure_template_available; then
    TEMPLATE_READY=1
  fi

  log "starting one Cloudflare OpenClaw tunnel per sandbox ($EXEC_COUNT total)"
  for n in $(seq 1 "$EXEC_COUNT"); do
    sandbox="$(printf 'exec-%02d' "$n")"
    allocate_port port "$BASE_PORT"

    url="$(start_tunnel "$sandbox-ui" "$port")"
    dashboard_url="$(dashboard_url_for_sandbox "$sandbox")"
    printf 'SANDBOX=%s\nPORT=%s\nCHAT_UI_URL=%s\nDASHBOARD_URL=%s\n' \
      "$sandbox" "$port" "$url" "$dashboard_url" > "$TUNNEL_DIR/$sandbox.env"
    log "$sandbox OpenClaw UI: $url -> 127.0.0.1:$port"
    if [ -n "$dashboard_url" ]; then
      log "$sandbox dashboard:   $dashboard_url -> GitHub Pages"
    fi
  done

  if [ "$TEMPLATE_READY" = "1" ]; then
    log "creating all executive sandboxes from reusable template $TEMPLATE_SANDBOX"
    for n in $(seq 1 "$EXEC_COUNT"); do
      env_file="$TUNNEL_DIR/$(printf 'exec-%02d' "$n").env"
      # shellcheck disable=SC1090
      . "$env_file"
      clone_sandbox_from_snapshot "$TEMPLATE_SANDBOX" "$TEMPLATE_SNAPSHOT_NAME" "$SANDBOX" "$PORT"
      start_forward "$SANDBOX" "$PORT" http
      update_registry_dashboard_port "$SANDBOX" "$PORT"
      repair_openclaw_state_symlinks "$SANDBOX"
      configure_dashboard_git_access "$SANDBOX" "$DASHBOARD_URL"
      configure_github_publish_policy "$SANDBOX"
      patch_sandbox_config "$SANDBOX" "$CHAT_UI_URL" "$PORT"
      restart_gateway "$SANDBOX"
    done
  else
    BASE_SANDBOX="exec-01"
    BASE_ENV_FILE="$TUNNEL_DIR/$BASE_SANDBOX.env"
    [ -f "$BASE_ENV_FILE" ] || die "missing base sandbox env file: $BASE_ENV_FILE"

    log "running non-interactive NemoClaw onboarding once for $BASE_SANDBOX"
    # shellcheck disable=SC1090
    . "$BASE_ENV_FILE"
    run_onboard "$SANDBOX" "$PORT" "$CHAT_UI_URL"
    start_forward "$SANDBOX" "$PORT" http
    repair_openclaw_state_symlinks "$SANDBOX"
    configure_dashboard_git_access "$SANDBOX" "$DASHBOARD_URL"
    configure_github_publish_policy "$SANDBOX"

    BASE_SNAPSHOT_NAME="${NEMOCLAW_DEMO_SNAPSHOT_NAME:-exec-demo-$(date -u +%Y%m%d%H%M%S)}"
    if [ "$EXEC_COUNT" -gt 1 ]; then
      create_base_snapshot "$BASE_SANDBOX" "$BASE_SNAPSHOT_NAME"
    fi

    patch_sandbox_config "$SANDBOX" "$CHAT_UI_URL" "$PORT"
    restart_gateway "$SANDBOX"

    if [ "$EXEC_COUNT" -gt 1 ]; then
      log "creating remaining sandboxes from the $BASE_SANDBOX image snapshot"
    fi
    for n in $(seq 2 "$EXEC_COUNT"); do
      env_file="$TUNNEL_DIR/$(printf 'exec-%02d' "$n").env"
      # shellcheck disable=SC1090
      . "$env_file"
      clone_sandbox_from_snapshot "$BASE_SANDBOX" "$BASE_SNAPSHOT_NAME" "$SANDBOX" "$PORT"
      start_forward "$SANDBOX" "$PORT" http
      update_registry_dashboard_port "$SANDBOX" "$PORT"
      repair_openclaw_state_symlinks "$SANDBOX"
      configure_dashboard_git_access "$SANDBOX" "$DASHBOARD_URL"
      configure_github_publish_policy "$SANDBOX"
      patch_sandbox_config "$SANDBOX" "$CHAT_UI_URL" "$PORT"
      restart_gateway "$SANDBOX"
    done
  fi

  sleep 8

  log "tokenized executive links"
  : > "$LINKS_FILE"
  for env_file in "$TUNNEL_DIR"/exec-*.env; do
    # shellcheck disable=SC1090
    . "$env_file"
    collect_link "$SANDBOX" "$CHAT_UI_URL" "$DASHBOARD_URL"
  done

  log "saved links to $LINKS_FILE"
  log "treat each OpenClaw UI URL like a password; give each executive exactly one OpenClaw link and its matching dashboard link"
}

main "$@"
