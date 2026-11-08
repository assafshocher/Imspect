#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$(dirname "$SOURCE_DIR")"
BUILD_DIR="$SOURCE_DIR/.build"
STAGING_DIR="$(mktemp -d /private/tmp/Imspect-package.XXXXXX)"
IMAGE_DIR="$(mktemp -d /private/tmp/Imspect-image.XXXXXX)"
trap 'rm -rf "$STAGING_DIR" "$IMAGE_DIR"' EXIT
APP="$STAGING_DIR/Imspect.app"
mkdir -p "$BUILD_DIR/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -module-cache-path "$BUILD_DIR/module-cache" -target "$(uname -m)-apple-macos13.0" \
  "$SOURCE_DIR"/Sources/*.swift -o "$APP/Contents/MacOS/Imspect" \
  -framework AppKit -framework Accelerate -framework UniformTypeIdentifiers
cp "$SOURCE_DIR/Info.plist" "$APP/Contents/Info.plist"
python3 - "$SOURCE_DIR/Research" "$APP/Contents/Resources/Research" <<'PY'
import shutil, sys
shutil.copytree(sys.argv[1], sys.argv[2], dirs_exist_ok=True, copy_function=shutil.copyfile, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
PY
chmod +x "$APP/Contents/Resources/Research/Setup.command"
cp "$SOURCE_DIR/README.md" "$APP/Contents/Resources/README.md"
cp "$SOURCE_DIR/RESEARCH.md" "$APP/Contents/Resources/RESEARCH.md"
if [ -f "$SOURCE_DIR/Imspect.icns" ]; then cp "$SOURCE_DIR/Imspect.icns" "$APP/Contents/Resources/Imspect.icns"; fi
find "$APP" -name '__pycache__' -type d -prune -exec rm -rf {} +
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
python3 - "$APP" "$OUTPUT_DIR" "$BUILD_DIR" <<'PY'
from pathlib import Path
import ctypes, os, shutil, sys, uuid, zipfile
app, output = Path(sys.argv[1]), Path(sys.argv[2])
incoming = output / ('.Imspect-incoming-' + str(uuid.uuid4()) + '.app')
shutil.copytree(app, incoming, copy_function=shutil.copyfile)
(incoming / 'Contents/MacOS/Imspect').chmod(0o755)
(incoming / 'Contents/Resources/Research/Setup.command').chmod(0o755)
destination = output / app.name
if destination.exists():
    # Keep the outer app directory stable so Finder/Dock aliases do not follow
    # a whole-bundle backup and launch an outdated copy on the next run.
    # Move the old executable inode intact; never truncate a running binary.
    backup = Path(sys.argv[3]) / 'previous-contents' / str(uuid.uuid4()) / 'Contents'
    backup.parent.mkdir(parents=True)
    swap = ctypes.CDLL(None, use_errno=True).renameatx_np
    swap.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    swap.restype = ctypes.c_int
    if swap(-2, os.fsencode(destination / 'Contents'), -2, os.fsencode(incoming / 'Contents'), 0x2) != 0:
        raise OSError(ctypes.get_errno(), 'Could not atomically exchange app contents')
    os.replace(incoming / 'Contents', backup)
    incoming.rmdir()
else:
    os.replace(incoming, destination)
with zipfile.ZipFile(output / 'Imspect.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob('*')):
        if path.is_file(): archive.write(path, path.relative_to(app.parent))
PY
printf 'Built %s/Imspect.app and Imspect.zip\n' "$OUTPUT_DIR"
if [ "${1:-}" = "--dmg" ]; then
  ln -s /Applications "$STAGING_DIR/Applications"
  cp "$SOURCE_DIR/README.md" "$STAGING_DIR/Read me.md"
  if ! hdiutil create -volname Imspect -srcfolder "$STAGING_DIR" -ov -format UDZO "$IMAGE_DIR/Imspect.dmg"; then
    # HFS+ image construction does not need a temporary mounted device.
    hdiutil makehybrid -hfs -hfs-volume-name Imspect -o "$IMAGE_DIR/Imspect.dmg" "$STAGING_DIR" -ov
  fi
  mv -f "$IMAGE_DIR/Imspect.dmg" "$OUTPUT_DIR/Imspect.dmg"
fi
