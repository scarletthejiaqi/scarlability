import Foundation

public enum InkMerge {
    /// What a page shows: every device's strokes, minus any stroke that any device erased,
    /// oldest first so newer strokes draw on top.
    public static func visibleStrokes(from inks: some Sequence<DeviceInk>) -> [Stroke] {
        var erased = Set<UUID>()
        var seen = Set<UUID>()
        var strokes: [Stroke] = []
        for ink in inks {
            erased.formUnion(ink.erasedStrokeIDs)
            for stroke in ink.strokes where seen.insert(stroke.id).inserted {
                strokes.append(stroke)
            }
        }
        return strokes
            .filter { !erased.contains($0.id) }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }
}
