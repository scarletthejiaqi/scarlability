#if os(iOS)
import ScarlabilityKit
import SwiftUI

/// The page panel on the right: a thumbnail of every page. Tap one to go to it, long-press to
/// delete it, + adds a blank page at the end.
struct PagePanel: View {
    static let width: CGFloat = 176

    let document: NoteDocument
    let session: EditorSession
    /// Space at the top for the toolbar buttons above the panel.
    var topInset: CGFloat = 0

    @State private var thumbnails = PageThumbnails()
    @State private var deleting: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                        thumbnail(page, number: index + 1)
                            .id(page.id)
                    }
                    Button {
                        let id = document.addPage()
                        session.send(.goToPage(id))
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .medium))
                            .frame(width: Self.thumbnailWidth, height: 64)
                            .background(Color(.systemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color(.systemGray3), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            }
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Page")
                }
                .padding(.top, topInset + 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                if let id = session.visiblePageID { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(.separator)).frame(width: 0.5)
        }
        .confirmationDialog("Delete this page?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { id in
            Button("Delete Page", role: .destructive) { document.deletePage(id) }
        } message: { _ in
            Text("Everything on it is deleted. This can't be undone.")
        }
    }

    static let thumbnailWidth: CGFloat = 120

    private func thumbnail(_ page: NoteDocument.Page, number: Int) -> some View {
        let isCurrent = session.visiblePageID == page.id
        let size = page.record.size
        return Button {
            session.send(.goToPage(page.id))
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let image = thumbnails.images[page.id] {
                        Image(decorative: image, scale: thumbnails.scale)
                            .resizable()
                    } else {
                        Rectangle().fill(.white)
                    }
                }
                .frame(width: Self.thumbnailWidth, height: Self.thumbnailWidth * size.height / max(size.width, 1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(-4)
                        .opacity(isCurrent ? 1 : 0)
                }
                Text("\(number)")
                    .font(.caption.weight(isCurrent ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Page", systemImage: "trash", role: .destructive) { deleting = page.id }
        }
        .accessibilityLabel("Page \(number)")
        .task(id: page.revision) {
            // While you write, redraw a little after the last change rather than after every stroke.
            if thumbnails.images[page.id] != nil {
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard !Task.isCancelled else { return }
            await thumbnails.render(page, in: document)
        }
    }
}

/// Pictures of the open note's pages, made in the background.
@Observable
final class PageThumbnails {
    private(set) var images: [UUID: CGImage] = [:]
    let scale: CGFloat = 2

    func render(_ page: NoteDocument.Page, in document: NoteDocument) async {
        var pictures: [String: CGImage] = [:]
        for item in page.visibleItems {
            if let name = item.image?.fileName, pictures[name] == nil {
                pictures[name] = await document.loadImage(named: name, maxPixelSize: 600)
            }
        }
        var background: CGImage?
        if case .image(let fileName)? = page.record.background {
            background = await document.loadImage(named: fileName, maxPixelSize: 600)
        }
        let content = PageContent(
            paper: page.record.paper,
            size: page.record.size,
            strokes: page.visibleStrokes.map(RenderedStroke.init),
            items: page.visibleItems.map { RenderedItem($0, image: $0.image.flatMap { pictures[$0.fileName] }) },
            backgroundImage: background
        )
        let width = PagePanel.thumbnailWidth, scale = scale
        let image = await Task.detached(priority: .utility) {
            Thumbnail.render(content, width: width, scale: scale)
        }.value
        if let image {
            images[page.id] = image
        }
    }
}

/// The page number at the bottom right ("3 / 7"), with buttons for the page above and below.
struct PageIndicator: View {
    let document: NoteDocument
    let session: EditorSession

    var body: some View {
        let count = document.pages.count
        let current = (session.visiblePageID.flatMap { document.pageIndex($0) } ?? 0) + 1
        VStack(spacing: 2) {
            Button {
                session.send(.scrollPage(-1))
            } label: {
                Image(systemName: "chevron.up").frame(width: 44, height: 34)
            }
            .disabled(current <= 1)
            .accessibilityLabel("Previous page")
            VStack(spacing: 1) {
                Text("\(current)")
                Rectangle().fill(.secondary).frame(width: 10, height: 1)
                Text("\(count)")
            }
            .font(.system(size: 14).monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(current) of \(count)")
            Button {
                session.send(.scrollPage(1))
            } label: {
                Image(systemName: "chevron.down").frame(width: 44, height: 34)
            }
            .disabled(current >= count)
            .accessibilityLabel("Next page")
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.vertical, 6)
        .floatingCard(cornerRadius: 14)
    }
}
#endif
