# Imspect user guide

**Every pixel. Under inspection.**

A native macOS research preview for comparing, inspecting, and editing images. Built with Swift and AppKit; no browser, Electron, server, or account. The core app works offline. This build targets Apple silicon and macOS 13 or later.

## Open the app

Open `Imspect.dmg`, then drag Imspect into Applications. The release is ad-hoc signed and is not Apple-notarized. See the [installation instructions](README.md#install).

Version **0.2.1** fixes a layout issue where Play or other updates could pack the panels at the left of a wide or full-screen window. The header now shows the running version.

Version **0.2.0** added brush/text, live RGB controls, cached histograms, sequential playback, and visible-region resampling at every zoom.

If an older Imspect window is still open, save its workspace and quit before opening the updated app from Applications. The running process keeps its previous code until relaunched.

Click **Demo** for a synthetic resolution target with reproducible Gaussian noise and blur. Add your own images with **Open images**, drag and drop, or **⌘V**. Images remain local. Opening images never overwrites the source files.

## Comparison workspace

| Action | Control |
|---|---|
| Native macOS full screen | Green window button; Control–Command–F; View → Toggle Full Screen |
| Split / flicker / draggable wipe | Top mode control; Tab on canvas |
| Switch between selected pair | Space or a click in Flicker + Pan |
| Automatic flicker / wipe sweep | Play; speed slider |
| Choose an image | Sidebar or keys 1–9 |
| Next / previous image | N or ] / [ |
| Remove selected sidebar image | Delete / Backspace while the image list has focus |
| Move every image together | Drag in Pan; arrow keys; scroll |
| Move exactly one source pixel | Option + arrow |
| Zoom every image together | ⌘ + scroll, pinch, + / − |
| Fit / 100% | F / 0; Fit / 1:1 buttons |
| Pixel values across images | I, then click a pixel |
| Matched region selection | S, then drag; Escape clears |
| Matched annotations | R rectangle, C circle, D dot, L line, B brush, T text |
| Enter text | Click in Text mode, type, Return to place; Escape cancels |
| Remove most recent annotation | Delete while canvas focused |
| Copy image / selected region | Copy / Crop copy |
| Save or restore comparison session | Save workspace / Open workspace |

All coordinates are measured from the top left. Every panel shares the same scale and image origin; changing images does not trigger a fit, animation, or recenter. Different image sizes are shown at their actual relative sizes. Split supports more than two images. Number shortcuts cover the first nine; the sidebar covers the full set.

Select the partner independently of metric reference. Choose **Play pair** or **Play all images in order** in the inspector. The all-images option visits the comparison set in sidebar order and wraps. Editing pauses playback so the edited image stays selected. Automatic flicker speed is switches per second (a complete A–B–A cycle takes two switches). Wipe sweeps continuously; the speed label shows seconds per sweep. In all-images wipe playback, the right-hand candidate advances at each boundary while the left-hand partner remains fixed. The timer is an interactive presentation timer, not a laboratory frame-timing guarantee.

Zoom uses a native implementation of ResizeRight's centered interpolation kernels: nearest, linear, cubic, Lanczos 2 and Lanczos 3, with antialiasing when shrinking and symmetric image boundaries. Changing the method reconstructs the visible area immediately from the base image at the current zoom. It does not change stored pixels or require pressing Resize. High magnification uses a bounded visible patch rather than a whole enlarged image; the chosen method remains active at every supported zoom. Patches share the exact source-coordinate sampling grid, so panning and flickering retain correspondence. While a patch updates, only newly uncovered regions may briefly use a native preview before the selected-kernel patch arrives.

Zoom is source pixels per macOS point; on Retina displays 100% occupies more than one physical display pixel. Display patches include Retina resolution. Formal **Resize** is a separate edit that changes the stored image dimensions and samples.

## Metrics and scientific conventions

Choose a reference; every other image reports RGB MSE, PSNR, SSIM, histogram distance, and mean ΔE76. A selected region applies at exactly the same integer pixel coordinates in every image. Mismatched dimensions, invalid regions, nonopaque alpha, and samples outside [0,1] produce explicit errors; the app never silently aligns, resizes, composites, or clips to obtain a score.

- Images are decoded through ImageIO with EXIF orientation and ICC conversion to **encoded sRGB**, stored as straight-alpha Float32 RGBA. Source color-space preservation and raw scientific tensor import are future work.
- MSE averages squared errors across RGB and pixels, with data range 1. PSNR is `10 log10(1/MSE)`; identical images yield infinity.
- SSIM uses an 11×11 Gaussian window, σ 1.5, population covariance, K₁ .01, K₂ .03, valid window centers, averaged across RGB. Regions smaller than 11 pixels in either dimension have no SSIM score.
- Histogram distance is the mean channel-wise 1D Wasserstein distance over 256 bins, normalized by 255. This describes color distribution and ignores geometry.
- ΔE76 uses sRGB → XYZ D65 → CIELAB D65. It is CIE76, not ΔE2000.
- CSV reports contain reference, ROI, edit history, and metric conventions. Numerical results are calculated from stored image samples, independent of display zoom and annotations.

The View control provides absolute RGB differences, MSE heatmaps, SSIM error maps, and centered FFT magnitudes. All comparisons use the chosen reference. Heatmaps use a shared black/violet/orange/yellow scale, not per-image normalization: MSE is `clip(gain × mean_RGB(error²))`; SSIM error is `clip(gain × (1−SSIM)/2)`. SSIM's invalid five-pixel border is transparent. Absolute differences are `clip(gain × abs(error))` per RGB channel.

FFT is the centered FFT2 of encoded-sRGB Rec.709 luminance, zero-padded to powers of two. Display intensity is `log(1 + 1000 × abs(F)/N) / log(1001)` with N the padded pixel count. All images share this amplitude scale. Source-image metric calculations are unavailable in FFT view, to avoid confusing frequency coordinates with image coordinates.

## Live histogram

The inspector always shows a cached 256-bin RGB histogram for the selected source image or matched region. Select **Overlay reference** to add dashed reference curves. Each channel is normalized to 100% of its pixels, and all displayed curves share the same vertical scale. The chart labels its peak probability per bin and the 0–255 horizontal range. This makes distributions comparable across different image sizes.

Histograms update when image samples or the region change. Switching images uses cached results; pan and zoom do not recalculate the histogram. All source RGB samples are counted, including pixels with alpha; out-of-range samples are clipped only for bin assignment. In FFT view the histogram continues to describe the full spatial source image.

## Editing and exports

Edits apply to the selected image or, with the checkbox, to all images. There is a ten-step pixel-edit undo history and a Restore original command. Rectangle, circle, point, line, freehand brush, and text annotations are nondestructive overlays and can be shared or image-specific. Annotations are included when copying/exporting, but excluded from numerical metrics. In the canvas, Delete removes the last annotation; in the image list, it removes the selected image from the comparison. Annotation history is separate from pixel-edit undo. Drawing width, color, and text size are set in the Annotations section. Sizes are measured in source-image pixels, so zoom does not change exported marks.

Available edits: live independent RGB channel controls; grayscale; Gaussian blur; unsharp sharpening; seeded additive Gaussian noise; bilateral filtering; 256-bin per-channel histogram matching to reference; explicit clipping; compositing onto white/black; and ResizeRight-compatible resizing. Noise σ is entered in 0–255 units, and uses the same seed for linked edits. Gaussian blur σ is in pixels. Bilateral amount is RGB range σ in [0,1], with spatial σ 2 pixels and radius 4. Grayscale uses encoded-sRGB Rec.709 luma, not linear-light luminance.

Each RGB slider has three exact landmarks: left = zero for that channel, center = its baseline values, right = one in every pixel. Intermediate negative settings scale toward zero; positive settings blend toward one. Adjustments are always evaluated from a fixed per-image baseline, so repeated dragging does not compound them. Values, baselines, and channel undo state are retained while editing; saved workspaces preserve the current channel settings and baselines. Applying another pixel edit starts a new neutral channel baseline. One mouse gesture creates one undo step.

Resize retains unclipped floating-point overshoots. Use **Clip RGB to 0–1** explicitly if you want bounded samples for metrics. Noise and sharpening are bounded editing operations and clip to [0,1]. Filters process the full image; selection limits metric evaluation and crop export, not filter application.

PNG exports are 16-bit sRGB, with clipping only in the exported copy. A selected region limits PNG export to that region. Copy uses the system image clipboard. A `.imspect` workspace stores self-contained Float32 originals and edited images, channel baselines, image order, brush/text annotations, drawing styles, playback choice, ROI, and view state; it does not depend on original file locations. Version 2 workspaces include the new controls; version 1 workspaces remain readable. Model weights, optional research reports, and transient derived-view caches are separate.

## Optional research models

**Research models…** offers actual LPIPS (scalar and spatial map), NIQE, MUSIQ, and TOPIQ-NR through an optional local Python environment. The installer and first model download are explicit actions. These packages and weights are not bundled in this small core app. No placeholder or proxy scores are used.

Model inputs are explicitly converted to 8-bit sRGB snapshots. The report records normalization, ROI, package versions, input hashes, and model-state hashes. LPIPS needs a reference; the other three are no-reference models. NIQE is lower-is-better; learned no-reference scores depend on their training distribution and are not universal measures of reconstruction accuracy. LPIPS spatial maps reflect neural receptive fields and do not isolate the error of an individual pixel.

See [RESEARCH.md](RESEARCH.md) for setup, dependencies, primary sources, model restrictions, and the protocol. Backend protocol and resize tests are covered by the test suite; pretrained model inference and weight downloads have not been validated for this release.

## Building and validation

Apple's command-line developer tools are sufficient; the full Xcode app is not required.

```sh
bash build.sh --dmg
bash test.sh
```

The Swift engine suite includes 40 comparisons against the original ResizeRight implementation and an independently calculated Gaussian SSIM reference. Backend tests require NumPy and Pillow but do not download models. Sources and vendored licenses are included. Swift source is macOS-specific; the research worker is portable and can be reused for a later Windows client.

## Useful next additions

The most valuable further research features would be explicit geometric registration with an inspectable transform; RGB/linear-light/Y-only metric protocols and border shaving; masks; `.npy`/EXR/raw float import; batch folder pairing and evaluation; multi-scale SSIM/DISTS; one-click paper comparison figures; sequences/video; and blind randomized A/B studies. Registration should remain opt-in so a favorable score cannot hide spatial misalignment.

This is a working research preview, not a completed production release. Current practical limits include whole-image processing, no cancellation within an individual native filter, no persistent edit graph, and no Windows build yet. Large images and expensive filters can use substantial memory; maximum input size is 64 million pixels.

## Primary implementations

- [ResizeRight](https://github.com/assafshocher/ResizeRight) — vendored original with MIT license; native port validated against it.
- [LPIPS](https://github.com/richzhang/PerceptualSimilarity) — official perceptual similarity implementation.
- [IQA-PyTorch](https://github.com/chaofengc/IQA-PyTorch) — optional no-reference metric implementations.
- [Apple notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) — public distribution requirements.
