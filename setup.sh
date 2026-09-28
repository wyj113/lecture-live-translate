#!/bin/bash
# One-time setup: whisper.cpp from Homebrew, the Whisper and VAD models, then the build.
set -euo pipefail
cd "$(dirname "$0")"

command -v brew >/dev/null || { echo "需要 Homebrew / Homebrew is required: https://brew.sh"; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "需要 Xcode 命令行工具 / Xcode Command Line Tools are required: xcode-select --install"; exit 1; }

brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp

mkdir -p models
download() {  # file name, URL
  if [ -f "models/$1" ]; then
    echo "✓ models/$1"
    return
  fi
  echo "下载 / downloading $1 …"
  curl -L --fail -o "models/$1.part" "$2"
  mv "models/$1.part" "models/$1"
}
download ggml-large-v3-turbo-q5_0.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
download ggml-silero-v5.1.2.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin

./build.sh

echo
echo "可选：装成全局命令 / optional, install as a global command:"
echo "  ln -sf \"$(pwd)/livetrans\" \"$(brew --prefix)/bin/livetrans\""
