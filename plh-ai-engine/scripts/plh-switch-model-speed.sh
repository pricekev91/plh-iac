#!/usr/bin/env bash
# plh-switch-model.sh
# Integrated: binary-search ngl probe, 1s polling, per-model ngl cache, LXC GPU userspace diagnostic
# Updated: 2026-07-29
set -euo pipefail

MODEL_DIR="/srv/ai/models"
PROCESS_NAME="llama-server"
LOG="/var/log/llama-server.log"
CACHE_DIR="/var/lib/plh-switch-model/cache"

RED=$(tput setaf 1 || true)
GREEN=$(tput setaf 2 || true)
YELLOW=$(tput setaf 3 || true)
CYAN=$(tput setaf 6 || true)
MAGENTA=$(tput setaf 5 || true)
NC=$(tput sgr0 || true)

mkdir -p "$CACHE_DIR"
chmod 755 "$CACHE_DIR" || true

is_mtp_model() {
  [[ "$(basename "$1")" =~ [Mm][Tt][Pp] ]]
}

get_cache_ram_size() {
  local free_kb
  free_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 8388608)
  local free_mb=$(( free_kb / 1024 ))
  local half_mb=$(( free_mb / 2 ))
  if (( half_mb > 16384 )); then
    echo 16384
  else
    echo "$half_mb"
  fi
}

parse_current_process() {
  local cmdline
  cmdline=$(ps -o args= -C llama-server 2>/dev/null || true)
  if [[ -z "$cmdline" ]]; then
    CUR_MODEL="none (not running)"
    CUR_CTX="unknown"
    CUR_NGL="unknown"
    CUR_CACHE_RAM="unknown"
    CUR_MTP="no"
    CUR_MTP_N="n/a"
    IS_RUNNING="no"
    return
  fi

  IS_RUNNING="yes"
  CUR_MODEL=$(grep -oP '(?<=--model )\S+' <<< "$cmdline" | head -n1 || echo "unknown")
  CUR_CTX=$(grep -oP '(?<=--ctx-size )\S+' <<< "$cmdline" | head -n1 || echo "unknown")
  CUR_NGL=$(grep -oP '(?<=-ngl )\S+' <<< "$cmdline" | head -n1 || echo "unknown")
  CUR_CACHE_RAM=$(grep -oP '(?<=--cache-ram )\S+' <<< "$cmdline" | head -n1 || echo "unknown")

  if grep -q -- '--spec-type draft-mtp' <<< "$cmdline"; then
    CUR_MTP="yes"
    CUR_MTP_N=$(grep -oP '(?<=--spec-draft-n-max )\S+' <<< "$cmdline" | head -n1 || echo "?")
  else
    CUR_MTP="no"
    CUR_MTP_N="n/a"
  fi
}

build_cmdline() {
  local model="$1" ctx="$2" ngl="$3" mtp="$4" mtpn="$5" cache_ram="$6" kv_quant="$7" batch_size="$8" ubatch_size="$9"

  local cmd="/opt/llama.cpp/build/bin/llama-server"
  cmd+=" --host 127.0.0.1 --port 80"
  cmd+=" --model $model"
  cmd+=" --ctx-size $ctx"
  cmd+=" -ngl $ngl"
  cmd+=" --batch-size $batch_size"
  cmd+=" --ubatch-size $ubatch_size"
  cmd+=" --no-op-offload"

  if [[ "$mtp" == "1" ]]; then
    cmd+=" --spec-type draft-mtp"
    cmd+=" --spec-draft-n-max $mtpn"
    cmd+=" --cache-type-k $kv_quant"
    cmd+=" --cache-type-v $kv_quant"
  fi

  cmd+=" --cache-ram $cache_ram"
  echo "$cmd"
}

check_oom() {
  local log="$1"
  if [[ -f "$log" ]]; then
    if grep -qE '(OOM|out.of.memory|cudaErrorOutOfMemory|alloc failed|failed to allocate)' "$log"; then
      return 0
    fi
  fi
  return 1
}

probe_chat_completions() {
  local model_path="$1"
  local model_name
  model_name="$(basename "$model_path")"

  local payload
  payload=$(cat <<EOF
{"model":"$model_name","messages":[{"role":"user","content":"reply with ok"}],"temperature":0,"max_tokens":4}
EOF
)

  local resp
  resp=$(curl -sS --max-time 15 http://127.0.0.1:80/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>&1 || true)

  if grep -qi 'does not logits computation' <<< "$resp"; then
    return 2
  fi

  if grep -q '"choices"' <<< "$resp"; then
    return 0
  fi

  if grep -q '"error"' <<< "$resp"; then
    return 3
  fi

  return 4
}

kill_existing() {
  local pids
  pids=$(pgrep -f "[/]llama-server" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    for pid in $pids; do
      kill "$pid" 2>/dev/null || true
    done
    local count=0
    while (( count < 15 )); do
      remaining=$(pgrep -f "[/]llama-server" 2>/dev/null || true)
      if [[ -z "$remaining" ]]; then break; fi
      sleep 1
      count=$(( count + 1 ))
    done
    remaining=$(pgrep -f "[/]llama-server" 2>/dev/null || true)
    if [[ -n "$remaining" ]]; then
      for pid in $remaining; do
        kill -9 "$pid" 2>/dev/null || true
      done
      sleep 2
    fi
  fi
}

# Diagnostic helper: checks for NVML and nvidia-smi presence and suggests bind-mounts
gpu_userspace_diagnostic() {
  echo ""
  echo "${CYAN}GPU userspace diagnostic${NC}"
  echo "Checking for nvidia-smi and NVML libraries inside container..."
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "${GREEN}nvidia-smi found inside container.${NC}"
    nvidia-smi -L || true
  else
    echo "${YELLOW}nvidia-smi not found inside container.${NC}"
  fi

  echo ""
  echo "Looking for libcuda and libnvidia-ml inside container..."
  ldconfig -p | grep -i 'libnvidia-ml' || true
  ldconfig -p | grep -i 'libcuda' || true

  echo ""
  echo "On the host, run these to find the exact files to bind-mount:"
  echo "  which nvidia-smi"
  echo "  find / -xdev -name 'libnvidia-ml.so*' 2>/dev/null"
  echo "  find / -xdev -name 'libcuda.so*' 2>/dev/null"
  echo ""
  echo "Then bind-mount the host files into the container (preserve paths) instead of apt-installing mismatched nvidia-utils."
  echo ""
}

# New: binary-search ngl probe with 1s polling and per-model cache
start_process_with_oom_retry() {
  local model="$1" ctx="$2" initial_ngl="$3" mtp="$4" mtpn="$5" cache_ram="$6" kv_quant="$7"
  local model_key
  model_key="$(basename "$model")-ctx${ctx}"
  local cached_file="$CACHE_DIR/${model_key}.ngl"

  # Always start blind at 99 for uncached models
  local low=0
  local high=99
  local probe_batch=32
  local probe_ubatch=32
  local final_batch=128
  local final_ubatch=128

  echo "${CYAN}Starting llama-server with binary-search ngl probe...${NC}"
  echo "  Probe batch profile: batch=$probe_batch ubatch=$probe_ubatch"
  echo "  Poll interval: 1s"

  local best_ok=-1
  local attempts=0
  local max_attempts=14

  # If cached value exists, we still probe full range but will restart at cached best if found
  if [[ -f "$cached_file" ]]; then
    echo "${YELLOW}Found cached ngl for ${model_key}: $(cat "$cached_file" 2>/dev/null)${NC}"
  fi

  while (( low <= high )) && (( attempts < max_attempts )); do
    attempts=$(( attempts + 1 ))
    local mid=$(( (low + high) / 2 ))
    local ngl=$mid

    echo ""
    echo "${CYAN}[Probe $attempts] Trying -ngl $ngl (range ${low}-${high})${NC}"
    local cmdline
    cmdline=$(build_cmdline "$model" "$ctx" "$ngl" "$mtp" "$mtpn" "$cache_ram" "$kv_quant" "$probe_batch" "$probe_ubatch")
    echo "${YELLOW}Command: $cmdline${NC}"

    kill_existing
    : > "$LOG"
    nohup $cmdline > "$LOG" 2>&1 &
    local pid=$!
    echo "${YELLOW}Started with PID $pid (ngl=$ngl)${NC}"

    # Poll every second for a short window
    local poll=0
    local ready="no"
    while (( poll < 20 )); do
      sleep 1
      poll=$(( poll + 1 ))

      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi

      if grep -qE '(starting|listening|server is ready|loaded model|speculative decoding)' "$LOG" 2>/dev/null; then
        if probe_chat_completions "$model"; then
          ready="yes"
          break
        fi
      fi
    done

    if [[ "$ready" == "yes" ]]; then
      echo "${GREEN}Probe succeeded at -ngl $ngl${NC}"
      best_ok=$ngl
      # try higher values
      low=$(( ngl + 1 ))
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      continue
    fi

    # If process died, check log for OOM
    if ! kill -0 "$pid" 2>/dev/null; then
      if check_oom "$LOG"; then
        echo "${RED}OOM detected at -ngl $ngl${NC}"
        high=$(( ngl - 1 ))
        # If ngl==0 and still OOM, try batch fallback reductions
        if (( ngl == 0 )); then
          echo "${YELLOW}ngl reached 0 and still OOM. Trying batch reductions as fallback.${NC}"
          local fallback_batch=32
          local fallback_ubatch=32
          local fallback_ok="no"
          while (( fallback_batch >= 1 )); do
            echo "${YELLOW}Fallback attempt with batch=$fallback_batch ubatch=$fallback_ubatch${NC}"
            cmdline=$(build_cmdline "$model" "$ctx" 0 "$mtp" "$mtpn" "$cache_ram" "$kv_quant" "$fallback_batch" "$fallback_ubatch")
            : > "$LOG"
            nohup $cmdline > "$LOG" 2>&1 &
            local fpid=$!
            sleep 2
            if kill -0 "$fpid" 2>/dev/null; then
              if grep -qE '(starting|listening|server is ready|loaded model|speculative decoding)' "$LOG" 2>/dev/null; then
                if probe_chat_completions "$model"; then
                  fallback_ok="yes"
                  best_ok=0
                  kill "$fpid" 2>/dev/null || true
                  wait "$fpid" 2>/dev/null || true
                  break
                fi
              fi
            fi
            kill "$fpid" 2>/dev/null || true
            wait "$fpid" 2>/dev/null || true
            fallback_batch=$(( fallback_batch / 2 ))
            fallback_ubatch=$fallback_batch
          done

          if [[ "$fallback_ok" == "yes" ]]; then
            echo "${GREEN}Fallback batch reduction succeeded at batch=$fallback_batch${NC}"
            break
          fi
        fi
      else
        echo "${RED}Process exited unexpectedly (not OOM). Tail of log:${NC}"
        tail -n 40 "$LOG"
        exit 1
      fi
    else
      # still running but probe didn't succeed
      echo "${YELLOW}Server still running but probe failed. Treating as failure for this probe.${NC}"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      high=$(( ngl - 1 ))
    fi
  done

  if (( best_ok >= 0 )); then
    echo "${GREEN}Final best -ngl found: $best_ok${NC}"
    echo "$best_ok" > "$cached_file"
    local final_cmd
    final_cmd=$(build_cmdline "$model" "$ctx" "$best_ok" "$mtp" "$mtpn" "$cache_ram" "$kv_quant" "$final_batch" "$final_ubatch")
    echo "${YELLOW}Starting final server with -ngl $best_ok and batch=$final_batch${NC}"
    nohup $final_cmd > "$LOG" 2>&1 &
    echo "${GREEN}✓ Server started with -ngl $best_ok. Log: $LOG${NC}"
    return 0
  fi

  echo "${RED}ERROR: Could not find any working -ngl in range 0-99. Model may not fit on GPU.${NC}"
  exit 1
}

# Main interactive flow (keeps your original UX)
echo ""
echo "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo "${CYAN}║                     plh-switch-model.sh                          ║${NC}"
echo "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

parse_current_process

echo "${YELLOW}Model directory :${NC} $MODEL_DIR"
echo "${YELLOW}Currently active:${NC} ${CUR_MODEL}"
echo "${YELLOW}ctx-size        :${NC} ${CUR_CTX}"
echo "${YELLOW}ngl             :${NC} ${CUR_NGL}"
echo "${YELLOW}Cache RAM       :${NC} ${CUR_CACHE_RAM}"
echo "${YELLOW}MTP mode        :${NC} ${CUR_MTP}"
echo "${YELLOW}MTP tokens      :${NC} ${CUR_MTP_N}"
if [[ "$IS_RUNNING" == "yes" ]]; then
  echo "${GREEN}Status: RUNNING${NC}"
else
  echo "${RED}Status: NOT RUNNING${NC}"
fi
echo ""

mapfile -t MODELS < <(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' | sort)
if [[ "${#MODELS[@]}" -eq 0 ]]; then
  echo "${RED}ERROR: No .gguf models found in ${MODEL_DIR}${NC}"
  exit 1
fi

echo "${CYAN}Available models:${NC}"
for i in "${!MODELS[@]}"; do
  if is_mtp_model "${MODELS[$i]}"; then
    printf "  ${GREEN}%2d${NC}) %s ${MAGENTA}[MTP]${NC}\n" $((i+1)) "${MODELS[$i]}"
  else
    printf "  ${GREEN}%2d${NC}) %s\n" $((i+1)) "${MODELS[$i]}"
  fi
done

read -rp "${CYAN}Select model number:${NC} " CHOICE
if ! [[ "${CHOICE:-}" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#MODELS[@]} )); then
  echo "${RED}ERROR: Invalid model selection.${NC}"
  exit 1
fi
NEW_MODEL="${MODELS[$((CHOICE-1))]}"

echo ""
echo "${CYAN}Context size options:${NC}"
echo "  1) 131072"
echo "  2) 98304"
echo "  3) 73728"
echo "  4) 65536 (default)"
echo "  5) 32768"
echo "  6) 16384"
echo "  7) Custom"

read -rp "Select ctx-size [default 65536]: " CTX_CHOICE
case "${CTX_CHOICE:-4}" in
  1) NEW_CTX=131072 ;;
  2) NEW_CTX=98304 ;;
  3) NEW_CTX=73728 ;;
  4) NEW_CTX=65536 ;;
  5) NEW_CTX=32768 ;;
  6) NEW_CTX=16384 ;;
  7)
    read -rp "Enter custom ctx-size: " NEW_CTX
    ;;
  *) NEW_CTX=65536 ;;
esac

NEW_CACHE_RAM=$(get_cache_ram_size)

NEW_NGL=99

echo "${YELLOW}Running mode:${NC} GPU-first mode (ngl=99, ctx in RAM, reduce batch before GPU layers)"
echo "${YELLOW}System RAM for KV cache:${NC} ${NEW_CACHE_RAM} MiB"

if is_mtp_model "$NEW_MODEL"; then
  echo ""
  echo "${CYAN}MTP model detected.${NC}"
  echo "Select number of draft tokens (2-6)."

  while true; do
    read -rp "MTP draft tokens [default 4]: " MTP_N
    MTP_N="${MTP_N:-4}"
    if [[ "$MTP_N" =~ ^[2-6]$ ]]; then break; fi
    echo "${RED}Invalid. Must be 2-6.${NC}"
  done

  NEW_MTP="yes"
else
  NEW_MTP="no"
  MTP_N="0"
fi

echo ""
echo "${CYAN}KV Cache Quantization:${NC}"
echo "  1) q4_0  (default)"
echo "  2) q6_K"
echo "  3) q8_0"

read -rp "Select KV cache quant [default q4_0]: " KV_CHOICE
case "${KV_CHOICE:-1}" in
  1) NEW_KV_QUANT="q4_0" ;;
  2) NEW_KV_QUANT="q6_K" ;;
  3) NEW_KV_QUANT="q8_0" ;;
  *) NEW_KV_QUANT="q4_0" ;;
esac

echo ""
echo "${CYAN}Summary:${NC}"
echo "  Model       : $(basename "$NEW_MODEL")"
echo "  ctx-size    : $NEW_CTX"
echo "  ngl         : $NEW_NGL (will keep GPU layers high until low batch is exhausted)"
echo "  Batch       : 128"
echo "  UBatch      : 128"
echo "  Cache RAM   : ${NEW_CACHE_RAM} MiB"
echo "  KV Quant    : $NEW_KV_QUANT"
echo "  MTP mode    : $NEW_MTP"
[[ "$NEW_MTP" == "yes" ]] && echo "  MTP tokens  : $MTP_N"
echo ""

read -rp "Apply and restart? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

# Kill existing process
kill_existing

# Clear old log
: > "$LOG"

# Run a quick GPU userspace diagnostic to help with LXC issues
gpu_userspace_diagnostic

# Start with OOM retry loop (binary-search ngl)
start_process_with_oom_retry "$NEW_MODEL" "$NEW_CTX" "$NEW_NGL" "$NEW_MTP" "$MTP_N" "$NEW_CACHE_RAM" "$NEW_KV_QUANT"

echo ""
echo "${GREEN}Switch complete.${NC}"
echo ""
echo "Follow logs: tail -f $LOG"
echo "Check status: ps aux | grep llama-server"
echo "API endpoint: curl http://127.0.0.1:80/v1/chat/completions"
