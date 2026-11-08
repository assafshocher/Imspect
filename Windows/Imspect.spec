# -*- mode: python ; coding: utf-8 -*-
"""One-folder distribution: Qt and other libraries remain replaceable files."""
from importlib import metadata
from pathlib import Path
import hashlib
import json
import sys
import tarfile
import urllib.request

from PyInstaller.utils.hooks import copy_metadata

windows = Path(SPECPATH).resolve()
repo = windows.parent

# PySide 6.8 wheels do not ship their full license texts. Keep the notices from
# the matching, unmodified official source trees beside the dynamically linked
# libraries. These are build-time downloads only, cached outside the source tree.
qt_notices = windows / "build" / "qt-upstream-notices-6.8.3"
manifest_path = qt_notices / "source-manifest.json"
if not manifest_path.is_file():
    qt_notices.mkdir(parents=True, exist_ok=True)
    archive_cache = windows / "build" / "upstream-archives"
    archive_cache.mkdir(parents=True, exist_ok=True)
    manifest = []
    upstream_archives = {
        "qt/qtbase": "cea5c8f2c20d9cbd684f8a402721e63b87a2886e906f6ec7e0f7e1ff69c83206",
        "qt/qtsvg": "fb53da582e98d23cbf6e8bedb71efb60720e61a982d31a741742c543e2f3838d",
        "qt/qtimageformats": "ad5039af9382395641e68905e26d5e29c6fd4e02a93214c8c9df3ef88c16a26f",
        "pyside/pyside-setup": "055b467903327e947b60ddefd2e9e66f6b7558b92a0728c4596e0dc8ce5dd695",
    }
    for upstream, expected_sha256 in upstream_archives.items():
        module = upstream.split("/")[-1]
        url = "https://codeload.github.com/{}/tar.gz/refs/tags/v6.8.3".format(upstream)
        archive_path = archive_cache / (module + "-6.8.3.tar.gz")
        if not archive_path.is_file():
            print("Collecting upstream Qt notices:", url)
            temporary = archive_path.with_suffix(".part")
            request = urllib.request.Request(url, headers={"User-Agent": "Imspect-build/0.3.1"})
            with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as output:
                while True:
                    block = response.read(1024 * 1024)
                    if not block:
                        break
                    output.write(block)
            temporary.replace(archive_path)
        archive_sha256 = hashlib.sha256(archive_path.read_bytes()).hexdigest()
        if archive_sha256 != expected_sha256:
            raise RuntimeError("Upstream archive checksum changed: " + upstream)
        license_count = 0
        with tarfile.open(archive_path, "r:gz") as archive:
            for entry in archive:
                if not entry.isfile() or entry.size > 5_000_000:
                    continue
                relative = Path(*Path(entry.name).parts[1:])
                if not relative.parts or relative.is_absolute() or ".." in relative.parts:
                    continue
                parts = [part.lower() for part in relative.parts]
                basename = relative.name.lower()
                is_notice = any(part in {"licenses", "license"} for part in parts)
                is_notice |= basename.startswith(("license", "licence", "copying", "notice", "copyright"))
                is_notice |= basename in {"qt_attribution.json", "qt_attributions.json", "reuse.toml", "reuse.toml.license"}
                is_notice |= "3rdparty" in parts and basename.startswith(("readme", "authors"))
                if is_notice:
                    destination = qt_notices / module / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(entry) as source:
                        destination.write_bytes(source.read())
                    license_count += 1
        if not license_count:
            raise RuntimeError("No upstream notices found for " + upstream)
        manifest.append({"source": upstream, "tag": "v6.8.3", "archive_url": url,
                         "sha256": archive_sha256,
                         "notice_files": license_count})
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

datas = [
    (str(windows / "assets"), "assets"),
    (str(windows / "README.md"), "."),
    (str(windows / "THIRD_PARTY.md"), "."),
    (str(repo / "GUIDE.md"), "docs"),
    (str(repo / "RESEARCH.md"), "docs"),
    (str(repo / "Research" / "backend.py"), "Research"),
    (str(repo / "Research" / "requirements.txt"), "Research"),
    (str(qt_notices), "licenses/Qt-upstream"),
]
# Copy only the upstream source and notices, never environments or caches.
for source in sorted((repo / "Research" / "vendor").rglob("*")):
    if source.is_file() and "__pycache__" not in source.parts and source.suffix != ".pyc":
        relative_parent = source.parent.relative_to(repo / "Research")
        datas.append((str(source), str(Path("Research") / relative_parent)))

# Preserve complete license trees and notices shipped in the installed wheels.
# This also includes notices for bundled BLAS, image codecs, Qt, and Shiboken.
for dist in metadata.distributions():
    dist_name = dist.metadata.get("Name", "unknown").replace("/", "_")
    for relative in dist.files or ():
        path = Path(str(relative))
        lowered = [part.lower() for part in path.parts]
        license_tree = any(part in {"licenses", "license", "licences", "third_party_licenses"} for part in lowered)
        notice_name = path.name.lower().startswith(("license", "licence", "copying", "notice", "copyright"))
        if not (license_tree or notice_name):
            continue
        source = Path(dist.locate_file(relative)).resolve()
        if source.is_file():
            # Flatten traversal parts from dist-info RECORD paths into a safe tree.
            safe_parent = Path(*[part for part in path.parent.parts if part not in {"..", ".", "/", "\\"}])
            datas.append((str(source), str(Path("licenses") / dist_name / safe_parent)))

for name in ("PySide6", "PySide6_Essentials", "PySide6_Addons", "shiboken6", "numpy", "Pillow", "scipy", "pypng"):
    datas += copy_metadata(name)
for name in ("LICENSE.txt", "LICENSE", "LICENSE.rst"):
    python_license = Path(sys.base_prefix) / name
    if python_license.is_file():
        datas.append((str(python_license), "licenses/Python"))

a = Analysis(
    [str(windows / "main.py")],
    pathex=[str(windows)],
    binaries=[],
    datas=datas,
    hiddenimports=["PIL.ImageCms", "PIL.ImageOps", "PIL.PngImagePlugin", "png"],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["tkinter", "matplotlib", "IPython", "torch", "torchvision", "lpips", "pyiqa"],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="Imspect",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    icon=str(windows / "assets" / "imspect.ico"),
    contents_directory="_internal",
)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="Imspect")
