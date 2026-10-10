#if os(iOS)
import ScarlabilityKit
import SwiftUI
import UIKit

/// "Export as PDF": which pages (for one open note), with or without the paper, and for several
/// notes, one combined PDF or one each. Then the Share menu (AirDrop, Save to Files, Mail…).
/// Shown inside a popover under what was tapped (the ⋯ panel, a note, the Export button).
struct ExportOptionsView: View {
    enum Source {
        /// The open note; "This page" means the page in the middle of the screen.
        case document(NoteDocument, currentPage: Int?)
        case notes([NotebookFolder.StoredNote])
    }

    enum PageChoice: Hashable {
        case all
        case current
        case custom
    }

    let source: Source
    let folder: NotebookFolder
    /// Where on screen the Share menu should point (the button that opened this).
    var shareSource: CGRect = .zero
    /// Called once the PDF is made, to close the popover before the Share menu opens.
    let onExported: () -> Void

    @State private var pageChoice = PageChoice.all
    @State private var customPages = ""
    @State private var includePaper = true
    @State private var combined = true
    @State private var isExporting = false
    @State private var failure: String?

    var body: some View {
        Form {
            if case .document(let document, let current) = source {
                Section("Pages") {
                    Picker("Pages", selection: $pageChoice) {
                        Text("All").tag(PageChoice.all)
                        if current != nil { Text("This Page").tag(PageChoice.current) }
                        Text("Custom").tag(PageChoice.custom)
                    }
                    .pickerStyle(.segmented)
                    if pageChoice == .custom {
                        TextField("e.g. 1-3, 5", text: $customPages)
                            .keyboardType(.numbersAndPunctuation)
                        if !customPages.isEmpty, PageRange.parse(customPages, pageCount: document.pages.count) == nil {
                            Text("Use page numbers from 1 to \(document.pages.count), like 1-3, 5.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            if case .notes(let notes) = source, notes.count > 1 {
                Section {
                    Picker("Files", selection: $combined) {
                        Text("One PDF").tag(true)
                        Text("A PDF per Note").tag(false)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(combined ? "The notes go one after another, in the order shown in the library." : "Each note becomes its own PDF.")
                }
            }
            Section {
                Toggle("Include Paper", isOn: $includePaper)
            } footer: {
                Text(includePaper ? "Lines and paper color are included." : "Pages are plain white, without lines.")
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
            Section {
                Button(action: export) {
                    HStack {
                        Spacer()
                        if isExporting {
                            ProgressView()
                        } else {
                            Label("Export", systemImage: "square.and.arrow.up").bold()
                        }
                        Spacer()
                    }
                }
                .disabled(!canExport || isExporting)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var title: String {
        switch source {
        case .document: "Export as PDF"
        case .notes(let notes): notes.count == 1 ? "Export as PDF" : "Export \(notes.count) Notes"
        }
    }

    private var canExport: Bool {
        guard case .document(let document, _) = source, pageChoice == .custom else { return true }
        return PageRange.parse(customPages, pageCount: document.pages.count) != nil
    }

    private func export() {
        isExporting = true
        failure = nil
        Task {
            do {
                let urls: [URL]
                switch source {
                case .document(let document, let current):
                    var options = NoteExport.Options(includePaper: includePaper)
                    switch pageChoice {
                    case .all: options.pages = nil
                    case .current: options.pages = current.map { [$0] }
                    case .custom: options.pages = PageRange.parse(customPages, pageCount: document.pages.count)
                    }
                    let note = NotebookFolder.StoredNote(url: await document.currentURL(), record: document.note)
                    urls = [try await NoteExport.pdf(of: [note], named: document.note.title, options: options, folder: folder)]
                case .notes(let notes):
                    let options = NoteExport.Options(includePaper: includePaper)
                    if combined || notes.count == 1 {
                        let name = notes.count == 1 ? notes[0].record.title : "\(notes.count) Notes"
                        urls = [try await NoteExport.pdf(of: notes, named: name, options: options, folder: folder)]
                    } else {
                        urls = try await NoteExport.pdfs(of: notes, options: options, folder: folder)
                    }
                }
                isExporting = false
                onExported()
                // After the popover is gone, so the Share menu has somewhere to appear.
                try? await Task.sleep(for: .milliseconds(450))
                SharePresenter.share(urls, from: shareSource)
            } catch {
                isExporting = false
                failure = "Couldn't make the PDF: \(error.localizedDescription)"
            }
        }
    }
}

/// Shows the system Share menu for files, pointing at `rect` (window coordinates).
enum SharePresenter {
    static func share(_ urls: [URL], from rect: CGRect = .zero) {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        guard let window, var presenter = window.rootViewController else { return }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        let activity = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = window
        if rect.isEmpty {
            activity.popoverPresentationController?.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
            activity.popoverPresentationController?.permittedArrowDirections = []
        } else {
            activity.popoverPresentationController?.sourceRect = rect
        }
        presenter.present(activity, animated: true)
    }
}
#endif
