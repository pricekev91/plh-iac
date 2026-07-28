#!/usr/bin/env bash
set -euo pipefail

# Import existing local model files into Lemonade's model path and refresh lemond.
#
# Usage:
#   ./lemonade-import.sh [SOURCE_DIR]
#
# Examples:
#   ./lemonade-import.sh
#   ./lemonade-import.sh /mnt/fast/models

PROJECT="${PROJECT:-prod}"
CT_NAME="${CT_NAME:-plh-ai-engine}"
MODEL_TARGET_HOST="${MODEL_TARGET_HOST:-/srv/ai/models}"
MODEL_TARGET_CT="/srv/ai/models"
MODELS_DEVICE_NAME="models"
LEMONADE_SERVICE_NAME="lemond"
LEMONADE_CONFIG_FILE="/etc/lemonade/config.json"
LEMONADE_LEGACY_CONFIG_FILE="/root/.config/lemonade/config.json"
SOURCE_DIR="${1:-$MODEL_TARGET_HOST}"

log() {
  echo "[import] $*" >&2
}

warn() {
  echo "[warn] $*" >&2
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

ct_exists() {
  lxc info "$CT_NAME" --project "$PROJECT" >/dev/null 2>&1
}

device_exists() {
  local dev="$1"
  lxc config device list "$CT_NAME" --project "$PROJECT" 2>/dev/null | grep -Fxq "$dev"
}

is_supported_model_file() {
  local f="$1"
  case "${f,,}" in
    *.gguf|*.ggml|*.bin|*.safetensors) return 0 ;;
    *) return 1 ;;
  esac
}

link_models_into_target() {
  local linked=0
  local skipped=0

  while IFS= read -r -d '' src_file; do
    if ! is_supported_model_file "$src_file"; then
      continue
    fi

    local base dst
    base="$(basename "$src_file")"
    dst="$MODEL_TARGET_HOST/$base"

    if [[ -e "$dst" || -L "$dst" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    ln -s "$src_file" "$dst"
    linked=$((linked + 1))
  done < <(find "$SOURCE_DIR" -type f -print0)

  log "Linked files: $linked"
  log "Skipped existing names: $skipped"
}

write_container_config() {
  local cfg
  cfg='{
  "llamacpp": {
    "backend": "cuda"
  },
  "models_dir": "/srv/ai/models"
}'

  lxc exec "$CT_NAME" --project "$PROJECT" -- bash -lc "mkdir -p /etc/lemonade /root/.config/lemonade"
  printf '%s\n' "$cfg" | lxc file push - --project "$PROJECT" "$CT_NAME$LEMONADE_CONFIG_FILE"
  printf '%s\n' "$cfg" | lxc file push - --project "$PROJECT" "$CT_NAME$LEMONADE_LEGACY_CONFIG_FILE"
}

ensure_container_model_dir_writable() {
  if lxc exec "$CT_NAME" --project "$PROJECT" -- bash -lc "touch $MODEL_TARGET_CT/.lemonade-write-test && rm -f $MODEL_TARGET_CT/.lemonade-write-test"; then
    log "Container model directory is writable: $MODEL_TARGET_CT"
  else
    warn "Container cannot write to $MODEL_TARGET_CT. Lemonade may list 0 downloaded models."
    warn "Fix permissions on host path: $MODEL_TARGET_HOST (for example: chmod a+rwx $MODEL_TARGET_HOST)"
  fi
}

verify_counts() {
  local host_count ct_count
  host_count="$(find "$MODEL_TARGET_HOST" -type f \( -iname '*.gguf' -o -iname '*.ggml' -o -iname '*.bin' -o -iname '*.safetensors' \) | wc -l | tr -d ' ')"
  ct_count="$(lxc exec "$CT_NAME" --project "$PROJECT" -- bash -lc "find $MODEL_TARGET_CT -type f \\( -iname '*.gguf' -o -iname '*.ggml' -o -iname '*.bin' -o -iname '*.safetensors' \\) | wc -l" | tr -d ' ')"

  log "Host model files visible at $MODEL_TARGET_HOST: $host_count"
  log "Container model files visible at $MODEL_TARGET_CT: $ct_count"
}

verify_api() {
  log "Lemonade /api/v1/models response (first 500 chars):"
  lxc exec "$CT_NAME" --project "$PROJECT" -- bash -lc "curl -sf http://127.0.0.1:13305/api/v1/models | head -c 500" || true
  echo
}

main() {
  require lxc
  require find
  require ln
  require curl

  [[ -d "$SOURCE_DIR" ]] || fail "Source directory does not exist: $SOURCE_DIR"
  mkdir -p "$MODEL_TARGET_HOST"

  if [[ "$SOURCE_DIR" != "$MODEL_TARGET_HOST" ]]; then
    log "Importing model files from $SOURCE_DIR into $MODEL_TARGET_HOST as symlinks"
    link_models_into_target
  else
    log "Source directory already matches Lemonade model path: $MODEL_TARGET_HOST"
  fi

  ct_exists || fail "Container not found: ${PROJECT}/${CT_NAME}. Run ./deploy-plh-ai-engine.sh first."

  if ! device_exists "$MODELS_DEVICE_NAME"; then
    log "Adding missing LXD disk device for models"
    lxc config device add "$CT_NAME" "$MODELS_DEVICE_NAME" disk \
      source="$MODEL_TARGET_HOST" path="$MODEL_TARGET_CT" \
      --project "$PROJECT"
  else
    log "Model disk device already present: $MODELS_DEVICE_NAME"
  fi

  log "Writing Lemonade model config inside container"
  write_container_config

  ensure_container_model_dir_writable

  log "Restarting Lemonade service"
  lxc exec "$CT_NAME" --project "$PROJECT" -- bash -lc "systemctl restart $LEMONADE_SERVICE_NAME"

  verify_counts
  verify_api

  log "Done. Open http://127.0.0.1:13305 and refresh the model list."
}

main "$@"
