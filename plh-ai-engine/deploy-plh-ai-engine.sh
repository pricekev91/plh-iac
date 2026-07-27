#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# deploy-plh-ai-engine.sh
#
# One-and-done deploy for the PLH AI Engine LXC container.
#
# Stack:
#   - Lemonade Server (PPA on Ubuntu 24.04)
#     UI + API: host :13305 → container :13305
#     OpenAI-compatible endpoint on port 5000
#
# Container: prod/plh-ai-engine (Ubuntu 24.04, privileged, GPU passthrough)
# Models:    /srv/ai/models bind-mounted into container
# =============================================================================

# ----------------- Config -----------------
PROJECT="prod"
CT_NAME="plh-ai-engine"
IMAGE="ubuntu:24.04"

MODEL_DIR_HOST="/srv/ai/models"
MODEL_DIR_CT="/srv/ai/models"

# LXC device names
GPU_DEVICE_NAME="gpu0"
LEMONADE_PROXY_NAME="lemonade-proxy"
MODELS_DEVICE_NAME="models"

# Ports — Lemonade
LEMONADE_HOST_PORT="13305"

# Systemd services — PPA installs as lemond.service
LEMONADE_SERVICE_NAME="lemond"

# Paths
LEMONADE_HOME="/opt/lemonade"
LEMONADE_CONFIG_DIR="/etc/lemonade"
# ------------------------------------------

log()   { echo "[deploy] $*" >&2; }
info()  { echo "[info] $*" >&2; }
warn()  { echo "[warn] $*" >&2; }
fail()  { echo "ERROR: $*" >&2; exit 1; }

# =============================================================================
# Helpers
# =============================================================================

require() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

exec_in_ct() {
    lxc exec "$CT_NAME" --project "$PROJECT" -- bash -lc "$*"
}

exec_in_ct_root() {
    lxc exec "$CT_NAME" --project "$PROJECT" -- bash -c "$*"
}

device_exists() {
    local dev="$1"
    lxc config device list "$CT_NAME" --project "$PROJECT" 2>/dev/null | grep -Fxq "$dev"
}

# =============================================================================
# LXD Project
# =============================================================================

ensure_project() {
    if lxc project show "$PROJECT" >/dev/null 2>&1; then
        log "Project exists: $PROJECT"
    else
        log "Creating project: $PROJECT"
        lxc project create "$PROJECT"
    fi
}

# =============================================================================
# Container Lifecycle
# =============================================================================

ct_exists() {
    lxc info "$CT_NAME" --project "$PROJECT" >/dev/null 2>&1
}

ensure_container() {
    # Always-nuke: destroy existing container for a clean slate
    if ct_exists; then
        log "Removing existing container: $PROJECT/$CT_NAME"
        lxc stop "$CT_NAME" --project "$PROJECT" --force >/dev/null 2>&1 || true
        lxc delete --force "$CT_NAME" --project "$PROJECT"
    fi

    log "Launching container: $PROJECT/$CT_NAME from $IMAGE"
    lxc launch "$IMAGE" "$CT_NAME" --project "$PROJECT" --profile default

    # Set privileged mode (required for GPU passthrough in LXC)
    log "Setting security.privileged=true"
    lxc config set "$CT_NAME" security.privileged=true --project "$PROJECT"
}

# =============================================================================
# Device Configuration
# =============================================================================

ensure_gpu_device() {
    if device_exists "$GPU_DEVICE_NAME"; then
        log "GPU device already present: $GPU_DEVICE_NAME"
        return
    fi
    log "Attaching GPU device: $GPU_DEVICE_NAME"
    lxc config device add "$CT_NAME" "$GPU_DEVICE_NAME" gpu --project "$PROJECT"
}

ensure_model_mount() {
    if [[ ! -d "$MODEL_DIR_HOST" ]]; then
        fail "Host model directory does not exist: $MODEL_DIR_HOST"
    fi

    if device_exists "$MODELS_DEVICE_NAME"; then
        log "Model mount already present: $MODELS_DEVICE_NAME"
        return
    fi

    log "Mounting model directory: $MODEL_DIR_HOST -> $MODEL_DIR_CT"
    lxc config device add "$CT_NAME" "$MODELS_DEVICE_NAME" disk \
        source="$MODEL_DIR_HOST" path="$MODEL_DIR_CT" \
        --project "$PROJECT"
}

ensure_proxy_devices() {
    # Lemonade Web UI proxy: host :13305 → container :13305
    if ! device_exists "$LEMONADE_PROXY_NAME"; then
        log "Adding proxy: host :$LEMONADE_HOST_PORT → container :$LEMONADE_HOST_PORT"
        lxc config device add "$CT_NAME" "$LEMONADE_PROXY_NAME" proxy \
            listen="tcp:0.0.0.0:${LEMONADE_HOST_PORT}" \
            connect="tcp:127.0.0.1:${LEMONADE_HOST_PORT}" \
            --project "$PROJECT"
    else
        log "Proxy device already present: $LEMONADE_PROXY_NAME"
    fi
}

# =============================================================================
# Wait for container network
# =============================================================================

wait_for_network() {
    local max_wait=120 waited=0
    while (( waited < max_wait )); do
        if exec_in_ct_root "ping -c 1 -W 2 8.8.8.8" >/dev/null 2>&1; then
            log "Container network ready (${waited}s)"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    fail "Container network not ready after ${max_wait}s"
}

# =============================================================================
# Base system setup inside container
# =============================================================================

ensure_base_packages() {
    wait_for_network

    log "Installing base packages..."
    exec_in_ct_root 'DEBIAN_FRONTEND=noninteractive apt-get update'
    exec_in_ct_root 'DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        curl wget ca-certificates lsof software-properties-common'

    log "Base packages installed"
}

# =============================================================================
# Lemonade Server (PPA)
# =============================================================================

purge_container_nvidia_runtime_conflicts() {
    local pkgs
    pkgs="$(exec_in_ct_root "dpkg-query -W -f='\${Package}\n' 'nvidia-utils-*' 'libnvidia-compute-*' 'cuda-compat-*' 2>/dev/null | sort -u || true")"

    if [[ -z "$pkgs" ]]; then
        log "No conflicting NVIDIA runtime packages in container"
        return 0
    fi

    log "Purging conflicting NVIDIA runtime packages from container"
    exec_in_ct_root "DEBIAN_FRONTEND=noninteractive apt-get purge -y $pkgs || true"
    exec_in_ct_root "DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true"
}

install_lemonade_ppa() {
    if exec_in_ct_root "dpkg -l lemonade-server 2>/dev/null | grep -q '^ii'"; then
        log "lemonade-server already installed"
        return 0
    fi

    log "Adding lemonade-team PPA and installing lemonade-server"
    exec_in_ct_root 'sudo add-apt-repository -y ppa:lemonade-team/stable'
    exec_in_ct_root 'DEBIAN_FRONTEND=noninteractive apt-get update'
    exec_in_ct_root 'DEBIAN_FRONTEND=noninteractive apt-get install -y lemonade-server'

    log "lemonade-server installed"
}

configure_lemonade() {
    log "Configuring Lemonade (CUDA backend, model paths)"

    # Lemonade auto-detects CUDA from the bundled runtime.
    # Write config.json with the model directory so it picks up GGUFs.
    # Container root home is /root
    local config_dir="/root/.config/lemonade"
    local config_file="$config_dir/config.json"

    exec_in_ct_root "mkdir -p $config_dir"

    cat <<'CFGEOF' | lxc file push - --project "$PROJECT" "$CT_NAME$config_file"
{
  "models": {
    "path": "/srv/ai/models"
  },
  "llamacpp": {
    "backend": "cuda"
  }
}
CFGEOF

    log "Lemonade config written to $config_file"
}

# =============================================================================
# Systemd Service
# =============================================================================

ensure_lemonade_service() {
    log "Configuring Lemonade systemd service"

    # The PPA package installs its own systemd unit (lemonade-server.service).
    # Just enable and start it — it listens on 127.0.0.1:13305 by default.
    # LXD proxy maps that to the host.
    exec_in_ct_root "systemctl daemon-reload"
    exec_in_ct_root "systemctl enable $LEMONADE_SERVICE_NAME"
    log "Lemonade systemd service configured and enabled"
}

# =============================================================================
# Start services and verify
# =============================================================================

start_and_verify_services() {
    log "Starting Lemonade server service..."
    exec_in_ct_root "systemctl restart $LEMONADE_SERVICE_NAME" || \
    exec_in_ct_root "systemctl start $LEMONADE_SERVICE_NAME"

    log "Waiting for Lemonade to be ready..."
    local waited=0
    while (( waited < 120 )); do
        local resp
        resp="$(lxc exec "$CT_NAME" --project "$PROJECT" -- \
            curl -sf http://127.0.0.1:13305/live 2>/dev/null || true)"
        if [[ "$resp" == *"ok"* || -n "$resp" ]]; then
            log "Lemonade is healthy on :13305"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if (( waited >= 120 )); then
        warn "Lemonade health check did not respond after ${waited}s — checking service status"
        exec_in_ct_root "systemctl status $LEMONADE_SERVICE_NAME --no-pager" || true
        exec_in_ct_root "journalctl -u $LEMONADE_SERVICE_NAME --no-pager -n 30" || true
    fi

    # Check the API endpoint too
    local models_resp
    models_resp="$(lxc exec "$CT_NAME" --project "$PROJECT" -- \
        curl -sf http://127.0.0.1:13305/api/v1/models 2>/dev/null || echo 'FAILED')"
    if [[ "$models_resp" != "FAILED" ]]; then
        info "API endpoint responding on :13305"
    else
        warn "API endpoint not responding on :13305 yet (models may need downloading)"
    fi
}

# =============================================================================
# Final verification (host-side)
# =============================================================================

verify_endpoints() {
    log ""
    log "========================================="
    log "Verifying endpoints from host..."
    log "========================================="

    # Test Lemonade Web UI endpoint
    log "Testing Lemonade Web UI (host :$LEMONADE_HOST_PORT)..."
    local lemonade_resp
    lemonade_resp="$(curl -sf --max-time 10 http://127.0.0.1:$LEMONADE_HOST_PORT/live 2>/dev/null || echo 'FAILED')"
    if [[ "$lemonade_resp" != "FAILED" ]]; then
        info "✅ Lemonade Web UI healthy at http://127.0.0.1:$LEMONADE_HOST_PORT"
    else
        warn "⚠️  Lemonade Web UI did not respond on http://127.0.0.1:$LEMONADE_HOST_PORT"
    fi

    # Show container status
    log ""
    lxc list --project "$PROJECT"
    log ""

    # Show device config
    log "Container devices:"
    lxc config device list "$CT_NAME" --project "$PROJECT"
    log ""

    # Show running services inside container
    log "Services inside container:"
    exec_in_ct_root "systemctl is-active $LEMONADE_SERVICE_NAME" || true
    log ""

    log "========================================="
    log "Deploy complete!"
    log "========================================="
    log "  Lemonade Web UI:  http://127.0.0.1:$LEMONADE_HOST_PORT"
    log "  API:              http://127.0.0.1:$LEMONADE_HOST_PORT/api/v1"
    log "  OpenAI compat:    curl -H \"Content-Type: application/json\" -d '{\"model\":\"gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}' http://127.0.0.1:$LEMONADE_HOST_PORT/v1/chat/completions"
    log ""
    log "  Pull a model:     lemonade pull Gemma-4-E2B-it-GGUF"
    log "  List models:      lemonade list"
    log "  Check backends:   lemonade backends"
    log ""
    log "  Stop container:   lxc stop $CT_NAME --project $PROJECT"
    log "  Start container:  lxc start $CT_NAME --project $PROJECT"
    log "========================================="
}

# =============================================================================
# Main
# =============================================================================

main() {
    require lxc

    # --- LXD setup ---
    ensure_project
    ensure_container
    ensure_gpu_device
    ensure_model_mount
    ensure_proxy_devices

    # --- Wait for container boot ---
    log "Waiting for container to boot..."
    sleep 5
    wait_for_network

    # --- Purge stale NVIDIA packages (cloud-init may have installed them) ---
    purge_container_nvidia_runtime_conflicts

    # --- Base system ---
    ensure_base_packages

    # --- Lemonade Server (PPA) — no CUDA toolkit, no llama.cpp build needed ---
    install_lemonade_ppa
    configure_lemonade
    ensure_lemonade_service

    # --- Start and verify ---
    start_and_verify_services

    # --- Final verification ---
    verify_endpoints
}

main "$@"
