import CoreGraphics
import Foundation

/// Zoom "locks" like Notability's: while pinching, the zoom sticks at special levels (page width
/// fills the screen, whole page fits) and only moves on after you pinch a bit further.
///
/// Works in log space, where pinching by the same factor always moves the same distance. Each
/// detent swallows a band of pinch positions; outside the bands, the zoom follows the fingers
/// exactly. Bands are laid out so each one holds exactly its detent's zoom, and neighboring bands
/// can never overlap, however close two detents are.
public struct ZoomDetents: Sendable {
    /// ln of each detent zoom, ascending.
    private let detents: [CGFloat]
    /// The pinch position at the middle of each detent's band.
    private let bandCenters: [CGFloat]
    /// Half a band's width.
    private let halfWidth: CGFloat

    /// How far past a detent you have to pinch to leave it (0.07 ≈ 7%).
    public static let defaultStrength: CGFloat = 0.07

    public init(zooms: [CGFloat], strength: CGFloat = ZoomDetents.defaultStrength) {
        let detents = Array(Set(zooms.filter { $0 > 0 }.map { log($0) })).sorted()
        let halfWidth = log(1 + strength)
        // Every band below a detent shifts it up by `halfWidth`, every band above shifts it down;
        // offsetting the band center by the same amount makes the band show exactly the detent.
        self.bandCenters = detents.indices.map { k in
            detents[k] + halfWidth * CGFloat(k) - halfWidth * CGFloat(detents.count - 1 - k)
        }
        self.detents = detents
        self.halfWidth = halfWidth
    }

    /// The zoom to show for a pinch position.
    public func zoom(forPinchPosition position: CGFloat) -> CGFloat {
        var logZoom = position
        for center in bandCenters {
            logZoom -= min(max(position - center, -halfWidth), halfWidth)
        }
        return exp(logZoom)
    }

    /// The pinch position that shows `zoom`. Starting at a detent puts you in the middle of its
    /// band, so leaving takes the full push either way.
    public func pinchPosition(forZoom zoom: CGFloat) -> CGFloat {
        let target = log(zoom)
        if let k = detents.firstIndex(where: { abs($0 - target) < 1e-4 }) {
            return bandCenters[k]
        }
        // `zoom(forPinchPosition:)` never decreases, so bisect.
        let spread = halfWidth * CGFloat(detents.count) + 1
        var low = target - spread, high = target + spread
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if log(self.zoom(forPinchPosition: mid)) < target { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}
