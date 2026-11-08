# Imspect for Windows

**Every pixel. Under inspection.**

Imspect 0.3.1 is a native Qt desktop app for comparing, inspecting, and editing images on **64-bit Windows 10 or 11**. The core app works locally and offline. Its installer includes Python and its runtime libraries; users do not need to install Python separately.

[Download for Windows](https://github.com/assafshocher/Imspect/releases/tag/v0.3.1-windows) · [Mac version](../README.md) · [Source code](https://github.com/assafshocher/Imspect)

## Install and start

1. Download **Imspect-0.3.1-Windows-x64-Setup.exe** from the release page.
2. Run the installer. It installs for the current user and creates a Start menu shortcut; administrator access is not required.
3. Open **Imspect**, then choose **Demo** or open your images. Images can also be pasted from the clipboard or dropped onto the window.

The Windows build is **unsigned**. Windows may show an unknown-publisher or SmartScreen notice. Verify that the download came from this repository. Release downloads include `SHA256SUMS.txt` for checking their integrity.

For a portable copy, download **Imspect-0.3.1-Windows-x64-Portable.zip**, extract the entire folder, and run `Imspect.exe` inside it. Keep the `_internal` folder beside the executable. Uninstall an installed copy through Windows Settings → Apps; deleting the portable folder removes that copy.

This is an x64 build. Native Windows ARM64 and 32-bit Windows packages are not provided. ARM emulation and high-DPI multi-monitor configurations need additional hardware coverage.

## Working with images

- **Split** shows the comparison set together. **Flicker** switches images in the same position. **Wipe** reveals two images on either side of a draggable boundary.
- Pan, zoom, inspection coordinates, and region selections are shared across images. Changing an image, method, or edit preserves the view.
- Choose a **reference** in the image list to compare every other image against it. Reference choice and playback partner are independent.
- Play either a pair or all images in sequence. Adjust playback speed with the slider.
- Inspect a pixel to see its values across the image set. Select a region to calculate matched-region metrics or export a crop.
- The inspector shows RGB histograms and reference metrics. Difference, MSE/SSIM error maps, and centered FFT views provide other comparisons.
- Draw points, lines, rectangles, circles, freehand brush strokes, or text. Annotations can be shared across images or attached to one image.
- Apply grayscale, noise, smoothing, sharpening, bilateral filtering, histogram matching, channel adjustments, or resizing to one image or all images. Undo and Restore original preserve the input files.

Canvas shortcuts apply while the comparison canvas has focus.

| Action | Shortcut |
|---|---|
| Switch comparison mode | Tab |
| Flicker / choose image | Space / 1–9 |
| Next / previous image | N or ] / [ |
| Pan every image | Drag in Pan mode or arrow keys |
| Pan one source pixel | Alt + arrow |
| Zoom every image | Ctrl + mouse wheel, + / − |
| Fit / 100% | F / 0 |
| Pan / inspect / select region | P / I / S |
| Rectangle / circle / dot / line | R / C / D / L |
| Brush / text | B / T |
| Clear region / cancel drawing | Escape |
| Remove an image | Delete or Backspace with image list focused |
| Remove last annotation on selected image | Delete or Backspace with canvas focused |
| Toggle full screen | F11 |

Press **F11** or choose **View → Full screen** for a larger comparison area. Application shortcuts include Ctrl+O to open images, Ctrl+V to paste, Ctrl+C to copy the image or region, Ctrl+E to export, Ctrl+Z to undo a pixel edit, Ctrl+D to duplicate, Ctrl+S to save a workspace, and Ctrl+Shift+O to open a workspace.

## Image and metric conventions

Stored samples are straight-alpha Float32 RGBA in encoded sRGB. Metrics use the stored source pixels, independently of display zoom and annotations. Images are never silently aligned or resized to obtain a score. Invalid regions, incompatible dimensions, nonopaque alpha, nonfinite values, and out-of-range metric inputs are reported explicitly.

- **MSE / PSNR:** RGB data range 1, averaged across channels and pixels; identical inputs have infinite PSNR.
- **SSIM:** 11×11 Gaussian window, σ 1.5, population covariance, valid window centers, mean over RGB. Crops smaller than the window have no SSIM score.
- **Histogram distance:** mean RGB Wasserstein-1 distance over 256 bins, divided by 255.
- **Color difference:** mean CIE76 ΔE in CIELAB D65.
- **Resizing and zoom:** centered ResizeRight-compatible kernels with antialiasing for shrinking and symmetric boundaries. Overshoots remain in stored resize results until explicitly clipped.
- **FFT:** centered luminance FFT with a shared amplitude display scale. Spatial metrics, pixel inspection, and annotations are disabled in FFT view. Switch View back to Images to inspect and measure source pixels.

Noise and sharpening are bounded edits. Noise amount is specified in 0–255 units. Seeded noise uses the same SplitMix64 and Box–Muller random-number sequence as the Swift Mac engine.

PNG export without annotations writes 16-bit sRGB samples, clipping exported values to 0–1 without changing the stored image. Annotated PNGs and clipboard copies use 8-bit display samples. No source image is overwritten automatically.

## Workspaces

Windows saves self-contained **`.imspectw`** workspaces with originals, current images, comparison settings, and annotations. This format is separate from the Swift Mac app's `.imspect` format. Do not rename one extension to the other. Export PNGs to transfer images between the two apps.

## Optional research models

LPIPS, NIQE, MUSIQ, and TOPIQ-NR use the existing local Python research worker. Their large dependencies and pretrained weights are **not included** in the core installer. Core comparisons, metrics, filtering, resampling, histograms, and FFT do not require these models.

In **Research models**, choose a Python 3.10+ executable, then use **Set up model environment…** to create a separate environment and install the model packages. An existing compatible environment can also be selected; dependencies are listed in the bundled `_internal/Research/requirements.txt` or this repository's `Research/requirements.txt`. Pretrained-weight downloads require enabling the download checkbox, and image inference remains local. The worker reports missing dependencies and model errors; it never substitutes placeholder scores.

See [RESEARCH.md](../RESEARCH.md) for numerical preprocessing and upstream model references. Its `Setup.command` installer is for macOS; on Windows use the separate Python environment selected in the app. Pretrained-model quality and hardware-specific inference need separate validation from the core app's tests.

## Build from source

Development works on macOS or Windows with Python 3.9–3.12. Published Windows binaries are built with Python 3.11 x64 **on Windows**, including GitHub's Windows build machines.

From the repository root on Windows:

```powershell
py -3.11 -m venv .windows-venv
.\.windows-venv\Scripts\python.exe -m pip install -r Windows\requirements-dev.txt
.\.windows-venv\Scripts\python.exe Windows\main.py
```

Install [Inno Setup 6 or later](https://jrsoftware.org/isdl.php) to create an installer, then run:

```powershell
.\Windows\build.ps1 -Python .\.windows-venv\Scripts\python.exe
```

The resulting installer, portable archive, and hashes are written to `Windows/release/`. `-SkipInstaller` produces only the portable archive. `-Iscc 'C:\path\to\ISCC.exe'` selects an explicit installer compiler. The first build downloads checksum-pinned official Qt/PySide source archives to collect the matching license notices; these are cached in `Windows/build/`. The build intentionally keeps Qt DLLs in ordinary files inside `_internal`; they are dynamically linked and replaceable.

On macOS, create a virtual environment, install `Windows/requirements-dev.txt`, and run `python Windows/main.py`. This exercises the shared application logic and interface, but does not produce or validate a Windows executable.

## Verification and release process

The [Windows workflow](../.github/workflows/windows.yml) runs on `windows-2022` and:

1. Installs the pinned dependencies and runs scientific, workspace, and interface tests, plus the existing research-worker protocol tests.
2. Builds the standalone application and installer, preserving third-party notices.
3. Starts the packaged EXE with the Windows desktop platform plugin and captures its smoke-test report and screenshots.
4. Runs the actual installer into a directory containing spaces, starts that installed app from outside the source checkout, and checks uninstall.
5. Uploads the packages, checksums, test reports, screenshots, and installed dependency list as workflow artifacts.

Ordinary source pushes produce artifacts only. A successful build triggered by tag `v0.3.1-windows`, or an explicitly published manual workflow, creates the GitHub release. A failed test prevents publication. Existing published release assets are never silently replaced.

These checks are automated Windows validation. They do not establish exhaustive manual usability, GPU, printer, monitor, or physical-machine compatibility. Inspect the workflow evidence and release notes for what passed on a particular build. The Windows and Swift Mac editions are maintained separately.

See [THIRD_PARTY.md](THIRD_PARTY.md) and the bundled `licenses` directory for dependency notices.
