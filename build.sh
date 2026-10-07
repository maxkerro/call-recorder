#!/bin/bash
# Builds "CallRecorder.app" next to this script. Needs Xcode 16+ (or its command line tools) on macOS 15.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v ffmpeg >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/ffmpeg ] && [ ! -x /usr/local/bin/ffmpeg ]; then
  echo "ffmpeg is needed for MP3 encoding. Install it with:  brew install ffmpeg"
fi

swift build -c release
APP="CallRecorder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CallRecorder "$APP/Contents/MacOS/CallRecorder"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier local.maxm.CallRecorder "$APP"
echo "Built: $(pwd)/$APP"
echo "Move it to /Applications, open it, and grant the permission prompts."
