#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -x VolumeBar >/dev/null; then
  echo 'Quit VolumeBar from its menu, then run make install again.' >&2
  exit 1
fi
# Choose this Mac's architecture for local development; CI releases default to arm64.
export ARCH="${ARCH:-$(uname -m)}"
./Scripts/build.sh
mkdir -p "$HOME/Applications"
ditto dist/VolumeBar.app "$HOME/Applications/VolumeBar.app"
open "$HOME/Applications/VolumeBar.app" --args --show
