"""Portable Float32 encoded-sRGB image operations used by Imspect.

Image arrays are H×W×4 straight RGBA. Measurement never resizes, aligns,
composites, or clips input implicitly. Display reconstruction uses image-edge
coordinates: the first sample's center is (0.5, 0.5).
"""
from __future__ import annotations

import io
import math
import struct
import zlib
from collections import OrderedDict
from pathlib import Path
from typing import Optional

import numpy as np
from PIL import Image, ImageCms, ImageOps
from scipy.ndimage import convolve1d

MAX_PIXELS = 64_000_000
MAX_SIDE = 16384
EPS = float(np.finfo(np.float32).eps)
KERNELS = ("nearest", "linear", "cubic", "lanczos2", "lanczos3")
CONVENTION = ("Encoded sRGB RGB, range 1, opaque alpha; SSIM: 11×11 Gaussian "
              "sigma1.5, population covariance, valid centers, mean RGB; "
              "histogram: mean RGB Wasserstein-1 /255; DeltaE: CIE76 D65.")


def validate_image(array, copy=False):
    a = np.asarray(array)
    if a.ndim != 3 or a.shape[2] != 4 or not 0 < a.shape[0] * a.shape[1] <= MAX_PIXELS:
        raise ValueError("Images must be nonempty H×W×4 RGBA arrays, at most 64 million pixels.")
    if a.dtype.kind not in "fiu":
        raise ValueError("Image samples must be numeric.")
    a = np.array(a, dtype=np.float32, copy=copy) if copy else np.asarray(a, dtype=np.float32)
    if not np.isfinite(a).all():
        raise ValueError("Image samples must be finite.")
    if np.any(a[..., 3] < 0) or np.any(a[..., 3] > 1):
        raise ValueError("Alpha must be in [0,1].")
    return a


def _size(width, height):
    if isinstance(width, bool) or isinstance(height, bool) or not isinstance(width, (int, np.integer)) or not isinstance(height, (int, np.integer)):
        raise ValueError("Image dimensions must be integers.")
    if not 0 < width <= MAX_SIDE or not 0 < height <= MAX_SIDE or width * height > MAX_PIXELS:
        raise ValueError("Image dimensions must be positive, at most 16384 per side and 64 million pixels.")


def _oriented(a, orientation):
    return {2: lambda x: x[:, ::-1], 3: lambda x: x[::-1, ::-1],
            4: lambda x: x[::-1], 5: lambda x: x.transpose(1, 0, 2),
            6: lambda x: np.rot90(x, -1), 7: lambda x: x.transpose(1, 0, 2)[::-1, ::-1],
            8: lambda x: np.rot90(x, 1)}.get(orientation, lambda x: x)(a).copy()


def load_image(path):
    path = Path(path)
    with Image.open(path) as source:
        if source.width * source.height > MAX_PIXELS:
            raise ValueError("Images above 64 million pixels are not supported.")
        orientation = int(source.getexif().get(274, 1))
        profile = source.info.get("icc_profile")
        # Pillow reduces RGB 16-bit PNG to 8 bits. Decode these explicitly.
        with path.open("rb") as header_file:
            header = header_file.read(25)
        png16 = header[:8] == b"\x89PNG\r\n\x1a\n" and len(header) >= 25 and header[24] == 16
        if png16:
            if profile:
                raise ValueError("16-bit PNG with an embedded ICC profile needs explicit sRGB conversion before import; it is never reduced to 8 bits silently.")
            import png
            with path.open("rb") as png_file:
                w, h, rows, meta = png.Reader(file=png_file).asDirect()
                values = np.vstack([np.asarray(row, dtype=np.float32) for row in rows]).reshape(h, w, meta["planes"]) / 65535
            if meta["greyscale"]:
                rgb = np.repeat(values[..., :1], 3, axis=2)
                alpha = values[..., 1:2] if meta["alpha"] else np.ones((h, w, 1), np.float32)
                a = np.concatenate((rgb, alpha), axis=2)
            else:
                a = values if meta["alpha"] else np.concatenate((values, np.ones((h, w, 1), np.float32)), axis=2)
            return validate_image(_oriented(a, orientation))
        bits = getattr(source, "tag_v2", {}).get(258, (8,))
        bits = bits if isinstance(bits, (tuple, list)) else (bits,)
        if any(b > 8 for b in bits) and source.mode not in ("I;16", "I;16L", "I;16B"):
            raise ValueError("High-bit-depth RGB TIFF import is not supported; use 16-bit sRGB PNG.")
        if source.mode in ("I;16", "I;16L", "I;16B"):
            if profile:
                raise ValueError("16-bit ICC conversion is unsupported; convert explicitly to sRGB PNG.")
            v = np.asarray(source, dtype=np.float32) / 65535
            a = np.concatenate((np.repeat(v[..., None], 3, axis=2), np.ones((*v.shape, 1), np.float32)), axis=2)
            return validate_image(_oriented(a, orientation))
        if source.mode in ("I", "F"):
            raise ValueError("Integer/float scientific image import needs a declared range and is not supported.")
        image = ImageOps.exif_transpose(source)
        alpha = image.convert("RGBA").getchannel("A")
        if profile:
            try:
                candidate = image if image.mode in ("RGB", "CMYK", "LAB", "L") else image.convert("RGB")
                image = ImageCms.profileToProfile(candidate, ImageCms.ImageCmsProfile(io.BytesIO(profile)), ImageCms.createProfile("sRGB"), outputMode="RGB")
            except Exception as exc:
                raise ValueError("Could not convert the embedded ICC profile to sRGB: " + str(exc)) from exc
        image = image.convert("RGBA")
        image.putalpha(alpha)
        return validate_image(np.asarray(image, dtype=np.float32) / 255)


def save_png(array, path):
    import png
    a = validate_image(array)
    h, w = a.shape[:2]
    samples = np.floor(np.clip(a, 0, 1) * 65535 + .5).astype(np.uint16)
    stream = io.BytesIO()
    png.Writer(w, h, greyscale=False, alpha=True, bitdepth=16).write(stream, samples.reshape(h, w * 4))
    encoded = stream.getvalue()
    # Standard sRGB chunk, perceptual intent, immediately after IHDR.
    body = b"sRGB\x00"
    chunk = struct.pack(">I", 1) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)
    Path(path).write_bytes(encoded[:33] + chunk + encoded[33:])


def crop(array, roi=None):
    a = validate_image(array)
    if roi is None:
        return a
    if not isinstance(roi, (tuple, list)) or len(roi) != 4 or any(isinstance(v, bool) or not isinstance(v, (int, np.integer)) for v in roi):
        raise ValueError("Region must be integer [x, y, width, height].")
    x, y, w, h = roi
    if x < 0 or y < 0 or w < 1 or h < 1 or x + w > a.shape[1] or y + h > a.shape[0]:
        raise ValueError("The selected region must lie completely inside every image.")
    return a[y:y+h, x:x+w]


def _bins(rgb):
    # Swift's rounded() is ties-away-from-zero for these nonnegative samples.
    return np.floor(np.clip(rgb, 0, 1) * 255 + .5).astype(np.uint8)


def histogram(array, roi=None):
    a = crop(array, roi)
    bins = _bins(a[..., :3])
    return np.stack([np.bincount(bins[..., c].ravel(), minlength=256) for c in range(3)]).astype(np.float64) / (a.shape[0] * a.shape[1])


def _pair(ref, array, roi=None):
    a, b = validate_image(ref), validate_image(array)
    if a.shape != b.shape:
        raise ValueError("Metrics require identical dimensions. Resize explicitly; no alignment is applied.")
    a, b = crop(a, roi), crop(b, roi)
    for im in (a, b):
        if np.any(np.abs(im[..., 3] - 1) >= 1e-5):
            raise ValueError("Metrics require opaque images. Composite transparency before measuring.")
        if np.any(im[..., :3] < -1e-6) or np.any(im[..., :3] > 1.000001):
            raise ValueError("Metrics require range [0,1]. Clip out-of-range samples explicitly.")
    return a, b


def _gaussian_kernel(sigma, radius):
    if sigma == 0:
        return np.ones(1)
    v = np.exp(-np.arange(-radius, radius + 1, dtype=np.float64)**2 / (2 * sigma**2))
    return v / v.sum()


def _blur(a, sigma=1.5, radius=5):
    weights = _gaussian_kernel(sigma, radius)
    return convolve1d(convolve1d(a, weights, axis=1, mode="reflect"), weights, axis=0, mode="reflect")


def ssim_map(ref, array):
    a, b = _pair(ref, array)
    if min(a.shape[:2]) < 11:
        return None
    score = np.zeros((a.shape[0] - 10, a.shape[1] - 10), np.float64)
    for c in range(3):
        x, y = a[..., c].astype(np.float64), b[..., c].astype(np.float64)
        ux, uy = _blur(x)[5:-5, 5:-5], _blur(y)[5:-5, 5:-5]
        vx = np.maximum(0, _blur(x*x)[5:-5, 5:-5] - ux*ux)
        vy = np.maximum(0, _blur(y*y)[5:-5, 5:-5] - uy*uy)
        cov = _blur(x*y)[5:-5, 5:-5] - ux*uy
        value = ((2*ux*uy + .0001)*(2*cov + .0009))/((ux*ux + uy*uy + .0001)*(vx + vy + .0009))
        score += np.clip(value, -1, 1) / 3
    return score.astype(np.float32)


def _lab(rgb):
    x = np.clip(rgb.astype(np.float64), 0, 1)
    x = np.where(x <= .04045, x / 12.92, ((x + .055)/1.055)**2.4)
    r,g,b = x[...,0],x[...,1],x[...,2]
    xyz = np.stack((.4124564*r+.3575761*g+.1804375*b,
                    .2126729*r+.7151522*g+.0721750*b,
                    .0193339*r+.1191920*g+.9503041*b),axis=-1)
    xyz /= [.95047, 1, 1.08883]
    f = np.where(xyz > 216/24389, np.cbrt(xyz), (24389/27*xyz + 16)/116)
    return np.stack((116*f[..., 1]-16, 500*(f[..., 0]-f[..., 1]), 200*(f[..., 1]-f[..., 2])), axis=-1)


def metrics(ref, array, roi=None):
    a, b = _pair(ref, array, roi)
    d = a[..., :3].astype(np.float64) - b[..., :3].astype(np.float64)
    mse = float(np.mean(d*d))
    h = np.abs(np.cumsum(histogram(a) - histogram(b), axis=1)[:, :255]).sum()/(3*255)
    local = ssim_map(a, b)
    delta = np.linalg.norm(_lab(a[..., :3]) - _lab(b[..., :3]), axis=-1).mean()
    return {"mse": mse, "psnr": math.inf if mse == 0 else -10*math.log10(mse),
            "ssim": None if local is None else float(local.mean(dtype=np.float64)),
            "histogram": float(h), "delta_e": float(delta), "pixels": a.shape[0]*a.shape[1]}


def _heat(values):
    stops = np.array([[.015,.01,.06],[.32,.06,.43],[.80,.20,.22],[.99,.59,.15],[.99,.98,.70]], np.float32)
    v = np.clip(values, 0, 1) * 4
    index = np.minimum(3, v.astype(np.int32))
    t = (v-index)[..., None]
    return stops[index]*(1-t) + stops[index+1]*t


def derived(array, reference=None, mode="images", gain=1):
    a = validate_image(array)
    if mode == "images":
        return a
    if not math.isfinite(gain) or gain <= 0:
        raise ValueError("Display gain must be finite and positive.")
    if mode == "fft":
        h, w = (1 << (int(s)-1).bit_length() for s in a.shape[:2])
        if w*h > MAX_PIXELS:
            raise ValueError("Padded FFT would exceed 64 million pixels.")
        luma = a[..., :3] @ np.array([.2126,.7152,.0722], np.float32)
        values = np.clip(np.log1p(1000*np.abs(np.fft.fftshift(np.fft.fft2(luma, s=(h,w))))/(h*w))/np.log(1001), 0, 1)
        out = np.ones((h,w,4), np.float32)
        out[..., :3] = values[..., None]
        return out
    if reference is None:
        raise ValueError("Choose a reference image for this view.")
    a, b = _pair(a, reference)
    out = np.ones_like(a)
    if mode in ("difference", "absolute"):
        out[..., :3] = np.clip(np.abs(a[..., :3] - b[..., :3])*gain, 0, 1)
    elif mode == "mse":
        out[..., :3] = _heat(np.mean((a[..., :3]-b[..., :3])**2, axis=2)*gain)
    elif mode == "ssim":
        local = ssim_map(a,b)
        if local is None:
            raise ValueError("SSIM maps need at least 11×11 pixels.")
        out[:] = 0
        out[5:-5,5:-5,:3] = _heat((1-local)/2*gain)
        out[5:-5,5:-5,3] = 1
    else:
        raise ValueError("Unknown image view: " + str(mode))
    return out.astype(np.float32)


def _kernel_values(d, kernel):
    x = np.abs(d)
    if kernel == "linear":
        return np.maximum(0, 1-x)
    if kernel == "cubic":
        return np.where(x <= 1, (1.5*x-2.5)*x*x+1, np.where(x <= 2, ((-.5*x+2.5)*x-4)*x+2, 0))
    r = 2 if kernel == "lanczos2" else 3
    return np.where(x < r, (np.sin(np.pi*x)*np.sin(np.pi*x/r)+EPS)/(np.pi*np.pi*x*x/r+EPS), 0)


def _taps(size, centers, scale, kernel, boundary):
    if kernel not in KERNELS or boundary not in ("symmetric", "constant"):
        raise ValueError("Unsupported resampling kernel or boundary rule.")
    if kernel == "nearest":
        indices = np.floor(centers[:, None] + .5).astype(np.int64)
        weights = np.ones(indices.shape, np.float64)
    else:
        support = {"linear":2, "cubic":4, "lanczos2":4, "lanczos3":6}[kernel]
        aa = min(1, scale)
        extent = support/aa
        count = int(np.ceil(extent-EPS))
        if count > 131072 or centers.size*count > 64_000_000:
            raise ValueError("Zoom is too small for the available display budget.")
        left = np.ceil(centers-extent/2-EPS).astype(np.int64)
        indices = left[:, None] + np.arange(count)
        weights = aa * _kernel_values((centers[:, None]-indices)*aa, kernel)
        sums = weights.sum(axis=1, keepdims=True)
        weights /= np.where(sums == 0, 1, sums)
    if boundary == "constant":
        weights *= (indices >= 0) & (indices < size)
        indices = np.clip(indices, 0, size-1)
    else:
        indices %= (2*size)
        indices = np.where(indices < size, indices, 2*size-1-indices)
    return indices, weights.astype(np.float32)


def _sample(array, xs, ys, sx, sy, kernel, boundary="symmetric", preserve_opaque=False):
    tx, wx = _taps(array.shape[1], xs, sx, kernel, boundary)
    ty, wy = _taps(array.shape[0], ys, sy, kernel, boundary)
    source = array.copy()
    source[..., :3] *= source[..., 3:4]
    result = np.zeros((len(ys),len(xs),4), np.float32)
    rows = OrderedDict()
    # A small row cache bounds memory independently of magnification.
    for y in range(len(ys)):
        for source_y, weight in zip(ty[y], wy[y]):
            if weight == 0:
                continue
            source_y = int(source_y)
            if source_y not in rows:
                rows[source_y] = np.einsum("ntc,nt->nc", source[source_y,tx], wx, optimize=True)
                if len(rows) > 128:
                    rows.popitem(last=False)
            result[y] += rows[source_y]*weight
            rows.move_to_end(source_y)
    alpha = result[...,3:4]
    if preserve_opaque:
        # Native opaque constant-padding behavior keeps zero-padded RGB and alpha1.
        result[...,3] = 1
    else:
        np.divide(result[...,:3], alpha, out=result[...,:3], where=np.abs(alpha)>1e-7)
        result[...,:3] = np.where(np.abs(alpha)>1e-7, result[...,:3], 0)
        result[...,3] = np.clip(result[...,3],0,1)
    return result


def resize(array, width, height, kernel="cubic", scale_x=None, scale_y=None, boundary="symmetric"):
    a = validate_image(array)
    _size(width,height)
    sx = width/a.shape[1] if scale_x is None else float(scale_x)
    sy = height/a.shape[0] if scale_y is None else float(scale_y)
    if not math.isfinite(sx) or not math.isfinite(sy) or min(sx,sy) < 1/16384:
        raise ValueError("Resize scale must be finite and positive.")
    if kernel not in KERNELS or boundary not in ("symmetric","constant"):
        raise ValueError("Unsupported resampling kernel or boundary rule.")
    if width == a.shape[1] and height == a.shape[0] and sx == 1 and sy == 1:
        return a.copy()
    xs = np.arange(width)/sx + (a.shape[1]-1)/2 - (width-1)/(2*sx)
    ys = np.arange(height)/sy + (a.shape[0]-1)/2 - (height-1)/(2*sy)
    return _sample(a,xs,ys,sx,sy,kernel,boundary,preserve_opaque=bool(np.all(np.abs(a[...,3]-1)<1e-6)))


def render_patch(array, origin, scale, width, height, kernel="cubic"):
    """Render a bounded viewport using source image-edge coordinates.

    Output center (j+.5,k+.5) samples source origin+(j+.5,k+.5)/scale.
    Source pixel (0,0) is centered at(.5,.5); outside-image centers are transparent.
    """
    a = validate_image(array)
    _size(width,height)
    if len(origin) != 2 or not all(math.isfinite(float(v)) and abs(float(v)) <= 100_000_000 for v in origin):
        raise ValueError("Invalid view origin.")
    if not math.isfinite(scale) or not 1/16384 <= scale <= 16384:
        raise ValueError("Zoom must be between 1/16384 and 16384.")
    xe = float(origin[0])+(np.arange(width)+.5)/scale
    ye = float(origin[1])+(np.arange(height)+.5)/scale
    valid_x = (xe >= 0) & (xe < a.shape[1])
    valid_y = (ye >= 0) & (ye < a.shape[0])
    out = np.zeros((height,width,4), np.float32)
    if valid_x.any() and valid_y.any():
        patch = _sample(a,xe[valid_x]-.5,ye[valid_y]-.5,scale,scale,kernel)
        out[np.ix_(valid_y,valid_x)] = patch
    return out


def channel_adjust(array, values):
    a = validate_image(array)
    values = np.asarray(values, dtype=np.float32)
    if values.shape != (3,) or not np.isfinite(values).all() or np.any(np.abs(values)>1):
        raise ValueError("Channel settings must contain three finite values in [-1,1].")
    out = a.copy()
    for c,t in enumerate(values):
        if t == -1:
            out[...,c] = 0
        elif t == 1:
            out[...,c] = 1
        elif t < 0:
            out[...,c] *= 1+t
        elif t > 0:
            out[...,c] += (1-out[...,c])*t
    return out


def apply_edit(array, operation, amount=1, seed=42, reference=None):
    a = validate_image(array)
    if not math.isfinite(amount) or amount < 0:
        raise ValueError("Filter amount must be finite and nonnegative.")
    out = a.copy()
    if operation == "grayscale":
        out[...,:3] = (a[...,:3] @ np.array([.2126,.7152,.0722],np.float32))[...,None]
    elif operation == "clip":
        out[:] = np.clip(a,0,1)
    elif operation in ("white","black"):
        out[...,:3] = np.clip(a[...,:3],0,1)*a[...,3:4] + (1 if operation=="white" else 0)*(1-a[...,3:4])
        out[...,3] = 1
    elif operation in ("gaussian","sharpen"):
        sigma = amount if operation == "gaussian" else 1
        if sigma > 50:
            raise ValueError("Gaussian sigma is limited to 50 pixels.")
        if sigma == 0:
            return out
        premul = a.copy()
        premul[...,:3] *= premul[...,3:4]
        blurred = _blur(premul, sigma, int(math.ceil(3*sigma)))
        smooth = np.divide(blurred[...,:3],blurred[...,3:4],out=np.zeros_like(blurred[...,:3]),where=blurred[...,3:4]>1e-7)
        out[...,:3] = smooth if operation == "gaussian" else np.clip(a[...,:3]+amount*(a[...,:3]-smooth),0,1)
    elif operation == "noise":
        if amount > 1:
            raise ValueError("Noise sigma must be in [0,1].")
        if not isinstance(seed,(int,np.integer)) or seed < 0:
            raise ValueError("Noise seed must be a nonnegative integer.")
        # Same SplitMix64 + Box-Muller sequence as the native Mac engine.
        rows_per_chunk = max(1,262144//(a.shape[1]*3))
        for y in range(0,a.shape[0],rows_per_chunk):
            block = a[y:y+rows_per_chunk,...,:3]
            count = block.size
            offset = y*a.shape[1]*6
            with np.errstate(over="ignore"):
                states = np.uint64(seed & ((1<<64)-1)) + np.arange(offset+1,offset+count*2+1,dtype=np.uint64)*np.uint64(0x9E3779B97F4A7C15)
                z = (states ^ (states >> np.uint64(30))) * np.uint64(0xBF58476D1CE4E5B9)
                z = (z ^ (z >> np.uint64(27))) * np.uint64(0x94D049BB133111EB)
                z ^= z >> np.uint64(31)
            u = ((z >> np.uint64(11)).astype(np.float64)+.5)/9007199254740992.0
            noise = (np.sqrt(-2*np.log(u[::2]))*np.cos(2*np.pi*u[1::2])).astype(np.float32).reshape(block.shape)
            out[y:y+rows_per_chunk,...,:3] = np.clip(block+np.float32(amount)*noise,0,1)
    elif operation == "bilateral":
        if amount > 1:
            raise ValueError("Bilateral RGB range sigma must be in [0,1].")
        if amount == 0:
            return out
        h,w = a.shape[:2]
        padded = np.pad(a,((4,4),(4,4),(0,0)),mode="symmetric")
        total = np.zeros((h,w),np.float32)
        weighted = np.zeros((h,w,3),np.float32)
        for dy in range(-4,5):
            for dx in range(-4,5):
                v = padded[4+dy:4+dy+h,4+dx:4+dx+w]
                distance = np.sum((a[...,:3]-v[...,:3])**2,axis=2)
                weight = np.exp(-(dx*dx+dy*dy)/8-distance/(2*max(amount,.00001)**2))*v[...,3]
                total += weight
                weighted += weight[...,None]*v[...,:3]
        np.divide(weighted,total[...,None],out=out[...,:3],where=total[...,None]>0)
    elif operation == "match_histogram":
        if reference is None:
            raise ValueError("Choose a reference image before matching histograms.")
        b = validate_image(reference)
        if a.shape == b.shape and np.array_equal(a,b):
            return out
        ca,cb = np.cumsum(histogram(a),axis=1),np.cumsum(histogram(b),axis=1)
        bins = _bins(a[...,:3])
        for c in range(3):
            lut = np.minimum(255,np.searchsorted(cb[c],ca[c],side="left"))/255
            out[...,c] = lut[bins[...,c]]
    else:
        raise ValueError("Unknown edit: " + str(operation))
    return out.astype(np.float32)


def demo_images():
    h,w = 384,512
    y,x = np.mgrid[:h,:w].astype(np.float32)
    a = np.ones((h,w,4),np.float32)
    a[...,0] = .15+.7*x/(w-1)
    a[...,1] = .15+.7*y/(h-1)
    a[...,2] = .25+.25*np.sin(x*.12)*np.cos(y*.13)
    checker = ((x//8+y//8)%2)*.8+.1
    a[40:180,35:225,:3] = checker[40:180,35:225,None]
    radius = np.sqrt((x-360)**2+(y-130)**2)
    rings = (.5+.4*np.cos(radius*.85)).astype(np.float32)
    mask = radius < 90
    a[mask,:3] = np.stack((rings[mask],.6*rings[mask],1-rings[mask]),axis=-1)
    for k in range(6):
        yy = 240+14*k
        a[yy:yy+3,40:470,:3] = [.95,.85,.25]
    blurred = apply_edit(a,"gaussian",.8)
    noisy = apply_edit(blurred,"noise",10/255,42)
    return [("Reference · resolution target",a),("Blurred + noise",noisy),("Bilateral filtered",apply_edit(noisy,"bilateral",.12))]
