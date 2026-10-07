#!/bin/bash
# One-time setup for the Whisper engine: installs whisper.cpp + ffmpeg and downloads a model.
# Model: large-v3-turbo, 5-bit quantized (~550 MB) — near-best accuracy for English, German and Russian,
# and fast on Apple Silicon. Everything runs locally; no audio leaves your Mac.
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required: https://brew.sh"
  exit 1
fi

brew install whisper-cpp ffmpeg

DIR="$HOME/Library/Application Support/CallRecorder/models"
MODEL="ggml-large-v3-turbo-q5_0.bin"
mkdir -p "$DIR"

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
