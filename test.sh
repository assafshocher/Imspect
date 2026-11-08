#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$SOURCE_DIR/.build/module-cache"
swiftc -O -module-cache-path "$SOURCE_DIR/.build/module-cache" \
  "$SOURCE_DIR/Sources/ImageEngine.swift" "$SOURCE_DIR/Tests/EngineTests.swift" \
  -framework AppKit -framework Accelerate -o "$SOURCE_DIR/.build/EngineTests"
"$SOURCE_DIR/.build/EngineTests" "$SOURCE_DIR/Tests/resize-fixtures.json"
APP_SOURCES=()
for source in "$SOURCE_DIR"/Sources/*.swift; do
  if [ "$(basename "$source")" != main.swift ]; then APP_SOURCES+=("$source"); fi
done
for suite in IntegrationTests WorkspaceUpdateTests LayoutTests; do
  swiftc -O -module-cache-path "$SOURCE_DIR/.build/module-cache" \
    "${APP_SOURCES[@]}" "$SOURCE_DIR/Tests/$suite.swift" \
    -framework AppKit -framework Accelerate -o "$SOURCE_DIR/.build/$suite"
  "$SOURCE_DIR/.build/$suite"
done
swiftc -O -module-cache-path "$SOURCE_DIR/.build/module-cache" \
  "$SOURCE_DIR/Sources/ComparisonCanvas.swift" "$SOURCE_DIR/Tests/CanvasInteractionTests.swift" \
  -framework AppKit -o "$SOURCE_DIR/.build/CanvasInteractionTests"
"$SOURCE_DIR/.build/CanvasInteractionTests"
swiftc -O -module-cache-path "$SOURCE_DIR/.build/module-cache" \
  "$SOURCE_DIR/Sources/RGBHistogramView.swift" "$SOURCE_DIR/Tests/HistogramViewTests.swift" \
  -framework AppKit -o "$SOURCE_DIR/.build/HistogramViewTests"
"$SOURCE_DIR/.build/HistogramViewTests"
python3 -m unittest discover -s "$SOURCE_DIR/Research" -p 'test_backend.py' -v
