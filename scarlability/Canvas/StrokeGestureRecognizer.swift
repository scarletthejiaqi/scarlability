#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Tracks one touch as a stroke and collects every sample the hardware reports.
///
/// Apple Pencil reports ~240 samples per second but the screen only refreshes at 60–120 Hz, so
/// each event carries several "coalesced" samples; using all of them keeps fast strokes smooth.
/// Predicted samples are only for display, to hide latency.
final class StrokeGestureRecognizer: UIGestureRecognizer {
    struct Sample {
        /// In `coordinateView`'s coordinates.
        var location: CGPoint
        /// `force / maximumPossibleForce`, or nil if the touch has no pressure (fingers).
        var force: Double?
        /// Set when the Pencil will send a more accurate force for this sample later.
        var estimationIndex: Int?
    }

    struct ForceUpdate {
        var estimationIndex: Int
        var force: Double
    }

    /// The view whose coordinate space samples are reported in.
    weak var coordinateView: UIView?
    private(set) var touchType: UITouch.TouchType = .pencil
    private(set) var predictedLocations: [CGPoint] = []

    private var trackedTouch: UITouch?
    private var samples: [Sample] = []
    private var forceUpdates: [ForceUpdate] = []

    /// Returns the samples received since the last call.
    func takeSamples() -> [Sample] {
        defer { samples.removeAll(keepingCapacity: true) }
        return samples
    }

    /// Returns the refined force readings received since the last call.
    func takeForceUpdates() -> [ForceUpdate] {
        defer { forceUpdates.removeAll() }
        return forceUpdates
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, let touch = touches.first else {
            // A second finger means scrolling or zooming, not writing. Extra touches during a Pencil
            // stroke (like a resting palm) are simply ignored.
            if trackedTouch?.type == .direct {
                state = state == .possible ? .failed : .cancelled
            } else {
                touches.filter { $0 !== trackedTouch }.forEach { ignore($0, for: event) }
            }
            return
        }
        // Two fingers landing together are a scroll or zoom.
        if touch.type == .direct, (event.allTouches?.filter { $0.type == .direct }.count ?? 0) > 1 {
            state = .failed
            return
        }
        trackedTouch = touch
        touchType = touch.type
        touches.filter { $0 !== touch }.forEach { ignore($0, for: event) }
        collect(touch, event)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        collect(touch, event)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        collect(touch, event)
        predictedLocations = []
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        state = .cancelled
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let index = touch.estimationUpdateIndex?.intValue, let force = Self.normalizedForce(touch) else { continue }
            forceUpdates.append(ForceUpdate(estimationIndex: index, force: force))
        }
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        samples.removeAll()
        forceUpdates.removeAll()
        predictedLocations = []
    }

    private func collect(_ touch: UITouch, _ event: UIEvent) {
        let view = coordinateView ?? self.view
        for sample in event.coalescedTouches(for: touch) ?? [touch] {
            let expectsForceUpdate = sample.estimatedPropertiesExpectingUpdates.contains(.force)
            samples.append(Sample(
                location: sample.preciseLocation(in: view),
                force: Self.normalizedForce(sample),
                estimationIndex: expectsForceUpdate ? sample.estimationUpdateIndex?.intValue : nil
            ))
        }
        predictedLocations = (event.predictedTouches(for: touch) ?? []).map { $0.preciseLocation(in: view) }
    }

    private static func normalizedForce(_ touch: UITouch) -> Double? {
        guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return nil }
        return Double(touch.force / touch.maximumPossibleForce)
    }
}
#endif
