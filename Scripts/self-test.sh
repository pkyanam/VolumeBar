#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -x VolumeBar >/dev/null; then
    echo "Quit VolumeBar before running the isolated audio self-test."
    exit 1
fi
mkdir -p artifacts
open "$HOME/Applications/VolumeBar.app" --args --self-test --report "$PWD/artifacts/integration-test.json"
echo "The test runs briefly and quits. Results: $PWD/artifacts/integration-test.json"
