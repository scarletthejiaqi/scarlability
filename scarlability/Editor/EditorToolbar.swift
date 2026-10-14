#if os(iOS)
import ScarlabilityKit
import SwiftUI
import UIKit

/// Notability-style floating toolbar: the back button on the left, the note's name and the tool
/// palette in the middle (tools on top, the current tool's colors and sizes below), and undo,
/// redo, the note menu and the page panel button on the right.
struct EditorToolbar: View {
    let document: NoteDocument
    @Bindable var settings: ToolSettings
    let session: EditorSession
    let model: AppModel
    @Binding var showsPages: Bool
    /// Where the palette ends, from the top of the screen.
    @Binding var bottom: CGFloat

    @State private var leftWidth: CGFloat = 0
    @State private var rightWidth: CGFloat = 0
    @State private var renamingFromTitle = false

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
        NoteActions(document: document, settings: settings, session: session, model: model, showsPages: $showsPages)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rightWidth = $0 }
    }

    /// The note's name (tap to rename it) above the tool palette.
    private var palette: some View {
        VStack(spacing: 6) {
            Button { renamingFromTitle = true } label: {
                Text(document.note.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Rename the note")
            // Right under the name, not in the middle of the screen.
            .popover(isPresented: $renamingFromTitle, arrowEdge: .top) {
                RenameField(title: "Rename Note", text: document.note.title) { title in
                    document.rename(to: title)
                    renamingFromTitle = false
                }
            }
            ToolPalette(settings: settings, session: session)
        }
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
    let session: EditorSession
    let model: AppModel
    @Binding var showsPages: Bool

    @State private var showsMenu = false
    @State private var menuPath: [NoteMenuPage] = []
    /// Where the ⋯ button is on screen, for pointing the Share menu at it.
    @State private var menuFrame: CGRect = .zero

    var body: some View {
        HStack(spacing: 4) {
            iconButton("arrow.uturn.backward", label: "Undo", action: document.undo)
                .disabled(!document.canUndo)
            iconButton("arrow.uturn.forward", label: "Redo", action: document.redo)
                .disabled(!document.canRedo)
            iconButton("ellipsis.circle", label: "More", isOn: showsMenu) {
                menuPath = []
                showsMenu = true
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { menuFrame = $0 }
            // Everything opens right under the ⋯ button, inside this one panel.
            .popover(isPresented: $showsMenu, arrowEdge: .top) {
                NoteMenuPanel(document: document, settings: settings, session: session, model: model, path: $menuPath,
                              shareSource: menuFrame) {
                    showsMenu = false
                }
            }
            iconButton("rectangle.portrait.on.rectangle.portrait", label: "Pages", isOn: showsPages) {
                // The same timing as the page zooming to fit beside the panel.
                withAnimation(.easeInOut(duration: 0.28)) { showsPages.toggle() }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .frame(height: 52)
        .floatingCard(cornerRadius: 14)
        #if DEBUG
        // `-DebugShowMenu` opens the ⋯ panel; `-DebugShowSettings` / `-DebugShowPaper` /
        // `-DebugShowExport` open it at that page.
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            let pages: [(String, NoteMenuPage)] = [("-DebugShowSettings", .settings), ("-DebugShowPaper", .paper), ("-DebugShowExport", .export)]
            if let page = pages.first(where: { arguments.contains($0.0) })?.1 {
                menuPath = [page]
                showsMenu = true
            } else if arguments.contains("-DebugShowMenu") {
                showsMenu = true
            }
        }
        #endif
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

/// The pages inside the ⋯ panel.
enum NoteMenuPage: Hashable {
    case rename
    case paper
    case export
    case settings
}

/// The ⋯ panel, right under its button: Rename, Paper, Export as PDF and Settings, each opening
/// inside the panel (nothing pops up in the middle of the screen).
private struct NoteMenuPanel: View {
    let document: NoteDocument
    @Bindable var settings: ToolSettings
    let session: EditorSession
    let model: AppModel
    @Binding var path: [NoteMenuPage]
    let shareSource: CGRect
    let close: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink(value: NoteMenuPage.rename) { Label("Rename Note", systemImage: "pencil") }
                NavigationLink(value: NoteMenuPage.paper) { Label("Paper", systemImage: "doc.richtext") }
                NavigationLink(value: NoteMenuPage.export) { Label("Export as PDF", systemImage: "square.and.arrow.up") }
                NavigationLink(value: NoteMenuPage.settings) { Label("Settings", systemImage: "gearshape") }
            }
            .navigationTitle(document.note.title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: NoteMenuPage.self) { page in
                switch page {
                case .rename:
                    RenameField(title: "Rename Note", text: document.note.title) { title in
                        document.rename(to: title)
                        close()
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                case .paper:
                    PaperSettingsView(document: document)
                        .navigationTitle("Paper")
                case .export:
                    if let folder = model.notesFolder {
                        ExportOptionsView(source: .document(document, currentPage: session.visiblePageID.flatMap { document.pageIndex($0) }),
                                          folder: folder, shareSource: shareSource, onExported: close)
                    }
                case .settings:
                    EditorSettingsView(settings: settings, folderName: model.folderName) {
                        close()
                        model.forgetFolder()
                    }
                    .navigationTitle("Settings")
                }
            }
        }
        // Each page's own height, so the short menu isn't a tall empty panel.
        .frame(width: 400, height: height)
        .presentationCompactAdaptation(.popover)
    }

    private var height: CGFloat {
        switch path.last {
        case nil: 290
        case .rename?: 220
        case .export?: 380
        case .paper?: 440
        case .settings?: 680
        }
    }
}

/// A name to change, right under what was tapped: the field is ready to type in.
struct RenameField: View {
    let title: String
    @State private var text: String
    let onRename: (String) -> Void
    @FocusState private var isFocused: Bool

    init(title: String, text: String, onRename: @escaping (String) -> Void) {
        self.title = title
        _text = State(initialValue: text)
        self.onRename = onRename
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(rename)
            HStack {
                Spacer()
                Button("Rename", action: rename)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { isFocused = true }
        .presentationCompactAdaptation(.popover)
    }

    private func rename() {
        guard !trimmed.isEmpty else { return }
        onRename(trimmed)
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
                // On the Mac the mouse always draws, so there's no finger-drawing switch.
                if !Platform.isMac {
                    fingerDrawingButton
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // Scrolls sideways when the options don't fit (text, in portrait).
            ViewThatFits(in: .horizontal) {
                ToolOptions(settings: settings, session: session)
                    .padding(.horizontal, 12)
                ScrollView(.horizontal, showsIndicators: false) {
                    ToolOptions(settings: settings, session: session)
                        .padding(.horizontal, 12)
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

    private var fingerDrawingButton: some View {
        Group {
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
            // The Mac has no camera picker or document scanner.
            if !Platform.isMac {
                Button("Take Photo", systemImage: "camera") { session.send(.insertImage(.camera)) }
                Button("Scan Document", systemImage: "doc.viewfinder") { session.send(.insertImage(.scanner)) }
            }
            Button("PDF or Image from Files", systemImage: "folder") { session.send(.insertImage(.files)) }
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
        HStack(spacing: 8) {
            switch settings.tool {
            case .pen:
                penStyleMenu
                separator
                presetOptions(\.pen, sizeRange: ToolSettings.penSizeRange)
            case .highlighter:
                presetOptions(\.highlighter, sizeRange: ToolSettings.highlighterSizeRange)
                separator
                Toggle(isOn: $settings.highlighterSnapsToText) {
                    Label("Snap to Text", systemImage: "text.alignleft")
                }
                .toggleStyle(.button)
                .font(.subheadline)
                .fixedSize()
                .accessibilityHint("On PDFs, highlights the text you go over, line by line")
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

    /// Pen or Fountain Pen (钢笔). Both use the same colors and sizes.
    private var penStyleMenu: some View {
        Menu {
            Picker("Pen", selection: $settings.penStyle) {
                ForEach(PenStyle.allCases, id: \.self) { style in
                    Label(style.title, systemImage: style.systemImage).tag(style)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: settings.penStyle.systemImage)
                Text(settings.penStyle == .fountain ? "Fountain" : "Pen")
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.subheadline.weight(.medium))
            .fixedSize()
        }
        .tint(.primary)
        .accessibilityLabel("Pen type: \(settings.penStyle.title)")
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
        HStack(spacing: 3) {
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
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Line spacing")
                            Spacer()
                            Text(String(format: "%g mm", paper.lineSpacingMillimeters))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Button("Default") { paper.lineSpacingMillimeters = PaperStyle.defaultLineSpacing }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(paper.lineSpacingMillimeters == PaperStyle.defaultLineSpacing)
                        }
                        // In quarter millimeters (rounded here rather than with `step`, which draws a tick per step).
                        Slider(value: Binding(get: { paper.lineSpacingMillimeters },
                                              set: { paper.lineSpacingMillimeters = ($0 * 4).rounded() / 4 }),
                               in: PaperStyle.lineSpacingRange) {
                            Text("Line spacing")
                        } minimumValueLabel: {
                            Image(systemName: "line.3.horizontal").font(.caption)
                        } maximumValueLabel: {
                            Image(systemName: "line.3.horizontal").font(.title3)
                        }
                    }
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

/// Settings: Pen Feel (笔感) with a strip to try the pen, finger drawing and the notes folder.
struct EditorSettingsView: View {
    @Bindable var settings: ToolSettings
    let folderName: String?
    let onChangeFolder: () -> Void

    @State private var clearCount = 0

    var body: some View {
        VStack(spacing: 0) {
            // Above the strip, not on it: the strip keeps every touch for writing.
            HStack {
                Text("Try your pen here (\(settings.penStyle.title))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { clearCount += 1 }
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            PenTestPad(settings: settings, clearCount: clearCount)
                .frame(height: 150)
            Divider()
            Form {
                Section {
                    FeelSlider(title: "Smoothing 平滑", value: $settings.smoothing, range: ToolSettings.smoothingRange,
                               less: "Sharper", more: "Smoother")
                    FeelSlider(title: "Pen pressure 压感", value: $settings.pressureSensitivity, range: 0...1,
                               less: "Even", more: "More")
                    FeelSlider(title: "Fountain pen pressure 钢笔压感", value: $settings.fountainSensitivity, range: 0...1,
                               less: "Even", more: "More")
                    FeelSlider(title: "Tip 跟手", value: $settings.tipLead, range: 0...1,
                               less: "Steadier", more: "Closer to tip")
                    Button("Reset Pen Feel") { settings.resetPenFeel() }
                } header: {
                    Text("Pen Feel")
                } footer: {
                    Text("Write in the strip above to try each change. Pick the pen type (Pen or Fountain) in the toolbar. "
                         + "Tell me the numbers you like best and I'll make them the defaults.")
                }
                if !Platform.isMac {
                    Section {
                        Toggle("Draw with finger", isOn: $settings.drawsWithFinger)
                    } footer: {
                        Text(settings.drawsWithFinger
                             ? "One finger writes. Use two fingers to scroll and zoom."
                             : "Only Apple Pencil writes. Fingers scroll and zoom.")
                    }
                }
                Section("Notes folder") {
                    Text(folderName ?? "Not chosen")
                    Button("Choose a Different Folder…", action: onChangeFolder)
                }
            }
        }
    }
}

/// A Pen Feel slider with its value shown, so you can tell me which numbers feel best.
private struct FeelSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let less: String
    let more: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(less).font(.caption).foregroundStyle(.secondary)
                Slider(value: $value, in: range)
                Text(more).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
