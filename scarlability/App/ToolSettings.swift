import Foundation
import Observation
import ScarlabilityKit

enum Tool: String, Codable, CaseIterable {
    case pen
    case highlighter
    case eraser
    case select
    case text
}

/// The pen's tip.
enum PenStyle: String, Codable, CaseIterable {
    /// Even lines, a little thicker when you press harder.
    case standard
    /// 钢笔: much thinner when light and bolder when firm.
    case fountain

    var title: String {
        switch self {
        case .standard: "Pen"
        case .fountain: "Fountain Pen"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "pencil.tip"
        case .fountain: "pencil.and.scribble"
        }
    }
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

    /// Black, blue, red, white, pink, orange and gray, like Notability.
    static let inkColors: [InkColor] = [.black, .blue, .red, .white, InkColor(hex: 0xE23BC8), InkColor(hex: 0xEFA33B), InkColor(hex: 0x949494)]
    /// Fluorescent (荧光) yellow, green, blue, pink and orange.
    static let highlighterColors: [InkColor] = [
        InkColor(hex: 0xF6FF00), InkColor(hex: 0x6BFF5A), InkColor(hex: 0x45D5FF), InkColor(hex: 0xFF5CCF), InkColor(hex: 0xFFA526),
    ]
    /// The highlighter colors M4.5 started with.
    static let paleHighlighterColors: [InkColor] = [
        InkColor(hex: 0xFFE14D), InkColor(hex: 0x7DDB6B), InkColor(hex: 0x6EC6FF), InkColor(hex: 0xFF8FC7), InkColor(hex: 0xFFB054),
    ]

    static let pen = ToolPresets(colors: inkColors, selectedColorSlot: 0, sizes: [1.4, 2.2, 3.4], selectedSizeSlot: 1)
    static let highlighter = ToolPresets(colors: highlighterColors, selectedColorSlot: 0, sizes: [10, 16, 24], selectedSizeSlot: 1)
    /// Text colors; the sizes aren't used (text has its own size setting).
    static let text = ToolPresets(colors: inkColors, selectedColorSlot: 0, sizes: [14, 17, 22], selectedSizeSlot: 1)

    /// Swaps in the longer color row if these are still the colors an older version started with.
    func upgradingColors(from old: [InkColor], to new: [InkColor]) -> ToolPresets {
        guard colors == old else { return self }
        var presets = self
        presets.colors = new
        if selectedColorSlot == old.count {
            presets.selectedColorSlot = new.count
        }
        return presets
    }
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
    /// On PDF pages, the highlighter highlights the text it goes over, line by line.
    var highlighterSnapsToText: Bool { didSet { save() } }
    var eraserSizes: [Double] { didSet { save() } }
    var selectedEraserSize: Int { didSet { save() } }
    var selectMode: SelectMode { didSet { save() } }
    var text: ToolPresets { didSet { save() } }
    var textFont: TextFont { didSet { save() } }
    var textSize: Double { didSet { save() } }
    var pressureSensitivity: Double { didSet { save() } }
    var drawsWithFinger: Bool { didSet { save() } }
    var penStyle: PenStyle { didSet { save() } }
    // Pen Feel (笔感), in Settings.
    /// How much the line is smoothed (σ, in screen points).
    var smoothing: Double { didSet { save() } }
    /// How much pressure changes the fountain pen's width (0–1).
    var fountainSensitivity: Double { didSet { save() } }
    /// How far ahead of the real line the Pencil's predicted path is drawn (0–1): more follows
    /// the tip more closely, less is steadier.
    var tipLead: Double { didSet { save() } }

    static let defaultSmoothing = Double(StrokeSmoothing.screenRadius)
    static let smoothingRange: ClosedRange<Double> = 0...2
    static let defaultTipLead = 0.6

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
        // Before M4.5 the pen and text had 3 colors and the highlighter 1.
        stored.pen = stored.pen.upgradingColors(from: [.black, .blue, .red], to: ToolPresets.inkColors)
        stored.highlighter = stored.highlighter
            .upgradingColors(from: [InkColor(hex: 0xFFE14D)], to: ToolPresets.highlighterColors)
            .upgradingColors(from: ToolPresets.paleHighlighterColors, to: ToolPresets.highlighterColors)
        stored.text = stored.text?.upgradingColors(from: [.black, .blue, .red], to: ToolPresets.inkColors)
        tool = stored.tool
        previousTool = stored.previousTool
        pen = stored.pen
        highlighter = stored.highlighter
        eraserMode = stored.eraserMode
        erasesHighlighterOnly = stored.erasesHighlighterOnly
        highlighterSnapsToText = stored.highlighterSnapsToText ?? false
        eraserSizes = stored.eraserSizes
        selectedEraserSize = stored.selectedEraserSize
        selectMode = stored.selectMode
        text = stored.text ?? .text
        textFont = stored.textFont ?? .system
        textSize = stored.textSize ?? 17
        pressureSensitivity = stored.pressureSensitivity
        drawsWithFinger = stored.drawsWithFinger
        penStyle = stored.penStyle ?? .standard
        smoothing = stored.smoothing ?? Self.defaultSmoothing
        fountainSensitivity = stored.fountainSensitivity ?? PressureCurve.defaultFountainSensitivity
        tipLead = stored.tipLead ?? Self.defaultTipLead
    }

    var pressureCurve: PressureCurve {
        switch penStyle {
        case .standard: PressureCurve(sensitivity: pressureSensitivity)
        case .fountain: .fountain(sensitivity: fountainSensitivity)
        }
    }

    /// How quickly the pen's width follows pressure, in screen points (shorter is quicker). The
    /// fountain pen evens pressure out twice (`pressureStages`), each a little quicker than the
    /// pen's one, so its wide thick-and-thin range flows instead of swelling into lumps.
    var pressureSmoothing: CGFloat {
        penStyle == .fountain ? StrokeBuilder.screenPressureSmoothing * 0.8 : StrokeBuilder.screenPressureSmoothing
    }

    var pressureStages: Int { penStyle == .fountain ? 2 : 1 }

    /// Puts the Pen Feel settings back to how they started.
    func resetPenFeel() {
        smoothing = Self.defaultSmoothing
        pressureSensitivity = PressureCurve.defaultSensitivity
        fountainSensitivity = PressureCurve.defaultFountainSensitivity
        tipLead = Self.defaultTipLead
    }

    /// The style new text boxes start with.
    var textStyle: TextRun { TextRun(text: "", font: textFont, size: textSize, color: text.currentColor) }

    static let textSizes: [Double] = [10, 12, 14, 17, 20, 24, 28, 36, 48]
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
        // Added in M4; optional so settings saved before still load.
        var text: ToolPresets?
        var textFont: TextFont?
        var textSize: Double?
        var pressureSensitivity: Double
        var drawsWithFinger: Bool
        // Added with the fountain pen and Pen Feel; optional for the same reason.
        var penStyle: PenStyle?
        var smoothing: Double?
        var fountainSensitivity: Double?
        var tipLead: Double?
        var highlighterSnapsToText: Bool?

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
            text: .text,
            textFont: .system,
            textSize: 17,
            pressureSensitivity: PressureCurve.defaultSensitivity,
            drawsWithFinger: false,
            penStyle: .standard,
            smoothing: ToolSettings.defaultSmoothing,
            fountainSensitivity: PressureCurve.defaultFountainSensitivity,
            tipLead: ToolSettings.defaultTipLead,
            highlighterSnapsToText: false
        )

        func validated() -> Stored? {
            guard pen.isValid, highlighter.isValid, text?.isValid ?? true,
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
            text: text,
            textFont: textFont,
            textSize: textSize,
            pressureSensitivity: pressureSensitivity,
            drawsWithFinger: drawsWithFinger,
            penStyle: penStyle,
            smoothing: smoothing,
            fountainSensitivity: fountainSensitivity,
            tipLead: tipLead,
            highlighterSnapsToText: highlighterSnapsToText
        )
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.storageKey)
    }
}
