#if os(iOS)
import ScarlabilityKit
import SwiftUI
import UIKit

/// Notability-style top toolbar: title row, tools row, then the current tool's options.
struct EditorToolbar: View {
    let document: NoteDocument
    @Bindable var settings: ToolSettings
    @Environment(AppModel.self) private var model

    @State private var swatchFrames: [Int: CGRect] = [:]
    @State private var editingSizeSlot: Int?
    @State private var showsSettings = false
    @State private var showsPaper = false
    @State private var renaming = false
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            HStack(spacing: 8) {
                ToolButton(title: "Pen", systemImage: "pencil.tip", tool: .pen, settings: settings)
                ToolButton(title: "Highlighter", systemImage: "highlighter", tool: .highlighter, settings: settings)
                ToolButton(title: "Eraser", systemImage: "eraser", tool: .eraser, settings: settings)
                ToolButton(title: "Select", systemImage: "lasso", tool: .select, settings: settings)
            }
            HStack(spacing: 14) {
                toolOptions
                Spacer()
                Button(action: document.undo) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!document.canUndo)
                .accessibilityLabel("Undo")
                Button(action: document.redo) {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!document.canRedo)
                .accessibilityLabel("Redo")
            }
            .font(.title3)
            .frame(height: 34)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var titleRow: some View {
        ZStack {
            // Tap the title to rename the note.
            Button {
                renameText = document.note.title
                renaming = true
            } label: {
                Text(document.note.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: 420)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Rename the note")
            .alert("Rename Note", isPresented: $renaming) {
                TextField("Title", text: $renameText)
                Button("Rename") { document.rename(to: renameText) }
                Button("Cancel", role: .cancel) {}
            }
            HStack(spacing: 16) {
                Button {
                    model.closeDocument()
                } label: {
                    Label("Library", systemImage: "chevron.left")
                        .font(.body.weight(.medium))
                }
                Spacer()
                if document.saveFailed {
                    Label("Not saved", systemImage: "exclamationmark.icloud")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                Button {
                    showsPaper = true
                } label: {
                    Image(systemName: "doc.richtext")
                        .font(.title3)
                }
                .accessibilityLabel("Paper")
                .popover(isPresented: $showsPaper) {
                    PaperSettingsView(document: document)
                }
                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .accessibilityLabel("Settings")
                .popover(isPresented: $showsSettings) {
                    EditorSettingsView(settings: settings, folderName: model.folderName) {
                        showsSettings = false
                        model.forgetFolder()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var toolOptions: some View {
        switch settings.tool {
        case .pen:
            presetOptions(\.pen, sizeRange: ToolSettings.penSizeRange)
        case .highlighter:
            presetOptions(\.highlighter, sizeRange: ToolSettings.highlighterSizeRange)
        case .eraser:
            Picker("Eraser", selection: $settings.eraserMode) {
                Text("Whole Stroke").tag(EraserMode.wholeStroke)
                Text("Partial").tag(EraserMode.partial)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Divider().frame(height: 26)
            ForEach(0..<ToolSettings.sizeCount, id: \.self) { slot in
                SizeDot(fraction: fraction(settings.eraserSizes[slot], in: ToolSettings.eraserSizeRange),
                        isSelected: settings.selectedEraserSize == slot, outlined: true)
                    .onTapGesture {
                        if settings.selectedEraserSize == slot { editingSizeSlot = slot } else { settings.selectedEraserSize = slot }
                    }
                    .popover(isPresented: sizePopoverBinding(slot)) {
                        SizeSliderView(size: $settings.eraserSizes[slot], range: ToolSettings.eraserSizeRange, preview: .eraser)
                    }
            }
            Divider().frame(height: 26)
            Toggle("Highlighter only", isOn: $settings.erasesHighlighterOnly)
                .toggleStyle(.button)
                .font(.subheadline)
        case .select:
            Picker("Select", selection: $settings.selectMode) {
                Label("Freeform", systemImage: "lasso").tag(SelectMode.freeform)
                Label("Box", systemImage: "rectangle.dashed").tag(SelectMode.box)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Text(settings.selectMode == .freeform ? "Draw around ink to select it" : "Drag a box around ink to select it")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Color presets, the extra color slot and size presets for the pen or highlighter.
    @ViewBuilder
    private func presetOptions(_ tool: ReferenceWritableKeyPath<ToolSettings, ToolPresets>, sizeRange: ClosedRange<Double>) -> some View {
        let presets = settings[keyPath: tool]
        ForEach(presets.colors.indices, id: \.self) { slot in
            ColorSwatch(color: presets.colors[slot], isSelected: presets.selectedColorSlot == slot)
                .onTapGesture { tapColor(slot, of: tool) }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { swatchFrames[slot] = $0 }
        }
        ExtraColorSwatch(color: presets.extraColor, isSelected: presets.selectedColorSlot == presets.extraColorSlot)
            .onTapGesture { tapColor(presets.extraColorSlot, of: tool) }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { swatchFrames[presets.extraColorSlot] = $0 }

        Divider().frame(height: 26)

        ForEach(0..<ToolSettings.sizeCount, id: \.self) { slot in
            SizeDot(fraction: fraction(presets.sizes[slot], in: sizeRange), isSelected: presets.selectedSizeSlot == slot, outlined: false)
                .onTapGesture {
                    if settings[keyPath: tool].selectedSizeSlot == slot {
                        editingSizeSlot = slot
                    } else {
                        settings[keyPath: tool].selectedSizeSlot = slot
                    }
                }
                .popover(isPresented: sizePopoverBinding(slot)) {
                    SizeSliderView(size: $settings[dynamicMember: tool].sizes[slot], range: sizeRange,
                                   preview: tool == \.highlighter ? .highlighter(presets.currentColor) : .pen(presets.currentColor))
                }
        }
    }

    private func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// Tapping a color selects it; tapping the selected color again opens the color picker for it.
    private func tapColor(_ slot: Int, of tool: ReferenceWritableKeyPath<ToolSettings, ToolPresets>) {
        let presets = settings[keyPath: tool]
        let isExtra = slot == presets.extraColorSlot
        let alreadySelected = presets.selectedColorSlot == slot
        guard alreadySelected || (isExtra && presets.extraColor == nil) else {
            settings[keyPath: tool].selectedColorSlot = slot
            return
        }
        let current = isExtra ? (presets.extraColor ?? presets.currentColor) : presets.colors[slot]
        ColorPickerPresenter.shared.present(color: current, from: swatchFrames[slot] ?? .zero) { color in
            if isExtra {
                settings[keyPath: tool].extraColor = color
            } else {
                settings[keyPath: tool].colors[slot] = color
            }
            settings[keyPath: tool].selectedColorSlot = slot
        }
    }

    private func sizePopoverBinding(_ slot: Int) -> Binding<Bool> {
        Binding(
            get: { editingSizeSlot == slot },
            set: { if !$0 { editingSizeSlot = nil } }
        )
    }
}

private struct ToolButton: View {
    let title: String
    let systemImage: String
    let tool: Tool
    @Bindable var settings: ToolSettings

    var body: some View {
        let isSelected = settings.tool == tool
        Button {
            settings.tool = tool
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ColorSwatch: View {
    let color: InkColor
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(Color(cgColor: color.cgColor))
            .frame(width: 26, height: 26)
            .overlay {
                Circle().strokeBorder(.white, lineWidth: 2).opacity(isSelected ? 1 : 0)
            }
            .padding(3)
            .overlay {
                Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(isSelected ? 1 : 0)
            }
            .contentShape(Circle())
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The color slot after the presets: shows a rainbow "+" until a color is picked, then that color.
private struct ExtraColorSwatch: View {
    let color: InkColor?
    let isSelected: Bool

    private static let rainbow = AngularGradient(
        colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
        center: .center
    )

    var body: some View {
        ZStack {
            if let color {
                Circle().fill(Color(cgColor: color.cgColor)).padding(3)
            } else {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold))
            }
            Circle().strokeBorder(Self.rainbow, lineWidth: 3)
        }
        .frame(width: 26, height: 26)
        .padding(3)
        .overlay {
            Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(isSelected ? 1 : 0)
        }
        .contentShape(Circle())
        .accessibilityLabel(color == nil ? "Add color" : "Extra color")
    }
}

private struct SizeDot: View {
    /// Where the size falls in its range, 0–1.
    let fraction: Double
    let isSelected: Bool
    /// An outline (for the eraser) instead of a filled dot.
    let outlined: Bool

    var body: some View {
        let diameter = 4 + CGFloat(fraction) * 18
        Group {
            if outlined {
                Circle().strokeBorder(.primary, lineWidth: 1.5)
            } else {
                Circle().fill(.primary)
            }
        }
        .frame(width: diameter, height: diameter)
        .frame(width: 32, height: 32)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: Circle())
        .contentShape(Circle())
    }
}

private struct SizeSliderView: View {
    enum Preview {
        case pen(InkColor)
        case highlighter(InkColor)
        case eraser
    }

    @Binding var size: Double
    let range: ClosedRange<Double>
    let preview: Preview

    var body: some View {
        VStack(spacing: 16) {
            // Roughly how it looks on the page at normal zoom.
            Group {
                switch preview {
                case .pen(let color):
                    Capsule().fill(Color(cgColor: color.cgColor)).frame(width: 200, height: max(1, size * 1.35))
                case .highlighter(let color):
                    Rectangle().fill(Color(cgColor: color.cgColor).opacity(PageRenderer.highlighterOpacity))
                        .frame(width: 200, height: size * 1.35)
                case .eraser:
                    Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: size * 2.7, height: size * 2.7)
                }
            }
            .frame(height: 84)
            HStack {
                Image(systemName: "circle.fill").font(.system(size: 6))
                Slider(value: $size, in: range)
                Image(systemName: "circle.fill").font(.system(size: 16))
            }
            Text(String(format: "%.1f", size))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }
}

/// Paper template, line spacing and color, for the whole note or just the page on screen.
private struct PaperSettingsView: View {
    let document: NoteDocument
    @State private var paper: PaperStyle = .whiteLined
    @State private var appliesToWholeNote = true
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Paper") {
                Picker("Template", selection: $paper.template) {
                    Text("Blank").tag(PaperTemplate.blank)
                    Text("Lined").tag(PaperTemplate.lined)
                }
                .pickerStyle(.segmented)
                if paper.template == .lined {
                    Picker("Line spacing", selection: $paper.lineSpacing) {
                        Text("Narrow").tag(LineSpacing.narrow)
                        Text("Medium").tag(LineSpacing.medium)
                        Text("Wide").tag(LineSpacing.wide)
                    }
                    .pickerStyle(.segmented)
                }
                HStack(spacing: 14) {
                    ForEach(InkColor.paperColors, id: \.self) { color in
                        Circle()
                            .fill(Color(cgColor: color.cgColor))
                            .frame(width: 30, height: 30)
                            .overlay { Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 1) }
                            .padding(3)
                            .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(paper.color == color ? 1 : 0) }
                            .onTapGesture { paper.color = color }
                            .accessibilityLabel(colorName(color))
                    }
                }
            }
            Section {
                Picker("Apply to", selection: $appliesToWholeNote) {
                    Text("Whole Note").tag(true)
                    Text("This Page").tag(false)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(appliesToWholeNote ? "All pages change, and new pages use this paper." : "Only the page in the middle of the screen changes.")
            }
        }
        .frame(width: 380, height: 380)
        .presentationCompactAdaptation(.popover)
        .onAppear {
            let page = document.pages.first { $0.id == document.visiblePageID } ?? document.pages.first
            paper = page?.record.paper ?? document.note.defaultPaper
            loaded = true
        }
        .onChange(of: paper) { _, newPaper in
            guard loaded else { return }
            document.setPaper(newPaper, onlyPage: appliesToWholeNote ? nil : (document.visiblePageID ?? document.pages.first?.id))
        }
    }

    private func colorName(_ color: InkColor) -> String {
        switch color {
        case .paperCream: "Cream"
        case .paperGray: "Gray"
        case .paperDark: "Dark"
        default: "White"
        }
    }
}

private struct EditorSettingsView: View {
    @Bindable var settings: ToolSettings
    let folderName: String?
    let onChangeFolder: () -> Void

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Less")
                    Slider(value: $settings.pressureSensitivity, in: 0...1)
                    Text("More")
                }
            } header: {
                Text("Pressure sensitivity")
            } footer: {
                Text("How much harder pressing makes the pen line thicker.")
            }
            Section {
                Toggle("Draw with finger", isOn: $settings.drawsWithFinger)
            } footer: {
                Text(settings.drawsWithFinger
                     ? "One finger writes. Use two fingers to scroll and zoom."
                     : "Only Apple Pencil writes. Fingers scroll and zoom.")
            }
            Section("Notes folder") {
                Text(folderName ?? "Not chosen")
                Button("Choose a Different Folder…", action: onChangeFolder)
            }
        }
        .frame(width: 380, height: 420)
        .presentationCompactAdaptation(.popover)
    }
}
#endif
