#!/usr/bin/env python3
"""Imspect research worker. File-based JSON protocol; no image uploads."""
from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.metadata
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import platform
import random
import sys
import tempfile
import time

PROTOCOL = 1
ROOT = Path(__file__).resolve().parent
MODEL_OPERATIONS = {"lpips", "niqe", "musiq", "topiq_nr"}
OPERATIONS = MODEL_OPERATIONS | {"resize", "fft", "capabilities"}


class RequestError(Exception):
    def __init__(self, code, message):
        self.code = code
        super().__init__(message)


def dependency(name, distribution=None):
    try:
        return importlib.import_module(name)
    except ImportError as exc:
        raise RequestError("missing_dependency", f"Missing {distribution or name}. Run Research/Setup.command with Python 3.10 or newer, then retry. ({exc})") from exc


def versions():
    result = {"python": platform.python_version(), "platform": platform.platform()}
    for package in ("numpy", "Pillow", "torch", "torchvision", "lpips", "pyiqa"):
        try:
            result[package] = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError:
            result[package] = None
    return result


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def path_argument(request, key, must_exist=False):
    value = request.get(key)
    if not isinstance(value, str) or not value:
        raise RequestError("invalid_request", f"'{key}' must be a nonempty absolute file path.")
    path = Path(value)
    if not path.is_absolute():
        raise RequestError("invalid_request", f"'{key}' must be an absolute file path.")
    if must_exist and not path.is_file():
        raise RequestError("missing_file", f"File does not exist: {path}")
    return path


def validate(request):
    if not isinstance(request, dict):
        raise RequestError("invalid_request", "The request must be a JSON object.")
    if request.get("protocol", PROTOCOL) != PROTOCOL:
        raise RequestError("unsupported_protocol", "This worker supports protocol version 1.")
    operation = request.get("operation")
    if operation not in OPERATIONS:
        raise RequestError("invalid_operation", "Choose capabilities, resize, fft, lpips, niqe, musiq, or topiq_nr.")
    if operation == "capabilities":
        return
    path_argument(request, "image", True)
    if operation == "lpips":
        path_argument(request, "reference", True)
    roi = request.get("roi")
    if roi is not None:
        if not isinstance(roi, list) or len(roi) != 4 or any(type(v) is not int for v in roi):
            raise RequestError("invalid_roi", "ROI must be [x, y, width, height] in integer, top-left image coordinates.")
        if roi[0] < 0 or roi[1] < 0 or roi[2] <= 0 or roi[3] <= 0:
            raise RequestError("invalid_roi", "ROI origin must be nonnegative and width and height must be positive.")
    if operation in {"resize", "fft"}:
        path_argument(request, "output")
    if "heatmap" in request:
        path_argument(request, "heatmap")
    sources = {Path(request[key]).resolve() for key in ("image", "reference") if key in request}
    for key in ("output", "heatmap", "float_output"):
        if key in request and path_argument(request, key).resolve() in sources:
            raise RequestError("would_overwrite_input", "Choose a separate output path; research operations never overwrite input files.")
    if operation == "resize":
        for key in ("width", "height"):
            if type(request.get(key)) is not int or not 1 <= request[key] <= 32768:
                raise RequestError("invalid_size", f"'{key}' must be an integer between 1 and 32768.")
        if request["width"] * request["height"] > 32_000_000:
            raise RequestError("invalid_size", "Resize output is limited to 32 megapixels in this worker.")
        if request.get("kernel", "cubic") not in {"cubic", "linear", "lanczos2", "lanczos3", "box"}:
            raise RequestError("invalid_kernel", "ResizeRight kernels: cubic, linear, lanczos2, lanczos3, box.")
        if request.get("pad_mode", "symmetric") not in {"symmetric", "reflect", "edge", "constant"}:
            raise RequestError("invalid_padding", "Padding must be symmetric, reflect, edge, or constant.")
        if type(request.get("antialiasing", True)) is not bool:
            raise RequestError("invalid_antialiasing", "antialiasing must be true or false.")
        scales = request.get("scale_factors")
        if scales is not None:
            if not isinstance(scales, list) or len(scales) != 2 or any(type(v) not in (int, float) or not math.isfinite(v) or v <= 0 for v in scales):
                raise RequestError("invalid_scale", "scale_factors must be [scale_y, scale_x], both positive and finite.")
        if "float_output" in request:
            path_argument(request, "float_output")
    if operation in MODEL_OPERATIONS:
        if request.get("device", "cpu") not in {"cpu", "mps", "cuda"}:
            raise RequestError("invalid_device", "Device must be cpu, mps, or cuda.")
        # The explicit action is the consent boundary for upstream weight downloads.
        if request.get("allow_downloads") is not True:
            raise RequestError("model_downloads_not_enabled", "This metric may download pretrained weights on first use. Set allow_downloads=true only after the user chooses to run model metrics. Images are processed locally.")


def load_image(path, roi=None, require_opaque=True):
    np = dependency("numpy")
    Image = dependency("PIL.Image", "Pillow")
    ImageOps = dependency("PIL.ImageOps", "Pillow")
    ImageCms = dependency("PIL.ImageCms", "Pillow")
    with open(path, "rb") as handle:
        header = handle.read(25)
    if header[:8] == b"\x89PNG\r\n\x1a\n" and len(header) >= 25 and header[24] > 8:
        raise RequestError("unsupported_precision", "The research bridge accepts up to 8-bit PNG input; explicitly convert a preview before using this bridge.")
    with Image.open(path) as source:
        tiff_bits = getattr(source, "tag_v2", {}).get(258, (8,))
        tiff_bits = tiff_bits if isinstance(tiff_bits, (tuple, list)) else (tiff_bits,)
        if any(value > 8 for value in tiff_bits):
            raise RequestError("unsupported_precision", "High-bit-depth TIFF data is not silently reduced to 8 bits by the research bridge.")
        if source.width * source.height > 32_000_000:
            raise RequestError("image_too_large", "The optional research bridge currently accepts images up to 32 megapixels.")
        source.load()
        if source.mode in {"I", "F", "I;16", "I;16B", "I;16L"}:
            raise RequestError("unsupported_precision", "The research bridge accepts RGB/RGBA 8-bit images. Export a declared sRGB preview; high-bit-depth data will not be silently quantized.")
        image = ImageOps.exif_transpose(source)
        original_size = list(image.size)
        alpha = image.getchannel("A") if "A" in image.getbands() else image.convert("RGBA").getchannel("A")
        if require_opaque and alpha.getextrema() != (255, 255):
            raise RequestError("transparent_image", "Metrics require opaque images. Explicitly composite alpha against a chosen background first.")
        profile = image.info.get("icc_profile")
        if profile:
            try:
                profile_image = image if image.mode in {"RGB", "CMYK", "LAB", "L"} else image.convert("RGB")
                image = ImageCms.profileToProfile(profile_image, ImageCms.ImageCmsProfile(io.BytesIO(profile)), ImageCms.createProfile("sRGB"), outputMode="RGB")
            except Exception as exc:
                raise RequestError("invalid_color_profile", f"Could not convert embedded ICC profile to sRGB: {exc}") from exc
        else:
            image = image.convert("RGB")
        if not require_opaque:
            image.putalpha(alpha)
        if roi:
            x, y, width, height = roi
            if x + width > image.width or y + height > image.height:
                raise RequestError("roi_out_of_bounds", f"ROI {roi} is outside the {image.width}×{image.height} image.")
            image = image.crop((x, y, x + width, y + height))
        array = np.asarray(image, dtype=np.float32) / 255.0
    metadata = {"input_path": str(path), "input_sha256": sha256(path), "original_size": original_size,
                "evaluated_size": [int(array.shape[1]), int(array.shape[0])], "roi": roi,
                "color_space": "encoded sRGB", "range": [0, 1], "input_precision": "8-bit",
                "icc_policy": "converted embedded profile to sRGB" if profile else "untagged assumed sRGB",
                "exif_orientation": "applied before ROI"}
    return array, metadata


def save_rgb(array, path):
    np = dependency("numpy")
    Image = dependency("PIL.Image", "Pillow")
    path.parent.mkdir(parents=True, exist_ok=True)
    array = np.rint(np.clip(array, 0, 1) * 255).astype(np.uint8)
    Image.fromarray(array).save(path, format="PNG")


def save_heatmap(values, path, upper=None):
    np = dependency("numpy")
    if not np.isfinite(values).all():
        raise RequestError("nonfinite_result", "Model returned a nonfinite spatial map.")
    # One declared, fixed scale makes independent maps comparable.
    upper = 1.0 if upper is None else float(upper)
    if not math.isfinite(upper) or upper <= 0:
        raise RequestError("invalid_heatmap_scale", "heatmap_max must be positive and finite.")
    t = np.clip(values / upper, 0, 1)
    anchors = np.array([[0.02, 0.03, 0.10], [0.07, 0.26, 0.48], [0.03, 0.68, 0.68], [0.94, 0.82, 0.24], [1.0, 0.18, 0.12]])
    scaled = t * (len(anchors) - 1)
    left = np.minimum(scaled.astype(int), len(anchors) - 2)
    fraction = (scaled - left)[..., None]
    rgb = anchors[left] * (1 - fraction) + anchors[left + 1] * fraction
    save_rgb(rgb, path)
    raw = path.with_suffix(".npy")
    np.save(raw, values.astype(np.float32), allow_pickle=False)
    return {"path": str(path), "raw_path": str(raw), "range": [0, upper], "data_min": float(values.min()),
            "data_max": float(values.max()), "colormap": "Imspect navy–cyan–yellow–red, fixed scale",
            "clipped_for_display": True}


def setup_torch(request):
    default_cache = Path.home() / "Library" / "Application Support" / "Imspect" / "models"
    cache = Path(request.get("model_cache", str(default_cache)))
    if not cache.is_absolute():
        raise RequestError("invalid_cache", "model_cache must be an absolute path.")
    os.environ.setdefault("TORCH_HOME", str(cache / "torch"))
    os.environ.setdefault("HF_HOME", str(cache / "huggingface"))
    torch = dependency("torch")
    device = request.get("device", "cpu")
    if device == "mps" and not torch.backends.mps.is_available():
        raise RequestError("device_unavailable", "MPS is unavailable. Choose CPU.")
    if device == "cuda" and not torch.cuda.is_available():
        raise RequestError("device_unavailable", "CUDA is unavailable. Choose CPU.")
    torch.manual_seed(0)
    random.seed(0)
    dependency("numpy").random.seed(0)
    return torch, device, cache


def model_digest(model):
    """Fingerprint the actual loaded tensors, including backbone and calibration."""
    digest = hashlib.sha256()
    for name, value in sorted(model.state_dict().items()):
        tensor = value.detach().cpu().contiguous()
        digest.update(name.encode("utf-8"))
        digest.update(str(tuple(tensor.shape)).encode("ascii"))
        digest.update(str(tensor.dtype).encode("ascii"))
        digest.update(tensor.numpy().tobytes())
    return digest.hexdigest()


def tensor_from_rgb(torch, rgb, device):
    return torch.from_numpy(rgb.copy()).permute(2, 0, 1).unsqueeze(0).to(device=device, dtype=torch.float32)


def run_lpips(request, image, metadata):
    reference, ref_metadata = load_image(path_argument(request, "reference", True), request.get("roi"))
    if metadata["original_size"] != ref_metadata["original_size"] or image.shape != reference.shape:
        raise RequestError("size_mismatch", "LPIPS requires identically sized, aligned images. No implicit resizing is performed.")
    if min(image.shape[:2]) < 64:
        raise RequestError("roi_too_small", "LPIPS in Imspect requires both ROI dimensions to be at least 64 pixels; no implicit resize or padding is applied.")
    torch, device, cache = setup_torch(request)
    lpips = dependency("lpips")
    network = request.get("network", "alex")
    if network not in {"alex", "vgg", "squeeze"}:
        raise RequestError("invalid_network", "LPIPS network must be alex, vgg, or squeeze.")
    model = lpips.LPIPS(net=network, version="0.1", spatial=False, verbose=False).to(device).eval()
    a, b = tensor_from_rgb(torch, image, device) * 2 - 1, tensor_from_rgb(torch, reference, device) * 2 - 1
    with torch.inference_mode():
        # Scalar uses native feature-level spatial averaging. It is not inferred from a rendered map.
        score = float(model(a, b).item())
        result = {"score": score, "lower_better": True, "metric": "LPIPS"}
        if request.get("heatmap"):
            model.spatial = True
            spatial = model(a, b).squeeze().cpu().numpy()
            description = save_heatmap(spatial, path_argument(request, "heatmap"), request.get("heatmap_max"))
            description["interpretation"] = "Upsampled feature-space contributions; each location has a receptive field. This is not an independent per-pixel metric. Its displayed-map mean is not used as the scalar LPIPS score."
            result["heatmap"] = description["path"]
            metadata["heatmap"] = description
    calibration = Path(lpips.__file__).resolve().parent / "weights" / "v0.1" / (network + ".pth")
    metadata.update({"reference": ref_metadata, "model": network, "model_version": "0.1", "normalization": "RGB encoded sRGB converted [0,1] → [-1,1]",
                     "device": device, "calibration_sha256": sha256(calibration) if calibration.exists() else None,
                     "model_state_sha256": model_digest(model), "random_seed": 0,
                     "model_cache": str(cache), "score_aggregation": "upstream scalar LPIPS: mean within each feature layer, then weighted sum"})
    return result


def run_no_reference(request, image, metadata):
    operation = request["operation"]
    if operation == "niqe" and min(image.shape[:2]) < 192:
        raise RequestError("roi_too_small", "NIQE requires an ROI of at least 192×192 pixels in this app to provide multiple 96-pixel blocks; no enlargement is performed.")
    torch, device, cache = setup_torch(request)
    pyiqa = dependency("pyiqa")
    model = pyiqa.create_metric(operation, device=device)
    with torch.inference_mode():
        score = float(model(tensor_from_rgb(torch, image, device)).item())
    metadata.update({"model": operation, "weights": "pyiqa default pretrained checkpoint for the recorded package version", "device": device,
                     "model_state_sha256": model_digest(model), "random_seed": 0,
                     "model_cache": str(cache), "normalization": "RGB encoded sRGB [0,1]; model-specific preprocessing by pyiqa",
                     "interpretation": "A no-reference perceptual quality estimate, not fidelity to ground truth. Scores depend on model training domain; compare within the same model and image family.",
                     "preprocessing": "pyiqa model defaults may crop/resize internally; no app-level resize"})
    return {"score": score, "lower_better": bool(model.lower_better), "metric": operation.upper()}


def run_resize(request, image, metadata):
    np = dependency("numpy")
    sys.path.insert(0, str(ROOT / "vendor" / "resize_right"))
    resize_right = importlib.import_module("resize_right")
    methods = importlib.import_module("interp_methods")
    kernel = request.get("kernel", "cubic")
    padding = request.get("pad_mode", "symmetric")
    result = resize_right.resize(image, out_shape=[request["height"], request["width"]],
                                 scale_factors=request.get("scale_factors"), interp_method=getattr(methods, kernel),
                                 antialiasing=request.get("antialiasing", True), pad_mode=padding)
    output = path_argument(request, "output")
    save_rgb(result, output)
    metadata.update({"engine": "original vendored ResizeRight", "kernel": kernel, "padding": padding,
                     "antialiasing": request.get("antialiasing", True), "scale_factors": request.get("scale_factors") or [request["height"]/image.shape[0], request["width"]/image.shape[1]],
                     "output_size": [request["width"], request["height"]], "float_range": [float(np.min(result)), float(np.max(result))],
                     "png_encoding": "clipped to [0,1], rounded to uint8", "alpha": "straight alpha resized independently, same kernel",
                     "source_sha256": sha256(ROOT / "vendor" / "resize_right" / "resize_right.py")})
    if "float_output" in request:
        float_output = path_argument(request, "float_output")
        float_output.parent.mkdir(parents=True, exist_ok=True)
        with float_output.open("wb") as handle:
            np.save(handle, result, allow_pickle=False)
        metadata["float_output"] = str(float_output)
    return {"output": str(output)}


def run_fft(request, image, metadata):
    np = dependency("numpy")
    # Luma here is encoded-sRGB Rec.709 weighted intensity, not linear luminance.
    luma = image[..., :3] @ np.array([0.2126, 0.7152, 0.0722])
    spectrum = np.fft.fftshift(np.fft.fft2(luma))
    magnitude = np.log1p(np.abs(spectrum))
    upper = float(request.get("fft_max", math.log1p(image.shape[0] * image.shape[1])))
    if not math.isfinite(upper) or upper <= 0:
        raise RequestError("invalid_fft_scale", "fft_max must be positive and finite.")
    output = path_argument(request, "output")
    save_rgb(np.repeat((magnitude / upper)[..., None], 3, axis=2), output)
    raw = output.with_suffix(".npy")
    np.save(raw, spectrum, allow_pickle=False)
    metadata.update({"transform": "fftshift(fft2(0.2126R+0.7152G+0.0722B))", "padding": "none", "window": "none",
                     "display": "log1p(abs(F)) / fft_max", "fft_max": upper, "raw_complex_spectrum": str(raw)})
    return {"output": str(output)}


def execute(request):
    validate(request)
    operation = request["operation"]
    if operation == "capabilities":
        return {"ok": True, "protocol": PROTOCOL, "operation": operation, "versions": versions(),
                "operations": sorted(OPERATIONS), "models_installed": all(importlib.util.find_spec(name) is not None for name in ("torch", "lpips", "pyiqa")),
                "models_verified": False, "note": "Package availability does not imply that weights are downloaded or model inference has passed."}
    image, metadata = load_image(path_argument(request, "image", True), request.get("roi"), require_opaque=operation != "resize")
    metadata.update({"versions": versions(), "protocol": PROTOCOL})
    if operation == "lpips":
        result = run_lpips(request, image, metadata)
    elif operation in MODEL_OPERATIONS:
        result = run_no_reference(request, image, metadata)
    elif operation == "resize":
        result = run_resize(request, image, metadata)
    else:
        result = run_fft(request, image, metadata)
    if "score" in result and not math.isfinite(result["score"]):
        raise RequestError("nonfinite_result", "The model returned NaN or infinity. This image/ROI may be outside the metric's supported domain.")
    return dict(ok=True, protocol=PROTOCOL, operation=operation, metadata=metadata, **result)


def write_response(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=".imspect-", suffix=".json", delete=False) as handle:
        json.dump(payload, handle, indent=2, allow_nan=False)
        handle.write("\n")
        temporary = handle.name
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", type=Path, required=True)
    parser.add_argument("--response", type=Path, required=True)
    arguments = parser.parse_args()
    started = time.monotonic()
    try:
        request = json.loads(arguments.request.read_text())
        result = execute(request)
    except RequestError as exc:
        result = {"ok": False, "protocol": PROTOCOL, "error": {"code": exc.code, "message": str(exc)}}
    except (json.JSONDecodeError, OSError) as exc:
        result = {"ok": False, "protocol": PROTOCOL, "error": {"code": "file_or_json_error", "message": str(exc)}}
    except Exception as exc:
        result = {"ok": False, "protocol": PROTOCOL, "error": {"code": "backend_error", "message": f"{type(exc).__name__}: {exc}. Check the installed dependency versions and retry on CPU."}}
    result["elapsed_seconds"] = round(time.monotonic() - started, 4)
    write_response(arguments.response, result)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
