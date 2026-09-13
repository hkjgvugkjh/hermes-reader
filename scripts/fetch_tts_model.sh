#!/usr/bin/env bash
# Downloads a small Chinese offline TTS model (Piper, via sherpa-onnx) into
# assets/tts/ so the reader can narrate without a system TTS engine or network.
#
# Requires `sherpa-onnx` to be added to pubspec.yaml and the model files placed
# under assets/tts/ (model.onnx, tokens.txt, model.onnx.json).
#
# Usage: scripts/fetch_tts_model.sh [target_dir]
set -euo pipefail

TARGET="${1:-assets/tts}"
mkdir -p "$TARGET"

# Piper Chinese model (zh_CN-huayan-x_low, ~40MB, good quality, fast).
# Hosted on the sherpa-onnx release assets mirror.
BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"
MODEL="piper-zh_CN-huayan-x_low"
ZIP="$MODEL.tar.bz2"

echo "Downloading $MODEL ..."
curl -L -o "/tmp/$ZIP" "$BASE/$ZIP"

echo "Extracting into $TARGET ..."
tar -xjf "/tmp/$ZIP" -C /tmp

SRC="/tmp/$MODEL"
# Normalize whatever the upstream tarball calls the model into the names the
# reader expects (model.onnx / tokens.txt / model.onnx.json).
cp "$SRC"/*.onnx "$TARGET/model.onnx"
cp "$SRC"/*tokens*.txt "$TARGET/tokens.txt" 2>/dev/null || true
cp "$SRC"/*.json "$TARGET/model.onnx.json" 2>/dev/null || true

echo "Done. Files in $TARGET:"
ls -lh "$TARGET"
echo
echo "assets/tts/ is already declared in pubspec.yaml; rebuild the app to bundle it."
