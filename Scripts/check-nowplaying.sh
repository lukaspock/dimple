#!/bin/bash
# Quick check that the bundled mediaremote-adapter can read system Now Playing on this Mac.
# Usage: Scripts/check-nowplaying.sh [path/to/Dimple.app]   (default: bundled copy in Dimple/Resources)
# Read-only: runs `test`, `get` and a 4 s `stream`; never sends playback commands.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ $# -ge 1 ]; then
  APP="$1"; PL="$APP/Contents/Resources/mediaremote-adapter.pl"; FW="$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
else
  PL="$HERE/Dimple/Resources/MediaRemote/mediaremote-adapter.pl"; FW="$HERE/Dimple/Resources/MediaRemote/MediaRemoteAdapter.framework"
fi
[ -f "$PL" ] && [ -d "$FW" ] || { echo "adapter not found ($PL / $FW)"; exit 2; }
echo "macOS $(sw_vers -productVersion)"; echo "== codesign =="; codesign --verify --strict "$FW" && echo "framework signature OK"
echo "== test =="; /usr/bin/perl "$PL" "$FW" test && echo "entitled: yes" || echo "entitled: NO (exit $?)"
echo "== get (no artwork) =="; /usr/bin/perl "$PL" "$FW" get --micros --no-artwork
echo "== stream (4 s, no artwork) =="
/usr/bin/perl "$PL" "$FW" stream --micros --no-artwork & PID=$!
sleep 4; kill $PID 2>/dev/null; wait $PID 2>/dev/null
echo "(empty payload / null = nothing is registered as Now Playing)"
