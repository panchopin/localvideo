#!/bin/bash
# smoke_test.sh — basic scriptable smoke tests for the LocalVideo app.
#
# Deterministic and camera-INDEPENDENT: uses unroutable TEST-NET-1 hosts
# (192.0.2.0/24, RFC 5737) so no real camera is needed and nothing ever connects.
# Verifies: the app builds, launches without crashing, shows its window, and that
# the per-camera "Show video stream" flag yields the correct shown-camera count
# (incl. backward-compat when the key is absent).
#
# The app reports its shown count via the LOCALVIDEO_SMOKE=1 stderr seam
# ("SHOWN_CAMERAS=<n>"). Requires a logged-in macOS GUI session (the app and
# CGWindowList need a window server). A GUI window briefly appears per case.
#
# Usage: bash tools/smoke_test.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/native/.build/debug/LocalVideoNative"
TMP="$(mktemp -d)"
PROBE=""
FAILED=0

cleanup() { pkill -f "debug/LocalVideoNative" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

echo "== build =="
swift build --package-path "$ROOT/native" 2>&1 | tail -2
[ -x "$BIN" ] || { fail "build produced no binary"; exit 1; }
pass "build"

# Window probe (optional assertion — skipped if it can't compile).
if swiftc -O "$ROOT/tools/window_probe.swift" -o "$TMP/window_probe" 2>/dev/null; then
    PROBE="$TMP/window_probe"
fi

# run_case <label> <config-file> <expected-shown-count>
run_case() {
    local label="$1" cfg="$2" want="$3"
    pkill -f "debug/LocalVideoNative" 2>/dev/null; sleep 1
    local err="$TMP/err_$label.txt"
    LOCALVIDEO_SMOKE=1 "$BIN" "$cfg" >/dev/null 2>"$err" &
    local pid=$!
    sleep 6
    if ! kill -0 "$pid" 2>/dev/null; then fail "$label: app crashed/exited during launch"; return; fi

    local got
    got=$(grep -o 'SHOWN_CAMERAS=[0-9]*' "$err" | tail -1 | cut -d= -f2)
    if [ "$got" = "$want" ]; then pass "$label: SHOWN_CAMERAS=$got"; else fail "$label: SHOWN_CAMERAS=${got:-<none>} (want $want)"; fi

    if [ -n "$PROBE" ]; then
        local wp; wp=$("$PROBE")
        if echo "$wp" | grep -q '^FOUND'; then pass "$label: window shown ($wp)"; else fail "$label: no app window ($wp)"; fi
    fi
    kill "$pid" 2>/dev/null
}

# Case 1: 3 cameras, one with showVideoStream:false → grid shows 2.
cat > "$TMP/hidden.json" <<'JSON'
{"cameras":[
 {"name":"A","url":"rtsp://192.0.2.1/a"},
 {"name":"B","url":"rtsp://192.0.2.2/b","showVideoStream":false},
 {"name":"C","url":"rtsp://192.0.2.3/c"}
]}
JSON
run_case "hidden-1-of-3" "$TMP/hidden.json" 2

# Case 2: backward-compat — no showVideoStream keys → all shown.
cat > "$TMP/legacy.json" <<'JSON'
{"cameras":[
 {"name":"A","url":"rtsp://192.0.2.1/a"},
 {"name":"B","url":"rtsp://192.0.2.2/b"}
]}
JSON
run_case "backcompat-all-shown" "$TMP/legacy.json" 2

echo
if [ "$FAILED" = 0 ]; then echo "ALL SMOKE TESTS PASSED"; else echo "SMOKE TESTS FAILED"; fi
exit $FAILED
