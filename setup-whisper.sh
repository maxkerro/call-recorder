#!/bin/bash
# One-time setup for the Whisper engine. Installs whisper.cpp + ffmpeg, makes sure whisper-server exists
# (needed for live transcription) and downloads the models:
#   large-v3-q5_0        (~1.1 GB)  most accurate; used for "Transcribe file…"
#   large-v3-turbo-q5_0  (~550 MB)  fast; used for the live transcript
#   silero VAD           (<1 MB)    skips silence/music so Whisper doesn't invent text
# Everything runs locally; no audio leaves your Mac. Safe to re-run: existing files are kept.
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required: https://brew.sh"
  exit 1
fi

brew install whisper-cpp ffmpeg

SUPPORT="$HOME/Library/Application Support/CallRecorder"
BIN_DIR="$SUPPORT/bin"
DIR="$SUPPORT/models"
mkdir -p "$DIR" "$BIN_DIR"

# Live transcription keeps the model loaded in whisper-server. Use Homebrew's if it ships one,
# otherwise build it from source (a few minutes, one time).
if [ -x "$(brew --prefix)/bin/whisper-server" ] || [ -x "$BIN_DIR/whisper-server" ]; then
  echo "whisper-server found."
else
  echo "whisper-server is not part of the Homebrew package here; building it from source…"
  brew install cmake
  SRC="$(mktemp -d)/whisper.cpp"
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp "$SRC"
  cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_SERVER=ON
  cmake --build "$SRC/build" --config Release -j --target whisper-server
  cp "$SRC/build/bin/whisper-server" "$BIN_DIR/whisper-server"
  echo "Built $BIN_DIR/whisper-server"
fi

download() {  # download <url> <file name> <description>
  if [ -f "$DIR/$2" ]; then
    echo "Already present: $2"
  else
    echo "Downloading $2 ($3)…"
    curl -L --fail --progress-bar -C - -o "$DIR/$2.part" "$1"
    mv "$DIR/$2.part" "$DIR/$2"
  fi
}

HF="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
download "$HF/ggml-large-v3-q5_0.bin" "ggml-large-v3-q5_0.bin" "~1.1 GB, most accurate"
download "$HF/ggml-large-v3-turbo-q5_0.bin" "ggml-large-v3-turbo-q5_0.bin" "~550 MB, fast, for live"
download "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" \
         "ggml-silero-v5.1.2.bin" "<1 MB, silence detection"

echo
echo "Done. Reopen CallRecorder and pick 'Whisper' as the engine."
echo "Tip: use the app's 'Vocabulary…' button to add names and terms you want spelled correctly."
