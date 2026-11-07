#!/usr/bin/env bash
# Launch one measured session of The Order 1886 port against a teststate copy.
# NEVER touches "/var/home/Pixel/Documents/The Order Linux" (read: runtime binary)
# or the game dump (read-only mounts by design).
# Usage: run.sh <label> <cold|warm> <duration_s> [extra KEY=VAL ...]
set -euo pipefail
W=/var/home/Pixel/Documents/order1886-perf-work
INSTALL="/var/home/Pixel/Documents/The Order Linux"
GAME="/var/home/Pixel/Documents/PS4/CUSA00035"
PY=/tmp/order-work/venv/bin/python
LABEL=$1; CACHE=$2; DUR=$3; shift 3
EXTRA=("$@")
RUNDIR="$W/runs/$LABEL-$(date +%H%M%S)"
STATE="$W/teststate"
mkdir -p "$RUNDIR"
BUDGET_FILE="$W/live-budget-seconds"
BUDGET_MAX=5400   # 90 minutes of live testing, hard
BUDGET=$(cat "$BUDGET_FILE" 2>/dev/null || echo 0)
if (( BUDGET + DUR + 60 > BUDGET_MAX )); then echo "LIVE BUDGET EXCEEDED ($BUDGET s used)" | tee "$RUNDIR/abort.txt"; exit 9; fi

# --- state: persistent across runs (warm) except caches when cold ---
if [[ ! -d "$STATE" ]]; then
    cp -a --reflink=auto "$W"/backup-user-*/order1886 "$STATE"
fi
mkdir -p "$STATE/gpu/native-ps4-v1"   # launcher env override only lands if the dir exists
if [[ $CACHE == cold ]]; then
    rm -rf "$STATE/gpu" "$STATE/cache" "$STATE/shader"; mkdir -p "$STATE/gpu/native-ps4-v1"
fi
# mesa driver shader cache: per-process dir, cold = fresh, warm = shared
MESA_DIR="$W/mesa-cache"
if [[ $CACHE == cold ]]; then rm -rf "$MESA_DIR"; mkdir -p "$MESA_DIR"; fi

# --- settings snapshot for this run (teststate copy only) ---
python3 - "$STATE/settings.json" << 'PYEOF'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s.update({'frame_rate': 30, 'fps_cap': 120, 'vsync': True, 'display_mode': 'borderless',
          'presentation_filter': 'fsr1', 'render_width': 1920, 'output_resolution': 'automatic',
          'sharpness': 0, 'anisotropy': 1, 'frames_queued': 1, 'async_shaders': True,
          'background_warmup': False, 'parallel_warmup': False, 'speculative_readbacks': False,
          'readbacks': 'relaxed', 'button_prompts': 'playstation', 'performance_capture': True,
          'overlay_frametime': True, 'overlay_gpu': False, 'overlay_cpu': False,
          'overlay_memory': False, 'mods_enabled': False, 'mods_dir': '', 'selected_patches': [],
          'mouse_look': True, 'mouse_sensitivity': 100, 'mouse_invert_y': False,
          'in_game_menu': False, 'game_language': 20})
json.dump(s, open(p, 'w'), indent=2)
PYEOF

# --- launch (exact flag set verified from the launcher's own session logs) ---
STOP="$RUNDIR/stop"
cd "$INSTALL"
export ORDER1886_PERF_RUNDIR="$RUNDIR"
for kv in "${EXTRA[@]}"; do export "$kv"; done
MESA_SHADER_CACHE_DIR="$MESA_DIR" \
"$PY" "$W/repo/order1886.py" \
  --game-dir "$GAME" --state-dir "$STATE" \
  --runtime "${RUNTIME_BIN:-$INSTALL/bin/order1886-runtime}" \
  --display-mode borderless --vsync 1 --show-fps 1 --presentation-filter fsr1 \
  --frame-rate 30 --aspect-ratio original --render-width 1920 \
  --mouse-look 1 --mouse-sensitivity 100 --mouse-invert-y 0 \
  --button-prompts playstation --system-language 20 --readbacks relaxed \
  --fps-cap 120 --performance-capture 1 --output-resolution automatic \
  --sharpness 0 --anisotropy 1 --frames-queued 1 \
  --overlay-frametime 1 --overlay-gpu 0 --overlay-cpu 0 --overlay-memory 0 \
  --async-shaders 1 --background-warmup 0 --parallel-warmup 0 --speculative-readbacks 0 \
  --keyboard-bindings '{}' --controller-bindings '{}' \
  --mods-dir '' --mods-enabled 0 --mods-order '[]' \
  --timeout 0 --stop-file "$STOP" > "$RUNDIR/backend.log" 2>&1 &
BACKEND=$!
sleep 6
RUNTIME=$(pgrep -P "$BACKEND" -f order1886-runtime || pgrep -f "bin/order1886-runtime" | head -1 || true)
[[ -n "${RUNTIME:-}" ]] || { echo "runtime not spawned"; kill "$BACKEND" 2>/dev/null; exit 8; }
"$PY" "$W/harness/sampler.py" "$RUNDIR/sampler.csv" "$RUNTIME" &
SAMPLER=$!

# --- watchdog: hard 10-minute cap per launch ---
(
  set +e
  END=$(( $(date +%s) + DUR ))
  while kill -0 "$BACKEND" 2>/dev/null && (( $(date +%s) < END )); do sleep 2; done
  touch "$STOP"
  for i in 1 2 3 4 5; do kill -0 "$BACKEND" 2>/dev/null || break; sleep 2; done
  kill -INT "$BACKEND" 2>/dev/null; sleep 3
  kill -INT "$RUNTIME" 2>/dev/null; sleep 3
  kill -9 "$RUNTIME" "$BACKEND" 2>/dev/null
) &
WD=$!
wait "$WD" 2>/dev/null || true
kill "$SAMPLER" 2>/dev/null || true; wait "$SAMPLER" 2>/dev/null || true
pgrep -f "bin/order1886-runtime" >/dev/null && { echo "RUNTIME STILL ALIVE - killing"; pkill -9 -f "bin/order1886-runtime"; } || true

# --- collect artifacts ---
cp -f "$STATE/logs/last-run.json" "$RUNDIR/last-run.json" 2>/dev/null || true
BOOT=$(ls -t "$STATE/logs/"*-boot.log 2>/dev/null | head -1 || true)
cp -f "$BOOT" "$RUNDIR/boot.log" 2>/dev/null || true
TR=$(ls -t "$STATE/logs/"performance-*.csv 2>/dev/null | head -1 || true)
cp -f "$TR" "$RUNDIR/trace.csv" 2>/dev/null || true
cp -f "$STATE/settings.json" "$RUNDIR/settings-used.json" 2>/dev/null || true
mkdir -p "$RUNDIR/screenshots"; find "$STATE" -maxdepth 4 -name "*.png" -newer "$RUNDIR/backend.log" -path "*hots*" -exec cp -f {} "$RUNDIR/screenshots/" \; 2>/dev/null || true
echo "$(( BUDGET + DUR ))" > "$BUDGET_FILE"
"$PY" "$W/harness/metrics.py" "$LABEL" "$RUNDIR/trace.csv" "$RUNDIR/boot.log" "$RUNDIR/sampler.csv" "$RUNDIR/metrics.json" | tail -3
echo "RUNDIR=$RUNDIR budget=$(cat "$BUDGET_FILE")s"
