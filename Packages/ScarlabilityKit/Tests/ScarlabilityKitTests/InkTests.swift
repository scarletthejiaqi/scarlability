import CoreGraphics
import Foundation
import Testing
@testable import ScarlabilityKit

struct PressureCurveTests {
    @Test func zeroSensitivityIgnoresPressure() {
        let curve = PressureCurve(sensitivity: 0)
        for force in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(curve.widthFactor(forNormalizedForce: force) == 1)
        }
    }

    @Test func pressingHarderNeverMakesTheLineThinner() {
        let curve = PressureCurve(sensitivity: 0.8)
        var previous = 0.0
        for force in stride(from: 0.0, through: 1.0, by: 0.01) {
            let factor = curve.widthFactor(forNormalizedForce: force)
            #expect(factor >= previous)
            previous = factor
        }
    }

    @Test func rangeFollowsSensitivity() {
        let curve = PressureCurve(sensitivity: 1)
        #expect(abs(curve.widthFactor(forNormalizedForce: 0) - 0.3) < 1e-9)
        #expect(abs(curve.widthFactor(forNormalizedForce: 1) - 1.7) < 1e-9)
        // Forces past a firm press, and out-of-range sensitivity, are clamped.
        #expect(curve.widthFactor(forNormalizedForce: 5) == curve.widthFactor(forNormalizedForce: 1))
        #expect(PressureCurve(sensitivity: 3).widthFactor(forNormalizedForce: 1) == curve.widthFactor(forNormalizedForce: 1))
    }
}

struct StrokeBuilderTests {
    @Test func inputWithoutPressureUsesTheBaseWidth() {
        var builder = StrokeBuilder(baseWidth: 3, curve: PressureCurve(sensitivity: 1))
        for x in stride(from: 0.0, through: 50, by: 2) {
            builder.add(CGPoint(x: x, y: 10), force: nil)
        }
        #expect(builder.finishedPoints().allSatisfy { $0.width == 3 })
    }

    @Test func nearbySamplesAreMergedButTheStrokeEndsAtThePen() {
        var builder = StrokeBuilder(baseWidth: 2, curve: PressureCurve())
        #expect(builder.add(CGPoint(x: 0, y: 0), force: 0.3) == 0)
        #expect(builder.add(CGPoint(x: 0.1, y: 0), force: 0.3) == nil)
        builder.add(CGPoint(x: 10, y: 0), force: 0.3)
        builder.add(CGPoint(x: 20, y: 0), force: 0.3)
        let last = builder.finishedPoints().last!
        #expect(last.location == CGPoint(x: 20, y: 0))
    }

    @Test func forceUpdatesChangeTheWidth() {
        var builder = StrokeBuilder(baseWidth: 2, curve: PressureCurve(sensitivity: 1))
        let index = builder.add(CGPoint(x: 0, y: 0), force: 0.05)!
        let before = builder.finishedPoints()[index].width
        builder.updateForce(0.6, at: index)
        #expect(builder.finishedPoints()[index].width > before)
    }

    @Test func livePointsIncludePredictions() {
        var builder = StrokeBuilder(baseWidth: 2, curve: PressureCurve())
        builder.add(CGPoint(x: 0, y: 0), force: 0.3)
        builder.add(CGPoint(x: 10, y: 0), force: 0.3)
        let live = builder.livePoints(predicted: [CGPoint(x: 15, y: 0)])
        #expect(live.last?.location == CGPoint(x: 15, y: 0))
        #expect(builder.finishedPoints().last?.location == CGPoint(x: 10, y: 0))
    }
}

struct StrokeGeometryTests {
    @Test func interpolationKeepsPointsClose() {
        let points = [
            InkPoint(x: 0, y: 0, width: 2),
            InkPoint(x: 20, y: 5, width: 2),
            InkPoint(x: 40, y: 0, width: 4),
            InkPoint(x: 55, y: 12, width: 4),
        ]
        let dense = StrokeGeometry.interpolate(points)
        #expect(dense.first == points.first)
        #expect(dense.last == points.last)
        for (a, b) in zip(dense, dense.dropFirst()) {
            #expect(a.location.distance(to: b.location) <= 1.5)
        }
    }

    @Test func pathCoversTheStroke() {
        let stroke = Stroke(color: .black, points: [InkPoint(x: 10, y: 10, width: 4), InkPoint(x: 60, y: 30, width: 6)])
        let pathBounds = StrokeGeometry.path(for: stroke.points).boundingBoxOfPath
        let expected = stroke.bounds
        #expect(abs(pathBounds.minX - expected.minX) < 0.5)
        #expect(abs(pathBounds.maxX - expected.maxX) < 0.5)
        #expect(abs(pathBounds.minY - expected.minY) < 1.5)
        #expect(abs(pathBounds.maxY - expected.maxY) < 1.5)
    }

    @Test func aSinglePointIsADot() {
        let path = StrokeGeometry.path(for: [InkPoint(x: 5, y: 5, width: 4)])
        let box = path.boundingBoxOfPath
        #expect(abs(box.width - 4) < 0.01 && abs(box.height - 4) < 0.01)
        #expect(path.contains(CGPoint(x: 5, y: 5)))
    }

    /// Overlapping capsules must add up, not cancel out: every point along a stroke with sharp
    /// turns and a self-crossing loop must be filled.
    @Test func sharpTurnsAndLoopsHaveNoHoles() {
        var builder = StrokeBuilder(baseWidth: 3, curve: PressureCurve())
        var centerline: [CGPoint] = []
        let corners = [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 60), CGPoint(x: 15, y: 60), CGPoint(x: 70, y: 5), CGPoint(x: 70, y: 70)]
        for (a, b) in zip(corners, corners.dropFirst()) {
            for step in 0..<40 {
                let t = CGFloat(step) / 40
                let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                builder.add(p, force: 0.3)
                centerline.append(p)
            }
        }
        builder.add(corners.last!, force: 0.3)
        let points = builder.finishedPoints()
        let path = StrokeGeometry.path(for: points)
        for point in points {
            #expect(path.contains(point.location, using: .winding), "hole at \(point.location)")
        }
    }
}

struct InkCodecTests {
    @Test func roundTrip() throws {
        let ink = DeviceInk(strokes: DemoInk.strokes(), erasedStrokeIDs: [UUID(), UUID()])
        let decoded = try InkCodec.decode(try InkCodec.encode(ink))
        #expect(decoded == ink)
    }

    @Test func encodingIsDeterministic() throws {
        let ink = DeviceInk(strokes: DemoInk.strokes(), erasedStrokeIDs: [UUID(), UUID(), UUID()])
        #expect(try InkCodec.encode(ink) == InkCodec.encode(ink))
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: InkCodec.DecodeError.notAnInkFile) {
            try InkCodec.decode(Data("hello world".utf8))
        }
    }

    @Test func rejectsTruncatedFiles() throws {
        let data = try InkCodec.encode(DeviceInk(strokes: DemoInk.strokes()))
        #expect(throws: InkCodec.DecodeError.self) {
            try InkCodec.decode(data.prefix(data.count / 2))
        }
    }
}

struct InkMergeTests {
    @Test func combinesDevicesAndAppliesErasures() {
        let t = Date(timeIntervalSinceReferenceDate: 0)
        let a1 = Stroke(color: .black, points: [InkPoint(x: 0, y: 0, width: 1)], createdAt: t + 1)
        let a2 = Stroke(color: .black, points: [InkPoint(x: 0, y: 0, width: 1)], createdAt: t + 3)
        let b1 = Stroke(color: .blue, points: [InkPoint(x: 0, y: 0, width: 1)], createdAt: t + 2)
        let ipad = DeviceInk(strokes: [a1, a2])
        // The Mac drew b1 and erased the iPad's a2.
        let mac = DeviceInk(strokes: [b1], erasedStrokeIDs: [a2.id])
        let visible = InkMerge.visibleStrokes(from: [ipad, mac])
        #expect(visible.map(\.id) == [a1.id, b1.id])
    }
}

struct UndoHistoryTests {
    @Test func undoRedo() {
        var history = UndoHistory<Int>()
        history.record(1)
        history.record(2)
        #expect(history.popUndo() == 2)
        #expect(history.popRedo() == 2)
        #expect(history.popUndo() == 2)
        history.record(3)
        #expect(!history.canRedo)
        #expect(history.popUndo() == 3)
        #expect(history.popUndo() == 1)
        #expect(history.popUndo() == nil)
    }

    @Test func respectsTheLimit() {
        var history = UndoHistory<Int>(limit: 3)
        (1...5).forEach { history.record($0) }
        #expect(history.undoStack == [3, 4, 5])
    }
}

struct NotebookFolderTests {
    @Test func savesAndLoadsNotesPagesAndInk() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "NotebookFolderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ipad = NotebookFolder(root: root, deviceID: UUID())
        let mac = NotebookFolder(root: root, deviceID: UUID())

        let note = NoteRecord(title: "Biology")
        try ipad.save(note)
        #expect(try ipad.loadNotes() == [note])

        let second = PageRecord(sortKey: 2, size: PageSize.a4, paper: .whiteLined)
        let first = PageRecord(sortKey: 1, size: PageSize.a4, paper: .whiteLined)
        try ipad.save(second, inNote: note.id)
        try ipad.save(first, inNote: note.id)

        let ipadInk = DeviceInk(strokes: Array(DemoInk.strokes().prefix(2)))
        let macInk = DeviceInk(strokes: [DemoInk.strokes()[3]], erasedStrokeIDs: [ipadInk.strokes[0].id])
        try ipad.saveOwnInk(ipadInk, page: first.id, inNote: note.id)
        try mac.saveOwnInk(macInk, page: first.id, inNote: note.id)

        let pages = try mac.loadPages(ofNote: note.id)
        #expect(pages.map(\.record) == [first, second])
        #expect(pages[0].inks == [ipad.deviceID: ipadInk, mac.deviceID: macInk])
        #expect(pages[1].inks.isEmpty)
    }

    @Test func unreadableInkOnlyFailsForThisDevicesOwnFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "NotebookFolderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ipad = NotebookFolder(root: root, deviceID: UUID())
        let mac = NotebookFolder(root: root, deviceID: UUID())
        let note = NoteRecord(title: "Biology")
        let page = PageRecord(sortKey: 1, size: PageSize.a4, paper: .whiteLined)
        try ipad.save(page, inNote: note.id)
        let pageDirectory = root.appending(path: "notes/\(note.id.uuidString)/pages/\(page.id.uuidString)")
        try Data("garbage".utf8).write(to: pageDirectory.appending(path: "\(mac.deviceID.uuidString).ink"))

        // The iPad skips the Mac's unreadable file…
        #expect(try ipad.loadPages(ofNote: note.id).first?.inks.isEmpty == true)
        // …but the Mac must not open the page without its own ink.
        #expect(throws: InkCodec.DecodeError.notAnInkFile) {
            try mac.loadPages(ofNote: note.id)
        }
    }
}
