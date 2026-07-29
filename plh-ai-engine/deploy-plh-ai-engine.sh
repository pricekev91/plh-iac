#!/usr/bin/env bash
set -euo pipefail

# ----------------- Config -----------------
PROJECT="prod"
CT_NAME="plh-ai-engine"
IMAGE="ubuntu:24.04"

MODEL_DIR_HOST="/srv/ai/models"
MODEL_DIR_CT="/srv/ai/models"
MODEL_FILE="gemma-4-E4B-it-Q4_K_M.gguf"

GPU_DEVICE_NAME="gpu0"          # LXD gpu device name inside CT
PROXY_DEVICE_NAME="http-local"  # LXD proxy device name

SERVICE_NAME="llama-server"
INSTALL_MARKER="/root/.llama_cpp_installed"
SCRIPTS_DIR="$(dirname "$0")/scripts"

CT_LISTEN_ADDR="127.0.0.1"
CT_LISTEN_PORT="80"
HOST_LISTEN_ADDR="127.0.0.1"
HOST_LISTEN_PORT="80"
# ------------------------------------------

log() { echo "[deploy] $*" >&2; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# =============================================================================
# NVIDIA driver / CUDA version detection (host-side)
# =============================================================================
# These functions run on the HOST (plh) to detect the current NVIDIA driver
# version and the maximum CUDA version it supports.  The detected CUDA version
# is then used to install the matching toolkit inside the container.

detect_cuda_version() {
    # Extract the CUDA UMD version from `nvidia-smi` on the host.
    # The UMD version is the highest CUDA toolkit version the driver supports.
    local cuda_ver
    cuda_ver="$(nvidia-smi 2>/dev/null | grep -oP 'CUDA UMD Version: \K[0-9.]+' || echo '')"
    if [[ -z "$cuda_ver" ]]; then
        fail "Could not detect CUDA version from nvidia-smi. Is the NVIDIA driver installed and loaded?"
    fi
    echo "$cuda_ver"
}

get_highest_cuda_version() {
    # Query the NVIDIA CUDA repo (Ubuntu 24.04 / x86_64) and return the
    # highest available CUDA toolkit version.  This is used as a fallback
    # when the detected driver CUDA version is newer than anything in the repo.
    local highest
    highest="$(curl -sL --max-time 30 \
        https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/Packages 2>/dev/null | \
        grep '^Package: cuda-nvcc-[0-9]' | \
        sed 's/Package: cuda-nvcc-//' | \
        sed 's/\(.*\)-\(.*\)/\1.\2/' | \
        sort -V | \
        tail -1)"
    if [[ -z "$highest" ]]; then
        fail "Could not determine highest available CUDA version from NVIDIA repo"
    fi
    log "Highest CUDA version available in NVIDIA repo: $highest"
    echo "$highest"
}

version_leq() {
    # Returns 0 (true) if $1 <= $2, 1 (false) otherwise.
    # Uses sort -V for correct semantic version comparison.
    local higher
    higher="$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)"
    [[ "$higher" == "$2" ]]
}

# =============================================================================

# Kill any llama-server running directly on the host (not inside the container).
# This prevents GPU VRAM waste and port conflicts.
kill_host_llama_server() {
    local pids
    pids="$(pgrep -f 'llama-server' 2>/dev/null || true)"
    if [[ -z "$pids" ]]; then
        log "No host-side llama-server found — nothing to kill"
        return 0
    fi
    log "Killing host-side llama-server (PIDs: $pids)"
    echo "$pids" | xargs -r kill -TERM 2>/dev/null || true
    # Wait up to 10s for clean shutdown
    local waited=0
    while (( waited < 10 )); do
        local still_running
        still_running="$(echo "$pids" | xargs -r ps -p 2>/dev/null | grep -c llama-server || true)"
        if (( still_running == 0 )); then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    # Force kill anything still alive
    pids="$(echo "$pids" | xargs -r ps -p 2>/dev/null | awk 'NR>1 && /llama-server/{print $1}' || true)"
    if [[ -n "$pids" ]]; then
        log "Force-killing remaining PIDs: $pids"
        echo "$pids" | xargs -r kill -9 2>/dev/null || true
    fi
    log "Host-side llama-server killed"
}

require() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

project_exists() {
    lxc project show "$PROJECT" >/dev/null 2>&1
}

ensure_project() {
    if project_exists; then
        log "Project exists: $PROJECT"
    else
        log "Create project: $PROJECT"
        lxc project create "$PROJECT"
    fi
}

ct_exists() {
    lxc info "$CT_NAME" --project "$PROJECT" >/dev/null 2>&1
}

ensure_container() {
    if ct_exists; then
        log "Always-nuke mode: removing existing container $PROJECT/$CT_NAME"
        lxc stop "$CT_NAME" --project "$PROJECT" >/dev/null 2>&1 || true
        lxc delete --force "$CT_NAME" --project "$PROJECT"
    fi

    log "Init container: $PROJECT/$CT_NAME from $IMAGE"
    lxc init "$IMAGE" "$CT_NAME" --project "$PROJECT" -p default
}

device_exists() {
    local dev="$1"
    lxc config device list "$CT_NAME" --project "$PROJECT" | grep -Fxq "$dev"
}

ensure_gpu_device() {
    if device_exists "$GPU_DEVICE_NAME"; then
        log "GPU device already present: $GPU_DEVICE_NAME"
        return
    fi

    log "Attach GPU device: $GPU_DEVICE_NAME"
    lxc config device add "$CT_NAME" "$GPU_DEVICE_NAME" gpu --project "$PROJECT"
}

ensure_model_mount() {
    if [[ ! -d "$MODEL_DIR_HOST" ]]; then
        fail "Host model dir does not exist: $MODEL_DIR_HOST"
    fi

    local dev_name="models"

    if device_exists "$dev_name"; then
        log "Model dir mount already present: $dev_name"
        return
    fi

    log "Mount model dir $MODEL_DIR_HOST -> $MODEL_DIR_CT"
    lxc config device add "$CT_NAME" "$dev_name" disk \
        source="$MODEL_DIR_HOST" path="$MODEL_DIR_CT" \
        --project "$PROJECT"
}

ensure_proxy_device() {
    if device_exists "$PROXY_DEVICE_NAME"; then
        log "Proxy device already present: $PROXY_DEVICE_NAME"
        return
    fi

    log "Add proxy device $PROXY_DEVICE_NAME (host ${HOST_LISTEN_ADDR}:${HOST_LISTEN_PORT} -> CT ${CT_LISTEN_ADDR}:${CT_LISTEN_PORT})"
    lxc config device add "$CT_NAME" "$PROXY_DEVICE_NAME" proxy \
        listen="tcp:${HOST_LISTEN_ADDR}:${HOST_LISTEN_PORT}" \
        connect="tcp:${CT_LISTEN_ADDR}:${CT_LISTEN_PORT}" \
        --project "$PROJECT"
}

ensure_cuda_driver_lib() {
    # The CUDA toolkit inside the container ships only a stub libcuda.so
    # (in /usr/local/cuda-*/targets/*/lib/stubs/) that lacks Driver API
    # symbols (cuGetErrorString, cuMemCreate, etc.) needed by llama.cpp at
    # link time.  Copy the real libcuda.so from the host NVIDIA driver.
    local host_lib
    host_lib="$(ls /usr/lib/libcuda.so /usr/lib/x86_64-linux-gnu/libcuda.so 2>/dev/null | head -1)" || true
    if [[ -z "$host_lib" ]]; then
        fail "Host libcuda.so not found — install NVIDIA driver (nvidia-driver-*) first"
    fi

    log "Copying host libcuda.so to container for build-time linking"
    lxc file push "$host_lib" --project "$PROJECT" "$CT_NAME/usr/lib/$(basename "$host_lib")"

    # Also push the versioned .so.1 if it exists
    if [[ -e "$(dirname "$host_lib")/libcuda.so.1" ]]; then
        lxc file push "$(dirname "$host_lib")/libcuda.so.1" --project "$PROJECT" "$CT_NAME/usr/lib/libcuda.so.1"
    fi
    # Push the actual versioned binary
    local libcuda_ver
    libcuda_ver="$(readlink -f "$host_lib")" || true
    if [[ -n "$libcuda_ver" && -f "$libcuda_ver" ]]; then
        lxc file push "$libcuda_ver" --project "$PROJECT" "$CT_NAME/usr/lib/$(basename "$libcuda_ver")"
    fi

    # Ensure symlink chain is correct inside container
    # Also REPLACE the CUDA toolkit stub so the build linker doesn't pick it up
    # (targets/*/lib/stubs/libcuda.so is a no-op stub with zero symbols).
    exec_in_ct "ln -sf /usr/lib/libcuda.so.1 /usr/lib/libcuda.so 2>/dev/null || true; ldconfig
      STUB=/usr/local/cuda/targets/x86_64-linux/lib/stubs/libcuda.so
      if [ -f \"\$STUB\" ]; then
        ln -sf /usr/lib/libcuda.so.1 \"\$STUB\"
      fi"

    log "Host libcuda.so copied to container (stub replaced)"
}

ensure_started() {
    local status
    status="$(lxc info "$CT_NAME" --project "$PROJECT" | awk '/^Status:/ {print $2}')"
    if [[ "$status" != "Running" && "$status" != "RUNNING" ]]; then
        log "Start container: $PROJECT/$CT_NAME"
        lxc start "$CT_NAME" --project "$PROJECT"
    else
        log "Container already running: $PROJECT/$CT_NAME"
    fi
}

exec_in_ct() {
    lxc exec "$CT_NAME" --project "$PROJECT" -- bash -lc "$*"
}

purge_container_nvidia_runtime_conflicts() {
    # In LXC, host kernel driver is authoritative. Container-side runtime
    # stacks (nvidia-utils/libnvidia-compute/cuda-compat) can drift and cause
    # NVML mismatches after host driver upgrades.
    local pkgs
    pkgs="$(exec_in_ct "dpkg-query -W -f='\${Package}\n' 'nvidia-utils-*' 'libnvidia-compute-*' 'cuda-compat-*' 2>/dev/null | sort -u || true")"

    if [[ -z "$pkgs" ]]; then
        log "No conflicting container NVIDIA runtime packages detected"
        return 0
    fi

    log "Purging conflicting container NVIDIA runtime packages"
    printf '%s\n' "$pkgs"
    exec_in_ct "DEBIAN_FRONTEND=noninteractive apt-get purge -y $pkgs || true"
    exec_in_ct "DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true"
}

# Add NVIDIA CUDA APT repository to the container
# Download from host (container may not have network ready during early boot)
add_cuda_repo() {
    # Check if CUDA repo is already configured
    if ls /etc/apt/sources.list.d/cuda-*.list 1>/dev/null 2>&1; then
        log "CUDA repo already configured inside container"
        return 0
    fi

    local deb_path="/tmp/cuda-keyring.deb"

    # Download keyring on host
    curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb -o "$deb_path" || \
        fail "Failed to download CUDA keyring from host"

    # Push into container
    lxc file push "$deb_path" --project "$PROJECT" "$CT_NAME/tmp/cuda-keyring.deb"

    # Install from within container
    exec_in_ct "dpkg -i /tmp/cuda-keyring.deb && rm -f /tmp/cuda-keyring.deb"

    rm -f "$deb_path"
}

# Wait for container network to be ready (DHCP + DNS)
wait_for_network() {
    local max_wait=60
    local waited=0
    while (( waited < max_wait )); do
        if exec_in_ct "ping -c 1 -W 2 8.8.8.8" >/dev/null 2>&1; then
            log "Container network is ready (${waited}s)"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    fail "Container network not ready after ${max_wait}s"
}

ensure_llama_cpp_installed() {
    local build_dir="/opt/llama.cpp/build"
    local cmake_cache="/opt/llama.cpp/build/CMakeCache.txt"
    local needs_rebuild=0

    # Wait for container network before any apt commands
    wait_for_network

    # Add CUDA repo if not already present
    if ! exec_in_ct "ls /etc/apt/sources.list.d/cuda-*.list >/dev/null 2>&1"; then
        add_cuda_repo
    fi

    # Determine package suffix: dots → dashes (13.3 → 13-3)
    local cuda_pkg_ver="${CT_CUDA_VER//./-}"

    # Check marker for driver + CUDA version match
    local marker_driver_ver="" marker_cuda_ver=""
    if exec_in_ct "[ -f '$INSTALL_MARKER' ]" 2>/dev/null; then
        marker_driver_ver="$(exec_in_ct "grep '^driver_ver=' '$INSTALL_MARKER' 2>/dev/null | cut -d= -f2" || echo '')"
        marker_cuda_ver="$(exec_in_ct "grep '^cuda_ver=' '$INSTALL_MARKER' 2>/dev/null | cut -d= -f2" || echo '')"

        if [[ "$marker_driver_ver" == "$DRIVER_VER" && "$marker_cuda_ver" == "$CT_CUDA_VER" ]]; then
            # Versions match — verify CUDA build actually exists
            if exec_in_ct "test -e /dev/nvidia0 && grep -q 'GGML_CUDA' '$cmake_cache' 2>/dev/null && test -f /opt/llama.cpp/build/bin/llama-server" 2>/dev/null; then
                log "llama.cpp already installed with CUDA $CT_CUDA_VER (marker present, CUDA build detected, binary exists)"
                return
            fi
            log "Marker matches but CUDA build / binary not found — rebuilding to be safe"
            needs_rebuild=1
        else
            log "Version changed — driver: ${marker_driver_ver:-none} → $DRIVER_VER, CUDA: ${marker_cuda_ver:-none} → $CT_CUDA_VER"
            needs_rebuild=1
        fi
    else
        log "No marker found — installing CUDA toolkit $CT_CUDA_VER (driver: $DRIVER_VER)"
        needs_rebuild=1
    fi

    if [[ "$needs_rebuild" -eq 1 ]]; then
        log "Cleaning old build"
        exec_in_ct "rm -rf '$build_dir'"
    fi

    log "Installing CUDA toolkit $CT_CUDA_VER and build dependencies"

    # Fix any dpkg state from a previous partial failure so the script
    # is fully idempotent (works on fresh install and after retries).
    exec_in_ct "DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true"
    exec_in_ct "DEBIAN_FRONTEND=noninteractive apt-get install -f -y 2>/dev/null || true"

    exec_in_ct "DEBIAN_FRONTEND=noninteractive apt-get update"

    # llama.cpp needs: nvcc (compiler), CUDA runtime + cuBLAS dev headers.
    # The CUDA toolkit stub libcuda.so lacks Driver API symbols needed at link
    # time — the real libcuda.so is copied from the host in ensure_cuda_driver_lib().
    # --no-install-recommends avoids nsight/GTK3/Java bloat.
    local cuda_pkg_ver="${CT_CUDA_VER//./-}"
    exec_in_ct "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        cuda-nvcc-$cuda_pkg_ver cuda-cudart-dev-$cuda_pkg_ver \
        libcublas-dev-$cuda_pkg_ver \
        cmake build-essential git"

    log "Get latest llama.cpp from GitHub"
    if exec_in_ct "[ -d /opt/llama.cpp/.git ]"; then
        log "Updating existing llama.cpp to latest main"
        exec_in_ct "cd /opt/llama.cpp && git fetch origin main && git reset --hard origin/main"
    else
        rm -rf /opt/llama.cpp
        exec_in_ct "mkdir -p /opt && cd /opt && git clone https://github.com/ggerganov/llama.cpp.git"
    fi
    LATEST_COMMIT="$(exec_in_ct "cd /opt/llama.cpp && git rev-parse --short HEAD" 2>/dev/null)"
    log "llama.cpp version: ${LATEST_COMMIT}"

    # Pass the real libcuda.so path to cmake so it links against the host driver
    # library (copied in ensure_cuda_driver_lib) instead of the CUDA toolkit stub
    # that lacks Driver API symbols.
    log "Configuring llama.cpp build with CUDA $CT_CUDA_VER support"
    exec_in_ct 'export PATH=/usr/local/cuda/bin:$PATH && export LD_LIBRARY_PATH=/usr/lib:$LD_LIBRARY_PATH && cd /opt/llama.cpp && cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_FLAGS="-L/usr/lib"'

    log "Building llama.cpp (this may take several minutes) ..."
    exec_in_ct 'export PATH=/usr/local/cuda/bin:$PATH && export LD_LIBRARY_PATH=/usr/lib:$LD_LIBRARY_PATH && cd /opt/llama.cpp && cmake --build build -j$(nproc)'

    # Write marker with both driver version and CUDA toolkit version
    exec_in_ct "echo 'driver_ver=$DRIVER_VER cuda_ver=$CT_CUDA_VER' > '$INSTALL_MARKER'"
    log "llama.cpp installed with CUDA $CT_CUDA_VER support (driver: $DRIVER_VER)"
}

ensure_service_unit() {
    local unit_path="/etc/systemd/system/${SERVICE_NAME}.service"
    local env_path="/etc/default/${SERVICE_NAME}"

    log "Write env file and unit to container (idempotent)"

    # Write env file via pipe → lxc file push (avoids nested quoting issues).
    # Host expands variables; systemd EnvironmentFile supports single-quoted values.
    cat <<ENVEOF | lxc file push - --project "$PROJECT" "$CT_NAME$env_path"
LLAMA_MODEL='${MODEL_DIR_CT}/${MODEL_FILE}'
LLAMA_BIND_ADDR='${CT_LISTEN_ADDR}'
LLAMA_BIND_PORT='${CT_LISTEN_PORT}'
ENVEOF

    # Write unit file via pipe — quoted heredoc delimiter so ${...} stays literal
    # (systemd substitutes them at runtime from EnvironmentFile).
    cat <<'UNITEOF' | lxc file push - --project "$PROJECT" "$CT_NAME$unit_path"
[Unit]
Description=llama.cpp server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/llama-server
WorkingDirectory=/opt/llama.cpp
ExecStart=/opt/llama.cpp/build/bin/llama-server --host ${LLAMA_BIND_ADDR} --port ${LLAMA_BIND_PORT} --model ${LLAMA_MODEL}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF

    log "Reload systemd and enable service"
    lxc exec "$CT_NAME" --project "$PROJECT" -- systemctl daemon-reload
    lxc exec "$CT_NAME" --project "$PROJECT" -- systemctl enable "$SERVICE_NAME"

    log "Ensure service is running"
    lxc exec "$CT_NAME" --project "$PROJECT" -- systemctl restart "$SERVICE_NAME" || \
    lxc exec "$CT_NAME" --project "$PROJECT" -- systemctl start "$SERVICE_NAME"
}

ensure_switch_model() {
    # Deploy the fixed switch-model.sh to the container.
    # The old awk-based version (in the container) had a bug where print
    # statements used \\\\ which produced literal " on each line of
    # ExecStart, creating a multi-line ExecStart that systemd chokes on:
    #   ExecStart=/opt/llama.cpp/build/bin/llama-server \"
    #     --model /path/gguf \"
    # Each trailing " is parsed as a separate (invalid) argument →
    # "error: invalid argument: \"". The new version builds a single-line
    # ExecStart using awk string concatenation (cmd=cmd " --foo") so there
    # are no stray quotes.
    local local_script="$SCRIPTS_DIR/plh-switch-model.sh"
    if [[ ! -f "$local_script" ]]; then
        log "WARNING: plh-switch-model.sh not found at $local_script, skipping"
        return 0
    fi

    local ct_script="/usr/local/bin/plh-switch-model.sh"
    # Check if we need to update
    if lxc file read --project "$PROJECT" "$CT_NAME$ct_script" 2>/dev/null | md5sum | grep -q "$(md5sum "$local_script" | cut -d' ' -f1)"; then
        log "plh-switch-model.sh already up to date in container"
        return 0
    fi

    log "Deploying plh-switch-model.sh to container"
    lxc file push --project "$PROJECT" "$local_script" "$CT_NAME$ct_script"
    exec_in_ct "chmod +x $ct_script"

    exec_in_ct "ln -sf $ct_script /usr/local/bin/switch-model.sh"

    # Also place in /srv/ai/models/ where some tooling expects it.
    # This is a host-mounted disk inside LXC, so chmod/chown can be denied by
    # idmapping even for container root. Treat permission changes as best-effort.
    lxc file push --project "$PROJECT" "$local_script" "$CT_NAME/srv/ai/models/plh-switch-model.sh"
    exec_in_ct "test -x /srv/ai/models/plh-switch-model.sh || chmod +x /srv/ai/models/plh-switch-model.sh || true"
    exec_in_ct "ln -sf /srv/ai/models/plh-switch-model.sh /srv/ai/models/switch-model.sh || true"

    log "plh-switch-model.sh deployed"
}

main() {
    require lxc

    # Detect NVIDIA driver and CUDA version from host at deploy time.
    # No hardcoded versions — we always match the host driver.
    DRIVER_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo '')"
    if [[ -z "$DRIVER_VER" ]]; then
        fail "Could not detect NVIDIA driver version. Is the NVIDIA driver installed and loaded?"
    fi
    log "Detected NVIDIA driver version: $DRIVER_VER"

    # Detect the CUDA version the driver supports (from nvidia-smi output)
    CT_CUDA_VER="$(detect_cuda_version)"

    # Check if detected CUDA version exists in the repo; if not, fall back
    # to the highest version available (driver may be newer than repo).
    HIGHEST_CUDA_VER="$(get_highest_cuda_version)"
    if ! version_leq "$CT_CUDA_VER" "$HIGHEST_CUDA_VER"; then
        log "Detected CUDA version $CT_CUDA_VER not yet in repo, using highest available: $HIGHEST_CUDA_VER"
        CT_CUDA_VER="$HIGHEST_CUDA_VER"
    fi

    log "Will install CUDA toolkit version $CT_CUDA_VER (host driver: $DRIVER_VER)"

    # Kill any host-side llama-server first (prevents VRAM waste + port conflicts)
    kill_host_llama_server

    ensure_project
    ensure_container
    ensure_gpu_device
    ensure_model_mount
    ensure_proxy_device
    ensure_started
    purge_container_nvidia_runtime_conflicts
    ensure_cuda_driver_lib
    ensure_llama_cpp_installed
    purge_container_nvidia_runtime_conflicts
    ensure_service_unit
    ensure_switch_model

    log "Done."
    log "From the host, open: http://127.0.0.1/  (Hermes Agent can also use 127.0.0.1:80)"
    log "When you want full GPU for gaming:  lxc stop $CT_NAME --project $PROJECT"

    # Clean up any old container leftovers
    for old_ct in $(lxc list --project "$PROJECT" -c n --format csv | grep -v "^${CT_NAME}$"); do
        log "Cleaning up old container: $old_ct"
        lxc delete --force "$old_ct" --project "$PROJECT"
    done
}

main "$@"
