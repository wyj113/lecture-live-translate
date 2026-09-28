#!/bin/bash
# Builds ./livetrans. Info.plist is embedded so macOS can show the
# microphone / speech-recognition permission prompts for a command-line tool.
# Needs whisper.cpp from Homebrew: brew install whisper-cpp
set -euo pipefail
cd "$(dirname "$0")"
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
WHISPER="$BREW/opt/whisper.cpp"
GGML="$BREW/opt/ggml"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos26.0 ${SWIFTFLAGS:-} \
  -import-objc-header Sources/whisper-bridge.h -I "$WHISPER/include" -I "$GGML/include" \
  -L "$WHISPER/lib" -lwhisper -Xlinker -rpath -Xlinker "$WHISPER/lib" \
  -L "$GGML/lib" -lggml -Xlinker -rpath -Xlinker "$GGML/lib" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist \
  Sources/livetrans.swift -o livetrans
echo "✅ built $(pwd)/livetrans"
