import AppKit
import ImageIO
import Accelerate
import UniformTypeIdentifiers

/// All coordinates use the top-left image corner, with integer pixel centers.
/// RGB is encoded sRGB, straight alpha, Float32. No transform silently clips stored samples.
struct PixelBuffer {
    let width: Int
    let height: Int
    var rgba: [Float]

    init(width: Int, height: Int, rgba: [Float]) {
        precondition(width > 0 && height > 0 && width <= Int.max / height / 4 && rgba.count == width * height * 4)
        self.width = width; self.height = height; self.rgba = rgba
    }

    static func load(url: URL) throws -> PixelBuffer {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImageEngineError.message("The image could not be decoded. Use PNG, JPEG, TIFF, HEIC or another ImageIO image format.")
        }
        guard image.width * image.height <= 64_000_000 else { throw ImageEngineError.message("Images above 64 million pixels are not supported in this build.") }
        let raw = try from(cgImage: image)
        let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (metadata?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return raw.oriented(orientation)
    }

    static func from(cgImage image: CGImage) throws -> PixelBuffer {
        guard image.width > 0, image.height > 0, image.width * image.height <= 64_000_000 else {
            throw ImageEngineError.message("The image dimensions are unsupported.")
        }
        let width = image.width, height = image.height
        var data = [Float](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let ok = data.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 32,
                                          bytesPerRow: width * 16, space: colorSpace, bitmapInfo: info) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw ImageEngineError.message("Could not convert the image to Float32 sRGB.") }
        for i in stride(from: 0, to: data.count, by: 4) {
            let alpha = data[i + 3]
            if alpha > 0 { for c in 0..<3 { data[i + c] /= alpha } }
            else { data[i] = 0; data[i + 1] = 0; data[i + 2] = 0 }
        }
        return PixelBuffer(width: width, height: height, rgba: data)
    }

    /// Float32 backing avoids an 8-bit quantization on the path to the display.
    /// Display compositing clamps out-of-gamut values; the stored samples remain untouched.
    func cgImage() -> CGImage {
        var premultiplied = rgba
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = max(0, min(1, rgba[i + 3]))
            for c in 0..<3 { premultiplied[i + c] = max(0, min(1, rgba[i + c])) * alpha }
            premultiplied[i + 3] = alpha
        }
        let data = premultiplied.withUnsafeBytes { Data($0) } as CFData
        let provider = CGDataProvider(data: data)!
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
                       bytesPerRow: width * 16, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric)!
    }

    /// Exports 16-bit sRGB PNG. Out-of-range samples are clipped only in the exported copy.
    func pngData() -> Data? {
        var samples = [UInt16](repeating: 0, count: rgba.count)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let a = max(0, min(1, rgba[i + 3]))
            for c in 0..<3 { samples[i + c] = UInt16((max(0, min(1, rgba[i + c])) * a * 65535).rounded()) }
            samples[i + 3] = UInt16((a * 65535).rounded())
        }
        let data = samples.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                                  bytesPerRow: width * 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric) else { return nil }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? result as Data : nil
    }

    func pixel(x: Int, y: Int) -> [Float]? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        return Array(rgba[i..<i + 4])
    }

    func cropped(_ rect: CGRect) throws -> PixelBuffer {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else {
            throw ImageEngineError.message("Crop coordinates must be finite.")
        }
        let r = rect.standardized.integral
        guard r.width >= 1, r.height >= 1, r.minX >= 0, r.minY >= 0, r.maxX <= CGFloat(width), r.maxY <= CGFloat(height) else {
            throw ImageEngineError.message("The crop must lie completely inside every selected image.")
        }
        let x = Int(r.minX), y = Int(r.minY), w = Int(r.width), h = Int(r.height)
        var out = [Float](); out.reserveCapacity(w * h * 4)
        for row in y..<y+h {
            let offset = (row * width + x) * 4
            out.append(contentsOf: rgba[offset..<offset+w*4])
        }
        return PixelBuffer(width: w, height: h, rgba: out)
    }

    fileprivate func oriented(_ orientation: Int) -> PixelBuffer {
        guard (2...8).contains(orientation) else { return self }
        let swapped = orientation >= 5
        let w = swapped ? height : width, h = swapped ? width : height
        var result = [Float](repeating: 0, count: rgba.count)
        for y in 0..<h { for x in 0..<w {
            let sx: Int, sy: Int
            switch orientation {
            case 2: sx = width - 1 - x; sy = y
            case 3: sx = width - 1 - x; sy = height - 1 - y
            case 4: sx = x; sy = height - 1 - y
            case 5: sx = y; sy = x
            case 6: sx = y; sy = height - 1 - x
            case 7: sx = width - 1 - y; sy = height - 1 - x
            case 8: sx = width - 1 - y; sy = x
            default: sx = x; sy = y
            }
            for c in 0..<4 { result[(y*w+x)*4+c] = rgba[(sy*width+sx)*4+c] }
        } }
        return PixelBuffer(width: w, height: h, rgba: result)
    }
}

enum ImageEngineError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum ResizeKernel: String, CaseIterable { case nearest, linear, cubic, lanczos2, lanczos3 }
enum ResizeBoundary: String, CaseIterable { case constant, symmetric }

struct MetricResult {
    let mse: Double
    let psnr: Double
    let ssim: Double?
    /// Mean channel-wise Wasserstein-1 distance between 256-bin histograms, in [0,1].
    let histogramDistance: Double
    /// Mean CIE76 distance, sRGB -> XYZ D65 -> Lab D65.
    let meanDeltaE: Double?
    let pixelCount: Int
    let convention = "Encoded sRGB RGB; range 1; all pixels; alpha must be opaque. SSIM: 11×11 Gaussian σ=1.5, population covariance, valid centers, mean over RGB. Histogram: mean RGB W₁ / 255. ΔE: CIE76, D65."
}

enum ImageEngine {
    private static func clamp(_ x: Float) -> Float { max(0, min(1, x)) }
    private static func mirrored(_ i: Int, _ count: Int) -> Int {
        let period = 2 * count
        let r = ((i % period) + period) % period
        return r < count ? r : period - 1 - r
    }

    /// Separable centered-grid resampler, mathematically based on ResizeRight.
    /// Unlike an output-size-only API, scaleX/scaleY retain the intended scale when dimensions round.
    /// Cubic/Lanczos/linear antialias when shrinking; nearest is an unfiltered point sampler.
    /// Symmetric padding is deliberate; ResizeRight's upstream default is constant padding.
    static func resize(_ image: PixelBuffer, width: Int, height: Int, kernel: ResizeKernel,
                       scaleX: Double? = nil, scaleY: Double? = nil,
                       boundary: ResizeBoundary = .symmetric) throws -> PixelBuffer {
        guard width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 64_000_000 else {
            throw ImageEngineError.message("Resize dimensions must be positive, at most 16384 per side and 64 million pixels in total.")
        }
        let sx = scaleX ?? Double(width) / Double(image.width)
        let sy = scaleY ?? Double(height) / Double(image.height)
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0, sx >= 1.0 / 16384, sy >= 1.0 / 16384 else {
            throw ImageEngineError.message("Resize scales must be finite and positive.")
        }
        if width == image.width && height == image.height && sx == 1 && sy == 1 { return image }
        struct Tap { let index: Int; let weight: Float }
        func taps(_ input: Int, _ output: Int, _ scale: Double) -> [[Tap]] {
            let support: Double
            switch kernel { case .nearest: support = 1; case .linear: support = 2; case .cubic, .lanczos2: support = 4; case .lanczos3: support = 6 }
            let aa = kernel == .nearest ? 1 : min(1, scale)
            let extent = support / aa
            let count = Int(ceil(extent - Double(Float.ulpOfOne)))
            func kernelValue(_ value: Double) -> Double {
                let x = abs(value)
                switch kernel {
                case .nearest: return x <= 0.5 ? 1 : 0
                case .linear: return max(0, 1 - x)
                case .cubic:
                    if x <= 1 { return (1.5*x-2.5)*x*x+1 }
                    if x <= 2 { return ((-0.5*x+2.5)*x-4)*x+2 }
                    return 0
                case .lanczos2, .lanczos3:
                    let radius = kernel == .lanczos2 ? 2.0 : 3.0
                    if x >= radius { return 0 }
                    // ResizeRight includes Float32 epsilon in numerator and denominator.
                    let eps = Double(Float.ulpOfOne)
                    return (sin(Double.pi * x) * sin(Double.pi * x / radius) + eps) / (Double.pi * Double.pi * x*x / radius + eps)
                }
            }
            return (0..<output).map { out in
                let center = Double(out) / scale + Double(input - 1) / 2 - Double(output - 1) / (2 * scale)
                if kernel == .nearest {
                    let index = Int(floor(center + 0.5))
                    return [Tap(index: boundary == .symmetric ? mirrored(index, input) : index, weight: 1)]
                }
                let left = Int(ceil(center - extent / 2 - Double(Float.ulpOfOne)))
                let weights = (0..<count).map { aa * kernelValue((center - Double(left + $0)) * aa) }
                let sum = weights.reduce(0, +)
                return weights.enumerated().map { j, weight in
                    let index = left + j
                    return Tap(index: boundary == .symmetric ? mirrored(index, input) : index, weight: Float(weight / (sum == 0 ? 1 : sum)))
                }.filter { $0.weight != 0 }
            }
        }
        let tx = taps(image.width, width, sx), ty = taps(image.height, height, sy)
        // Premultiply during reconstruction so transparent pixels cannot create color fringes.
        var source = image.rgba
        let opaque = stride(from: 3, to: source.count, by: 4).allSatisfy { abs(source[$0] - 1) < 1e-6 }
        if !opaque { for i in stride(from: 0, to: source.count, by: 4) { for c in 0..<3 { source[i+c] *= source[i+3] } } }
        func horizontal(_ input: [Float], _ inW: Int, _ inH: Int) -> [Float] {
            var result = [Float](repeating: 0, count: width * inH * 4)
            for y in 0..<inH { for x in 0..<width { for t in tx[x] where t.index >= 0 && t.index < inW {
                let from = (y*inW+t.index)*4, to = (y*width+x)*4
                for c in 0..<4 { result[to+c] += input[from+c] * t.weight }
            } } }
            return result
        }
        func vertical(_ input: [Float], _ inW: Int, _ inH: Int) -> [Float] {
            var result = [Float](repeating: 0, count: inW * height * 4)
            for y in 0..<height { for t in ty[y] where t.index >= 0 && t.index < inH { for x in 0..<inW {
                let from = (t.index*inW+x)*4, to = (y*inW+x)*4
                for c in 0..<4 { result[to+c] += input[from+c] * t.weight }
            } } }
            return result
        }
        // Same dimension ordering as ResizeRight: smallest scale first, y first on a tie.
        var result: [Float]
        if sy <= sx { result = horizontal(vertical(source, image.width, image.height), image.width, height) }
        else { result = vertical(horizontal(source, image.width, image.height), width, image.height) }
        if !opaque {
            for i in stride(from: 0, to: result.count, by: 4) {
                let a = result[i+3]
                if abs(a) > 1e-7 { for c in 0..<3 { result[i+c] /= a } }
                else { for c in 0..<3 { result[i+c] = 0 } }
                result[i+3] = clamp(a)
            }
        } else {
            // RGB is padded with zeros, but the comparison image remains opaque.
            for i in stride(from: 3, to: result.count, by: 4) { result[i] = 1 }
        }
        return PixelBuffer(width: width, height: height, rgba: result)
    }

    /// Reconstructs only the visible viewport, with the selected kernel at every zoom.
    /// sourceRect uses image-edge coordinates (the first pixel center is at 0.5,0.5).
    /// Output center j maps to sourceRect.minX + (j+0.5)*sourceRect.width/width - 0.5
    /// in the integer-centered sample grid. Padding is symmetric at the full image edges,
    /// never at the viewport edges, so separately requested adjacent patches have no seams.
    /// Continuous kernels antialias shrinking; nearest remains point sampling.
    /// A bounded row cache avoids allocating an enlarged copy of the full source image.
    static func resampleViewport(_ image: PixelBuffer, sourceRect: CGRect,
                                 width: Int, height: Int, kernel: ResizeKernel) throws -> PixelBuffer {
        guard width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 64_000_000 else {
            throw ImageEngineError.message("Viewport dimensions must be positive, at most 16384 per side and 64 million pixels in total.")
        }
        guard sourceRect.minX.isFinite, sourceRect.minY.isFinite, sourceRect.width.isFinite, sourceRect.height.isFinite,
              sourceRect.width > 0, sourceRect.height > 0,
              abs(sourceRect.minX) <= 100_000_000, abs(sourceRect.minY) <= 100_000_000,
              sourceRect.width <= 1_000_000, sourceRect.height <= 1_000_000 else {
            throw ImageEngineError.message("The visible image region must have finite, positive dimensions.")
        }
        let sx = Double(width) / Double(sourceRect.width), sy = Double(height) / Double(sourceRect.height)
        struct Tap { let index: Int; let weight: Float }
        func taps(_ input: Int, _ output: Int, _ scale: Double, _ origin: Double) -> [[Tap]] {
            let support: Double
            switch kernel { case .nearest: support = 1; case .linear: support = 2; case .cubic, .lanczos2: support = 4; case .lanczos3: support = 6 }
            let aa = kernel == .nearest ? 1 : min(1, scale)
            let extent = support / aa
            let count = Int(ceil(extent - Double(Float.ulpOfOne)))
            func weight(_ distance: Double) -> Double {
                let x = abs(distance)
                switch kernel {
                case .nearest: return x <= 0.5 ? 1 : 0
                case .linear: return max(0, 1-x)
                case .cubic:
                    if x <= 1 { return (1.5*x-2.5)*x*x+1 }
                    if x <= 2 { return ((-0.5*x+2.5)*x-4)*x+2 }
                    return 0
                case .lanczos2, .lanczos3:
                    let radius = kernel == .lanczos2 ? 2.0 : 3.0
                    guard x < radius else { return 0 }
                    let eps = Double(Float.ulpOfOne)
                    return (sin(Double.pi*x)*sin(Double.pi*x/radius)+eps)/(Double.pi*Double.pi*x*x/radius+eps)
                }
            }
            return (0..<output).map { j in
                let center = origin + (Double(j)+0.5)/scale - 0.5
                if kernel == .nearest { return [Tap(index: mirrored(Int(floor(center+0.5)),input),weight: 1)] }
                let left = Int(ceil(center-extent/2-Double(Float.ulpOfOne)))
                let weights = (0..<count).map { aa*weight((center-Double(left+$0))*aa) }
                let sum = weights.reduce(0,+)
                return weights.enumerated().compactMap { offset, value -> Tap? in
                    guard value != 0 else { return nil }
                    return Tap(index: mirrored(left+offset,input),weight: Float(value/(sum == 0 ? 1 : sum)))
                }
            }
        }
        let tx = taps(image.width,width,sx,Double(sourceRect.minX))
        let ty = taps(image.height,height,sy,Double(sourceRect.minY))
        let rowLength = width*4
        var result = [Float](repeating: 0,count: rowLength*height)
        var rows: [Int:[Float]] = [:]
        // At most 128 horizontal rows, and at most 2x the output height (8-row minimum).
        // Strong downsampling streams rows instead of retaining a full-image intermediate.
        let rowLimit = min(128,max(8,height*2))
        func horizontalRow(_ y: Int) -> [Float] {
            var row = [Float](repeating: 0,count: rowLength)
            let rowBase = y*image.width*4
            for x in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                for tap in tx[x] {
                    let i = rowBase+tap.index*4, alpha = image.rgba[i+3], alphaWeight = alpha*tap.weight
                    r += image.rgba[i]*alphaWeight; g += image.rgba[i+1]*alphaWeight
                    b += image.rgba[i+2]*alphaWeight; a += alphaWeight
                }
                let out = x*4
                row[out] = r; row[out+1] = g; row[out+2] = b; row[out+3] = a
            }
            return row
        }
        for y in 0..<height {
            let neededRows = Set(ty[y].map { $0.index })
            rows = rows.filter { neededRows.contains($0.key) }
            let outputStart = y*rowLength
            for tap in ty[y] {
                let row: [Float]
                if let cached = rows[tap.index] { row = cached }
                else {
                    row = horizontalRow(tap.index)
                    if rows.count < rowLimit { rows[tap.index] = row }
                }
                for i in 0..<rowLength { result[outputStart+i] += row[i]*tap.weight }
            }
        }
        for i in stride(from: 0,to: result.count,by: 4) {
            let a = result[i+3]
            if abs(a) > 1e-7 { for c in 0..<3 { result[i+c] /= a } }
            else { for c in 0..<3 { result[i+c] = 0 } }
            result[i+3] = clamp(a)
        }
        return PixelBuffer(width: width,height: height,rgba: result)
    }

    /// Independent channel controls, in [-1,1]. Zero is exact identity; -1 is black;
    /// +1 is full channel intensity. Negative settings scale toward 0; positive toward 1.
    /// Alpha and channels whose control equals zero are preserved exactly.
    static func adjustChannels(_ image: PixelBuffer, red: Float, green: Float, blue: Float) throws -> PixelBuffer {
        let settings = [red,green,blue]
        guard settings.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
            throw ImageEngineError.message("Channel controls must be finite values from −1 to 1.")
        }
        if settings.allSatisfy({ $0 == 0 }) { return image }
        var result = image.rgba
        for c in 0..<3 {
            let t = settings[c]
            if t == 0 { continue }
            for i in stride(from: c,to: result.count,by: 4) {
                if t == -1 { result[i] = 0 }
                else if t == 1 { result[i] = 1 }
                else if t < 0 { result[i] *= 1+t }
                else { result[i] += (1-result[i])*t }
            }
        }
        return PixelBuffer(width: image.width,height: image.height,rgba: result)
    }

    private static func validatePair(_ a: PixelBuffer, _ b: PixelBuffer) throws {
        guard a.width == b.width, a.height == b.height else {
            throw ImageEngineError.message("Metrics need identical pixel dimensions. Resize explicitly before comparing; no implicit alignment is applied.")
        }
        for image in [a,b] {
            for i in stride(from: 0, to: image.rgba.count, by: 4) {
                guard image.rgba[i+3].isFinite, abs(image.rgba[i+3] - 1) < 1e-5 else {
                    throw ImageEngineError.message("Metrics require opaque images. Composite transparency onto a chosen background before measuring.")
                }
                for c in 0..<3 {
                    guard image.rgba[i+c].isFinite, image.rgba[i+c] >= -1e-6, image.rgba[i+c] <= 1.000001 else {
                        throw ImageEngineError.message("Metrics use range [0,1]. This image has out-of-range samples; clip explicitly or choose another image.")
                    }
                }
            }
        }
    }

    static func metrics(_ a: PixelBuffer, _ b: PixelBuffer, roi: CGRect? = nil) throws -> MetricResult {
        guard a.width == b.width, a.height == b.height else { throw ImageEngineError.message("Metrics require images with identical dimensions.") }
        let left = try roi.map { try a.cropped($0) } ?? a
        let right = try roi.map { try b.cropped($0) } ?? b
        try validatePair(left, right)
        let n = left.width * left.height
        var squared = 0.0, delta = 0.0
        var ha = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var hb = ha
        for i in stride(from: 0, to: left.rgba.count, by: 4) {
            for c in 0..<3 {
                let d = Double(left.rgba[i+c]) - Double(right.rgba[i+c])
                squared += d*d
                ha[c][Int((clamp(left.rgba[i+c])*255).rounded())] += 1
                hb[c][Int((clamp(right.rgba[i+c])*255).rounded())] += 1
            }
            let l = lab(left.rgba[i],left.rgba[i+1],left.rgba[i+2])
            let r = lab(right.rgba[i],right.rgba[i+1],right.rgba[i+2])
            delta += sqrt(pow(l.0-r.0,2)+pow(l.1-r.1,2)+pow(l.2-r.2,2))
        }
        var histogram = 0.0
        for c in 0..<3 {
            var cumulative = 0
            for bin in 0..<255 { cumulative += ha[c][bin]-hb[c][bin]; histogram += Double(abs(cumulative)) / Double(n) }
        }
        let mse = squared / Double(n*3)
        let local = ssimMap(left, right)
        let ssim: Double? = local.map { $0.reduce(0.0) { $0 + Double($1) } / Double($0.count) }
        return MetricResult(mse: mse, psnr: mse == 0 ? .infinity : -10 * log10(mse), ssim: ssim,
                            histogramDistance: histogram / (3*255), meanDeltaE: delta / Double(n), pixelCount: n)
    }

    private static func lab(_ r: Float, _ g: Float, _ b: Float) -> (Double, Double, Double) {
        func linear(_ sample: Float) -> Double { let v = Double(clamp(sample)); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055)/1.055,2.4) }
        let r = linear(r), g = linear(g), b = linear(b)
        let x = (0.4124564*r+0.3575761*g+0.1804375*b)/0.95047
        let y = 0.2126729*r+0.7151522*g+0.0721750*b
        let z = (0.0193339*r+0.1191920*g+0.9503041*b)/1.08883
        func f(_ v: Double) -> Double { v > 216.0/24389 ? pow(v, 1.0/3) : (24389.0/27*v+16)/116 }
        return (116*f(y)-16, 500*(f(x)-f(y)), 200*(f(y)-f(z)))
    }

    private static func gaussianWeights(sigma: Float, radius: Int) -> [Float] {
        if sigma <= 0 { return [1] }
        let values = (-radius...radius).map { exp(-Float($0*$0)/(2*sigma*sigma)) }
        let sum = values.reduce(0,+)
        return values.map { $0/sum }
    }

    /// Convolution with symmetric boundaries; SSIM excludes all centers that touch padding.
    private static func blur(_ input: [Float], width: Int, height: Int, channels: Int, weights: [Float]) -> [Float] {
        let radius = weights.count/2
        if radius == 0 { return input }
        var temp = [Float](repeating: 0, count: input.count), result = temp
        for y in 0..<height { for x in 0..<width {
            let to = (y*width+x)*channels
            for (k, w) in weights.enumerated() {
                let from = (y*width+mirrored(x+k-radius,width))*channels
                for c in 0..<channels { temp[to+c] += input[from+c]*w }
            }
        } }
        for y in 0..<height { for x in 0..<width {
            let to = (y*width+x)*channels
            for (k, w) in weights.enumerated() {
                let from = (mirrored(y+k-radius,height)*width+x)*channels
                for c in 0..<channels { result[to+c] += temp[from+c]*w }
            }
        } }
        return result
    }

    /// RGB mean local SSIM, ordered by valid output rows (width-10) × (height-10).
    /// Double-precision moments avoid cancellation in nearly constant patches.
    private static func ssimMap(_ a: PixelBuffer, _ b: PixelBuffer) -> [Float]? {
        let w = a.width, h = a.height
        guard w >= 11, h >= 11 else { return nil }
        let vw = w-10, vh = h-10
        var weights = (-5...5).map { exp(-Double($0*$0)/(2*1.5*1.5)) }
        let weightSum = weights.reduce(0,+)
        weights = weights.map { $0/weightSum }
        var result = [Float](repeating: 0, count: vw*vh)
        // Process channels separately and retain only horizontally valid moments.
        // This bounds scratch memory at 40 bytes per input pixel.
        var horizontal = [Double](repeating: 0, count: vw*h*5)
        let c1 = 0.0001, c2 = 0.0009
        for c in 0..<3 {
            for y in 0..<h { for x in 0..<vw {
                var u = 0.0, v = 0.0, aa = 0.0, bb = 0.0, ab = 0.0
                for k in 0..<11 {
                    let i = (y*w+x+k)*4+c, weight = weights[k]
                    let left = Double(a.rgba[i]), right = Double(b.rgba[i])
                    u += left*weight; v += right*weight
                    aa += left*left*weight; bb += right*right*weight; ab += left*right*weight
                }
                let i = (y*vw+x)*5
                horizontal[i] = u; horizontal[i+1] = v; horizontal[i+2] = aa
                horizontal[i+3] = bb; horizontal[i+4] = ab
            } }
            for y in 0..<vh { for x in 0..<vw {
                var u = 0.0, v = 0.0, aa = 0.0, bb = 0.0, ab = 0.0
                for k in 0..<11 {
                    let i = ((y+k)*vw+x)*5, weight = weights[k]
                    u += horizontal[i]*weight; v += horizontal[i+1]*weight
                    aa += horizontal[i+2]*weight; bb += horizontal[i+3]*weight; ab += horizontal[i+4]*weight
                }
                let va = max(0,aa-u*u), vb = max(0,bb-v*v), cov = ab-u*v
                let score = ((2*u*v+c1)*(2*cov+c2))/((u*u+v*v+c1)*(va+vb+c2))
                result[y*vw+x] += Float(max(-1,min(1,score))/3)
            } }
        }
        return result
    }

    /// Absolute RGB difference, per-pixel mean squared RGB error, or local (1-SSIM)/2.
    /// MSE / SSIM maps use a fixed [0,1] color scale times gain. Invalid SSIM border is transparent.
    static func heatmap(_ a: PixelBuffer, _ b: PixelBuffer, kind: String, gain: Float = 1) throws -> PixelBuffer {
        try validatePair(a, b)
        guard gain.isFinite, gain > 0 else { throw ImageEngineError.message("Heatmap gain must be finite and positive.") }
        guard ["absolute", "mse", "ssim"].contains(kind) else { throw ImageEngineError.message("Unknown heatmap method: \(kind)") }
        let local = kind == "ssim" ? ssimMap(a, b) : nil
        if kind == "ssim" && local == nil { throw ImageEngineError.message("SSIM maps need at least 11×11 pixels.") }
        var out = [Float](repeating: 0, count: a.rgba.count)
        for y in 0..<a.height { for x in 0..<a.width {
            let p = (y*a.width+x)*4
            out[p+3] = 1
            if kind == "absolute" {
                for c in 0..<3 { out[p+c] = clamp(abs(a.rgba[p+c]-b.rgba[p+c])*gain) }
            } else {
                let value: Float
                if kind == "ssim", let local = local {
                    if x < 5 || y < 5 || x >= a.width-5 || y >= a.height-5 { out[p+3] = 0; continue }
                    value = clamp((1-local[(y-5)*(a.width-10)+(x-5)])/2*gain)
                } else {
                    var sum: Float = 0
                    for c in 0..<3 { let d = a.rgba[p+c]-b.rgba[p+c]; sum += d*d }
                    value = clamp(sum/3*gain)
                }
                let color = heatColor(value)
                out[p] = color.0; out[p+1] = color.1; out[p+2] = color.2
            }
        } }
        return PixelBuffer(width: a.width, height: a.height, rgba: out)
    }

    private static func heatColor(_ x: Float) -> (Float, Float, Float) {
        // A monotonic-luminance black -> violet -> orange -> pale-yellow scale.
        let stops: [(Float, Float, Float)] = [(0.015,0.01,0.06),(0.32,0.06,0.43),(0.80,0.20,0.22),(0.99,0.59,0.15),(0.99,0.98,0.70)]
        let v = clamp(x)*4, i = min(3,Int(v)), t = v-Float(i)
        return (stops[i].0*(1-t)+stops[i+1].0*t, stops[i].1*(1-t)+stops[i+1].1*t, stops[i].2*(1-t)+stops[i+1].2*t)
    }

    /// Centered FFT2 of encoded-sRGB Rec.709 luminance, zero padded to powers of two.
    /// Shared scale: log(1 + 1000 * |F| / paddedPixelCount) / log(1001), no per-image normalization.
    static func fft(_ image: PixelBuffer) -> PixelBuffer {
        func powerOfTwo(_ n: Int) -> Int { var p = 1; while p < n { p <<= 1 }; return p }
        let w = powerOfTwo(image.width), h = powerOfTwo(image.height), n = w*h
        var real = [Float](repeating: 0, count: n), imag = real
        for y in 0..<image.height { for x in 0..<image.width {
            let i = (y*image.width+x)*4
            real[y*w+x] = 0.2126*image.rgba[i]+0.7152*image.rgba[i+1]+0.0722*image.rgba[i+2]
        } }
        let logW = vDSP_Length(log2(Double(w))), logH = vDSP_Length(log2(Double(h)))
        if let setup = vDSP_create_fftsetup(max(logW,logH,1), FFTRadix(kFFTRadix2)) {
            defer { vDSP_destroy_fftsetup(setup) }
            real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { im in
                if w > 1 {
                    for y in 0..<h {
                        var split = DSPSplitComplex(realp: r.baseAddress! + y*w, imagp: im.baseAddress! + y*w)
                        vDSP_fft_zip(setup, &split, 1, logW, FFTDirection(FFT_FORWARD))
                    }
                }
                if h > 1 {
                    for x in 0..<w {
                        var split = DSPSplitComplex(realp: r.baseAddress! + x, imagp: im.baseAddress! + x)
                        vDSP_fft_zip(setup, &split, vDSP_Stride(w), logH, FFTDirection(FFT_FORWARD))
                    }
                }
            } }
        }
        var out = [Float](repeating: 1, count: n*4)
        for y in 0..<h { for x in 0..<w {
            let from = ((y+h/2)%h)*w+(x+w/2)%w
            let magnitude = hypot(real[from],imag[from])/Float(n)
            let value = clamp(log1p(1000*magnitude)/log(1001))
            for c in 0..<3 { out[(y*w+x)*4+c] = value }
        } }
        return PixelBuffer(width: w, height: h, rgba: out)
    }

    /// Sigma values are in pixels for smoothing, normalized RGB for noise and bilateral range.
    /// Noise is repeatable for the same seed; clipping is explicit in this editing operation.
    static func filter(_ image: PixelBuffer, kind: String, amount: Float, seed: UInt64 = 0) throws -> PixelBuffer {
        guard amount.isFinite, amount >= 0 else { throw ImageEngineError.message("Filter strength must be finite and nonnegative.") }
        var out = image.rgba
        switch kind {
        case "grayscale":
            for i in stride(from: 0, to: out.count, by: 4) {
                let luma = 0.2126*out[i]+0.7152*out[i+1]+0.0722*out[i+2]
                for c in 0..<3 { out[i+c] = luma }
            }
        case "red", "green", "blue":
            let channel = kind == "red" ? 0 : kind == "green" ? 1 : 2
            for i in stride(from: channel, to: out.count, by: 4) { out[i] = 0 }
        case "clip":
            for i in out.indices { out[i] = clamp(out[i]) }
        case "opaque":
            for i in stride(from: 0, to: out.count, by: 4) {
                let alpha = clamp(out[i+3])
                for c in 0..<3 { out[i+c] = clamp(out[i+c])*alpha + clamp(amount)*(1-alpha) }
                out[i+3] = 1
            }
        case "gaussian", "sharpen":
            let sigma: Float = kind == "gaussian" ? amount : 1
            guard sigma <= 50 else { throw ImageEngineError.message("Gaussian sigma is limited to 50 pixels.") }
            if sigma == 0 { return image }
            var premult = out
            for i in stride(from: 0, to: out.count, by: 4) { for c in 0..<3 { premult[i+c] *= premult[i+3] } }
            let smoothed = blur(premult, width: image.width, height: image.height, channels: 4,
                                weights: gaussianWeights(sigma: sigma, radius: Int(ceil(3*sigma))))
            for i in stride(from: 0, to: out.count, by: 4) {
                for c in 0..<3 {
                    let value = smoothed[i+3] > 1e-7 ? smoothed[i+c]/smoothed[i+3] : 0
                    out[i+c] = kind == "gaussian" ? value : clamp(out[i+c]+amount*(out[i+c]-value))
                }
            }
        case "noise":
            guard amount <= 1 else { throw ImageEngineError.message("Noise sigma is expressed in [0,1], with a maximum of 1.") }
            var random = SplitMix64(seed: seed)
            for i in stride(from: 0, to: out.count, by: 4) {
                for c in 0..<3 { out[i+c] = clamp(out[i+c] + amount * random.gaussian()) }
            }
        case "bilateral":
            guard amount <= 1 else { throw ImageEngineError.message("Bilateral range sigma is expressed in [0,1].") }
            if amount == 0 { return image }
            let radius = 4, spatialSigma: Float = 2, rangeSigma = max(amount,0.00001)
            for y in 0..<image.height { for x in 0..<image.width {
                let target = (y*image.width+x)*4
                var sum: Float = 0, rgb: [Float] = [0,0,0]
                for dy in -radius...radius { for dx in -radius...radius {
                    let i = (mirrored(y+dy,image.height)*image.width+mirrored(x+dx,image.width))*4
                    var distance: Float = 0
                    for c in 0..<3 { let d = out[target+c]-image.rgba[i+c]; distance += d*d }
                    let weight = exp(-Float(dx*dx+dy*dy)/(2*spatialSigma*spatialSigma)-distance/(2*rangeSigma*rangeSigma))*clamp(image.rgba[i+3])
                    sum += weight
                    for c in 0..<3 { rgb[c] += weight*image.rgba[i+c] }
                } }
                if sum > 0 { for c in 0..<3 { out[target+c] = rgb[c]/sum } }
            } }
        default: throw ImageEngineError.message("Unknown filter: \(kind)")
        }
        return PixelBuffer(width: image.width, height: image.height, rgba: out)
    }

    /// Per-channel 256-bin CDF matching. Geometry and alpha remain unchanged.
    static func histogramMatch(_ image: PixelBuffer, reference: PixelBuffer) -> PixelBuffer {
        if image.width == reference.width && image.height == reference.height && image.rgba == reference.rgba { return image }
        var out = image.rgba
        for c in 0..<3 {
            var sourceHistogram = [Double](repeating: 0, count: 256), targetHistogram = sourceHistogram
            for i in stride(from: c, to: image.rgba.count, by: 4) { sourceHistogram[Int((clamp(image.rgba[i])*255).rounded())] += 1 }
            for i in stride(from: c, to: reference.rgba.count, by: 4) { targetHistogram[Int((clamp(reference.rgba[i])*255).rounded())] += 1 }
            let sourceCount = Double(image.width*image.height), targetCount = Double(reference.width*reference.height)
            for j in 0..<256 {
                sourceHistogram[j] = sourceHistogram[j]/sourceCount+(j > 0 ? sourceHistogram[j-1] : 0)
                targetHistogram[j] = targetHistogram[j]/targetCount+(j > 0 ? targetHistogram[j-1] : 0)
            }
            var lut = [Float](repeating: 0, count: 256), k = 0
            for j in 0..<256 {
                while k < 255 && targetHistogram[k] < sourceHistogram[j] { k += 1 }
                lut[j] = Float(k)/255
            }
            for i in stride(from: c, to: image.rgba.count, by: 4) { out[i] = lut[Int((clamp(image.rgba[i])*255).rounded())] }
        }
        return PixelBuffer(width: image.width, height: image.height, rgba: out)
    }

    static func histogram(_ image: PixelBuffer, bins: Int = 256) -> [[Int]] {
        precondition(bins > 1)
        var result = [[Int]](repeating: [Int](repeating: 0, count: bins), count: 3)
        for i in stride(from: 0, to: image.rgba.count, by: 4) {
            for c in 0..<3 { result[c][Int((clamp(image.rgba[i+c])*Float(bins-1)).rounded())] += 1 }
        }
        return result
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { (Double(next() >> 11)+0.5)/9007199254740992.0 }
    mutating func gaussian() -> Float { Float(sqrt(-2*log(uniform()))*cos(2*Double.pi*uniform())) }
}
