#!/bin/bash
# One-time setup for the Whisper engine: installs whisper.cpp + ffmpeg, makes sure whisper-server exists
# (needed for live transcription), and downloads a model.
# Model: large-v3-turbo, 5-bit quantized (~550 MB) — near-best accuracy for English, German and Russian,
# and fast on Apple Silicon. Everything runs locally; no audio leaves your Mac.
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required: https://brew.sh"
  exit 1
fi

brew install whisper-cpp ffmpeg

SUPPORT="$HOME/Library/Application Support/CallRecorder"
BIN_DIR="$SUPPORT/bin"
DIR="$SUPPORT/models"
MODEL="ggml-large-v3-turbo-q5_0.bin"
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

if [ -f "$DIR/$MODEL" ]; then
  echo "Model already present: $DIR/$MODEL"
else
  echo "Downloading $MODEL (~550 MB)…"
  curl -L --fail --progress-bar -C - \
    -o "$DIR/$MODEL.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"
  mv "$DIR/$MODEL.part" "$DIR/$MODEL"
fi

echo
echo "Done. Whisper is ready. Reopen CallRecorder and pick 'Whisper' as the engine."
