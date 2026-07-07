#!/usr/bin/env bash
# Build LocalVideo.app — a real, double-clickable macOS app bundle from the SPM
# executable. The ffmpeg/libav dylibs (and their transitive Homebrew deps) are
# bundled into Contents/Frameworks and all load paths rewritten to @rpath, so the
# app is SELF-CONTAINED: it runs on any Apple Silicon Mac (macOS 13+) with no
# Homebrew/ffmpeg installed. Ad-hoc code-signed (fine for personal use; frictionless
# distribution would still need a Developer ID + notarization).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/LocalVideo.app"
BIN_NAME="LocalVideo"
MACOS="$APP/Contents/MacOS/$BIN_NAME"
FRAMEWORKS="$APP/Contents/Frameworks"

echo "==> Building release binary…"
swift build -c release --package-path "$ROOT"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$FRAMEWORKS"
cp "$ROOT/.build/release/LocalVideoNative" "$MACOS"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# ---- Bundle the libav/ffmpeg dylib closure (only what's actually loaded) --------
#
# Walk the Mach-O's non-system deps transitively, copy each real dylib into
# Frameworks under its canonical install-name, and rewrite every reference (in the
# main binary and between dylibs) from the absolute Homebrew path to @rpath. This
# pulls in exactly the used libraries — not the whole Homebrew Cellar.

# Non-system (Homebrew) dylib deps of a Mach-O file, one per line.
hb_deps() { otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E '^/opt/homebrew|^/usr/local' || true; }
# The canonical install-name basename a dylib is referenced by (its LC_ID).
id_base() { local i; i="$(otool -D "$1" 2>/dev/null | sed -n '2p')"; basename "${i:-$1}"; }

echo "==> Bundling libav dylib closure into Contents/Frameworks…"
# bash 3.2 (macOS default) has no associative arrays — use parallel indexed
# arrays (b_list = canonical basenames, s_list = source paths) + a seen-string,
# and an index-based worklist (no array slicing).
seen=" "
b_list=()
s_list=()
queue=()
while IFS= read -r d; do [ -n "$d" ] && queue+=("$d"); done < <(hb_deps "$MACOS")
qi=0
while [ "$qi" -lt "${#queue[@]}" ]; do
    dep="${queue[$qi]}"; qi=$((qi + 1))
    base="$(id_base "$dep")"
    case "$seen" in *" $base "*) continue ;; esac   # already queued this lib
    seen="$seen$base "
    b_list+=("$base"); s_list+=("$dep")
    while IFS= read -r d; do [ -n "$d" ] && queue+=("$d"); done < <(hb_deps "$dep")
done

# Copy them in (cp follows the opt→Cellar symlink to the real file).
i=0
while [ "$i" -lt "${#b_list[@]}" ]; do
    cp "${s_list[$i]}" "$FRAMEWORKS/${b_list[$i]}"
    chmod u+w "$FRAMEWORKS/${b_list[$i]}"
    i=$((i + 1))
done

# Rewrite each bundled dylib: set its id and repoint its deps to @rpath siblings.
i=0
while [ "$i" -lt "${#b_list[@]}" ]; do
    f="$FRAMEWORKS/${b_list[$i]}"
    install_name_tool -id "@rpath/${b_list[$i]}" "$f"
    while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        install_name_tool -change "$dep" "@rpath/$(id_base "$dep")" "$f" || true
    done < <(hb_deps "$f")
    install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
    i=$((i + 1))
done

# Rewrite the main binary's deps + add the rpath to Frameworks.
while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    install_name_tool -change "$dep" "@rpath/$(id_base "$dep")" "$MACOS" || true
done < <(hb_deps "$MACOS")
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS" 2>/dev/null || true

echo "==> Bundled ${#b_list[@]} dylibs ($(du -sh "$FRAMEWORKS" | cut -f1))"

# ---- Code sign (inner dylibs first, then the bundle) ----------------------------
# install_name_tool invalidates the Homebrew signatures, so re-sign everything.
echo "==> Code signing (ad-hoc)…"
for f in "$FRAMEWORKS"/*.dylib; do codesign --force --sign - --timestamp=none "$f"; done
codesign --force --sign - "$APP"

# Seed the user's config on first install (never overwrite existing data).
SUPPORT="$HOME/Library/Application Support/LocalVideo"
mkdir -p "$SUPPORT"
if [ ! -f "$SUPPORT/cameras.json" ] && [ -f "$ROOT/../cameras.json" ]; then
    cp "$ROOT/../cameras.json" "$SUPPORT/cameras.json"
    echo "==> Seeded $SUPPORT/cameras.json from the project config"
fi

echo "==> Done: $APP"
echo "    Self-contained (no Homebrew/ffmpeg needed). Launch with:  open \"$APP\""
