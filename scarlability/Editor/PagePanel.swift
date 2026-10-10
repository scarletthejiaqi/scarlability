#if os(iOS)
import ScarlabilityKit
import SwiftUI

/// What the page panel and the page grid share: the search, the All Pages / Bookmarks choice,
/// and the pages picked with Select.
@Observable
final class PageBrowser {
    var query = ""
    var showsBookmarksOnly = false
    var isSelecting = false
    var selected: Set<UUID> = []
    /// The full-screen grid of pages (the ⤢ button).
    var showsGrid = false
    /// Pages whose text matches `query` (nil while not searching).
    var matches: Set<UUID>?

    func pages(of document: NoteDocument) -> [(number: Int, page: NoteDocument.Page)] {
        document.pages.enumerated()
            .filter { _, page in (!showsBookmarksOnly || page.record.isBookmarked) && (matches?.contains(page.id) ?? true) }
            .map { (number: $0.offset + 1, page: $0.element) }
    }

    func finishSelecting() {
        isSelecting = false
        selected = []
    }
}

/// What the page menus do: add, cut, copy, paste, duplicate, bookmark, clear, delete, export.
struct PageCommands {
    let document: NoteDocument
    let session: EditorSession

    static var canPaste: Bool { UIPasteboard.general.contains(pasteboardTypes: [CopiedPages.pasteboardType]) }

    func addPage(after id: UUID) {
        if let new = document.addPage(after: id) { session.send(.goToPage(new)) }
    }

    func copy(_ ids: Set<UUID>) async {
        guard let copied = await document.copyPages(ids), let data = try? JSONEncoder().encode(copied) else { return }
        UIPasteboard.general.setData(data, forPasteboardType: CopiedPages.pasteboardType)
    }

    func cut(_ ids: Set<UUID>) async {
        await copy(ids)
        document.deletePages(ids)
    }

    func paste(after id: UUID) {
        guard let data = UIPasteboard.general.data(forPasteboardType: CopiedPages.pasteboardType),
              let copied = try? JSONDecoder().decode(CopiedPages.self, from: data) else { return }
        if let first = document.pastePages(copied, after: id).first { session.send(.goToPage(first)) }
    }

    func duplicate(_ ids: Set<UUID>) async {
        if let first = await document.duplicatePages(ids).first { session.send(.goToPage(first)) }
    }

    /// The chosen pages as one PDF, then the Share menu (pointing at `source`).
    func export(_ ids: Set<UUID>, from source: CGRect) async {
        let indexes = document.pages.indices.filter { ids.contains(document.pages[$0].id) }
        let note = NotebookFolder.StoredNote(url: await document.currentURL(), record: document.note)
        guard let url = try? await NoteExport.pdf(of: [note], named: document.note.title,
                                                  options: NoteExport.Options(pages: indexes), folder: document.folder) else { return }
        SharePresenter.share([url], from: source)
    }
}

/// The page panel on the right, like Notability's: Search, All Pages or just Bookmarks, a
/// thumbnail of every page (tap to go to it; ⋯ for Add page, Cut, Copy, Paste, Duplicate,
/// Bookmark, Clear Page, Delete), and Select at the bottom to work on several pages at once.
/// ⤢ opens all pages as a big grid.
struct PagePanel: View {
    static let width: CGFloat = 200
    static let thumbnailWidth: CGFloat = 150

    let document: NoteDocument
    let session: EditorSession
    /// Kept by the note screen, so reopening the panel shows them right away.
    let thumbnails: PageThumbnails
    @Bindable var browser: PageBrowser
    /// Space at the top for the toolbar buttons above the panel.
    var topInset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageSearchField(text: $browser.query)
            PageFilterMenu(browser: browser, document: document)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(browser.pages(of: document), id: \.page.id) { entry in
                            PageCell(page: entry.page, number: entry.number, width: Self.thumbnailWidth, document: document,
                                     session: session, thumbnails: thumbnails, browser: browser)
                                .id(entry.page.id)
                        }
                        if !browser.isSelecting && browser.matches == nil && !browser.showsBookmarksOnly {
                            AddPageButton(width: Self.thumbnailWidth) {
                                let id = document.addPage()
                                session.send(.goToPage(id))
                            }
                        }
                        if browser.pages(of: document).isEmpty {
                            Text(browser.matches != nil ? "No pages with that text." : "No bookmarked pages. Tap a page's bookmark to add one.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 20)
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 90)
                    .frame(maxWidth: .infinity)
                }
                .onAppear {
                    if let id = session.visiblePageID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, topInset + 4)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(.separator)).frame(width: 0.5)
        }
        .overlay(alignment: .bottom) {
            PageSelectBar(document: document, session: session, browser: browser)
                .padding(10)
        }
        .task(id: browser.query) { await search() }
    }

    private func search() async {
        let query = browser.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            browser.matches = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let matches = await document.pagesMatching(query)
        if !Task.isCancelled { browser.matches = matches }
    }
}

/// All the pages as a big grid over the note (the panel's ⤢ button), with the same search,
/// filter, menus and Select.
struct PageGrid: View {
    let document: NoteDocument
    let session: EditorSession
    let thumbnails: PageThumbnails
    @Bindable var browser: PageBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                PageFilterMenu(browser: browser, document: document)
                Spacer()
                PageSearchField(text: $browser.query)
                    .frame(maxWidth: 280)
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        browser.showsGrid = false
                        browser.finishSelecting()
                    }
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back to the note")
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 22)], spacing: 24) {
                    ForEach(browser.pages(of: document), id: \.page.id) { entry in
                        PageCell(page: entry.page, number: entry.number, width: 170, document: document, session: session,
                                 thumbnails: thumbnails, browser: browser) {
                            withAnimation(.easeInOut(duration: 0.25)) { browser.showsGrid = false }
                        }
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) {
            PageSelectBar(document: document, session: session, browser: browser, showsExpand: false)
                .frame(maxWidth: 360)
                .padding(20)
        }
        .task(id: browser.query) {
            let query = browser.query.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { browser.matches = nil; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let matches = await document.pagesMatching(query)
            if !Task.isCancelled { browser.matches = matches }
        }
    }
}

/// One page: its picture, number, bookmark, and ⋯ menu; in Select, a check to pick it.
private struct PageCell: View {
    let page: NoteDocument.Page
    let number: Int
    let width: CGFloat
    let document: NoteDocument
    let session: EditorSession
    let thumbnails: PageThumbnails
    @Bindable var browser: PageBrowser
    /// Also called after going to the page (the grid closes).
    var onOpen: () -> Void = {}

    @State private var confirmingDelete = false

    private var commands: PageCommands { PageCommands(document: document, session: session) }

    var body: some View {
        let isCurrent = session.visiblePageID == page.id
        let isPicked = browser.selected.contains(page.id)
        let size = page.record.size
        VStack(spacing: 6) {
            Group {
                if let image = thumbnails.images[page.id] {
                    Image(decorative: image, scale: thumbnails.scale)
                        .resizable()
                } else {
                    Rectangle().fill(.white)
                }
            }
            .frame(width: width, height: width * size.height / max(size.width, 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isCurrent || isPicked ? Color.accentColor : Color(.systemGray4), lineWidth: isCurrent || isPicked ? 3 : 1)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    document.setBookmarked(!page.record.isBookmarked, pages: [page.id])
                } label: {
                    Image(systemName: page.record.isBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(page.record.isBookmarked ? Color.accentColor : Color(.systemGray))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.record.isBookmarked ? "Remove bookmark" : "Bookmark page")
            }
            .overlay(alignment: .bottomLeading) {
                if !browser.isSelecting {
                    Menu {
                        PageMenuItems(ids: [page.id], commands: commands, isBookmarked: page.record.isBookmarked) {
                            confirmingDelete = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color(.systemBackground)))
                            .overlay(Circle().strokeBorder(Color(.systemGray4)))
                            .padding(8)
                            .contentShape(Rectangle())
                    }
                    .tint(.primary)
                    .accessibilityLabel("Page \(number) options")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if browser.isSelecting {
                    Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isPicked ? Color.accentColor : Color(.systemGray2))
                        .background(Circle().fill(Color(.systemBackground)).padding(2))
                        .padding(8)
                }
            }
            Text("\(number)")
                .font(.callout.weight(isCurrent ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if browser.isSelecting {
                if isPicked { browser.selected.remove(page.id) } else { browser.selected.insert(page.id) }
            } else {
                session.send(.goToPage(page.id))
                onOpen()
            }
        }
        // Asked at the page itself.
        .confirmationDialog("Delete page \(number)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Page", role: .destructive) { document.deletePage(page.id) }
        } message: {
            Text("Everything on it is deleted. This can't be undone.")
        }
        .accessibilityLabel("Page \(number)")
        .task(id: page.revision) {
            guard !thumbnails.isCurrent(page) else { return }
            // While you write, redraw a little after the last change rather than after every stroke.
            if thumbnails.images[page.id] != nil {
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard !Task.isCancelled else { return }
            await thumbnails.render(page, in: document)
        }
    }
}

/// The ⋯ menu of one page, or of the pages picked with Select.
private struct PageMenuItems: View {
    let ids: Set<UUID>
    let commands: PageCommands
    let isBookmarked: Bool
    let onDelete: () -> Void
    var onDone: () -> Void = {}

    var body: some View {
        if ids.count == 1, let id = ids.first {
            Button("Add Page", systemImage: "doc.badge.plus") { commands.addPage(after: id) }
        }
        Button("Cut", systemImage: "scissors") { Task { await commands.cut(ids); onDone() } }
        Button("Copy", systemImage: "doc.on.doc") { Task { await commands.copy(ids); onDone() } }
        if ids.count == 1, let id = ids.first, PageCommands.canPaste {
            Button("Paste", systemImage: "doc.on.clipboard") { commands.paste(after: id) }
        }
        Button("Duplicate", systemImage: "plus.square.on.square") { Task { await commands.duplicate(ids); onDone() } }
        Button(isBookmarked ? "Remove Bookmark" : "Bookmark", systemImage: isBookmarked ? "bookmark.slash" : "bookmark") {
            commands.document.setBookmarked(!isBookmarked, pages: ids)
            onDone()
        }
        if ids.count == 1, let id = ids.first {
            Button("Clear Page", systemImage: "paintbrush") { commands.document.clearPage(id) }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
}

/// The bar at the bottom of the panel: Select (and ⤢ for the grid); while selecting, Done, how
/// many are picked, and what to do with them.
private struct PageSelectBar: View {
    let document: NoteDocument
    let session: EditorSession
    @Bindable var browser: PageBrowser
    var showsExpand = true

    @State private var confirmingDelete = false
    @State private var actionsFrame: CGRect = .zero

    private var commands: PageCommands { PageCommands(document: document, session: session) }

    var body: some View {
        HStack(spacing: 8) {
            if browser.isSelecting {
                Button("Done") { browser.finishSelecting() }
                    .font(.system(size: 17, weight: .semibold))
                    .fixedSize()
                Spacer(minLength: 4)
                // How many are picked.
                Text("\(browser.selected.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel("\(browser.selected.count) pages selected")
                Menu {
                    let allBookmarked = document.pages.filter { browser.selected.contains($0.id) }.allSatisfy(\.record.isBookmarked)
                    PageMenuItems(ids: browser.selected, commands: commands, isBookmarked: allBookmarked,
                                  onDelete: { confirmingDelete = true }, onDone: { browser.finishSelecting() })
                    Button("Export as PDF", systemImage: "square.and.arrow.up") {
                        let ids = browser.selected, source = actionsFrame
                        browser.finishSelecting()
                        Task { await commands.export(ids, from: source) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 22))
                        .frame(width: 36, height: 36)
                }
                .disabled(browser.selected.isEmpty)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { actionsFrame = $0 }
                .confirmationDialog("Delete \(browser.selected.count) page\(browser.selected.count == 1 ? "" : "s")?",
                                    isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        document.deletePages(browser.selected)
                        browser.finishSelecting()
                    }
                } message: {
                    Text("Everything on them is deleted. This can't be undone.")
                }
            } else {
                Button("Select") { browser.isSelecting = true }
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if showsExpand {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { browser.showsGrid = true }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 36, height: 36)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Show all pages")
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .floatingCard(cornerRadius: 12)
    }
}

/// "All Pages ⌄": all pages, or only bookmarked ones.
private struct PageFilterMenu: View {
    @Bindable var browser: PageBrowser
    let document: NoteDocument

    var body: some View {
        Menu {
            Picker("Show", selection: $browser.showsBookmarksOnly) {
                Label("All Pages", systemImage: "doc.on.doc").tag(false)
                Label("Bookmarks (\(document.pages.filter(\.record.isBookmarked).count))", systemImage: "bookmark").tag(true)
            }
        } label: {
            HStack(spacing: 6) {
                Text(browser.showsBookmarksOnly ? "Bookmarks" : "All Pages")
                    .font(.system(size: 20, weight: .bold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .tint(.primary)
    }
}

private struct PageSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 16))
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(.systemGray4), lineWidth: 1)
        }
    }
}

private struct AddPageButton: View {
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .medium))
                .frame(width: width, height: 60)
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
}

/// Pictures of the open note's pages, made in the background.
@Observable
final class PageThumbnails {
    private(set) var images: [UUID: CGImage] = [:]
    /// The page revision each picture shows.
    @ObservationIgnored private var revisions: [UUID: Int] = [:]
    let scale: CGFloat = 2

    func isCurrent(_ page: NoteDocument.Page) -> Bool {
        images[page.id] != nil && revisions[page.id] == page.revision
    }

    func render(_ page: NoteDocument.Page, in document: NoteDocument) async {
        let revision = page.revision
        var pictures: [String: CGImage] = [:]
        for item in page.visibleItems {
            if let name = item.image?.fileName, pictures[name] == nil {
                pictures[name] = await document.loadImage(named: name, maxPixelSize: 600)
            }
        }
        var background: CGImage?
        var backgroundPDF: PDFBackground?
        switch page.record.background {
        case .image(let fileName)?: background = await document.loadImage(named: fileName, maxPixelSize: 600)
        case .pdf(let fileName, let index)?: backgroundPDF = await document.loadPDF(named: fileName)?.page(at: index)
        case nil: break
        }
        let content = PageContent(
            paper: page.record.paper,
            size: page.record.size,
            strokes: page.visibleStrokes.map(RenderedStroke.init),
            items: page.visibleItems.map { RenderedItem($0, image: $0.image.flatMap { pictures[$0.fileName] }) },
            backgroundImage: background,
            backgroundPDF: backgroundPDF
        )
        // Wide enough for the page grid's bigger cells too.
        let width: CGFloat = 170, scale = scale
        let image = await Task.detached(priority: .utility) {
            Thumbnail.render(content, width: width, scale: scale)
        }.value
        if let image {
            images[page.id] = image
            revisions[page.id] = revision
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
