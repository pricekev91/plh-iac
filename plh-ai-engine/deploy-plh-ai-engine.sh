#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# deploy-plh-ai-engine.sh
#
# One-and-done IaC deploy for the PLH AI Engine LXC container.
#
# Stack:
#   - llama.cpp server (CUDA) on container :80  → host :80
#   - Unsloth Studio UI   on container :8888  → host :8080
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

# Default model loaded by llama-server at boot (change via switch-model.sh)
MODEL_FILE="gemma-4-E4B-it-Q4_K_M.gguf"

# LXC device names
GPU_DEVICE_NAME="gpu0"
LLAMA_PROXY_NAME="llama-proxy"
UNSLOTH_PROXY_NAME="unsloth-proxy"
MODELS_DEVICE_NAME="models"

# Ports
LLAMA_CT_ADDR="127.0.0.1"
LLAMA_CT_PORT="80"
LLAMA_HOST_ADDR="127.0.0.1"
LLAMA_HOST_PORT="80"

UNSLOTH_CT_ADDR="127.0.0.1"
UNSLOTH_CT_PORT="8888"
UNSLOTH_HOST_ADDR="127.0.0.1"
UNSLOTH_HOST_PORT="8080"

# Systemd services
LLAMA_SERVICE_NAME="llama-server"
UNSLOTH_SERVICE_NAME="unsloth-studio"

# Paths
LLAMA_BUILD_DIR="/opt/llama.cpp/build"
LLAMA_INSTALL_MARKER="/root/.llama_cpp_installed"
UNSLOTH_STUDIO_HOME="/root/.unsloth/studio"
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
# NVIDIA driver / CUDA version detection (host-side)
# =============================================================================

detect_driver_version() {
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo ''
}

detect_cuda_umd_version() {
    # Extract the CUDA UMD version from nvidia-smi — the highest CUDA toolkit
    # version the current driver supports.
    nvidia-smi 2>/dev/null | grep -oP 'CUDA UMD Version: \K[0-9.]+' || echo ''
}

get_highest_cuda_version() {
    curl -sL --max-time 30 \
        https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/Packages 2>/dev/null | \
        grep '^Package: cuda-nvcc-[0-9]' | \
        sed 's/Package: cuda-nvcc-//' | \
        sed 's/\(.*\)-\(.*\)/\1.\2/' | \
        sort -V | tail -1
}

version_leq() {
    local higher
    higher="$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)"
    [[ "$higher" == "$2" ]]
}

# =============================================================================
# Host-side cleanup
# =============================================================================

kill_host_llama_server() {
    local pids
    pids="$(pgrep -f 'llama-server' 2>/dev/null || true)"
    [[ -z "$pids" ]] && { log "No host-side llama-server found"; return 0; }

    log "Killing host-side llama-server (PIDs: $pids)"
    echo "$pids" | xargs -r kill -TERM 2>/dev/null || true

    local waited=0
    while (( waited < 10 )); do
        echo "$pids" | xargs -r ps -p >/dev/null 2>&1 || break
        sleep 1
        waited=$((waited + 1))
    done

    # Force kill anything still alive
    echo "$pids" | xargs -r kill -9 2>/dev/null || true
    log "Host-side llama-server killed"
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

    # Set privileged mode (required for host driver access in LXC)
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
    # llama.cpp proxy: host :80 → container :80
    if ! device_exists "$LLAMA_PROXY_NAME"; then
        log "Adding llama proxy: ${LLAMA_HOST_ADDR}:${LLAMA_HOST_PORT} → ${LLAMA_CT_ADDR}:${LLAMA_CT_PORT}"
        lxc config device add "$CT_NAME" "$LLAMA_PROXY_NAME" proxy \
            listen="tcp:${LLAMA_HOST_ADDR}:${LLAMA_HOST_PORT}" \
            connect="tcp:${LLAMA_CT_ADDR}:${LLAMA_CT_PORT}" \
            --project "$PROJECT"
    else
        log "llama proxy device already present: $LLAMA_PROXY_NAME"
    fi

    # Unsloth Studio proxy: host :8080 → container :8888
    if ! device_exists "$UNSLOTH_PROXY_NAME"; then
        log "Adding unsloth proxy: ${UNSLOTH_HOST_ADDR}:${UNSLOTH_HOST_PORT} → ${UNSLOTH_CT_ADDR}:${UNSLOTH_CT_PORT}"
        lxc config device add "$CT_NAME" "$UNSLOTH_PROXY_NAME" proxy \
            listen="tcp:${UNSLOTH_HOST_ADDR}:${UNSLOTH_HOST_PORT}" \
            connect="tcp:${UNSLOTH_CT_ADDR}:${UNSLOTH_CT_PORT}" \
            --project "$PROJECT"
    else
        log "unsloth proxy device already present: $UNSLOTH_PROXY_NAME"
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

    log "Installing base packages (build-essential, git, curl, python3, etc.)"
    exec_in_ct_root 'DEBIAN_FRONTEND=noninteractive apt-get update'
    exec_in_ct_root 'DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential git curl python3 python3-venv python3-pip wget ca-certificates lsof'

    log "Base packages installed"
}

# =============================================================================
# CUDA toolkit inside container
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

copy_host_libcuda() {
    # Copy the real libcuda.so from the host NVIDIA driver into the container
    # so llama.cpp can link against it (CUDA toolkit stub lacks Driver API symbols).
    local host_lib
    host_lib="$(ls /usr/lib/libcuda.so /usr/lib/x86_64-linux-gnu/libcuda.so 2>/dev/null | head -1)" || true

    if [[ -z "$host_lib" || ! -e "$host_lib" ]]; then
        fail "Host libcuda.so not found — install NVIDIA driver first"
    fi

    local host_dir
    host_dir="$(dirname "$host_lib")"
    local base
    base="$(basename "$host_lib")"

    log "Copying host libcuda.so ($host_lib) to container"
    lxc file push --project "$PROJECT" "$host_lib" "$CT_NAME/usr/lib/$base"

    # Also push the versioned .so.1 if it exists
    if [[ -e "$host_dir/libcuda.so.1" ]]; then
        lxc file push --project "$PROJECT" "$host_dir/libcuda.so.1" "$CT_NAME/usr/lib/libcuda.so.1"
    fi

    # Push the actual versioned binary
    local libcuda_ver
    libcuda_ver="$(readlink -f "$host_lib")" || true
    if [[ -n "$libcuda_ver" && -f "$libcuda_ver" && "$libcuda_ver" != "$host_lib" ]]; then
        lxc file push --project "$PROJECT" "$libcuda_ver" "$CT_NAME/usr/lib/$(basename "$libcuda_ver")"
    fi

    # Ensure symlink chain and replace CUDA toolkit stub
    exec_in_ct_root "ln -sf /usr/lib/libcuda.so.1 /usr/lib/libcuda.so 2>/dev/null || true; ldconfig
      STUB=/usr/local/cuda/targets/x86_64-linux/lib/stubs/libcuda.so
      if [ -f \"\$STUB\" ]; then
        ln -sf /usr/lib/libcuda.so.1 \"\$STUB\"
      fi"

    log "Host libcuda.so copied to container"
}

add_cuda_repo() {
    if exec_in_ct_root "ls /etc/apt/sources.list.d/cuda-*.list >/dev/null 2>&1"; then
        log "CUDA repo already configured in container"
        return 0
    fi

    local deb_path="/tmp/cuda-keyring.deb"
    curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
        -o "$deb_path" || fail "Failed to download CUDA keyring"

    lxc file push --project "$PROJECT" "$deb_path" "$CT_NAME/tmp/cuda-keyring.deb"
    exec_in_ct_root "dpkg -i /tmp/cuda-keyring.deb && rm -f /tmp/cuda-keyring.deb"
    rm -f "$deb_path"

    exec_in_ct_root "DEBIAN_FRONTEND=noninteractive apt-get update"
    log "CUDA repo added to container"
}

install_cuda_toolkit() {
    local cuda_pkg_ver="${CT_CUDA_VER//./-}"

    log "Installing CUDA toolkit $CT_CUDA_VER in container"
    exec_in_ct_root "DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true"
    exec_in_ct_root "DEBIAN_FRONTEND=noninteractive apt-get install -f -y 2>/dev/null || true"

    exec_in_ct_root "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        cuda-nvcc-$cuda_pkg_ver cuda-cudart-dev-$cuda_pkg_ver \
        libcublas-dev-$cuda_pkg_ver cmake"

    log "CUDA toolkit $CT_CUDA_VER installed"
}

# =============================================================================
# llama.cpp build
# =============================================================================

ensure_llama_cpp_installed() {
    local cmake_cache="$LLAMA_BUILD_DIR/CMakeCache.txt"
    local needs_rebuild=1

    # Check marker for driver + CUDA version match
    if exec_in_ct_root "[ -f '$LLAMA_INSTALL_MARKER' ]" 2>/dev/null; then
        local marker_driver_ver marker_cuda_ver
        marker_driver_ver="$(exec_in_ct_root "grep '^driver_ver=' '$LLAMA_INSTALL_MARKER' 2>/dev/null | cut -d= -f2" || echo '')"
        marker_cuda_ver="$(exec_in_ct_root "grep '^cuda_ver=' '$LLAMA_INSTALL_MARKER' 2>/dev/null | cut -d= -f2" || echo '')"

        if [[ "$marker_driver_ver" == "$DRIVER_VER" && "$marker_cuda_ver" == "$CT_CUDA_VER" ]]; then
            if exec_in_ct_root "grep -q 'GGML_CUDA' '$cmake_cache' 2>/dev/null && test -f /opt/llama.cpp/build/bin/llama-server" 2>/dev/null; then
                log "llama.cpp already installed with CUDA $CT_CUDA_VER (verified)"
                return
            fi
            log "Marker matches but CUDA build/binary not found — rebuilding"
        else
            log "Version changed — rebuilding (driver: ${marker_driver_ver:-none}→$DRIVER_VER, CUDA: ${marker_cuda_ver:-none}→$CT_CUDA_VER)"
        fi
    fi

    log "Installing/building llama.cpp with CUDA $CT_CUDA_VER"
    exec_in_ct_root "rm -rf '$LLAMA_BUILD_DIR'"

    if exec_in_ct_root "[ -d /opt/llama.cpp/.git ]"; then
        exec_in_ct_root "cd /opt/llama.cpp && git fetch origin main && git reset --hard origin/main"
    else
        exec_in_ct_root "mkdir -p /opt && cd /opt && git clone https://github.com/ggerganov/llama.cpp.git"
    fi

    local latest_commit
    latest_commit="$(exec_in_ct_root "cd /opt/llama.cpp && git rev-parse --short HEAD" 2>/dev/null)"
    log "llama.cpp commit: ${latest_commit}"

    # Configure with CUDA
    exec_in_ct_root 'export PATH=/usr/local/cuda/bin:$PATH && export LD_LIBRARY_PATH=/usr/lib:$LD_LIBRARY_PATH && \
        cd /opt/llama.cpp && \
        cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_FLAGS="-L/usr/lib"'

    # Build
    log "Building llama.cpp (this may take several minutes)..."
    exec_in_ct_root 'export PATH=/usr/local/cuda/bin:$PATH && export LD_LIBRARY_PATH=/usr/lib:$LD_LIBRARY_PATH && \
        cd /opt/llama.cpp && cmake --build build -j$(nproc)'

    # Write marker
    exec_in_ct_root "echo 'driver_ver=$DRIVER_VER cuda_ver=$CT_CUDA_VER' > '$LLAMA_INSTALL_MARKER'"
    log "llama.cpp installed with CUDA $CT_CUDA_VER (driver: $DRIVER_VER)"
}

# =============================================================================
# Unsloth Studio
# =============================================================================

install_unsloth_studio() {
    log "Installing Unsloth Studio..."

    # Check if already installed (look in venv or symlink location)
    if exec_in_ct_root "test -f '$UNSLOTH_STUDIO_HOME/unsloth_studio/bin/unsloth'" 2>/dev/null || \
       exec_in_ct_root "test -f '/root/.local/bin/unsloth'" 2>/dev/null; then
        log "Unsloth Studio already installed"
        return
    fi

    # Install via official script:
    #   --no-torch: skip PyTorch (we're using GGUF-only models)
    #   UNSLOTH_SKIP_AUTOSTART=1: don't prompt to launch at end of install
    #   Non-interactive: no TTY in lxc exec
    exec_in_ct 'curl -fsSL https://unsloth.ai/install.sh | UNSLOTH_SKIP_AUTOSTART=1 UNSLOTH_NO_TORCH=1 sh -s -- --no-torch'

    # Verify installation — binary can be in several locations
    if exec_in_ct_root "test -f '$UNSLOTH_STUDIO_HOME/unsloth_studio/bin/unsloth'" 2>/dev/null; then
        log "Unsloth Studio installed successfully"
    elif exec_in_ct_root "test -f '/root/.local/bin/unsloth'" 2>/dev/null; then
        log "Unsloth Studio installed (symlink at /root/.local/bin/unsloth)"
    else
        # Search for it
        local found
        found="$(exec_in_ct_root "find /root/.unsloth -name 'unsloth' -type f 2>/dev/null | head -1" || echo '')"
        if [[ -n "$found" ]]; then
            log "Unsloth Studio installed at: $found"
        else
            fail "Unsloth Studio installation did not create expected binary"
        fi
    fi

    # Configure model directory for Unsloth Studio
    log "Configuring Unsloth Studio model directory: $MODEL_DIR_CT"
    exec_in_ct_root "mkdir -p $HOME/.unsloth/studio/config"
    exec_in_ct_root "echo 'models_dir: $MODEL_DIR_CT' > $HOME/.unsloth/studio/config/settings.yaml"
}

# =============================================================================
# Systemd Services
# =============================================================================

ensure_llama_service() {
    local unit_path="/etc/systemd/system/${LLAMA_SERVICE_NAME}.service"
    local env_path="/etc/default/${LLAMA_SERVICE_NAME}"

    log "Configuring llama-server systemd service"

    # Write env file
    cat <<ENVEOF | lxc file push - --project "$PROJECT" "$CT_NAME$env_path"
LLAMA_MODEL='${MODEL_DIR_CT}/${MODEL_FILE}'
LLAMA_BIND_ADDR='${LLAMA_CT_ADDR}'
LLAMA_BIND_PORT='${LLAMA_CT_PORT}'
CUDA_VISIBLE_DEVICES=0
ENVEOF

    # Write unit file
    cat <<'UNITEOF' | lxc file push - --project "$PROJECT" "$CT_NAME$unit_path"
[Unit]
Description=llama.cpp server (CUDA)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/llama-server
Environment=PATH=/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin
Environment=LD_LIBRARY_PATH=/usr/lib:/usr/local/cuda/lib64
WorkingDirectory=/opt/llama.cpp
ExecStart=/opt/llama.cpp/build/bin/llama-server \
    --host ${LLAMA_BIND_ADDR} \
    --port ${LLAMA_BIND_PORT} \
    --model ${LLAMA_MODEL} \
    --ctx-size 8192 \
    --threads 4 \
    --batch-size 2048
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNITEOF

    exec_in_ct_root "systemctl daemon-reload"
    exec_in_ct_root "systemctl enable $LLAMA_SERVICE_NAME"
    log "llama-server systemd service configured and enabled"
}

ensure_unsloth_service() {
    local unit_path="/etc/systemd/system/${UNSLOTH_SERVICE_NAME}.service"
    local env_path="/etc/default/${UNSLOTH_SERVICE_NAME}"

    log "Configuring Unsloth Studio systemd service"

    # Find the actual unsloth binary path (check venv, symlink, and known locations)
    local unsloth_bin
    unsloth_bin="$(exec_in_ct_root "find /root/.unsloth -name 'unsloth' -type f 2>/dev/null | head -1" || echo '')"
    if [[ -z "$unsloth_bin" ]]; then
        # Try symlink location
        if exec_in_ct_root "test -L '/root/.local/bin/unsloth'" 2>/dev/null; then
            unsloth_bin="/root/.local/bin/unsloth"
        fi
    fi
    if [[ -z "$unsloth_bin" ]]; then
        fail "Unsloth binary not found"
    fi
    log "Unsloth binary: $unsloth_bin"

    # Write env file
    cat <<ENVEOF | lxc file push - --project "$PROJECT" "$CT_NAME$env_path"
UNSLOTH_STUDIO_HOME='$UNSLOTH_STUDIO_HOME'
PYTHONPATH='$UNSLOTH_STUDIO_HOME/lib'
CUDA_VISIBLE_DEVICES=0
ENVEOF

    # Write unit file
    cat <<UNITEOF | lxc file push - --project "$PROJECT" "$CT_NAME$unit_path"
[Unit]
Description=Unsloth Studio UI
After=network-online.target $LLAMA_SERVICE_NAME.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/unsloth-studio
Environment=PATH=/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin:$UNSLOTH_STUDIO_HOME/bin
Environment=LD_LIBRARY_PATH=/usr/lib:/usr/local/cuda/lib64:$UNSLOTH_STUDIO_HOME/lib
Environment=HOME=/root
WorkingDirectory=/root
ExecStart=$unsloth_bin studio -p $UNSLOTH_CT_PORT -H $UNSLOTH_CT_ADDR
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNITEOF

    exec_in_ct_root "systemctl daemon-reload"
    exec_in_ct_root "systemctl enable $UNSLOTH_SERVICE_NAME"
    log "Unsloth Studio systemd service configured and enabled"
}

# =============================================================================
# Switch model script
# =============================================================================

deploy_switch_model() {
    local scripts_dir="$(cd "$(dirname "$0")" && pwd)/scripts"
    local local_script="$scripts_dir/switch-model.sh"

    if [[ ! -f "$local_script" ]]; then
        log "switch-model.sh not found at $local_script, skipping"
        return 0
    fi

    local ct_script="/usr/local/bin/switch-model.sh"

    # Deploy to container
    lxc file push --project "$PROJECT" "$local_script" "$CT_NAME$ct_script"
    exec_in_ct_root "chmod +x $ct_script"

    # Also place in model directory
    lxc file push --project "$PROJECT" "$local_script" "$CT_NAME/srv/ai/models/switch-model.sh"
    exec_in_ct_root "chmod +x /srv/ai/models/switch-model.sh"

    log "switch-model.sh deployed to container"
}

# =============================================================================
# Start services and verify
# =============================================================================

start_and_verify_services() {
    log "Starting llama-server service..."
    exec_in_ct_root "systemctl restart $LLAMA_SERVICE_NAME" || \
    exec_in_ct_root "systemctl start $LLAMA_SERVICE_NAME"

    log "Waiting for llama-server to be ready..."
    local waited=0
    while (( waited < 60 )); do
        if lxc exec "$CT_NAME" --project "$PROJECT" -- curl -sf http://127.0.0.1:$LLAMA_CT_PORT/health >/dev/null 2>&1; then
            log "llama-server is healthy on :$LLAMA_CT_PORT"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if (( waited >= 60 )); then
        warn "llama-server health check did not respond after ${waited}s — checking service status"
        exec_in_ct_root "systemctl status $LLAMA_SERVICE_NAME --no-pager" || true
        exec_in_ct_root "journalctl -u $LLAMA_SERVICE_NAME --no-pager -n 20" || true
    fi

    log "Starting Unsloth Studio service..."
    exec_in_ct_root "systemctl restart $UNSLOTH_SERVICE_NAME" || \
    exec_in_ct_root "systemctl start $UNSLOTH_SERVICE_NAME"

    log "Waiting for Unsloth Studio to be ready..."
    waited=0
    while (( waited < 120 )); do
        local resp
        resp="$(lxc exec "$CT_NAME" --project "$PROJECT" -- curl -sf http://127.0.0.1:$UNSLOTH_CT_PORT/api/health 2>/dev/null || true)"
        if [[ "$resp" == *"healthy"* ]]; then
            log "Unsloth Studio is healthy on :$UNSLOTH_CT_PORT"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if (( waited >= 120 )); then
        warn "Unsloth Studio health check did not respond after ${waited}s — checking service status"
        exec_in_ct_root "systemctl status $UNSLOTH_SERVICE_NAME --no-pager" || true
        exec_in_ct_root "journalctl -u $UNSLOTH_SERVICE_NAME --no-pager -n 30" || true
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

    # Test llama.cpp endpoint
    log "Testing llama.cpp (host :$LLAMA_HOST_PORT)..."
    local llama_resp
    llama_resp="$(curl -sf --max-time 10 http://$LLAMA_HOST_ADDR:$LLAMA_HOST_PORT/health 2>/dev/null || echo 'FAILED')"
    if [[ "$llama_resp" != "FAILED" ]]; then
        info "✅ llama.cpp healthy at http://$LLAMA_HOST_ADDR:$LLAMA_HOST_PORT"
    else
        warn "⚠️  llama.cpp did not respond on http://$LLAMA_HOST_ADDR:$LLAMA_HOST_PORT"
    fi

    # Test Unsloth Studio endpoint
    log "Testing Unsloth Studio (host :$UNSLOTH_HOST_PORT)..."
    local unsloth_resp
    unsloth_resp="$(curl -sf --max-time 10 http://$UNSLOTH_HOST_ADDR:$UNSLOTH_HOST_PORT/api/health 2>/dev/null || echo 'FAILED')"
    if [[ "$unsloth_resp" != "FAILED" && "$unsloth_resp" == *"healthy"* ]]; then
        info "✅ Unsloth Studio healthy at http://$UNSLOTH_HOST_ADDR:$UNSLOTH_HOST_PORT"
    else
        warn "⚠️  Unsloth Studio did not respond on http://$UNSLOTH_HOST_ADDR:$UNSLOTH_HOST_PORT"
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
    exec_in_ct_root "systemctl is-active $LLAMA_SERVICE_NAME $UNSLOTH_SERVICE_NAME" || true
    log ""

    # GPU check
    log "GPU status inside container:"
    exec_in_ct_root "nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv 2>/dev/null || echo 'nvidia-smi not available'"
    log ""

    log "========================================="
    log "Deploy complete!"
    log "========================================="
    log "  llama.cpp API:    http://127.0.0.1:$LLAMA_HOST_PORT"
    log "  Unsloth Studio:   http://127.0.0.1:$UNSLOTH_HOST_PORT"
    log ""
    log "  Stop container:   lxc stop $CT_NAME --project $PROJECT"
    log "  Start container:  lxc start $CT_NAME --project $PROJECT"
    log "  Switch model:     lxc exec $CT_NAME --project $PROJECT -- /usr/local/bin/switch-model.sh <model.gguf>"
    log "========================================="
}

# =============================================================================
# Main
# =============================================================================

main() {
    require lxc

    # --- Host detection ---
    DRIVER_VER="$(detect_driver_version)"
    if [[ -z "$DRIVER_VER" ]]; then
        fail "Could not detect NVIDIA driver version. Is the NVIDIA driver installed?"
    fi
    log "Detected NVIDIA driver version: $DRIVER_VER"

    CT_CUDA_VER="$(detect_cuda_umd_version)"
    if [[ -z "$CT_CUDA_VER" ]]; then
        fail "Could not detect CUDA UMD version from nvidia-smi"
    fi
    log "CUDA UMD version from driver: $CT_CUDA_VER"

    # Fallback to highest available if driver is newer than repo
    local highest_cuda
    highest_cuda="$(get_highest_cuda_version)"
    if [[ -n "$highest_cuda" ]] && ! version_leq "$CT_CUDA_VER" "$highest_cuda"; then
        log "Detected CUDA $CT_CUDA_VER not in repo, falling back to highest: $highest_cuda"
        CT_CUDA_VER="$highest_cuda"
    fi
    log "Will install CUDA toolkit: $CT_CUDA_VER"

    # --- Pre-flight ---
    kill_host_llama_server

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
    copy_host_libcuda

    # --- CUDA toolkit ---
    add_cuda_repo
    install_cuda_toolkit

    # --- llama.cpp ---
    ensure_llama_cpp_installed

    # --- Unsloth Studio ---
    install_unsloth_studio

    # --- Systemd services ---
    ensure_llama_service
    ensure_unsloth_service

    # --- Deploy helper scripts ---
    deploy_switch_model

    # --- Start and verify ---
    start_and_verify_services

    # --- Final verification ---
    verify_endpoints
}

main "$@"
