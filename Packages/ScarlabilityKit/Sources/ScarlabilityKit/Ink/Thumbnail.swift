import CoreGraphics

public enum Thumbnail {
    /// A picture of a page, `width` points wide at `scale` pixels per point.
    public static func render(_ content: PageContent, width: CGFloat, scale: CGFloat) -> CGImage? {
        guard content.size.width > 0 else { return nil }
        let zoom = width / content.size.width
        let pixelWidth = Int((width * scale).rounded()), pixelHeight = Int((content.size.height * zoom * scale).rounded())
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Page coordinates have their origin at the top-left.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: zoom * scale, y: -zoom * scale)
        PageRenderer.draw(content, layer: .all, in: context, clip: CGRect(origin: .zero, size: content.size))
        return context.makeImage()
    }
}
