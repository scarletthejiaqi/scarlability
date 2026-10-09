import Foundation
import Observation
import ScarlabilityKit

enum Tool: String, Codable, CaseIterable {
    case pen
    case highlighter
    case eraser
    case select
}

enum EraserMode: String, Codable {
    /// Touching a line removes all of it.
    case wholeStroke
    /// Rubs out just the part you touch.
    case partial
}

enum SelectMode: String, Codable {
    /// Draw a loop around what you want.
    case freeform
    /// Drag a rectangle.
    case box
}

/// Colors and sizes for a drawing tool. The color slot after the presets is the extra
/// (rainbow) slot.
struct ToolPresets: Codable, Equatable {
    var colors: [InkColor]
    /// The color in the extra slot, once the user has picked one.
    var extraColor: InkColor?
    var selectedColorSlot: Int
    /// In page points.
    var sizes: [Double]
    var selectedSizeSlot: Int

    var extraColorSlot: Int { colors.count }

    var currentColor: InkColor {
        if selectedColorSlot == extraColorSlot, let extraColor {
            return extraColor
        }
        return colors[min(selectedColorSlot, colors.count - 1)]
    }

    var currentSize: Double { sizes[min(selectedSizeSlot, sizes.count - 1)] }

    var isValid: Bool {
        !colors.isEmpty && (0...extraColorSlot).contains(selectedColorSlot)
            && sizes.count == ToolSettings.sizeCount && sizes.indices.contains(selectedSizeSlot)
    }

    static let pen = ToolPresets(colors: [.black, .blue, .red], selectedColorSlot: 0, sizes: [1.4, 2.2, 3.4], selectedSizeSlot: 1)
    static let highlighter = ToolPresets(colors: [InkColor(hex: 0xFFE14D)], selectedColorSlot: 0, sizes: [10, 16, 24], selectedSizeSlot: 1)
}

/// Which tool is active and each tool's settings, saved on this device.
@Observable
final class ToolSettings {
    static let sizeCount = 3
    static let penSizeRange: ClosedRange<Double> = 0.5...12
    static let highlighterSizeRange: ClosedRange<Double> = 4...40
    /// Eraser radius in page points.
    static let eraserSizeRange: ClosedRange<Double> = 2...30

    var tool: Tool {
        didSet {
            if tool != oldValue { previousTool = oldValue }
            save()
        }
    }
    /// The tool used before the current one (for Apple Pencil double-tap).
    private(set) var previousTool: Tool
    var pen: ToolPresets { didSet { save() } }
    var highlighter: ToolPresets { didSet { save() } }
    var eraserMode: EraserMode { didSet { save() } }
    /// The eraser only removes highlights, leaving pen ink alone.
    var erasesHighlighterOnly: Bool { didSet { save() } }
    var eraserSizes: [Double] { didSet { save() } }
    var selectedEraserSize: Int { didSet { save() } }
    var selectMode: SelectMode { didSet { save() } }
    var pressureSensitivity: Double { didSet { save() } }
    var drawsWithFinger: Bool { didSet { save() } }

    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "toolSettings"
    /// Where M1 kept the pen settings.
    private static let oldPenKey = "penSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var stored = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
            .flatMap { $0.validated() } ?? .defaults
        if defaults.data(forKey: Self.storageKey) == nil, let old = defaults.data(forKey: Self.oldPenKey),
           let pen = try? JSONDecoder().decode(OldPenSettings.self, from: old) {
            stored.pen = ToolPresets(colors: pen.colorPresets, extraColor: pen.extraColor, selectedColorSlot: pen.selectedColorSlot,
                                     sizes: pen.sizePresets, selectedSizeSlot: pen.selectedSizeSlot)
            stored.pressureSensitivity = pen.pressureSensitivity
            stored.drawsWithFinger = pen.drawsWithFinger
            if !stored.pen.isValid { stored.pen = .pen }
        }
        tool = stored.tool
        previousTool = stored.previousTool
        pen = stored.pen
        highlighter = stored.highlighter
        eraserMode = stored.eraserMode
        erasesHighlighterOnly = stored.erasesHighlighterOnly
        eraserSizes = stored.eraserSizes
        selectedEraserSize = stored.selectedEraserSize
        selectMode = stored.selectMode
        pressureSensitivity = stored.pressureSensitivity
        drawsWithFinger = stored.drawsWithFinger
    }

    var pressureCurve: PressureCurve { PressureCurve(sensitivity: pressureSensitivity) }
    var eraserRadius: Double { eraserSizes[min(selectedEraserSize, eraserSizes.count - 1)] }

    private struct Stored: Codable {
        var tool: Tool
        var previousTool: Tool
        var pen: ToolPresets
        var highlighter: ToolPresets
        var eraserMode: EraserMode
        var erasesHighlighterOnly: Bool
        var eraserSizes: [Double]
        var selectedEraserSize: Int
        var selectMode: SelectMode
        var pressureSensitivity: Double
        var drawsWithFinger: Bool

        static let defaults = Stored(
            tool: .pen,
            previousTool: .pen,
            pen: .pen,
            highlighter: .highlighter,
            eraserMode: .wholeStroke,
            erasesHighlighterOnly: false,
            eraserSizes: [4, 9, 18],
            selectedEraserSize: 1,
            selectMode: .freeform,
            pressureSensitivity: PressureCurve.defaultSensitivity,
            drawsWithFinger: false
        )

        func validated() -> Stored? {
            guard pen.isValid, highlighter.isValid,
                  eraserSizes.count == ToolSettings.sizeCount, eraserSizes.indices.contains(selectedEraserSize) else { return nil }
            return self
        }
    }

    private struct OldPenSettings: Codable {
        var colorPresets: [InkColor]
        var extraColor: InkColor?
        var selectedColorSlot: Int
        var sizePresets: [Double]
        var selectedSizeSlot: Int
        var pressureSensitivity: Double
        var drawsWithFinger: Bool
    }

    private func save() {
        let stored = Stored(
            tool: tool,
            previousTool: previousTool,
            pen: pen,
            highlighter: highlighter,
            eraserMode: eraserMode,
            erasesHighlighterOnly: erasesHighlighterOnly,
            eraserSizes: eraserSizes,
            selectedEraserSize: selectedEraserSize,
            selectMode: selectMode,
            pressureSensitivity: pressureSensitivity,
            drawsWithFinger: drawsWithFinger
        )
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.storageKey)
    }
}
