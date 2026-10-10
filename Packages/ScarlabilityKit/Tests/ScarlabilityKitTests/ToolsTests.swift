import CoreGraphics
import Foundation
import Testing
@testable import ScarlabilityKit

struct EraserTests {
    let line = Stroke(color: .black, points: (0...100).map { InkPoint(x: Float($0), y: 50, width: 2) })

    @Test func wholeStrokeEraserHitsOnlyWhatItTouches() {
        #expect(StrokeHitTesting.eraser(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 50, y: 60), radius: 3, touches: line))
        #expect(!StrokeHitTesting.eraser(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 60, y: 40), radius: 3, touches: line))
    }

    @Test func partialEraserCutsTheStrokeInTwo() throws {
        let pieces = try #require(StrokeHitTesting.erase(line, from: CGPoint(x: 50, y: 30), to: CGPoint(x: 50, y: 70), radius: 4))
        #expect(pieces.count == 2)
        // The gap is about the eraser's size plus the line's width.
        let leftEnd = pieces[0].last!.x, rightStart = pieces[1].first!.x
        #expect(leftEnd < 46 && leftEnd > 43)
        #expect(rightStart > 54 && rightStart < 57)
    }

    @Test func partialEraserCanRemoveEverything() throws {
        let pieces = try #require(StrokeHitTesting.erase(line, from: CGPoint(x: -10, y: 50), to: CGPoint(x: 110, y: 50), radius: 5))
        #expect(pieces.isEmpty)
        #expect(StrokeHitTesting.erase(line, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0), radius: 3) == nil)
    }
}

struct SelectionTests {
    @Test func lassoSelectsStrokesMostlyInside() {
        let lasso = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
        let inside = Stroke(color: .black, points: (10...90).map { InkPoint(x: Float($0), y: 50, width: 2) })
        let half = Stroke(color: .black, points: (60...150).map { InkPoint(x: Float($0), y: 50, width: 2) })
        let outside = Stroke(color: .black, points: (200...250).map { InkPoint(x: Float($0), y: 50, width: 2) })
        #expect(StrokeHitTesting.lasso(lasso, selects: inside))
        #expect(!StrokeHitTesting.lasso(lasso, selects: half))
        #expect(!StrokeHitTesting.lasso(lasso, selects: outside))
    }

    @Test func movedCopyKeepsDepthButGetsANewID() {
        let stroke = Stroke(color: .black, points: [InkPoint(x: 10, y: 10, width: 2), InkPoint(x: 20, y: 10, width: 2)])
        let moved = stroke.transformed(CGAffineTransform(translationX: 5, y: 7), widthScale: 2)
        #expect(moved.id != stroke.id)
        #expect(moved.createdAt == stroke.createdAt)
        #expect(moved.points.first == InkPoint(x: 15, y: 17, width: 4))
    }
}

struct HighlighterTests {
    @Test func chiselIsTallAndNarrow() {
        let dot = StrokeGeometry.chiselPath(for: [InkPoint(x: 50, y: 50, width: 20)]).boundingBoxOfPath
        #expect(abs(dot.height - 20) < 0.01)
        #expect(abs(dot.width - 20 * StrokeGeometry.chiselAspect) < 0.01)
        let sideways = StrokeGeometry.chiselPath(for: (0...50).map { InkPoint(x: Float($0), y: 50, width: 20) }).boundingBoxOfPath
        #expect(abs(sideways.height - 20) < 0.01)
    }
}

struct ShapeRecognizerTests {
    private func wobble(_ points: [CGPoint], amount: CGFloat = 0.8) -> [CGPoint] {
        var random = SeededRandom(seed: 3)
        return points.map { CGPoint(x: $0.x + random.gaussian() * amount, y: $0.y + random.gaussian() * amount) }
    }

    @Test func line() {
        let points = wobble((0...100).map { CGPoint(x: 10 + CGFloat($0) * 2, y: 40 + CGFloat($0) * 0.5) })
        guard case .line(let a, let b) = ShapeRecognizer.recognize(points) else {
            Issue.record("not a line")
            return
        }
        #expect(a.distance(to: CGPoint(x: 10, y: 40)) < 3 && b.distance(to: CGPoint(x: 210, y: 90)) < 3)
    }

    @Test func circle() {
        let points = wobble((0...200).map { i in
            let t = CGFloat(i) / 200 * 2 * .pi
            return CGPoint(x: 100 + 50 * cos(t), y: 100 + 50 * sin(t))
        })
        guard case .ellipse(let center, let radii, _) = ShapeRecognizer.recognize(points) else {
            Issue.record("not an ellipse")
            return
        }
        #expect(center.distance(to: CGPoint(x: 100, y: 100)) < 3)
        #expect(abs(radii.width - 50) < 3 && radii.width == radii.height)
    }

    @Test func rectangle() {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 160, y: 0), CGPoint(x: 160, y: 90), CGPoint(x: 0, y: 90)]
        var outline: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst() + [corners[0]]) {
            for step in 0..<60 {
                let t = CGFloat(step) / 60
                outline.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        guard case .polygon(let found) = ShapeRecognizer.recognize(wobble(outline)) else {
            Issue.record("not a polygon")
            return
        }
        #expect(found.count == 4)
        // Snapped to a clean, page-aligned rectangle.
        let xs = Set(found.map { ($0.x / 2).rounded() }), ys = Set(found.map { ($0.y / 2).rounded() })
        #expect(xs.count == 2 && ys.count == 2)
    }

    @Test func triangle() {
        let corners = [CGPoint(x: 0, y: 100), CGPoint(x: 60, y: 0), CGPoint(x: 120, y: 100)]
        var outline: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst() + [corners[0]]) {
            for step in 0..<50 {
                let t = CGFloat(step) / 50
                outline.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        guard case .polygon(let found) = ShapeRecognizer.recognize(wobble(outline)) else {
            Issue.record("not a polygon")
            return
        }
        #expect(found.count == 3)
    }

    @Test func handwritingIsLeftAlone() {
        // Cursive loops are neither a line nor a closed shape.
        let loops = (0...300).map { i -> CGPoint in
            let t = CGFloat(i) / 300
            return CGPoint(x: t * 200 + 14 * sin(t * .pi * 10), y: 50 - 18 * cos(t * .pi * 10))
        }
        #expect(ShapeRecognizer.recognize(loops) == nil)
        // An open arc isn't closed.
        let arc = (0...100).map { i -> CGPoint in
            let t = CGFloat(i) / 100 * .pi
            return CGPoint(x: 100 + 50 * cos(t), y: 100 + 50 * sin(t))
        }
        #expect(ShapeRecognizer.recognize(arc) == nil)
    }

    @Test func highlighterOnlySnapsLines() {
        let circle = (0...200).map { i -> CGPoint in
            let t = CGFloat(i) / 200 * 2 * .pi
            return CGPoint(x: 100 + 50 * cos(t), y: 100 + 50 * sin(t))
        }
        #expect(ShapeRecognizer.recognize(circle, linesOnly: true) == nil)
    }
}

struct ShapeAdjustingTests {
    private func angle(of shape: ShapeRecognizer.Shape) -> CGFloat {
        guard case .line(let a, let b) = shape else { return .nan }
        return atan2(b.y - a.y, b.x - a.x) * 180 / .pi
    }

    @Test func lineEndFollowsThePen() {
        let line = ShapeRecognizer.Shape.line(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 30))
        let moved = ShapeAdjusting.adjust(line, from: CGPoint(x: 100, y: 30), to: CGPoint(x: 120, y: 80))
        #expect(moved == .line(CGPoint(x: 0, y: 0), CGPoint(x: 120, y: 80)))
    }

    /// Nearly flat or nearly upright locks exactly flat or upright; a bit further frees it.
    @Test func lineLocksFlatAndUpright() {
        let line = ShapeRecognizer.Shape.line(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 30))
        let start = CGPoint(x: 100, y: 30)
        #expect(angle(of: ShapeAdjusting.adjust(line, from: start, to: CGPoint(x: 100, y: 6))) == 0)
        #expect(angle(of: ShapeAdjusting.adjust(line, from: start, to: CGPoint(x: -100, y: 5))) == 180)
        #expect(abs(angle(of: ShapeAdjusting.adjust(line, from: start, to: CGPoint(x: 4, y: 100))) - 90) < 1e-9)
        let free = angle(of: ShapeAdjusting.adjust(line, from: start, to: CGPoint(x: 100, y: 12)))
        #expect(free > 6 && free < 7)
        // Locking keeps the length the pen gives it.
        guard case .line(let a, let b) = ShapeAdjusting.adjust(line, from: start, to: CGPoint(x: 100, y: 6)) else { return }
        #expect(abs(a.distance(to: b) - hypot(100, 6)) < 1e-9)
    }

    @Test func closedShapesTurnAndGrowAroundTheirCenter() throws {
        let square = ShapeRecognizer.Shape.polygon([CGPoint(x: -10, y: -10), CGPoint(x: 10, y: -10), CGPoint(x: 10, y: 10), CGPoint(x: -10, y: 10)])
        // Pull the corner out to twice as far, turned 30°: the square doubles and turns 30°.
        let turned = CGPoint(x: 20 * sqrt(2) * cos(-.pi / 4 + .pi / 6), y: 20 * sqrt(2) * sin(-.pi / 4 + .pi / 6))
        guard case .polygon(let corners) = ShapeAdjusting.adjust(square, from: CGPoint(x: 10, y: -10), to: turned) else {
            Issue.record("not a polygon")
            return
        }
        #expect(abs(corners[1].x - turned.x) < 1e-9 && abs(corners[1].y - turned.y) < 1e-9)
        // Turned only 3°, it stays square to the page but still grows.
        let nudged = CGPoint(x: 20 * sqrt(2) * cos(-.pi / 4 + .pi / 60), y: 20 * sqrt(2) * sin(-.pi / 4 + .pi / 60))
        guard case .polygon(let squared) = ShapeAdjusting.adjust(square, from: CGPoint(x: 10, y: -10), to: nudged) else { return }
        #expect(abs(squared[1].x - 20) < 1e-9 && abs(squared[1].y + 20) < 1e-9)
    }
}

struct PaperTests {
    @Test func oldNotesWithoutLineSpacingStillOpen() throws {
        let json = #"{"template":"lined","color":{"red":255,"green":255,"blue":255,"alpha":255}}"#
        let paper = try JSONDecoder().decode(PaperStyle.self, from: Data(json.utf8))
        #expect(paper.lineSpacingMillimeters == 8)
    }

    @Test func namedLineSpacingsStillOpen() throws {
        let json = #"{"template":"lined","color":{"red":255,"green":255,"blue":255,"alpha":255},"lineSpacing":"wide"}"#
        #expect(try JSONDecoder().decode(PaperStyle.self, from: Data(json.utf8)).lineSpacingMillimeters == 10)
    }

    /// Any spacing round-trips, and the nearest named one is stored too, for older app versions.
    @Test func lineSpacingInBetweenIsSaved() throws {
        let paper = PaperStyle(template: .lined, color: .white, lineSpacingMillimeters: 9.25)
        let data = try JSONEncoder().encode(paper)
        #expect(try JSONDecoder().decode(PaperStyle.self, from: data) == paper)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["lineSpacing"] as? String == "wide")
        #expect(PaperStyle.whiteLined.lineSpacingMillimeters == 9)
    }

    /// Live highlights are drawn solid in this color; it must match a finished highlight.
    @Test func highlightColorOnPaperMatchesTheRenderedPage() throws {
        let yellow = InkColor(hex: 0xF6FF00)
        let solid = yellow.highlighted(on: .white)
        let content = PageContent(paper: PaperStyle(template: .blank, color: .white), size: CGSize(width: 40, height: 40), strokes: [
            RenderedStroke(Stroke(tool: .highlighter, color: yellow, points: [InkPoint(x: 5, y: 20, width: 16), InkPoint(x: 35, y: 20, width: 16)])),
        ])
        let image = try #require(Thumbnail.render(content, width: 40, scale: 1))
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -20, y: -20, width: 40, height: 40))
        let pixel = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        #expect(abs(Int(pixel[0]) - Int(solid.red)) <= 2)
        #expect(abs(Int(pixel[1]) - Int(solid.green)) <= 2)
        #expect(abs(Int(pixel[2]) - Int(solid.blue)) <= 2)
    }

    @Test func blackInkTurnsWhiteOnDarkPaper() {
        let dark = PaperStyle(template: .blank, color: .paperDark)
        #expect(dark.isDark)
        #expect(InkColor.black.displayed(on: dark).luminance > 0.9)
        #expect(InkColor.red.displayed(on: dark) == .red)
        #expect(InkColor.black.displayed(on: .whiteLined) == .black)
    }
}
