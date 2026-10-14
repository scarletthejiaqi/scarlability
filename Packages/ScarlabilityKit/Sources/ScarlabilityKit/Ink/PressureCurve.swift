import Foundation

/// Turns Apple Pencil force into a width multiplier for the pressure pen.
///
/// Normal writing pressure gives the pen's base width; pressing harder makes the line thicker and
/// writing lightly makes it thinner. `sensitivity` scales how far it can go either way.
public struct PressureCurve: Hashable, Sendable {
    /// 0 means pressure has no effect; 1 is the strongest effect.
    public var sensitivity: Double
    /// How far above the base width the line can go at full sensitivity (0.7 → up to 170%).
    public var maxSwing: Double
    /// How far below the base width the line can go at full sensitivity (0.7 → down to 30%).
    public var thinSwing: Double
    /// Below 1, light pressure ramps the width up quickly, so light writing doesn't look starved;
    /// above 1, light pressure stays thin.
    public var exponent: Double

    public static let defaultSensitivity = 0.5
    public static let defaultFountainSensitivity = 0.8

    /// Normalized force (`force / maximumPossibleForce`) treated as a firm press. Handwriting rarely
    /// gets near the Pencil's maximum, so the full range is reached well before it.
    static let firmForce = 0.55

    /// - Parameter thinSwing: Defaults to `maxSwing`, so the line goes as far thinner as thicker.
    public init(sensitivity: Double = PressureCurve.defaultSensitivity, maxSwing: Double = 0.7, thinSwing: Double? = nil,
                exponent: Double = 0.8) {
        self.sensitivity = sensitivity
        self.maxSwing = maxSwing
        self.thinSwing = thinSwing ?? maxSwing
        self.exponent = exponent
    }

    /// The fountain pen (钢笔): a wider range, and light pressure stays thin, so a line can go
    /// from thin to bold within one stroke. Its thinnest line (45% at the default sensitivity) is
    /// still about two pixels wide: thinner hairlines looked scratchy and jagged on screen.
    public static func fountain(sensitivity: Double = PressureCurve.defaultFountainSensitivity) -> PressureCurve {
        PressureCurve(sensitivity: sensitivity, maxSwing: 0.9, thinSwing: 0.69, exponent: 1.2)
    }

    public func widthFactor(forNormalizedForce force: Double) -> Double {
        let pressure = min(max(force / Self.firmForce, 0), 1)
        let curved = pow(pressure, exponent)
        let strength = min(max(sensitivity, 0), 1)
        let thinnest = 1 - thinSwing * strength, thickest = 1 + maxSwing * strength
        return thinnest + (thickest - thinnest) * curved
    }
}
