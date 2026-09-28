import Foundation
import CoreGraphics
import ImageIO
import Vision
import UniformTypeIdentifiers

/// Local image helpers: decoding, downscaling, JPEG encoding and on-device OCR (Apple Vision).
/// Nothing here touches the network.
public enum Imaging {
    public static func loadImage(_ url: URL, maxPixel: Int? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return image(from: src, maxPixel: maxPixel)
    }

    public static func loadImage(data: Data, maxPixel: Int? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return image(from: src, maxPixel: maxPixel)
    }

    static func image(from src: CGImageSource, maxPixel: Int?) -> CGImage? {
        guard CGImageSourceGetCount(src) > 0 else { return nil }
        if let maxPixel {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    public static func jpegData(_ image: CGImage, quality: Double = 0.78) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flattened(image) ?? image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Composites transparent images on white so JPEG output doesn't turn transparency black.
    static func flattened(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Recognizes printed or handwritten text, returning lines top to bottom.
    public static func recognizeText(_ image: CGImage, fast: Bool = false) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return "" }
        let observations = request.results ?? []
        let lines = observations
            .sorted { a, b in
                // Vision uses a bottom-left origin: higher y is higher on the page.
                abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    public static func recognizeText(url: URL) -> String {
        guard let img = loadImage(url, maxPixel: 3000) else { return "" }
        return recognizeText(img)
    }

    /// Renders one PDF page to an image of the given pixel width.
    public static func render(page: CGPDFPage, width: Int) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let rotation = page.rotationAngle % 360
        let rotated = rotation == 90 || rotation == 270
        let pageW = rotated ? box.height : box.width, pageH = rotated ? box.width : box.height
        let scale = CGFloat(width) / pageW
        let w = Int(pageW * scale), h = Int(pageH * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let transform = page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: w, height: h), rotate: 0, preserveAspectRatio: true)
        ctx.concatenate(transform)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    /// Counts image XObjects referenced by a page (a proxy for "this page has pictures the text can't carry").
    public static func imageCount(page: CGPDFPage) -> Int {
        guard let dict = page.dictionary else { return 0 }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return 0 }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return 0 }
        var count = 0
        CGPDFDictionaryApplyBlock(xobjects, { _, object, ctx in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream, let sdict = CGPDFStreamGetDictionary(stream) {
                var subtype: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(sdict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" {
                    ctx?.assumingMemoryBound(to: Int.self).pointee += 1
                }
            }
            return true
        }, &count)
        return count
    }
}
