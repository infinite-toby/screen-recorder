import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import CoreText
import Foundation
import Vision

/// Draws one output frame: background, screen (styled, zoomed, motion-blurred), camera.
/// Used by both the live preview and export so they always match.
public final class FrameRenderer: @unchecked Sendable {
    public let context: CIContext

    public init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
    }

    public struct Options {
        /// Show the whole canvas regardless of zoom (used while placing a zoom's focal point).
        public var ignoreZoom = false
        public var hideCamera = false
        /// Decoded `FrameStyle.backgroundImage`, if any.
        public var backgroundImage: CIImage?
        /// Slower, cleaner person edges for camera background blur (export); preview uses the faster mode.
        public var accurateSegmentation = false
        /// Captions on the edited timeline; drawn when the project's subtitles are set to burn in.
        public var captions: [Caption] = []
        public init(ignoreZoom: Bool = false, hideCamera: Bool = false, backgroundImage: CIImage? = nil,
                    accurateSegmentation: Bool = false, captions: [Caption] = []) {
            self.ignoreZoom = ignoreZoom
            self.hideCamera = hideCamera
            self.backgroundImage = backgroundImage
            self.accurateSegmentation = accurateSegmentation
            self.captions = captions
        }
    }

    public func render(scene: RenderScene, time t: Double, screen: CIImage?, camera: CIImage?, options: Options = Options()) -> CIImage {
        let out = scene.output
        let extent = CGRect(origin: .zero, size: out)
        let style = scene.project.style
        var image = background(style: style, image: options.backgroundImage, size: out)

        if let screen {
            let g = scene.geometry(at: t)
            let views = options.ignoreZoom ? [g.fullView] : scene.viewSamples(at: t)
            // Sharp resampling for still frames; blurred multi-sample frames don't benefit from it.
            let sharp = views.count == 1
            let layers = views.map { screenLayer(screen, geometry: g, view: $0, style: style, output: out, sharp: sharp) }
            image = average(layers).composited(over: image)
        }

        var cameraRect: CGRect?
        if let camera, !options.hideCamera {
            let state = scene.cameraState(at: t)
            if !state.isHidden {
                image = cameraLayer(camera, state: state, style: style, options: options, output: out).composited(over: image)
                cameraRect = state.rect
            }
        }
        let subs = scene.project.subtitles
        if subs.burnIn, let caption = CaptionBuilder.caption(at: t, in: options.captions),
           let layer = captionLayer(caption, time: t, settings: subs, avoiding: cameraRect, output: out) {
            image = layer.composited(over: image)
        }
        return image.cropped(to: extent)
    }

    // MARK: - Layers

    private func background(style: FrameStyle, image: CIImage?, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        if style.backgroundImage != nil, let image, image.extent.width > 0 {
            // Aspect-fill the output.
            let e = image.extent
            let s = max(size.width / e.width, size.height / e.height)
            return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: (size.width - e.width * s) / 2, y: (size.height - e.height * s) / 2)))
                .clampedToExtent().cropped(to: rect)
        }
        let f = CIFilter.linearGradient()
        f.point0 = CGPoint(x: 0, y: size.height)
        f.point1 = CGPoint(x: size.width * 0.3, y: 0)
        f.color0 = ciColor(style.backgroundTop)
        f.color1 = ciColor(style.backgroundBottom)
        return f.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Screen placed via one combined transform (fit into content rect, then view → output) so it's resampled once.
    private func screenLayer(_ screen: CIImage, geometry g: ScreenGeometry, view: CGRect, style: FrameStyle, output: CGSize,
                             sharp: Bool) -> CIImage {
        let k = output.width / view.width
        // Content rect in output space (top-left origin), after applying the view.
        let r = CGRect(x: (g.contentRect.minX - view.minX) * k, y: (g.contentRect.minY - view.minY) * k,
                       width: g.contentRect.width * k, height: g.contentRect.height * k)
        let ciRect = flip(r, height: output.height)
        let src = screen.extent
        let placed = place(screen.transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY)),
                           sourceSize: src.size, into: ciRect, sharp: sharp)

        let base = min(output.width, output.height)
        let radius = style.effectiveScreenCornerRadius * base * k
        let mask = roundedRect(ciRect, radius: radius)
        var layer = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
        ])
        if style.effectiveShadow > 0 {
            layer = layer.composited(over: shadow(for: mask, strength: style.effectiveShadow, blur: base * 0.02 * k,
                                                  offset: base * 0.008 * k))
        }
        return layer
    }

    private func cameraLayer(_ camera: CIImage, state: CameraState, style: FrameStyle, options: Options,
                             output: CGSize) -> CIImage {
        let rect = flip(state.rect, height: output.height)
        var cam = camera.transformed(by: CGAffineTransform(translationX: -camera.extent.minX, y: -camera.extent.minY))
        let size = camera.extent.size
        if style.cameraBackgroundBlur > 0.01 {
            cam = blurBackground(cam, pixelBuffer: camera.pixelBuffer, strength: style.cameraBackgroundBlur,
                                 accurate: options.accurateSegmentation)
        }
        if style.mirrorCamera {
            cam = cam.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -size.width, y: 0))
        }
        // Aspect-fill: scale to cover the rect, centre, crop.
        let s = max(rect.width / size.width, rect.height / size.height)
        let filled = CGRect(x: rect.midX - size.width * s / 2, y: rect.midY - size.height * s / 2,
                            width: size.width * s, height: size.height * s)
        let placed = place(cam, sourceSize: size, into: filled, sharp: true).cropped(to: rect)
        let mask = roundedRect(rect, radius: state.cornerRadius)
        var layer = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
        ])
        let base = min(output.width, output.height)
        layer = layer.composited(over: shadow(for: mask, strength: 0.45, blur: base * 0.015, offset: base * 0.006))
        if state.opacity < 1 { layer = scaleAlpha(layer, by: state.opacity) }
        return layer
    }

    // MARK: - Captions

    private let captionCache = NSCache<NSString, CIImage>()

    /// Caption text on a rounded dark plate, bottom or top centre, nudged clear of the camera if they'd overlap.
    private func captionLayer(_ caption: Caption, time t: Double, settings: SubtitleSettings, avoiding camera: CGRect?,
                              output: CGSize) -> CIImage? {
        let base = min(output.width, output.height)
        let fontSize = (base * settings.size).rounded()
        let highlight = settings.highlightWord ? caption.wordIndex(at: t) : nil
        let maxWidth = (output.width * 0.84).rounded()
        let key = "\(caption.start)|\(highlight ?? -1)|\(fontSize)|\(maxWidth)|\(caption.text)" as NSString
        let plate: CIImage
        if let cached = captionCache.object(forKey: key) {
            plate = cached
        } else {
            guard let made = Self.captionImage(caption, highlight: highlight, fontSize: fontSize, maxWidth: maxWidth) else { return nil }
            captionCache.setObject(made, forKey: key)
            plate = made
        }
        // Position in top-left output coordinates, then flip for Core Image.
        let margin = output.height * 0.06
        var rect = CGRect(x: (output.width - plate.extent.width) / 2, y: 0, width: plate.extent.width, height: plate.extent.height)
        rect.origin.y = settings.position == .bottom ? output.height - margin - rect.height : margin
        if let cam = camera, cam.intersects(rect) {
            // Prefer sliding sideways beside the camera (stays at the edge); otherwise hop above/below it.
            let gap = margin * 0.5
            let leftX = cam.minX - gap - rect.width, rightX = cam.maxX + gap
            if cam.midX > output.width / 2, leftX >= gap {
                rect.origin.x = leftX
            } else if cam.midX <= output.width / 2, rightX + rect.width <= output.width - gap {
                rect.origin.x = rightX
            } else {
                rect.origin.y = settings.position == .bottom ? max(cam.minY - gap - rect.height, margin)
                    : min(cam.maxY + gap, output.height - margin - rect.height)
            }
        }
        return plate.transformed(by: CGAffineTransform(translationX: rect.minX, y: output.height - rect.maxY))
    }

    static func captionImage(_ caption: Caption, highlight: Int?, fontSize: CGFloat, maxWidth: CGFloat) -> CIImage? {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil).map { CTFontCreateCopyWithSymbolicTraits($0, fontSize, nil, .boldTrait, .boldTrait) ?? $0 }
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let text = NSMutableAttributedString()
        for (i, w) in caption.words.enumerated() {
            let color = i == highlight ? CGColor(red: 1, green: 0.83, blue: 0.2, alpha: 1) : CGColor(gray: 1, alpha: 1)
            text.append(NSAttributedString(string: (i > 0 ? " " : "") + w.text, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: para,
            ]))
        }
        let pad = CGSize(width: fontSize * 0.6, height: fontSize * 0.32)
        let setter = CTFramesetterCreateWithAttributedString(text)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                                                              CGSize(width: maxWidth - 2 * pad.width, height: .greatestFiniteMagnitude), nil)
        let textSize = CGSize(width: ceil(fit.width), height: ceil(fit.height))
        let size = CGSize(width: textSize.width + 2 * pad.width, height: textSize.height + 2 * pad.height)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let plate = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: fontSize * 0.35, cornerHeight: fontSize * 0.35,
                           transform: nil)
        ctx.addPath(plate)
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 0.86))
        ctx.fillPath()
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(origin: CGPoint(x: pad.width, y: pad.height), size: textSize),
                                                                         transform: nil), nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    // MARK: - Helpers

    /// Scales an image with origin at zero and `sourceSize` into `rect`. With `sharp`, uses Lanczos in both
    /// directions (crisp text when shrinking, less mush when enlarging) plus light sharpening on big enlargements.
    private func place(_ image: CIImage, sourceSize: CGSize, into rect: CGRect, sharp: Bool) -> CIImage {
        let sx = rect.width / sourceSize.width, sy = rect.height / sourceSize.height
        var scaled: CIImage
        if abs(sx - 1) < 0.005 && abs(sy - 1) < 0.005 {
            scaled = image
        } else if sharp || sx < 0.7 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = image.clampedToExtent().cropped(to: CGRect(origin: .zero, size: sourceSize))
            f.scale = Float(sy)
            f.aspectRatio = Float(sx / sy)
            scaled = f.outputImage!
            if sharp && sx > 1.3 {
                // Enlarged detail reads softer; counter it gently, scaled to how far we've enlarged.
                let f = CIFilter.sharpenLuminance()
                f.inputImage = scaled
                f.sharpness = Float(min(0.25 * (sx - 1), 0.6))
                f.radius = Float(min(0.8 * sx, 4))
                scaled = f.outputImage!.cropped(to: scaled.extent)
            }
        } else {
            scaled = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy), highQualityDownsample: true)
        }
        return scaled.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    // MARK: - Camera background blur

    private let segmentationLock = NSLock()
    private lazy var segmentation: [VNGeneratePersonSegmentationRequest.QualityLevel: VNGeneratePersonSegmentationRequest] = [:]

    private func segmentationRequest(accurate: Bool) -> VNGeneratePersonSegmentationRequest {
        let level: VNGeneratePersonSegmentationRequest.QualityLevel = accurate ? .accurate : .balanced
        if let r = segmentation[level] { return r }
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = level
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        segmentation[level] = r
        return r
    }

    /// Blurs everything except the person, using Vision's person segmentation. `image` has its origin at zero.
    private func blurBackground(_ image: CIImage, pixelBuffer: CVPixelBuffer?, strength: Double, accurate: Bool) -> CIImage {
        let extent = image.extent
        let raw: CIImage? = segmentationLock.withLock {
            let request = segmentationRequest(accurate: accurate)
            let handler = pixelBuffer.map { VNImageRequestHandler(cvPixelBuffer: $0) }
                ?? VNImageRequestHandler(ciImage: image)
            guard (try? handler.perform([request])) != nil,
                  let buffer = request.results?.first?.pixelBuffer else { return nil }
            return CIImage(cvPixelBuffer: buffer)
        }
        guard let raw else { return image }
        // Lanczos-upscale the low-res mask, then steepen its edge so the soft fringe of untouched room shrinks.
        let up = CIFilter.lanczosScaleTransform()
        up.inputImage = raw
        up.scale = Float(extent.height / raw.extent.height)
        up.aspectRatio = Float((extent.width / raw.extent.width) / (extent.height / raw.extent.height))
        let mask = up.outputImage!.cropped(to: extent).applyingFilter("CIColorMatrix", parameters: [
            // The one-channel mask arrives in red; spread it to grey so every mask filter reads it.
            "inputRVector": CIVector(x: 2.5, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 2.5, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 2.5, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -1.2, y: -1.2, z: -1.2, w: 0),
        ]).applyingFilter("CIColorClamp")

        // Normalised blur: blur only the background (person weighted out), then divide by the blurred weight so
        // the person's colours never bleed into the blurred room as a halo.
        let sigma = strength * extent.height * 0.03
        // Grow the cut-out used for weighting so the fringe just outside the person (hair wisps, webcam edge
        // sharpening) isn't sampled either; otherwise it smears into a pale glow around the outline.
        let grown = mask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: extent.height * 0.02])
            .cropped(to: extent)
        let weighted = image.clampedToExtent().applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: grown.clampedToExtent().applyingFilter("CIColorInvert").applyingFilter("CIMaskToAlpha"),
        ])
        let blurredWeighted = weighted.applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        // CIColorMatrix unpremultiplies its input (colour / alpha) before applying the matrix, so forcing alpha
        // to 1 here *is* the normalisation: blurred background colour / blurred background weight.
        let normalised = blurredWeighted
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                         "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .applyingFilter("CIColorClamp")
        // Deep inside the person almost no background reaches the blur, so dividing is unstable; fall back to a
        // plain blur there (it's hidden behind the person anyway). Confidence = blurred background weight x4.
        let plain = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        let confidence = blurredWeighted.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 4), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 4),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 4), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).applyingFilter("CIColorClamp")
        let blurred = normalised.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: plain, kCIInputMaskImageKey: confidence,
        ]).cropped(to: extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: blurred, kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
    }

    private func roundedRect(_ rect: CGRect, radius: CGFloat) -> CIImage {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = rect
        f.radius = Float(max(0, min(radius, min(rect.width, rect.height) / 2)))
        f.color = .white
        return f.outputImage!
    }

    private func shadow(for mask: CIImage, strength: Double, blur: CGFloat, offset: CGFloat) -> CIImage {
        let dark = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(strength)),
        ])
        return dark.applyingGaussianBlur(sigma: Double(blur))
            .cropped(to: mask.extent.insetBy(dx: -blur * 3, dy: -blur * 3))
            .transformed(by: CGAffineTransform(translationX: 0, y: -offset))
    }

    private func scaleAlpha(_ image: CIImage, by a: Double) -> CIImage {
        // CIColorMatrix works on unpremultiplied colour, so only alpha is scaled.
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(a))])
    }

    private func average(_ layers: [CIImage]) -> CIImage {
        guard layers.count > 1 else { return layers.first ?? .empty() }
        let w = 1.0 / Double(layers.count)
        return layers.map { scaleAlpha($0, by: w) }.dropFirst().reduce(scaleAlpha(layers[0], by: w)) { acc, next in
            next.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: acc])
        }
    }

    private func flip(_ r: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    private func ciColor(_ c: RGBA) -> CIColor {
        CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }
}
