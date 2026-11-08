# Imspect

**Every pixel. Under inspection.**

A desktop app for comparing, inspecting, and editing images for computer-vision research. The Mac edition uses Swift and AppKit; the Windows preview uses native Qt widgets. The core app works locally and offline, without a browser or account.

**[Download Imspect 0.2.1 for Mac](https://github.com/assafshocher/Imspect/releases/download/v0.2.1/Imspect.dmg)** · [User guide](GUIDE.md) · [Research models](RESEARCH.md) · [Changelog](CHANGELOG.md)

**[Download Imspect 0.3.0 for Windows (preview)](https://github.com/assafshocher/Imspect/releases/download/v0.3.0-windows-preview/Imspect-0.3.0-Windows-x64-Setup.exe)** · [Windows guide](Windows/README.md) · [Portable ZIP and checksums](https://github.com/assafshocher/Imspect/releases/tag/v0.3.0-windows-preview)

Windows 10/11 x64; the core app includes Python. This preview is unsigned and may show an unknown-publisher notice. The two editions share image-processing conventions; workspace files use separate formats.

## Features

- Split, flicker, and draggable wipe comparisons, with pair or sequential playback and adjustable speed.
- Synchronized pan, zoom, region selection, pixel inspection, and annotations across multiple images.
- ResizeRight-compatible nearest, linear, cubic, and Lanczos display resampling at every zoom level.
- Reference-based PSNR, SSIM, MSE, histogram distance, and ΔE76 for full images or matched crops.
- Cached RGB histograms with a reference overlay, difference images, error maps, and centered FFT views.
- Brush, text, circles, rectangles, points, and lines; copy or export annotated images.
- Live RGB controls, grayscale, noise, blur, sharpening, bilateral filtering, histogram matching, resizing, and undo.
- Clipboard import, drag and drop, native full screen, and self-contained comparison workspaces.

## Install on Mac

The downloadable build supports **Apple silicon Macs with macOS 13 or later**.

1. Download and open the DMG.
2. Drag **Imspect** into **Applications**.
3. Open Imspect. Use **Demo** to explore a synthetic comparison, or open/paste your images.

This research-preview release is **ad-hoc signed, not Apple-notarized**. macOS may block the first launch. If you trust the download, try opening it, then use **System Settings → Privacy & Security → Open Anyway**, following [Apple's instructions](https://support.apple.com/en-us/102445). No system-wide security changes are required.

## Mac quick controls

| Action | Shortcut |
|---|---|
| Switch comparison mode | Tab |
| Flicker the pair / select image | Space / 1–9 |
| Pan all images | Drag or arrow keys |
| Zoom all images | Command + scroll, pinch, + / − |
| Fit / 100% | F / 0 |
| Inspect a pixel / select a region | I / S |
| Brush / text / circle | B / T / C |
| Remove selected image | Delete with the image list focused |

See the [user guide](GUIDE.md) for the complete controls, scientific conventions, and editing behavior. Edits can apply to one image or all images; **all-image edits also modify the reference**.

## Build the Mac app from source

Requirements: macOS 13+, Apple's command-line developer tools, and Python 3. The full Xcode application is not required.

```sh
xcode-select --install  # only if the command-line tools are not installed
git clone https://github.com/assafshocher/Imspect.git
cd Imspect
bash build.sh --dmg
```

The script builds for the current Mac's architecture and creates `Imspect.app`, `Imspect.zip`, and `Imspect.dmg` **in the parent directory of this checkout**. It signs the local application ad hoc. The published binary has been built and checked on Apple silicon; an Intel build is not provided or validated.

To run the test suites, first make NumPy and Pillow available to Python:

```sh
python3 -m venv .test-venv
.test-venv/bin/python -m pip install numpy pillow
PATH="$PWD/.test-venv/bin:$PATH" bash test.sh
```

Tests cover the image engine, ResizeRight parity fixtures, workspaces, native interactions, histograms, layout, and the optional worker's numerical/protocol behavior. They do not download research-model weights.

## Measurement conventions and limits

Native image samples are Float32 RGBA in **encoded sRGB**. Comparison metrics use the same source coordinates, independently of display zoom and annotations. Imspect does not silently align, resize, composite, or clip inputs to obtain a score. SSIM uses an 11×11 Gaussian window with σ 1.5 and valid window centers; ΔE is CIE76. Full definitions are in the [guide](GUIDE.md#metrics-and-scientific-conventions).

This is a research preview. Raw tensor/EXR import, geometric registration, and a persistent edit graph are not currently included. Large images and expensive filters can consume substantial memory; the input limit is 64 million pixels. The [Windows guide](Windows/README.md) documents that edition's export paths and automated Windows validation.

## Optional research models

The optional local Python worker integrates upstream **LPIPS**, **NIQE**, **MUSIQ**, and **TOPIQ-NR**, plus original ResizeRight and NumPy FFT operations. Python packages and model weights are **not bundled** in the core app. Installation and first-use downloads require explicit actions.

Model inference and pretrained-weight downloads have not been validated for this release. Missing dependencies or failed inference produce errors, never placeholder scores. See [RESEARCH.md](RESEARCH.md) for setup, preprocessing, protocol, and limitations.

## Third-party code

The vendored [ResizeRight](https://github.com/assafshocher/ResizeRight) implementation retains its [MIT license](Research/vendor/resize_right/LICENSE) and [upstream provenance](Research/vendor/resize_right/UPSTREAM.md). Optional metric implementations are linked from [RESEARCH.md](RESEARCH.md) and are installed separately under their own licenses.
