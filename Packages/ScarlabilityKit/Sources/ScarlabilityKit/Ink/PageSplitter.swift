import CoreGraphics

/// Pages sit edge to edge, so writing can run from one page onto the next. A stroke is stored per
/// page, so one that crosses a page edge is split into a piece for each page it touches.
public enum PageSplitter {
    public struct Piece: Equatable, Sendable {
        public var pageIndex: Int
        /// In that page's coordinates.
        public var points: [InkPoint]
    }

    /// Splits a stroke given in content coordinates (the space the page frames are in).
    ///
    /// Each piece reaches past its page edge by the stroke's width plus two extra points, so the
    /// curve inside the page is exactly the same as the unsplit stroke's. Pages clip at their edges,
    /// so the pieces meet without a seam.
    public static func split(_ points: [InkPoint], pageFrames: [CGRect]) -> [Piece] {
        guard !points.isEmpty else { return [] }
        let margin = CGFloat(points.map(\.width).max() ?? 0) / 2 + 1
        let extraPoints = 2
        var pieces: [Piece] = []

        for (pageIndex, frame) in pageFrames.enumerated() {
            let top = frame.minY - margin, bottom = frame.maxY + margin
            var runs: [ClosedRange<Int>] = []
            var runStart: Int?
            for (i, point) in points.enumerated() {
                let inside = CGFloat(point.y) >= top && CGFloat(point.y) <= bottom
                if inside, runStart == nil { runStart = i }
                if !inside, let start = runStart {
                    runs.append(start...(i - 1))
                    runStart = nil
                }
            }
            if let start = runStart { runs.append(start...(points.count - 1)) }

            // Extend each run and merge runs that now overlap.
            var merged: [ClosedRange<Int>] = []
            for run in runs {
                let extended = max(0, run.lowerBound - extraPoints)...min(points.count - 1, run.upperBound + extraPoints)
                if let last = merged.last, extended.lowerBound <= last.upperBound + 1 {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, extended.upperBound)
                } else {
                    merged.append(extended)
                }
            }

            for run in merged {
                let local = points[run].map {
                    InkPoint(x: $0.x - Float(frame.minX), y: $0.y - Float(frame.minY), width: $0.width)
                }
                pieces.append(Piece(pageIndex: pageIndex, points: local))
            }
        }
        return pieces
    }
}
