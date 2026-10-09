import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ScarlabilityKit

/// Renders a demo page the same way the page tiles do. Set `SCARLABILITY_RENDER_DIR` to also save
/// the image as a PNG for checking by eye.
struct RenderSnapshotTests {
    @Test func rendersDemoPage() throws {
        let scale: CGFloat = 2
        let size = PageSize.a4
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Match the top-left origin the iPad's layers use.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)

        let strokes = DemoInk.strokes().map(RenderedStroke.init)
        let page = CGRect(origin: .zero, size: size)
        PaperRenderer.draw(.whiteLined, pageSize: size, in: context, clip: page)
        InkRenderer.draw(strokes, in: context, clip: page)

        let image = try #require(context.makeImage())
        // Spot check: the middle of the zigzag's first segment is ink-dark, a blank spot is white.
        #expect(try luminance(of: image, at: CGPoint(x: 75, y: 275), scale: scale) < 0.3)
        #expect(try luminance(of: image, at: CGPoint(x: 300, y: 700), scale: scale) > 0.95)

        if let directory = ProcessInfo.processInfo.environment["SCARLABILITY_RENDER_DIR"] {
            let url = URL(filePath: directory).appending(path: "demo-page.png")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
    }

    private func luminance(of image: CGImage, at point: CGPoint, scale: CGFloat) throws -> Double {
        let x = Int(point.x * scale), y = Int(point.y * scale)
        let data = try #require(image.dataProvider?.data as Data?)
        let offset = y * image.bytesPerRow + x * 4
        let (r, g, b) = (Double(data[offset]), Double(data[offset + 1]), Double(data[offset + 2]))
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    }
}
