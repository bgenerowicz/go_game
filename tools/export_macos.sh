#!/bin/zsh
# Builds build/macos/go_game.app: a release export with the KataGo networks and
# analysis config bundled inside it, ad-hoc signed so it runs on this Mac.
#
#   tools/export_macos.sh            # export now (also run by .githooks/post-commit)
#
# The KataGo binary itself is not bundled: the app finds Homebrew's
# /opt/homebrew/bin/katago first (brew install katago). The networks and config
# go in Contents/Resources/engine/, which is where an exported app looks.
set -euo pipefail

ROOT="${0:A:h:h}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
OUT_DIR="$ROOT/build/macos"
APP="$OUT_DIR/go_game.app"
LOCK="$OUT_DIR/.export.lock"

mkdir -p "$OUT_DIR"
# One export at a time: commits in quick succession must not race.
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "export already running; skipping"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

echo "== $(date '+%Y-%m-%d %H:%M:%S') exporting $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
for f in engine/models/main.bin.gz engine/models/human.bin.gz engine/analysis.cfg; do
  [[ -f "$ROOT/$f" ]] || { echo "missing $f (see tools/README.md)"; exit 1; }
done

# Export to a temporary bundle and swap it in at the end, so a failed export
# never leaves a half-written app where the working one was.
TMP_APP="$OUT_DIR/go_game.new.app"
rm -rf "$TMP_APP"
"$GODOT" --headless --path "$ROOT" --export-release "macOS" "$TMP_APP" 2>&1 \
  | grep -E "ERROR|failed" || true
[[ -x "$TMP_APP/Contents/MacOS/go_game" ]] || { echo "export failed: no app produced"; exit 1; }

RES="$TMP_APP/Contents/Resources/engine"
mkdir -p "$RES/models"
# cp -c makes APFS clones: the 200 MB of networks cost no extra disk space.
cp -c "$ROOT/engine/models/main.bin.gz" "$ROOT/engine/models/human.bin.gz" "$RES/models/"
cp -c "$ROOT/engine/analysis.cfg" "$RES/"

# Adding files invalidates the export's signature; sign the whole bundle again.
codesign --force --deep --sign - "$TMP_APP" >/dev/null 2>&1
codesign --verify --deep "$TMP_APP"

rm -rf "$APP"
mv "$TMP_APP" "$APP"
echo "== built $APP ($(du -sh "$APP" | cut -f1))"
