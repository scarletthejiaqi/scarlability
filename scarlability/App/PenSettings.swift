import Foundation
import Observation
import ScarlabilityKit

/// The pen's color and size presets and pressure settings, saved on this device.
@Observable
final class PenSettings {
    static let presetCount = 3
    /// `selectedColorSlot` value for the extra color next to the three presets.
    static let extraColorSlot = presetCount
    static let sizeRange: ClosedRange<Double> = 0.5...12

    var colorPresets: [InkColor] { didSet { save() } }
    /// The color in the extra slot, once the user has picked one.
    var extraColor: InkColor? { didSet { save() } }
    var selectedColorSlot: Int { didSet { save() } }
    /// Pen widths in page points.
    var sizePresets: [Double] { didSet { save() } }
    var selectedSizeSlot: Int { didSet { save() } }
    var pressureSensitivity: Double { didSet { save() } }
    var drawsWithFinger: Bool { didSet { save() } }

    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "penSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
            .flatMap { $0.validated() } ?? .defaults
        colorPresets = stored.colorPresets
        extraColor = stored.extraColor
        selectedColorSlot = stored.selectedColorSlot
        sizePresets = stored.sizePresets
        selectedSizeSlot = stored.selectedSizeSlot
        pressureSensitivity = stored.pressureSensitivity
        drawsWithFinger = stored.drawsWithFinger
    }

    var currentColor: InkColor {
        if selectedColorSlot == Self.extraColorSlot, let extraColor {
            return extraColor
        }
        return colorPresets[min(selectedColorSlot, Self.presetCount - 1)]
    }

    var currentWidth: Double { sizePresets[selectedSizeSlot] }

    var pressureCurve: PressureCurve { PressureCurve(sensitivity: pressureSensitivity) }

    private struct Stored: Codable {
        var colorPresets: [InkColor]
        var extraColor: InkColor?
        var selectedColorSlot: Int
        var sizePresets: [Double]
        var selectedSizeSlot: Int
        var pressureSensitivity: Double
        var drawsWithFinger: Bool

        static let defaults = Stored(
            colorPresets: [.black, .blue, .red],
            extraColor: nil,
            selectedColorSlot: 0,
            sizePresets: [1.4, 2.2, 3.4],
            selectedSizeSlot: 1,
            pressureSensitivity: PressureCurve.defaultSensitivity,
            drawsWithFinger: false
        )

        func validated() -> Stored? {
            guard colorPresets.count == PenSettings.presetCount,
                  sizePresets.count == PenSettings.presetCount,
                  (0...PenSettings.extraColorSlot).contains(selectedColorSlot),
                  sizePresets.indices.contains(selectedSizeSlot) else { return nil }
            return self
        }
    }

    private func save() {
        let stored = Stored(
            colorPresets: colorPresets,
            extraColor: extraColor,
            selectedColorSlot: selectedColorSlot,
            sizePresets: sizePresets,
            selectedSizeSlot: selectedSizeSlot,
            pressureSensitivity: pressureSensitivity,
            drawsWithFinger: drawsWithFinger
        )
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.storageKey)
    }
}
