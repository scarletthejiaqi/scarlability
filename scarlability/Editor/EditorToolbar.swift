#if os(iOS)
import ScarlabilityKit
import SwiftUI
import UIKit

/// Notability-style top toolbar: title row, tools row, then the current tool's colors and sizes.
struct EditorToolbar: View {
    let document: NoteDocument
    @Bindable var settings: PenSettings
    @Environment(AppModel.self) private var model

    @State private var swatchFrames: [Int: CGRect] = [:]
    @State private var editingSizeSlot: Int?
    @State private var showsSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            HStack(spacing: 8) {
                ToolButton(title: "Pen", systemImage: "pencil.tip", isSelected: true)
            }
            presetsRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var titleRow: some View {
        ZStack {
            Text(document.note.title)
                .font(.headline)
            HStack {
                Spacer()
                if document.saveFailed {
                    Label("Not saved", systemImage: "exclamationmark.icloud")
                        .font(.subheadline)
                        .foregroundStyle(.red)
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

    private var presetsRow: some View {
        HStack(spacing: 14) {
            ForEach(0..<PenSettings.presetCount, id: \.self) { slot in
                ColorSwatch(color: settings.colorPresets[slot], isSelected: settings.selectedColorSlot == slot)
                    .onTapGesture { tapColor(slot) }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { swatchFrames[slot] = $0 }
            }
            ExtraColorSwatch(color: settings.extraColor, isSelected: settings.selectedColorSlot == PenSettings.extraColorSlot)
                .onTapGesture { tapColor(PenSettings.extraColorSlot) }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { swatchFrames[PenSettings.extraColorSlot] = $0 }

            Divider().frame(height: 26)

            ForEach(0..<PenSettings.presetCount, id: \.self) { slot in
                SizeDot(width: settings.sizePresets[slot], isSelected: settings.selectedSizeSlot == slot)
                    .onTapGesture { tapSize(slot) }
                    .popover(isPresented: sizePopoverBinding(slot)) {
                        SizeSliderView(width: $settings.sizePresets[slot], color: settings.currentColor)
                    }
            }

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
    }

    /// Tapping a color selects it; tapping the selected color again opens the color picker for it.
    private func tapColor(_ slot: Int) {
        let isExtra = slot == PenSettings.extraColorSlot
        let alreadySelected = settings.selectedColorSlot == slot
        guard alreadySelected || (isExtra && settings.extraColor == nil) else {
            settings.selectedColorSlot = slot
            return
        }
        let current = isExtra ? (settings.extraColor ?? settings.currentColor) : settings.colorPresets[slot]
        ColorPickerPresenter.shared.present(color: current, from: swatchFrames[slot] ?? .zero) { color in
            if isExtra {
                settings.extraColor = color
            } else {
                settings.colorPresets[slot] = color
            }
            settings.selectedColorSlot = slot
        }
    }

    /// Tapping a size selects it; tapping the selected size again shows its thickness slider.
    private func tapSize(_ slot: Int) {
        if settings.selectedSizeSlot == slot {
            editingSizeSlot = slot
        } else {
            settings.selectedSizeSlot = slot
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
    let isSelected: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
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

/// The fourth color slot: shows a rainbow "+" until a color is picked, then that color.
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
    let width: Double
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(.primary)
            .frame(width: dotDiameter, height: dotDiameter)
            .frame(width: 32, height: 32)
            .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: Circle())
            .contentShape(Circle())
            .accessibilityLabel("Pen size \(String(format: "%.1f", width))")
    }

    private var dotDiameter: CGFloat {
        let range = PenSettings.sizeRange
        let fraction = (width - range.lowerBound) / (range.upperBound - range.lowerBound)
        return 4 + CGFloat(fraction) * 18
    }
}

private struct SizeSliderView: View {
    @Binding var width: Double
    let color: InkColor

    var body: some View {
        VStack(spacing: 16) {
            // Roughly how the line looks on the page at normal zoom.
            Capsule()
                .fill(Color(cgColor: color.cgColor))
                .frame(width: 200, height: max(1, width * 1.35))
                .frame(height: 24)
            HStack {
                Image(systemName: "circle.fill").font(.system(size: 6))
                Slider(value: $width, in: PenSettings.sizeRange)
                Image(systemName: "circle.fill").font(.system(size: 16))
            }
            Text(String(format: "%.1f", width))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }
}

private struct EditorSettingsView: View {
    @Bindable var settings: PenSettings
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
