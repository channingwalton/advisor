#!/bin/sh
# Symlink whisper.cpp headers into the CWhisper shim target (flat dir so
# quoted includes like "ggml.h" resolve), assuming vendor/whisper.cpp is built.
set -e
cd "$(dirname "$0")"
W=../vendor/whisper.cpp
DEST=Sources/CWhisper/include
mkdir -p "$DEST"
ln -sf "../../../$W/include/whisper.h"        "$DEST/whisper.h"
ln -sf "../../../$W/ggml/include/ggml.h"      "$DEST/ggml.h"
ln -sf "../../../$W/ggml/include/ggml-alloc.h" "$DEST/ggml-alloc.h"
ln -sf "../../../$W/ggml/include/ggml-backend.h" "$DEST/ggml-backend.h"
ln -sf "../../../$W/ggml/include/ggml-cpu.h"  "$DEST/ggml-cpu.h"
echo "headers linked:"
ls -l "$DEST"
