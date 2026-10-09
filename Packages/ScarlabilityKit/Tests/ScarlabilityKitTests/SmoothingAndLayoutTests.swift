import CoreGraphics
import Foundation
import Testing
@testable import ScarlabilityKit

struct StrokeSmoothingTests {
    /// A straight line drawn with a shaky hand should come out much straighter.
    @Test func removesJitter() {
        var random = SeededRandom(seed: 7)
        let raw = (0..<400).map { i in
            InkPoint(x: Float(i) * 0.4, y: Float(random.gaussian() * 0.15), width: 2)
        }
        let smoothed = StrokeSmoothing.smooth(raw, radius: 1.2)
        func wobble(_ points: [InkPoint]) -> Float {
            // Ignore the ends, where smoothing deliberately fades out.
            let offsets: [Float] = points[20..<380].map { abs($0.y) }
            return offsets.reduce(0, +) / Float(offsets.count)
        }
        #expect(wobble(smoothed) < wobble(raw) * 0.4)
    }

    @Test func keepsTheEndsWhereThePenWas() {
        let raw: [InkPoint] = (0...100).map { i in
            let wobble = Float(i % 2), width = Float(1 + i % 3)
            return InkPoint(x: Float(i), y: wobble, width: width)
        }
        let smoothed = StrokeSmoothing.smooth(raw, radius: 1.5)
        #expect(smoothed.first == raw.first)
        #expect(smoothed.last == raw.last)
        #expect(smoothed.count == raw.count)
    }

    @Test func keepsTheShapeOfACurve() {
        // Points on a circle of radius 20 stay on it (within a fraction of a point).
        let raw = (0..<600).map { i -> InkPoint in
            let angle = Double(i) / 600 * 2 * .pi
            return InkPoint(x: Float(20 * cos(angle)), y: Float(20 * sin(angle)), width: 2)
        }
        for point in StrokeSmoothing.smooth(raw, radius: 1.2) {
            #expect(abs(hypot(Double(point.x), Double(point.y)) - 20) < 0.1)
        }
    }

    @Test func liveAndFinishedStrokesMatch() {
        var builder = StrokeBuilder(baseWidth: 2.2, curve: PressureCurve(), smoothing: 1.2)
        for (location, force) in DemoInk.shakyHandwritingSamples() {
            builder.add(location, force: force)
        }
        #expect(builder.livePoints() == builder.finishedPoints())
    }
}

struct PageSplitterTests {
    let pages = [
        CGRect(x: 14, y: 14, width: 595, height: 842),
        CGRect(x: 14, y: 856, width: 595, height: 842),
    ]

    @Test func strokeWithinOnePageStaysWhole() {
        let points = (0..<50).map { InkPoint(x: 100 + Float($0), y: 300, width: 2) }
        let pieces = PageSplitter.split(points, pageFrames: pages)
        #expect(pieces.count == 1)
        #expect(pieces[0].pageIndex == 0)
        #expect(pieces[0].points.first == InkPoint(x: 86, y: 286, width: 2))
    }

    @Test func strokeCrossingThePageEdgeContinuesOnTheNextPage() {
        // A vertical line from y = 800 to y = 900 in content coordinates; the edge is at 856.
        let points = (0...100).map { InkPoint(x: 200, y: 800 + Float($0), width: 2) }
        let pieces = PageSplitter.split(points, pageFrames: pages)
        #expect(pieces.map(\.pageIndex) == [0, 1])
        // Page 1's piece reaches just past its bottom edge (842 in its coordinates)…
        let firstMaxY = pieces[0].points.map(\.y).max()!
        #expect(firstMaxY > 842 && firstMaxY < 848)
        // …and page 2's piece starts just above its top edge.
        let secondMinY = pieces[1].points.map(\.y).min()!
        #expect(secondMinY < 0 && secondMinY > -6)
        #expect(pieces[1].points.last == InkPoint(x: 186, y: 44, width: 2))
    }

    @Test func zigzagAcrossTheEdgeMakesSeveralPieces() {
        var points: [InkPoint] = []
        for bounce in 0..<3 {
            for step in 0...40 {
                let y = bounce.isMultiple(of: 2) ? 820 + Float(step) * 2 : 900 - Float(step) * 2
                points.append(InkPoint(x: 100 + Float(bounce * 41 + step), y: y, width: 2))
            }
        }
        let pieces = PageSplitter.split(points, pageFrames: pages)
        #expect(pieces.filter { $0.pageIndex == 0 }.count == 2)
        #expect(pieces.filter { $0.pageIndex == 1 }.count == 2)
    }
}

struct ZoomDetentsTests {
    let detents = ZoomDetents(zooms: [1.3, 0.8])

    @Test func startsWhereYouAre() {
        for zoom: CGFloat in [0.5, 0.8, 1.0, 1.3, 2.0, 4.0] {
            let position = detents.pinchPosition(forZoom: zoom)
            #expect(abs(detents.zoom(forPinchPosition: position) - zoom) < 1e-6)
        }
    }

    @Test func sticksNearADetentThenMovesOn() {
        let start = detents.pinchPosition(forZoom: 1.3)
        // Pinching out 5% stays locked…
        #expect(abs(detents.zoom(forPinchPosition: start + log(1.05)) - 1.3) < 1e-9)
        // …and 15% moves on, from the detent, without a jump.
        let moved = detents.zoom(forPinchPosition: start + log(1.15))
        #expect(moved > 1.3 && moved < 1.3 * 1.15)
    }

    @Test func closeDetentsEachLockAtTheirOwnZoom() {
        // Portrait iPad: "whole page fits" and "width fits" are only ~8% apart.
        let close = ZoomDetents(zooms: [1.22, 1.316])
        for zoom: CGFloat in [1.22, 1.316] {
            let start = close.pinchPosition(forZoom: zoom)
            #expect(abs(close.zoom(forPinchPosition: start) - zoom) < 1e-9)
            #expect(abs(close.zoom(forPinchPosition: start + log(1.05)) - zoom) < 1e-9)
            #expect(abs(close.zoom(forPinchPosition: start - log(1.05)) - zoom) < 1e-9)
        }
    }

    @Test func zoomNeverMovesBackwards() {
        let close = ZoomDetents(zooms: [1.0, 1.05, 1.1])
        var previous: CGFloat = 0
        for step in -200...200 {
            let zoom = close.zoom(forPinchPosition: CGFloat(step) / 400)
            #expect(zoom >= previous - 1e-12)
            previous = zoom
        }
    }
}
