#!/bin/bash
# measure_cpu.sh — measure sustained CPU of the LocalVideo app + its ffmpeg children.
#
# Method: build the RELEASE binary, launch it, let streams stabilize (warmup),
# then measure the *cumulative CPU-time delta* over a fixed window and divide by
# wall-clock — a noise-robust average %CPU (vs. ps's decaying instantaneous %cpu).
# Reports the app process and the summed ffmpeg children separately so each
# optimization can be attributed correctly.
#
# Usage: measure_cpu.sh <label> [warmup_s] [window_s]
set -u
ROOT="/Users/franciscocollarte/Documents/localvideo"
LABEL="${1:-run}"
WARMUP="${2:-25}"
WINDOW="${3:-60}"
BIN="$ROOT/native/.build/release/LocalVideoNative"

[ -x "$BIN" ] || { echo "ERROR: release binary missing — run: swift build -c release --package-path $ROOT/native" >&2; exit 1; }

# Cumulative CPU seconds for one pid (0 if gone). Handles HH:MM:SS / MM:SS.ss.
cputime_secs() {
  local t; t=$(ps -o cputime= -p "$1" 2>/dev/null | tr -d ' ')
  [ -z "$t" ] && { echo 0; return; }
  awk -v s="$t" 'BEGIN{n=split(s,a,":"); v=0;
    if(n==3) v=a[1]*3600+a[2]*60+a[3]; else if(n==2) v=a[1]*60+a[2]; else v=a[1];
    printf "%.2f", v}'
}

# Echo "appSecs ffmpegSecs childPids" for the app and its direct ffmpeg children.
group_cputime() {
  local app="$1" kids a f=0 k
  kids=$(pgrep -P "$app" 2>/dev/null)
  a=$(cputime_secs "$app")
  for k in $kids; do f=$(awk -v x="$f" -v y="$(cputime_secs "$k")" 'BEGIN{printf "%.2f", x+y}'); done
  echo "$a $f $kids"
}

# Make sure no stale instance or orphaned ffmpeg skews the run.
# "dump_extra=freq=keyframe" is a credential-free signature unique to this app's ffmpeg.
pkill -f "release/LocalVideoNative" 2>/dev/null
pkill -f "dump_extra=freq=keyframe" 2>/dev/null
sleep 1

cd "$ROOT"
"$BIN" cameras.json >/dev/null 2>&1 &
APP=$!
sleep "$WARMUP"

if ! kill -0 "$APP" 2>/dev/null; then echo "$LABEL  ERROR: app exited during warmup" >&2; exit 1; fi

read -r A0 F0 _ <<< "$(group_cputime "$APP")"
sleep "$WINDOW"
read -r A1 F1 KIDS <<< "$(group_cputime "$APP")"

# Cleanup: app + its (possibly reconnected) ffmpeg children + any orphans.
kill "$APP" 2>/dev/null
for k in $KIDS; do kill "$k" 2>/dev/null; done
sleep 1
pkill -f "release/LocalVideoNative" 2>/dev/null
pkill -f "dump_extra=freq=keyframe" 2>/dev/null

awk -v a0="$A0" -v a1="$A1" -v f0="$F0" -v f1="$F1" -v w="$WINDOW" -v l="$LABEL" 'BEGIN{
  app=(a1-a0)/w*100; ff=(f1-f0)/w*100;
  printf "%-16s app=%6.1f%%  ffmpeg=%6.1f%%  total=%6.1f%%\n", l, app, ff, app+ff}'
