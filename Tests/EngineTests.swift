import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct EngineTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a-b) <= tolerance }
    static func constant(_ value: Float, width: Int = 16, height: Int = 16) -> PixelBuffer {
        var rgba = [Float](repeating: value, count: width*height*4)
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 1 }
        return PixelBuffer(width: width, height: height, rgba: rgba)
    }
    static func mustThrow(_ label: String, _ action: () throws -> Void) {
        do { try action(); expect(false,label) } catch { expect(true,label) }
    }
    static func main() throws {
        let a = constant(0.25), b = constant(0.5)
        let identity = try ImageEngine.metrics(a,a)
        expect(identity.mse == 0 && identity.psnr.isInfinite,"Identical images have zero MSE and infinite PSNR")
        expect(close(identity.ssim!,1,1e-6),"Identical constant images have SSIM 1")
        expect(identity.histogramDistance == 0 && identity.meanDeltaE == 0,"Identical color distances")
        let measured = try ImageEngine.metrics(a,b)
        expect(close(measured.mse,0.0625),"Known squared RGB error")
        expect(close(measured.psnr,12.041199826559248),"Known PSNR with range 1")
        expect(close(measured.ssim!, (2*0.25*0.5+0.0001)/(0.25*0.25+0.5*0.5+0.0001)),"Gaussian SSIM on constant patches")
        expect(close(measured.histogramDistance,64.0/255),"Histogram Wasserstein distance")
        let bw = try ImageEngine.metrics(constant(0),constant(1))
        expect(close(bw.meanDeltaE!,100,0.0001),"Black-to-white CIE76 is 100")
        // Independent NumPy direct 2D Gaussian-window reference, not the separable implementation.
        var textureA = constant(0,width:19,height:17), textureB = textureA
        for y in 0..<17 { for x in 0..<19 { for c in 0..<3 {
            textureA.rgba[(y*19+x)*4+c] = Float((x*13+y*7+c*11)%101)/100
            textureB.rgba[(y*19+x)*4+c] = Float((x*13+y*7+c*11+5)%101)/100
        } } }
        let texturedMetrics = try ImageEngine.metrics(textureA,textureB)
        expect(close(texturedMetrics.mse,0.04613116691524676,1e-9),"Textured RGB MSE vs independent NumPy reference")
        expect(close(texturedMetrics.ssim!,0.7240059520606388,1e-7),"Textured Gaussian SSIM vs direct 2D reference")
        expect(ImageEngine.histogramMatch(textureA,reference:textureA).rgba == textureA.rgba,"Histogram identity preserves Float precision")
        let small = try ImageEngine.metrics(a,b,roi:CGRect(x:2,y:3,width:3,height:4))
        expect(small.ssim == nil && small.pixelCount == 12,"Small ROIs have no SSIM and count exact crop pixels")
        mustThrow("Mismatched sizes rejected") { _ = try ImageEngine.metrics(a,constant(0,width:15)) }
        mustThrow("Out of bounds ROI rejected") { _ = try ImageEngine.metrics(a,b,roi:CGRect(x:15,y:1,width:2,height:2)) }
        var translucent = a; translucent.rgba[3] = 0.5
        mustThrow("Transparent metrics rejected") { _ = try ImageEngine.metrics(a,translucent) }
        var negative = a; negative.rgba[0] = -0.02
        mustThrow("Out of range metrics rejected") { _ = try ImageEngine.metrics(a,negative) }
        let clipped = try ImageEngine.filter(negative,kind:"clip",amount:0)
        expect(clipped.rgba[0] == 0,"Explicit clipping")
        let flattened = try ImageEngine.filter(translucent,kind:"opaque",amount:1)
        expect(flattened.rgba[3] == 1 && close(Double(flattened.rgba[0]),0.625),"Alpha compositing onto white")

        let pixels = PixelBuffer(width:2,height:3,rgba:[
            1,0,0,1, 0,1,0,1,
            0,0,1,1, 1,1,0,1,
            0.1,0.2,0.3,0.5, 1,0,1,0.25])
        let decoded = try PixelBuffer.from(cgImage:pixels.cgImage())
        expect(decoded.width == 2 && decoded.height == 3,"CGImage retains dimensions")
        for i in pixels.rgba.indices { expect(close(Double(decoded.rgba[i]),Double(pixels.rgba[i]),0.0001),"CGImage preserves top-left order, channel and alpha \(i)") }
        let crop = try pixels.cropped(CGRect(x:1,y:1,width:1,height:2))
        expect(crop.rgba == [1,1,0,1,1,0,1,0.25],"Crop uses top-left coordinates")
        expect(pixels.pixel(x:2,y:0) == nil,"Pixel probe excludes right boundary")
        expect(pixels.pixel(x:0,y:1) == [0,0,1,1],"Pixel probe indexes row then column")

        let pngURL = FileManager.default.temporaryDirectory.appendingPathComponent("pixelbench-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at:pngURL) }
        try pixels.pngData()!.write(to:pngURL)
        let png = try PixelBuffer.load(url:pngURL)
        for i in pixels.rgba.indices { expect(close(Double(png.rgba[i]),Double(pixels.rgba[i]),0.0002),"PNG roundtrip \(i)") }
        let orientURL = FileManager.default.temporaryDirectory.appendingPathComponent("pixelbench-test-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at:orientURL) }
        let destination = CGImageDestinationCreateWithURL(orientURL as CFURL,UTType.tiff.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,pixels.cgImage(),[kCGImagePropertyOrientation:6] as CFDictionary)
        expect(CGImageDestinationFinalize(destination),"Write EXIF orientation fixture")
        let rotated = try PixelBuffer.load(url:orientURL)
        expect(rotated.width == 3 && rotated.height == 2,"EXIF 6 swaps image dimensions")
        for (x,y,sx,sy) in [(0,0,0,2),(2,0,0,0),(0,1,1,2),(2,1,1,0)] {
            let observed = rotated.pixel(x:x,y:y)!, expected = pixels.pixel(x:sx,y:sy)!
            for c in 0..<4 { expect(close(Double(observed[c]),Double(expected[c]),0.002),"EXIF orientation top-left \(x),\(y),\(c)") }
        }

        for kernel in ResizeKernel.allCases {
            let expanded = try ImageEngine.resize(a,width:29,height:31,kernel:kernel)
            let reduced = try ImageEngine.resize(a,width:5,height:7,kernel:kernel)
            expect(expanded.rgba.enumerated().allSatisfy { close(Double($0.element),$0.offset%4 == 3 ? 1 : 0.25,0.000001) },"\(kernel) expansion preserves constants with symmetric padding")
            expect(reduced.rgba.enumerated().allSatisfy { close(Double($0.element),$0.offset%4 == 3 ? 1 : 0.25,0.000001) },"\(kernel) antialiased reduction preserves constants")
            let unchanged = try ImageEngine.resize(pixels,width:2,height:3,kernel:kernel)
            expect(unchanged.rgba == pixels.rgba,"\(kernel) identity exact")
        }
        let impulse = PixelBuffer(width:5,height:1,rgba:[0,0,0,1,0,0,0,1,1,1,1,1,0,0,0,1,0,0,0,1])
        let centered = try ImageEngine.resize(impulse,width:8,height:1,kernel:.cubic,scaleX:1.5,scaleY:1)
        for x in 0..<4 { expect(close(Double(centered.rgba[x*4]),Double(centered.rgba[(7-x)*4]),1e-6),"Noninteger-scale centered grid symmetry \(x)") }
        let point = try ImageEngine.resize(pixels,width:4,height:6,kernel:.nearest)
        expect(point.pixel(x:0,y:0) == pixels.pixel(x:0,y:0) && point.pixel(x:3,y:5) == pixels.pixel(x:1,y:2),"Nearest samples pixel centers")
        mustThrow("Zero resize dimensions rejected") { _ = try ImageEngine.resize(a,width:0,height:2,kernel:.cubic) }

        let noise1 = try ImageEngine.filter(a,kind:"noise",amount:0.05,seed:123)
        let noise2 = try ImageEngine.filter(a,kind:"noise",amount:0.05,seed:123)
        let noise3 = try ImageEngine.filter(a,kind:"noise",amount:0.05,seed:124)
        expect(noise1.rgba == noise2.rgba && noise1.rgba != noise3.rgba,"Seeded Gaussian noise repeatable")
        expect(noise1.rgba.enumerated().allSatisfy { $0.offset%4 != 3 || $0.element == 1 },"Noise preserves alpha")
        let noBlur = try ImageEngine.filter(pixels,kind:"gaussian",amount:0)
        expect(noBlur.rgba == pixels.rgba,"Zero sigma exact identity")
        for kind in ["gaussian","bilateral","sharpen"] {
            let result = try ImageEngine.filter(a,kind:kind,amount:0.2)
            expect(result.rgba.enumerated().allSatisfy { close(Double($0.element),$0.offset%4 == 3 ? 1 : 0.25,1e-5) },"\(kind) preserves constant field")
        }
        let gray = try ImageEngine.filter(pixels,kind:"grayscale",amount:1)
        expect(close(Double(gray.rgba[0]),0.2126),"Encoded RGB Rec.709 luma grayscale")
        let noRed = try ImageEngine.filter(pixels,kind:"red",amount:1)
        expect(noRed.rgba[0] == 0 && noRed.rgba[5] == 1,"Red removal preserves green")
        let matched = ImageEngine.histogramMatch(a,reference:b)
        expect(close(Double(matched.rgba[0]),128.0/255),"CDF histogram match")

        let difference = try ImageEngine.heatmap(a,b,kind:"absolute",gain:2)
        expect(close(Double(difference.rgba[0]),0.5),"Difference gain")
        let ssimImage = try ImageEngine.heatmap(a,b,kind:"ssim")
        expect(ssimImage.pixel(x:0,y:0)![3] == 0 && ssimImage.pixel(x:5,y:5)![3] == 1,"SSIM map marks invalid border")
        mustThrow("Unknown heatmap rejected") { _ = try ImageEngine.heatmap(a,b,kind:"lpips") }
        let spectrum = ImageEngine.fft(constant(1,width:8,height:8))
        expect(spectrum.width == 8 && spectrum.height == 8,"FFT shape")
        expect(close(Double(spectrum.pixel(x:4,y:4)![0]),1,0.00001),"FFT DC centered with fixed normalization")
        expect(spectrum.pixel(x:0,y:0)![0] < 0.00001,"Constant FFT has no non-DC content")
        let padded = ImageEngine.fft(constant(0,width:3,height:5))
        expect(padded.width == 4 && padded.height == 8,"FFT power-of-two padding explicit in dimensions")
        expect(padded.rgba.enumerated().allSatisfy { $0.offset%4 == 3 || $0.element == 0 },"Zero FFT finite and black")

        func maxError(_ left: PixelBuffer, _ right: PixelBuffer) -> Double {
            guard left.width == right.width, left.height == right.height else { return .infinity }
            return zip(left.rgba,right.rgba).reduce(0) { max($0,abs(Double($1.0)-Double($1.1))) }
        }
        for kernel in ResizeKernel.allCases {
            let whole = try ImageEngine.resize(textureA,width:31,height:27,kernel:kernel)
            let fullViewport = try ImageEngine.resampleViewport(textureA,sourceRect:CGRect(x:0,y:0,width:19,height:17),width:31,height:27,kernel:kernel)
            expect(maxError(whole,fullViewport) < 3e-6,"\(kernel) viewport matches whole-image reconstruction")
            let cropRect = CGRect(x:7,y:6,width:13,height:11)
            let croppedWhole = try whole.cropped(cropRect)
            let viewport = CGRect(x:7.0*19/31,y:6.0*17/27,width:13.0*19/31,height:11.0*17/27)
            let direct = try ImageEngine.resampleViewport(textureA,sourceRect:viewport,width:13,height:11,kernel:kernel)
            expect(maxError(croppedWhole,direct) < 3e-6,"\(kernel) viewport crop has no artificial patch boundary")
            let sx = 1.37, sy = 0.82, ow = 27, oh = 14
            let explicit = try ImageEngine.resize(textureA,width:ow,height:oh,kernel:kernel,scaleX:sx,scaleY:sy)
            let footprint = CGRect(x:(19-Double(ow)/sx)/2,y:(17-Double(oh)/sy)/2,width:Double(ow)/sx,height:Double(oh)/sy)
            let optical = try ImageEngine.resampleViewport(textureA,sourceRect:footprint,width:ow,height:oh,kernel:kernel)
            expect(maxError(explicit,optical) < 3e-6,"\(kernel) noninteger optical scale retains centered registration")
            let border = try ImageEngine.resampleViewport(constant(0.375,width:4,height:3),sourceRect:CGRect(x:-1.25,y:-2.5,width:7.5,height:6.25),width:30,height:25,kernel:kernel)
            expect(border.rgba.enumerated().allSatisfy { close(Double($0.element),$0.offset%4 == 3 ? 1 : 0.375,2e-6) },"\(kernel) source-edge symmetric padding preserves constants")
        }
        var ramp = constant(0,width:16,height:16)
        for y in 0..<16 { for x in 0..<16 { for c in 0..<3 { ramp.rgba[(y*16+x)*4+c] = Float(x)*0.01+Float(y)*0.02 } } }
        let fractional = try ImageEngine.resampleViewport(ramp,sourceRect:CGRect(x:2.375,y:1.625,width:3.25,height:4.75),width:13,height:19,kernel:.linear)
        for (x,y) in [(0,0),(6,9),(12,18)] {
            let sourceX = 2.375+(Double(x)+0.5)/4-0.5, sourceY = 1.625+(Double(y)+0.5)/4-0.5
            expect(close(Double(fractional.pixel(x:x,y:y)![0]),sourceX*0.01+sourceY*0.02,2e-7),"Fractional viewport maps output center \(x),\(y) exactly")
        }
        for kernel in [ResizeKernel.linear,.cubic,.lanczos2,.lanczos3] {
            let rect = CGRect(x:1.23,y:2.61,width:8.7,height:6.1)
            let combined = try ImageEngine.resampleViewport(textureA,sourceRect:rect,width:87,height:61,kernel:kernel)
            let left = try ImageEngine.resampleViewport(textureA,sourceRect:CGRect(x:1.23,y:2.61,width:3.5,height:6.1),width:35,height:61,kernel:kernel)
            let right = try ImageEngine.resampleViewport(textureA,sourceRect:CGRect(x:4.73,y:2.61,width:5.2,height:6.1),width:52,height:61,kernel:kernel)
            let expectedLeft = try combined.cropped(CGRect(x:0,y:0,width:35,height:61)), expectedRight = try combined.cropped(CGRect(x:35,y:0,width:52,height:61))
            expect(maxError(left,expectedLeft) < 2e-6 && maxError(right,expectedRight) < 2e-6,"\(kernel) adjacent fractional patches are seamless")
        }
        let magnificationRect = CGRect(x:2.1,y:3.2,width:0.25,height:0.25)
        let highNearest = try ImageEngine.resampleViewport(ramp,sourceRect:magnificationRect,width:256,height:256,kernel:.nearest)
        let highCubic = try ImageEngine.resampleViewport(ramp,sourceRect:magnificationRect,width:256,height:256,kernel:.cubic)
        expect(maxError(highNearest,highCubic) > 0.002,"Cubic visibly differs from nearest at 1024× magnification")
        expect(highCubic.width == 256 && highCubic.height == 256,"High magnification allocates only viewport output")
        var checker = constant(0,width:64,height:64)
        for y in 0..<64 { for x in 0..<64 { for c in 0..<3 { checker.rgba[(y*64+x)*4+c] = Float((x+y)%2) } } }
        let antialiased = try ImageEngine.resampleViewport(checker,sourceRect:CGRect(x:0,y:0,width:64,height:64),width:8,height:8,kernel:.linear)
        let checkerWhole = try ImageEngine.resize(checker,width:8,height:8,kernel:.linear)
        expect(maxError(antialiased,checkerWhole) < 2e-6,"Viewport antialiasing matches whole ResizeRight reduction")
        expect((1..<7).allSatisfy { y in (1..<7).allSatisfy { x in close(Double(antialiased.pixel(x:x,y:y)![0]),0.5,1e-6) } },"Viewport reduction antialiases checkerboard interior to its mean")
        let alphaEdge = PixelBuffer(width:2,height:1,rgba:[1,0,0,0, 0,0,1,1])
        let alphaFiltered = try ImageEngine.resampleViewport(alphaEdge,sourceRect:CGRect(x:0,y:0,width:2,height:1),width:16,height:8,kernel:.linear)
        expect(stride(from:0,to:alphaFiltered.rgba.count,by:4).allSatisfy { alphaFiltered.rgba[$0] == 0 },"Transparent red cannot bleed into blue during viewport interpolation")
        expect(alphaFiltered.pixel(x:8,y:4)![2] > 0.99 && alphaFiltered.pixel(x:8,y:4)![3] < 1,"Viewport unpremultiplies color while preserving interpolated alpha")
        mustThrow("Invalid viewport dimensions rejected") { _ = try ImageEngine.resampleViewport(ramp,sourceRect:CGRect(x:0,y:0,width:0,height:5),width:10,height:10,kernel:.cubic) }

        let untouchedChannels = try ImageEngine.adjustChannels(pixels,red:0,green:0,blue:0)
        expect(untouchedChannels.rgba == pixels.rgba,"Centered channel sliders are exact identity")
        let removedRed = try ImageEngine.adjustChannels(pixels,red:-1,green:0,blue:0)
        let fullBlue = try ImageEngine.adjustChannels(pixels,red:0,green:0,blue:1)
        expect(stride(from:0,to:pixels.rgba.count,by:4).allSatisfy { removedRed.rgba[$0] == 0 },"Red slider minimum sets every red sample to zero")
        expect(stride(from:2,to:pixels.rgba.count,by:4).allSatisfy { fullBlue.rgba[$0] == 1 },"Blue slider maximum sets every blue sample to one")
        expect(stride(from:3,to:pixels.rgba.count,by:4).allSatisfy { fullBlue.rgba[$0] == pixels.rgba[$0] && removedRed.rgba[$0] == pixels.rgba[$0] },"Channel controls preserve alpha exactly")
        let partialChannels = try ImageEngine.adjustChannels(a,red:-0.4,green:0,blue:0.4)
        expect(close(Double(partialChannels.rgba[0]),0.15) && partialChannels.rgba[1] == a.rgba[1] && close(Double(partialChannels.rgba[2]),0.55),"Channel controls interpolate independently toward exact endpoints")
        mustThrow("Channel range validated") { _ = try ImageEngine.adjustChannels(a,red:1.01,green:0,blue:0) }
        mustThrow("Nonfinite channel control rejected") { _ = try ImageEngine.adjustChannels(a,red:.nan,green:0,blue:0) }

        if CommandLine.arguments.count > 1 {
            let fixture = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
            for item in fixture {
                let input = (item["input"] as! [NSNumber]).map { $0.floatValue }
                let original = PixelBuffer(width:item["input_width"] as! Int,height:item["input_height"] as! Int,rgba:input)
                let result = try ImageEngine.resize(original,width:item["width"] as! Int,height:item["height"] as! Int,
                    kernel:ResizeKernel(rawValue:item["kernel"] as! String)!,scaleX:item["scale_x"] as? Double,
                    scaleY:item["scale_y"] as? Double,boundary:ResizeBoundary(rawValue:item["boundary"] as! String)!)
                let expected = (item["expected"] as! [NSNumber]).map { $0.doubleValue }
                var maxError = 0.0
                for i in result.rgba.indices where i%4 != 3 { maxError = max(maxError,abs(Double(result.rgba[i])-expected[i])) }
                expect(maxError < 0.000003,"Upstream ResizeRight \(item["name"]!) parity: max error \(maxError)")
            }
            print("Upstream ResizeRight fixtures passed: \(fixture.count)")
        }
        print("PASS: \(checks) image engine checks")
    }
}
