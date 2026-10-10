#if os(iOS)
import ScarlabilityKit
import SwiftUI
import UIKit

/// Notability-style floating toolbar: the back button on the left, the tool palette in the
/// middle (tools on top, the current tool's colors and sizes below), and undo, redo, the note
/// menu and the page panel button on the right.
struct EditorToolbar: View {
    let document: NoteDocument
    @Bindable var settings: ToolSettings
    let session: EditorSession
    @Binding var showsPages: Bool
    /// Where the palette ends, from the top of the screen.
    @Binding var bottom: CGFloat
    @Environment(AppModel.self) private var model

    @State private var leftWidth: CGFloat = 0
    @State private var rightWidth: CGFloat = 0

    var body: some View {
        let side = max(leftWidth, rightWidth)
        ViewThatFits(in: .horizontal) {
            // Centered on screen when there's room…
            HStack(alignment: .top, spacing: 0) {
                leading.frame(width: side, alignment: .leading)
                Spacer(minLength: 12)
                palette.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                trailing.frame(width: side, alignment: .trailing)
            }
            // …otherwise between the buttons, the options row scrolling if it has to.
            HStack(alignment: .top, spacing: 12) {
                leading
                Spacer(minLength: 0)
                palette
                Spacer(minLength: 0)
                trailing
            }
        }
        .padding(.horizontal, 12)
    }

    private var leading: some View {
        HStack(spacing: 10) {
            Button {
                model.closeDocument()
            } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .floatingCard(cornerRadius: 14)
            .accessibilityLabel("Library")
            if document.saveFailed {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(width: 48, height: 48)
                    .floatingCard(cornerRadius: 14)
                    .accessibilityLabel("Not saved")
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leftWidth = $0 }
    }

    private var trailing: some View {
        NoteActions(document: document, settings: settings, showsPages: $showsPages)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rightWidth = $0 }
    }

    private var palette: some View {
        ToolPalette(settings: settings, session: session)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom = $0 }
    }
}

extension View {
    /// A white card with a soft shadow, floating over the page.
    func floatingCard(cornerRadius: CGFloat = 16) -> some View {
        background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 10, y: 2)
    }
}

// MARK: - Right side

/// Undo, redo, the note's menu (rename, paper, settings) and the page panel button.
private struct NoteActions: View {
    let document: NoteDocument
    @Bindable var settings: ToolSettings
    @Binding var showsPages: Bool
    @Environment(AppModel.self) private var model

    @State private var showsSettings = false
    @State private var showsPaper = false
    @State private var renaming = false
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 4) {
            iconButton("arrow.uturn.backward", label: "Undo", action: document.undo)
                .disabled(!document.canUndo)
            iconButton("arrow.uturn.forward", label: "Redo", action: document.redo)
                .disabled(!document.canRedo)
            Menu {
                Button("Rename Note", systemImage: "pencil") {
                    renameText = document.note.title
                    renaming = true
                }
                Button("Paper", systemImage: "doc.richtext") { showsPaper = true }
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 21))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
            .popover(isPresented: $showsPaper) {
                PaperSettingsView(document: document)
            }
            .popover(isPresented: $showsSettings) {
                EditorSettingsView(settings: settings, folderName: model.folderName) {
                    showsSettings = false
                    model.forgetFolder()
                }
            }
            iconButton("rectangle.portrait.on.rectangle.portrait", label: "Pages", isOn: showsPages) {
                withAnimation(.snappy(duration: 0.25)) { showsPages.toggle() }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .frame(height: 52)
        .floatingCard(cornerRadius: 14)
        .alert("Rename Note", isPresented: $renaming) {
            TextField("Title", text: $renameText)
            Button("Rename") { document.rename(to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func iconButton(_ systemImage: String, label: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .regular))
                .frame(width: 44, height: 40)
                .background(isOn ? Color(.systemGray5) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Tool palette

/// The tools on top, and the current tool's options below.
private struct ToolPalette: View {
    @Bindable var settings: ToolSettings
    let session: EditorSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ToolButton(tool: .pen, systemImage: "pencil.tip", title: "Pen", color: settings.pen.currentColor, settings: settings)
                ToolButton(tool: .highlighter, systemImage: "highlighter", title: "Highlighter",
                           color: settings.highlighter.currentColor, settings: settings)
                ToolButton(tool: .eraser, systemImage: "eraser", title: "Eraser", settings: settings)
                ToolButton(tool: .text, systemImage: "textformat", title: "Text", settings: settings)
                ToolButton(tool: .select, systemImage: "lasso", title: "Lasso", settings: settings)
                InsertMenu(session: session)
                Rectangle().fill(Color(.separator)).frame(width: 1, height: 26).padding(.horizontal, 6)
                Button {
                    settings.drawsWithFinger.toggle()
                } label: {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 21))
                        .frame(width: 44, height: 42)
                        .background(settings.drawsWithFinger ? Color.accentColor.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(settings.drawsWithFinger ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Draw with finger")
                .accessibilityAddTraits(settings.drawsWithFinger ? .isSelected : [])
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // Scrolls sideways when the options don't fit (text, in portrait).
            ViewThatFits(in: .horizontal) {
                ToolOptions(settings: settings, session: session)
                    .padding(.horizontal, 14)
                ScrollView(.horizontal, showsIndicators: false) {
                    ToolOptions(settings: settings, session: session)
                        .padding(.horizontal, 14)
                }
            }
            .frame(height: 50)
            .overlay(alignment: .top) {
                Rectangle().fill(Color(.separator)).frame(height: 0.5)
            }
        }
        .floatingCard(cornerRadius: 16)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ToolButton: View {
    let tool: Tool
    let systemImage: String
    let title: String
    /// Shown as a bar under the icon (the pen's and highlighter's current color).
    var color: InkColor?
    @Bindable var settings: ToolSettings

    var body: some View {
        let isSelected = settings.tool == tool
        Button {
            settings.tool = tool
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: isSelected ? .semibold : .regular))
                Capsule()
                    .fill(color.map { Color(cgColor: $0.cgColor) } ?? .clear)
                    .frame(width: 18, height: 3)
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(width: 44, height: 42)
            .background(isSelected ? Color(.systemGray5) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The + button: photos, camera, scanner, files, paste.
private struct InsertMenu: View {
    let session: EditorSession

    var body: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { session.send(.insertImage(.photos)) }
            Button("Take Photo", systemImage: "camera") { session.send(.insertImage(.camera)) }
            Button("Scan Document", systemImage: "doc.viewfinder") { session.send(.insertImage(.scanner)) }
            Button("Files", systemImage: "folder") { session.send(.insertImage(.files)) }
            Button("Paste", systemImage: "doc.on.clipboard") { session.send(.insertImage(.paste)) }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 21))
                .frame(width: 44, height: 42)
        }
        .tint(.primary)
        .accessibilityLabel("Insert")
    }
}

// MARK: - Tool options

/// The second row: colors and sizes for the pen and highlighter, eraser and lasso modes, and
/// text styles.
private struct ToolOptions: View {
    @Bindable var settings: ToolSettings
    let session: EditorSession

    @State private var swatchFrames: [Int: CGRect] = [:]
    @State private var editingSizeSlot: Int?

    var body: some View {
        HStack(spacing: 10) {
            switch settings.tool {
            case .pen:
                presetOptions(\.pen, sizeRange: ToolSettings.penSizeRange)
            case .highlighter:
                presetOptions(\.highlighter, sizeRange: ToolSettings.highlighterSizeRange)
            case .text:
                textOptions
            case .eraser:
                eraserOptions
            case .select:
                Picker("Lasso", selection: $settings.selectMode) {
                    Label("Freeform", systemImage: "lasso").tag(SelectMode.freeform)
                    Label("Box", systemImage: "rectangle.dashed").tag(SelectMode.box)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Text(settings.selectMode == .freeform ? "Draw around ink to select it" : "Drag a box around ink to select it")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .frame(height: 50)
    }

    @ViewBuilder
    private var eraserOptions: some View {
        Picker("Eraser", selection: $settings.eraserMode) {
            Text("Whole Stroke").tag(EraserMode.wholeStroke)
            Text("Partial").tag(EraserMode.partial)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        separator
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
        separator
        Toggle("Highlighter only", isOn: $settings.erasesHighlighterOnly)
            .toggleStyle(.button)
            .font(.subheadline)
            .fixedSize()
    }

    /// Font, size, colors, bold/italic/underline and lists. Changes apply to what's selected
    /// while typing, and become the style for new text boxes.
    @ViewBuilder
    private var textOptions: some View {
        let style = session.isEditingText ? session.currentStyle : settings.textStyle
        Menu {
            ForEach(TextFont.allCases, id: \.self) { font in
                Button {
                    settings.textFont = font
                    session.send(.font(font))
                } label: {
                    Label(font.displayName, systemImage: style.font == font ? "checkmark" : "")
                }
            }
        } label: {
            Text(style.font.displayName).font(.subheadline.weight(.medium)).frame(minWidth: 80)
        }
        .fixedSize()
        Menu {
            ForEach(ToolSettings.textSizes, id: \.self) { size in
                Button {
                    settings.textSize = size
                    session.send(.size(size))
                } label: {
                    Label("\(Int(size)) pt", systemImage: style.size == size ? "checkmark" : "")
                }
            }
        } label: {
            Text("\(Int(style.size)) pt").font(.subheadline.monospacedDigit()).frame(minWidth: 44)
        }
        .fixedSize()
        separator
        presetOptions(\.text, sizeRange: nil) { color in session.send(.color(color)) }
        separator
        Group {
            StyleButton(systemImage: "bold", isOn: style.bold) { session.send(.bold) }
            StyleButton(systemImage: "italic", isOn: style.italic) { session.send(.italic) }
            StyleButton(systemImage: "underline", isOn: style.underline) { session.send(.underline) }
            StyleButton(systemImage: "list.bullet", isOn: false) { session.send(.bullets) }
            StyleButton(systemImage: "list.number", isOn: false) { session.send(.numbers) }
        }
        .disabled(!session.isEditingText)
    }

    private var separator: some View {
        Rectangle().fill(Color(.separator)).frame(width: 1, height: 26)
    }

    /// Color presets and the extra color slot, then (with `sizeRange`) size presets, for the
    /// pen, highlighter or text. `onColor` hears about colors picked.
    @ViewBuilder
    private func presetOptions(_ tool: ReferenceWritableKeyPath<ToolSettings, ToolPresets>, sizeRange: ClosedRange<Double>?,
                               onColor: ((InkColor) -> Void)? = nil) -> some View {
        let presets = settings[keyPath: tool]
        HStack(spacing: 6) {
            ForEach(presets.colors.indices, id: \.self) { slot in
                ColorSwatch(color: presets.colors[slot], isSelected: presets.selectedColorSlot == slot)
                    .onTapGesture { tapColor(slot, of: tool, onColor: onColor) }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { swatchFrames[slot] = $0 }
            }
            ExtraColorSwatch(color: presets.extraColor, isSelected: presets.selectedColorSlot == presets.extraColorSlot)
                .onTapGesture { tapColor(presets.extraColorSlot, of: tool, onColor: onColor) }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { swatchFrames[presets.extraColorSlot] = $0 }
        }
        if let sizeRange {
            separator
            sizeOptions(tool, sizeRange: sizeRange)
        }
    }

    @ViewBuilder
    private func sizeOptions(_ tool: ReferenceWritableKeyPath<ToolSettings, ToolPresets>, sizeRange: ClosedRange<Double>) -> some View {
        let presets = settings[keyPath: tool]
        HStack(spacing: 4) {
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
    }

    private func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// Tapping a color selects it; tapping the selected color again opens the color picker for it.
    private func tapColor(_ slot: Int, of tool: ReferenceWritableKeyPath<ToolSettings, ToolPresets>, onColor: ((InkColor) -> Void)?) {
        let presets = settings[keyPath: tool]
        let isExtra = slot == presets.extraColorSlot
        let alreadySelected = presets.selectedColorSlot == slot
        guard alreadySelected || (isExtra && presets.extraColor == nil) else {
            settings[keyPath: tool].selectedColorSlot = slot
            onColor?(settings[keyPath: tool].currentColor)
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
            onColor?(color)
        }
    }

    private func sizePopoverBinding(_ slot: Int) -> Binding<Bool> {
        Binding(
            get: { editingSizeSlot == slot },
            set: { if !$0 { editingSizeSlot = nil } }
        )
    }
}

private struct StyleButton: View {
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 32, height: 32)
                .background(isOn ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct ColorSwatch: View {
    let color: InkColor
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(Color(cgColor: color.cgColor))
            .frame(width: 26, height: 26)
            // Light colors (white) need an edge to show on the white toolbar.
            .overlay { Circle().strokeBorder(Color(.systemGray3), lineWidth: 1).opacity(color.isLight ? 1 : 0) }
            .padding(3)
            .overlay {
                Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(isSelected ? 1 : 0)
            }
            .contentShape(Circle())
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private extension InkColor {
    /// Close to white, so it needs an outline to show on the white toolbar.
    var isLight: Bool { Int(red) + Int(green) + Int(blue) > 690 }
}

/// The color slot after the presets: a gray "+" until a color is picked, then that color.
private struct ExtraColorSwatch: View {
    let color: InkColor?
    let isSelected: Bool

    var body: some View {
        ZStack {
            if let color {
                Circle().fill(Color(cgColor: color.cgColor))
            } else {
                Circle().fill(Color(.systemGray6))
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
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
        let diameter = 4 + CGFloat(fraction) * 16
        Group {
            if outlined {
                Circle().strokeBorder(.primary, lineWidth: 1.5)
            } else {
                Circle().fill(.primary)
            }
        }
        .frame(width: diameter, height: diameter)
        .frame(width: 32, height: 32)
        .overlay {
            Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(isSelected ? 1 : 0)
        }
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

struct EditorSettingsView: View {
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
