# Imspect research tools

The native application runs without Python. The optional research worker adds the **original ResizeRight implementation**, LPIPS and its spatial map, NIQE, MUSIQ, and TOPIQ-NR. It also offers an exact-size NumPy FFT for comparison with the native FFT view.

## Installation

Run `Research/Setup.command` after installing Python 3.10–3.12. It creates an isolated environment at `~/Library/Application Support/Imspect/research` and records its resolved dependency versions in `installed-versions.txt`. Installing PyTorch and the quality libraries can take several GB. Installation does not initialize pretrained models. A model's weights may download on the first explicitly requested metric evaluation; image processing remains local.

The native bridge should use `~/Library/Application Support/Imspect/research/bin/python3`. An existing compatible interpreter can also run the worker. `IMSPECT_PYTHON` selects the installer interpreter and `IMSPECT_RESEARCH_ENV` changes the installation directory. A custom directory must also be selected by the app's bridge.

## Measurement contract

The bridge accepts 8-bit RGB/RGBA files up to 32 megapixels, applies EXIF orientation, converts embedded profiles to encoded sRGB, and assumes untagged inputs are sRGB. It rejects high-bit-depth PNG/TIFF inputs rather than silently reducing their precision. Metrics reject transparent images rather than choosing an implicit background. Coordinates start at the top left. ROIs are integer `[x, y, width, height]` rectangles and must lie completely inside both images. Pairwise metrics require identical original dimensions; the worker never silently aligns or resizes a pair.

LPIPS uses the upstream learned metric, default AlexNet trunk, version 0.1, in evaluation mode. Input RGB values are transformed from `[0,1]` to `[-1,1]`. The scalar comes from the upstream scalar implementation. The optional spatial view contains upsampled feature contributions with nonlocal receptive fields; it is not an independent per-pixel loss and its displayed-map average does not define the scalar score. Imspect requires an ROI of at least 64×64 pixels. [Official LPIPS implementation](https://github.com/richzhang/PerceptualSimilarity)

NIQE is a useful traditional baseline, but no-reference scores do not establish fidelity to a ground truth. MUSIQ and TOPIQ-NR provide learned alternatives. Their ranking can depend on image domain and training data, so retain the model identity when comparing scores. The bridge records the library's `lower_better` property and uses its default model preprocessing. For NIQE, Imspect requires at least 192×192 pixels to provide multiple 96-pixel blocks; degenerate inputs can still be undefined. [IQA-PyTorch model documentation](https://github.com/chaofengc/IQA-PyTorch/blob/main/docs/ModelCard.md)

Each successful model result includes package versions, device, input hashes, crop, normalization, random seed, and a SHA-256 fingerprint of the actual loaded model tensors. CPU is the default. A GPU backend must be requested explicitly and can differ numerically. Model scores are not substituted if a dependency, weight, device, or inference operation fails.

## ResizeRight

The vendored Python files are upstream source, with their MIT license retained. The bridge defaults to **symmetric padding**; this is an explicit application choice, whereas upstream's function default is zero padding. Pass `pad_mode: "constant"` to select the upstream default. Available kernels are cubic, linear, Lanczos-2, Lanczos-3, and box. The box kernel follows upstream behavior; it is not advertised as identical to nearest-neighbor point sampling.

The optional `scale_factors: [scale_y, scale_x]` preserves a chosen scale independently of the integer output size. This matters when scaled dimensions are not integers. Without it, scale is derived from the requested output size. Resampling preserves float overshoot in an optional `.npy` artifact; PNG output clips to `[0,1]` and rounds to 8 bits. Straight alpha is resized independently using the same kernel. [ResizeRight source and conventions](https://github.com/assafshocher/ResizeRight)

## File protocol

Launch without a shell, passing paths as separate process arguments:

```text
python3 backend.py --request /absolute/request.json --response /absolute/response.json
```

LPIPS example:

```json
{
  "protocol": 1,
  "operation": "lpips",
  "image": "/absolute/candidate.png",
  "reference": "/absolute/reference.png",
  "roi": [20, 40, 256, 256],
  "heatmap": "/absolute/lpips-map.png",
  "heatmap_max": 1.0,
  "allow_downloads": true,
  "device": "cpu",
  "network": "alex"
}
```

Use `niqe`, `musiq`, or `topiq_nr` as the operation for individual quality estimates; `reference` and `heatmap` are not used for them. Model operations require explicit `allow_downloads: true`, even when weights may already be cached, so the caller must communicate first-use downloads. `model_cache` can override the default `~/Library/Application Support/Imspect/models` directory. Existing `TORCH_HOME` and `HF_HOME` environment settings take precedence.

Resize example:

```json
{
  "operation": "resize",
  "image": "/absolute/input.png",
  "output": "/absolute/resized.png",
  "float_output": "/absolute/resized.npy",
  "width": 257,
  "height": 257,
  "scale_factors": [0.5, 0.5],
  "kernel": "cubic",
  "antialiasing": true,
  "pad_mode": "symmetric"
}
```

Successful metric responses contain `ok`, `score`, `lower_better`, `metric`, and `metadata`; an optional `heatmap` is an absolute PNG path. Heatmaps use a fixed declared range (default 0–1), retain unclipped values in a neighboring `.npy` file, and record the display color scale. Image operations return `output` and `metadata`.

Failures return `{"ok": false, "error": {"code": "…", "message": "…"}}` with exit code 1. The native app should show that message and leave the current images intact. Output files may not overwrite inputs. A `capabilities` request requires no image or model imports and reports installed package versions; availability is not a promise that model weights have been downloaded or tested.

## Verification status

The protocol and numerical test suite contains sixteen tests and requires NumPy and Pillow. They check validation, ROI coordinates, transparency rejection, original ResizeRight identity/constant behavior for all five kernels, centered FFT DC position, and unclipped heatmap export. Run them with:

```text
python3 -m unittest discover -s Research -p 'test_backend.py' -v
```

PyTorch, LPIPS, and IQA-PyTorch were not installed in the build environment, so **model inference and pretrained-weight downloads have not been executed or validated in this build**. The worker contains real upstream-library calls and reports missing dependencies explicitly. This is an optional integration ready for environment installation, not a claim that the model metrics already ran successfully.
