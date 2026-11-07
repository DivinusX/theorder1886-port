#!/usr/bin/env bash
# Guarded synthetic input. Sends NOTHING unless the game window is the active window.
# Allowed verbs: shot (F12 screenshot), key <Space|Return|Escape|w|a|s|d>,
# move <dx> <dy>, click. Every command is appended to the input log.
# ydotool socket verified: ydotoold -p /run/user/1000/mouse-aim.sock (daemon running).
W=/var/home/Pixel/Documents/order1886-perf-work
LOG="$W/input.log"
export YDOTOOL_SOCKET=/run/user/1000/mouse-aim.sock
ACTIVE=$(kdotool getactivewindow getwindowname 2>/dev/null || true)
if [[ "$ACTIVE" != "The Order: 1886" ]]; then
    echo "$(date -Is) REFUSED active='$ACTIVE' args=$*" >> "$LOG"; exit 1
fi
case "$1" in
  shot) CMD=(key 88:1 88:0) ;;                     # KEY_F12 down/up
  key)  case "$2" in
          Space) CMD=(key 57:1 57:0);; Return) CMD=(key 28:1 28:0);;
          Escape) CMD=(key 1:1 1:0);; w) CMD=(key 17:1 17:0);;
          a) CMD=(key 30:1 30:0);; s) CMD=(key 31:1 31:0);; d) CMD=(key 32:1 32:0);;
          *) echo "key not allowed: $2" >> "$LOG"; exit 2;;
        esac ;;
  down) CMD=(keydown "$2");; up) CMD=(keyup "$2");;
  move) CMD=(mousemove --relative "$2" "$3");;
  click) CMD=(click -- 0x110);;
  *) echo "verb not allowed: $1" >> "$LOG"; exit 2;;
esac
echo "$(date -Is) SEND $* -> ydotool ${CMD[*]}" >> "$LOG"
ydotool "${CMD[@]}" 2>> "$LOG"
