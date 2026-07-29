#!/usr/bin/env bash
# plh-switch-model.sh
# Updated: exact flags per user spec, OOM auto-retry, no kv-offload, kv-quant via cache-type-k/v
# Flags: --ctx-size 65536 --batch-size 512 --spec-type draft-mtp --spec-draft-n-max 4
#        --cache-ram 8192 --cache-type-k q4_0 --cache-type-v q4_0 -ngl 99
# No --kv-offload. No autodetect GPU layers. OOM -> reduce -ngl by 2 until stable.

set -euo pipefail

MODEL_DIR="/srv/ai/models"
PROCESS_NAME="llama-server"

RED=$(tput setaf 1 || true)
GREEN=$(tput setaf 2 || true)
YELLOW=$(tput setaf 3 || true)
CYAN=$(tput setaf 6 || true)
MAGENTA=$(tput setaf 5 || true)
NC=$(tput sgr0 || true)

is_mtp_model() {
  [[ "$(basename "$1")" =~ [Mm][Tt][Pp] ]]
}

get_cache_ram_size() {
  local free_mb
  free_mb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 8192)
  local half_mb=$(( free_mb / 2 ))
  if (( half_mb > 16384 )); then
    echo 16384
  else
    echo "$half_mb"
  fi
}

# Parse the currently running process to show current settings
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

# Build the new command line with exact flags
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
    # NO --kv-offload. Use kv quant instead.
    cmd+=" --cache-type-k $kv_quant"
    cmd+=" --cache-type-v $kv_quant"
  fi

  cmd+=" --cache-ram $cache_ram"
  echo "$cmd"
}

# Check if log indicates OOM
check_oom() {
  local log="$1"
  if [[ -f "$log" ]]; then
    if grep -qE '(OOM|out.of.memory|cudaErrorOutOfMemory|alloc failed|failed to allocate)' "$log"; then
      return 0
    fi
  fi
  return 1
}

# Validate chat-completions works for the selected model.
# Some models load successfully but cannot compute logits for chat generation.
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

# Kill any existing llama-server process
kill_existing() {
  local pids
  pids=$(pgrep -f "[/]llama-server" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    echo "${YELLOW}Stopping existing llama-server processes...${NC}"
    echo "   PIDs: $pids"
    for pid in $pids; do
      kill "$pid" 2>/dev/null || true
    done
    local count=0
    local remaining
    while (( count < 15 )); do
      remaining=$(pgrep -f "[/]llama-server" 2>/dev/null || true)
      if [[ -z "$remaining" ]]; then break; fi
      sleep 1
      count=$(( count + 1 ))
    done
    remaining=$(pgrep -f "[/]llama-server" 2>/dev/null || true)
    if [[ -n "$remaining" ]]; then
      echo "${RED}Warning: Process still running, force killing...${NC}"
      for pid in $remaining; do
        kill -9 "$pid" 2>/dev/null || true
      done
      sleep 2
    fi
    remaining=$(pgrep -f "[/]llama-server" 2>/dev/null || true)
    if [[ -z "$remaining" ]]; then
      echo "${GREEN}Old process(es) stopped.${NC}"
    else
      echo "${RED}Warning: Some processes still running: $remaining${NC}"
    fi
  else
    echo "No existing llama-server process found."
  fi
}

# Start the llama-server process and handle OOM retries
start_process_with_oom_retry() {
  local model="$1" ctx="$2" initial_ngl="$3" mtp="$4" mtpn="$5" cache_ram="$6" kv_quant="$7"
  local ngl="$initial_ngl"
  local batch_size=128
  local ubatch_size=128
  local log="/var/log/llama-server.log"
  local max_attempts=50
  local attempt=0

  echo "${CYAN}Starting llama-server with OOM auto-retry...${NC}"
  echo "  Initial -ngl: $initial_ngl (keep model on GPU if possible)"
  echo "  Initial batch profile: batch=$batch_size ubatch=$ubatch_size (--no-op-offload enabled)"

  while (( attempt < max_attempts )); do
    attempt=$(( attempt + 1 ))
    echo ""
    echo "${CYAN}[Attempt $attempt] Trying with -ngl $ngl${NC}"

    # Build cmdline with current ngl
    local cmdline
    cmdline=$(build_cmdline "$model" "$ctx" "$ngl" "$mtp" "$mtpn" "$cache_ram" "$kv_quant" "$batch_size" "$ubatch_size")

    echo "${YELLOW}Command: $cmdline${NC}"

    # Kill existing
    local existing_pids
    existing_pids=$(pgrep -f "[/]llama-server" 2>/dev/null || true)
    if [[ -n "$existing_pids" ]]; then
      for pid in $existing_pids; do
        kill "$pid" 2>/dev/null || true
      done
      sleep 2
    fi

    # Start the server
    nohup $cmdline > "$log" 2>&1 &
    local pid=$!
    echo "${YELLOW}Started with PID $pid (ngl=$ngl)${NC}"

    # Wait for it to initialize (check if it's still alive after 10 seconds)
    sleep 10

    if ! kill -0 "$pid" 2>/dev/null; then
      # Process died
      if check_oom "$log"; then
        if (( batch_size > 32 )); then
          batch_size=$(( batch_size / 2 ))
          ubatch_size=$batch_size
          echo "${RED}OOM detected! Reducing batch profile to batch=$batch_size ubatch=$ubatch_size while keeping -ngl $ngl...${NC}"
        else
          echo "${RED}OOM detected! Reducing -ngl by 2...${NC}"
          ngl=$(( ngl - 2 ))
          if (( ngl < 0 )); then
            echo "${RED}ERROR: -ngl dropped below 0. Model may not fit on GPU.${NC}"
            exit 1
          fi
          echo "${YELLOW}Next attempt: -ngl $ngl${NC}"
        fi
        continue
      else
        echo "${RED}Process exited unexpectedly (not OOM). Check log:${NC}"
        tail -20 "$log"
        exit 1
      fi
    fi

    # Check log for initialization success
    if grep -qE '(starting|listening|server is ready|loaded model|speculative decoding)' "$log" 2>/dev/null; then
      local probe_try=0
      local probe_ok="no"
      while (( probe_try < 5 )); do
        probe_try=$(( probe_try + 1 ))
        if probe_chat_completions "$model"; then
          probe_ok="yes"
          break
        fi
        local probe_rc=$?
        if (( probe_rc == 2 )); then
          echo "${RED}Model is loaded but cannot serve chat completions (no logits support): $(basename "$model")${NC}"
          echo "${YELLOW}Choose a chat-capable model for /v1/chat/completions.${NC}"
          kill "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
          exit 1
        fi
        sleep 2
      done

      if [[ "$probe_ok" == "yes" ]]; then
        echo "${GREEN}✓ Server started successfully with -ngl $ngl!${NC}"
        echo "  PID: $pid"
        echo "  Log: $log"
        return 0
      fi

      echo "${RED}Server started but chat probe did not pass in time.${NC}"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      exit 1
    fi

    # Check if still running but not ready yet
    if kill -0 "$pid" 2>/dev/null; then
      echo "${YELLOW}Server still initializing...${NC}"
      sleep 5
      if check_oom "$log"; then
        if (( batch_size > 32 )); then
          batch_size=$(( batch_size / 2 ))
          ubatch_size=$batch_size
          echo "${RED}OOM detected! Reducing batch profile to batch=$batch_size ubatch=$ubatch_size while keeping -ngl $ngl...${NC}"
        else
          echo "${RED}OOM detected! Reducing -ngl by 2...${NC}"
          ngl=$(( ngl - 2 ))
          if (( ngl < 0 )); then
            echo "${RED}ERROR: -ngl dropped below 0.${NC}"
            exit 1
          fi
        fi
        continue
      fi
    fi

    # Give it one more check
    sleep 5
    if kill -0 "$pid" 2>/dev/null && grep -qE '(starting|listening|server is ready|loaded model|speculative decoding)' "$log" 2>/dev/null; then
      local probe_try=0
      local probe_ok="no"
      while (( probe_try < 5 )); do
        probe_try=$(( probe_try + 1 ))
        if probe_chat_completions "$model"; then
          probe_ok="yes"
          break
        fi
        local probe_rc=$?
        if (( probe_rc == 2 )); then
          echo "${RED}Model is loaded but cannot serve chat completions (no logits support): $(basename "$model")${NC}"
          echo "${YELLOW}Choose a chat-capable model for /v1/chat/completions.${NC}"
          kill "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
          exit 1
        fi
        sleep 2
      done

      if [[ "$probe_ok" == "yes" ]]; then
        echo "${GREEN}✓ Server started successfully with -ngl $ngl!${NC}"
        echo "  PID: $pid"
        echo "  Log: $log"
        return 0
      fi

      echo "${RED}Server started but chat probe did not pass in time.${NC}"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      exit 1
    fi

    if check_oom "$log"; then
      if (( batch_size > 32 )); then
        batch_size=$(( batch_size / 2 ))
        ubatch_size=$batch_size
        echo "${RED}OOM detected! Reducing batch profile to batch=$batch_size ubatch=$ubatch_size while keeping -ngl $ngl...${NC}"
      else
        echo "${RED}OOM detected! Reducing -ngl by 2...${NC}"
        ngl=$(( ngl - 2 ))
        if (( ngl < 0 )); then
          echo "${RED}ERROR: -ngl dropped below 0.${NC}"
          exit 1
        fi
      fi
      continue
    fi

    echo "${RED}Server failed to start. Check log for details:${NC}"
    tail -20 "$log"
    exit 1
  done

  echo "${RED}ERROR: Max retry attempts ($max_attempts) reached. Model cannot fit on GPU.${NC}"
  exit 1
}

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

# Default ngl = 99 (offload all layers possible, let retry reduce batch first)
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

# KV cache quantization (applied for MTP models, default q4_0)
echo ""
echo "${CYAN}KV Cache Quantization:${NC}"
echo "  Controls the precision of the KV cache stored in RAM."
echo "  Higher quality = more RAM usage but better context handling."
echo "  1) q4_0  (default - good balance of quality and RAM)"
echo "  2) q6_K  (higher quality, uses more RAM)"
echo "  3) q8_0  (highest quality, uses the most RAM)"

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
> /var/log/llama-server.log

# Start with OOM retry loop
start_process_with_oom_retry "$NEW_MODEL" "$NEW_CTX" "$NEW_NGL" "$NEW_MTP" "$MTP_N" "$NEW_CACHE_RAM" "$NEW_KV_QUANT"

echo ""
echo "${GREEN}Switch complete.${NC}"
echo ""
echo "Follow logs: tail -f /var/log/llama-server.log"
echo "Check status: ps aux | grep llama-server"
echo "API endpoint: curl http://127.0.0.1:80/v1/chat/completions"