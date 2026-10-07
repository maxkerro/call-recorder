#!/bin/bash
# Pull the latest code, rebuild, and reinstall CallRecorder into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

pkill CallRecorder || true
git pull
./build.sh
rm -rf /Applications/CallRecorder.app
mv CallRecorder.app /Applications
open /Applications/CallRecorder.app
