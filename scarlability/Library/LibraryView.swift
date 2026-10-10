#if os(iOS)
import ScarlabilityKit
import SwiftUI
import UniformTypeIdentifiers

/// Notability-style library: the sidebar (settings, search, Notes, Folders) on the left, and the
/// selected notes as cards on the right.
struct LibraryView: View {
    @Bindable var library: LibraryModel
    let model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar(library: library, model: model)
                .frame(width: 300)
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 0.5)
                .ignoresSafeArea()
            NotesBrowser(library: library, model: model)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(library.errorMessage ?? "")
        }
    }
}

/// What a new-folder sheet makes.
private enum NewFolderKind: Identifiable {
    /// A folder for notes, at the top level or inside a folder group.
    case folder(inGroup: String?)
    /// A folder that holds other folders (a Divider).
    case group

    var id: String {
        switch self {
        case .folder(let group): "f:" + (group ?? "")
        case .group: "g"
        }
    }
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
    @Bindable var library: LibraryModel
    let model: AppModel

    @State private var showsSettings = false
    @State private var creating: NewFolderKind?
    @State private var renaming: FolderTarget?
    @State private var renameText = ""
    @State private var deleting: FolderTarget?

    private enum FolderTarget: Identifiable {
        case subject(NotebookFolder.Subject)
        case divider(NotebookFolder.Divider)

        var id: String {
            switch self {
            case .subject(let subject): "s:" + subject.id
            case .divider(let divider): "d:" + divider.id
            }
        }

        var name: String {
            switch self {
            case .subject(let subject): subject.name
            case .divider(let divider): divider.name
            }
        }

        var noteCount: Int {
            switch self {
            case .subject(let subject): subject.notes.count
            case .divider(let divider): divider.subjects.reduce(0) { $0 + $1.notes.count }
            }
        }
    }

    /// Top-level folders and folder groups, in the order they were made.
    private enum TopLevel: Identifiable {
        case subject(NotebookFolder.Subject)
        case divider(NotebookFolder.Divider)

        var id: String {
            switch self {
            case .subject(let subject): "s:" + subject.id
            case .divider(let divider): "d:" + divider.id
            }
        }

        var sortKey: (Double, String) {
            switch self {
            case .subject(let subject): (subject.sortIndex, subject.name.localizedLowercase)
            case .divider(let divider): (divider.sortIndex, divider.name.localizedLowercase)
            }
        }
    }

    var body: some View {
        let snapshot = library.snapshot
        let topLevel = (snapshot.subjects.map(TopLevel.subject) + snapshot.dividers.map(TopLevel.divider))
            .sorted { $0.sortKey < $1.sortKey }
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 22))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Settings")
                .popover(isPresented: $showsSettings) {
                    EditorSettingsView(settings: model.toolSettings, folderName: model.folderName) {
                        showsSettings = false
                        model.forgetFolder()
                    }
                }
                .padding(.bottom, 14)

                SearchField(text: $library.searchText)
                    .padding(.bottom, 22)

                row(isSelected: library.section.isNoteTab && !library.isSearching) {
                    library.searchText = ""
                    library.section = .allNotes
                } content: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 26)
                    Text("Notes").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Text("\(snapshot.allNotes.count)")
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                }

                HStack {
                    Text("Folders")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("New Folder", systemImage: "folder.badge.plus") { creating = .folder(inGroup: nil) }
                        Button("New Folder Group", systemImage: "folder.fill.badge.plus") { creating = .group }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 19, weight: .regular))
                            .frame(width: 40, height: 40)
                    }
                    .tint(.primary)
                    .accessibilityLabel("New Folder")
                }
                .padding(.leading, 12)
                .padding(.top, 22)
                .padding(.bottom, 4)

                ForEach(topLevel) { entry in
                    switch entry {
                    case .subject(let subject):
                        subjectRow(subject, indent: 0)
                    case .divider(let divider):
                        dividerRow(divider)
                        if !library.collapsedDividers.contains(divider.id) {
                            ForEach(divider.subjects) { subject in
                                subjectRow(subject, indent: 26)
                            }
                        }
                    }
                }
                if topLevel.isEmpty {
                    Text("Tap + to make a folder.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .padding(.vertical, 8)
                }

                row(isSelected: library.section == .recentlyDeleted && !library.isSearching) {
                    library.searchText = ""
                    library.section = .recentlyDeleted
                } content: {
                    Image(systemName: "trash")
                        .font(.system(size: 17))
                        .frame(width: 26)
                    Text("Recently Deleted")
                    Spacer()
                    if !snapshot.recentlyDeleted.isEmpty {
                        Text("\(snapshot.recentlyDeleted.count)").monospacedDigit()
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.top, 24)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.secondarySystemBackground).opacity(0.6))
        .sheet(item: $creating) { kind in
            NewFolderSheet(library: library, kind: kind)
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { target in
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task {
                    switch target {
                    case .subject(let subject): await library.renameFolder(subject.id, to: name)
                    case .divider(let divider): await library.renameDivider(divider.id, to: name)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { target in
            Button("Delete", role: .destructive) {
                Task {
                    switch target {
                    case .subject(let subject): await library.deleteSubject(subject.id)
                    case .divider(let divider): await library.deleteDivider(divider.id)
                    }
                }
            }
        } message: { target in
            Text(target.noteCount == 0
                 ? "It's empty."
                 : "Its \(target.noteCount) note\(target.noteCount == 1 ? "" : "s") will go to Recently Deleted for 30 days.")
        }
    }

    /// A sidebar row: gray behind it when selected.
    private func row(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                content()
            }
            .font(.system(size: 17))
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(isSelected ? Color(.systemGray5) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func subjectRow(_ subject: NotebookFolder.Subject, indent: CGFloat) -> some View {
        row(isSelected: library.section == .subject(subject.id) && !library.isSearching) {
            library.searchText = ""
            library.section = .subject(subject.id)
        } content: {
            FolderDot(color: subject.color)
            Text(subject.name).lineLimit(1)
            Spacer()
        }
        .padding(.leading, indent)
        .dropDestination(for: String.self) { paths, _ in drop(paths, onto: subject.id) }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { startRenaming(.subject(subject)) }
            colorMenu(selected: subject.color) { color in await library.setColor(color, ofSubject: subject.id) }
            Menu("Move to Group", systemImage: "folder") {
                Button("None (Top Level)") { Task { await library.moveSubject(subject.id, toDivider: nil) } }
                ForEach(library.snapshot.dividers) { divider in
                    Button(divider.name) { Task { await library.moveSubject(subject.id, toDivider: divider.id) } }
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = .subject(subject) }
        }
    }

    private func dividerRow(_ divider: NotebookFolder.Divider) -> some View {
        let isExpanded = !library.collapsedDividers.contains(divider.id)
        return row(isSelected: false) {
            withAnimation(.snappy(duration: 0.2)) {
                if isExpanded { library.collapsedDividers.insert(divider.id) } else { library.collapsedDividers.remove(divider.id) }
            }
        } content: {
            FolderDot(color: divider.color)
            Text(divider.name).lineLimit(1)
            Spacer()
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
        }
        .accessibilityHint(isExpanded ? "Hides its folders" : "Shows its folders")
        .contextMenu {
            Button("New Folder Inside", systemImage: "folder.badge.plus") { creating = .folder(inGroup: divider.id) }
            Button("Rename", systemImage: "pencil") { startRenaming(.divider(divider)) }
            colorMenu(selected: divider.color) { color in await library.setColor(color, ofDivider: divider.id) }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = .divider(divider) }
        }
    }

    private func colorMenu(selected: InkColor, set: @escaping (InkColor) async -> Void) -> some View {
        Menu("Color", systemImage: "paintpalette") {
            ForEach(InkColor.folderColors, id: \.self) { color in
                Button {
                    Task { await set(color) }
                } label: {
                    Image(systemName: color == selected ? "checkmark.circle.fill" : "circle.fill")
                        .foregroundStyle(Color(cgColor: color.cgColor))
                }
            }
        }
    }

    private func startRenaming(_ target: FolderTarget) {
        renameText = target.name
        renaming = target
    }

    private func drop(_ paths: [String], onto subject: String?) -> Bool {
        Task { _ = await library.moveDropped(paths, toSubject: subject) }
        return true
    }
}

extension InkColor {
    /// The colors a folder can have: the subject colors, plus the dark gray folder groups start with.
    static let folderColors = InkColor.subjectColors + [InkColor.dividerColor]
}

private struct FolderDot: View {
    let color: InkColor

    var body: some View {
        Circle()
            .fill(Color(cgColor: color.cgColor))
            .frame(width: 15, height: 15)
            .frame(width: 26)
    }
}

private struct SearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 17))
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(.systemGray4), lineWidth: 1)
        }
    }
}

private struct NewFolderSheet: View {
    let library: LibraryModel
    let kind: NewFolderKind
    @State private var name = ""
    @State private var color = InkColor.subjectColors[5]
    @State private var group: String?
    @Environment(\.dismiss) private var dismiss

    init(library: LibraryModel, kind: NewFolderKind) {
        self.library = library
        self.kind = kind
        switch kind {
        case .folder(let group):
            _group = State(initialValue: group)
        case .group:
            _color = State(initialValue: InkColor.dividerColor)
        }
    }

    private var isGroup: Bool {
        if case .group = kind { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(isGroup ? "Group name, like Fall 2026" : "Folder name, like Math 185", text: $name)
                } footer: {
                    if isGroup {
                        Text("A folder group holds other folders, like a semester. Notes go in the folders inside it.")
                    }
                }
                Section("Color") {
                    HStack(spacing: 12) {
                        ForEach(InkColor.folderColors, id: \.self) { option in
                            Circle()
                                .fill(Color(cgColor: option.cgColor))
                                .frame(width: 28, height: 28)
                                .padding(3)
                                .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(option == color ? 1 : 0) }
                                .onTapGesture { color = option }
                        }
                    }
                }
                if !isGroup {
                    Picker("Inside", selection: $group) {
                        Text("Nothing (top level)").tag(String?.none)
                        ForEach(library.snapshot.dividers) { divider in
                            Text(divider.name).tag(String?.some(divider.id))
                        }
                    }
                }
            }
            .navigationTitle(isGroup ? "New Folder Group" : "New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = name.trimmingCharacters(in: .whitespaces)
                        let group = group, color = color, isGroup = isGroup
                        Task {
                            if isGroup {
                                await library.createDivider(named: name, color: color)
                            } else {
                                await library.createSubject(named: name, color: color, inDivider: group)
                            }
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Notes

private struct NotesBrowser: View {
    @Bindable var library: LibraryModel
    let model: AppModel

    @State private var isSelecting = false
    @State private var selected: Set<URL> = []
    @State private var renaming: NotebookFolder.StoredNote?
    @State private var renameText = ""
    @State private var moving: [NotebookFolder.StoredNote] = []
    @State private var creatingFolder = false
    @State private var exporting: [NotebookFolder.StoredNote] = []
    @State private var confirmingEmpty = false
    @State private var deletedNoteActions: NotebookFolder.StoredNote?

    private var inRecentlyDeleted: Bool { library.section == .recentlyDeleted && !library.isSearching }

    var body: some View {
        let notes = library.notes
        VStack(alignment: .leading, spacing: 0) {
            actions(notes)
                .padding(.horizontal, 28)
                .padding(.top, 6)
            Text(isSelecting ? "\(selected.count) Selected" : library.title)
                .font(.system(size: 44, weight: .black))
                .tracking(-0.8)
                .lineLimit(1)
                .padding(.horizontal, 28)
            if library.section.isNoteTab && !library.isSearching {
                tabs
                    .padding(.horizontal, 28)
                    .padding(.top, 6)
            }
            ScrollView {
                if notes.isEmpty {
                    emptyState
                        .padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 26)], spacing: 30) {
                        ForEach(notes) { note in
                            card(note)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 40)
                }
            }
            .refreshable { await library.reload() }
        }
        .background(Color(.systemBackground))
        .onChange(of: library.section) {
            isSelecting = false
            selected = []
        }
        .alert("Rename Note", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { note in
            TextField("Title", text: $renameText)
            Button("Rename") {
                let title = renameText
                Task { await library.renameNote(note, to: title) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: Binding(get: { !moving.isEmpty }, set: { if !$0 { moving = [] } })) {
            MoveNotesSheet(library: library, notes: moving) {
                isSelecting = false
                selected = []
            }
        }
        .sheet(isPresented: $creatingFolder) {
            NewFolderSheet(library: library, kind: .folder(inGroup: nil))
        }
        .sheet(isPresented: Binding(get: { !exporting.isEmpty }, set: { if !$0 { exporting = [] } })) {
            ExportSheet(source: .notes(exporting), folder: library.folder)
        }
        .fileImporter(isPresented: Bindable(model).isImportingPDF, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task {
                let notes = await library.importPDFs(urls)
                if notes.count == 1, let note = notes.first {
                    model.openNote(note)
                }
            }
        }
        .confirmationDialog("Delete everything in Recently Deleted?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("Delete Forever", role: .destructive) { Task { await library.emptyRecentlyDeleted() } }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(deletedNoteActions?.record.title ?? "", isPresented: Binding(
            get: { deletedNoteActions != nil }, set: { if !$0 { deletedNoteActions = nil } }
        ), titleVisibility: .visible, presenting: deletedNoteActions) { note in
            Button("Restore") { Task { await library.restore([note]) } }
            Button("Delete Forever", role: .destructive) { Task { await library.deleteForever([note]) } }
        }
    }

    /// All Notes, Recents, Favorites, Unfiled.
    private var tabs: some View {
        HStack(spacing: 30) {
            ForEach(LibraryModel.Section.noteTabs, id: \.self) { tab in
                let isSelected = library.section == tab
                Button {
                    library.section = tab
                } label: {
                    VStack(spacing: 7) {
                        Text(tab.tabTitle)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.primary : Color(.systemGray2))
                        Capsule()
                            .fill(isSelected ? Color.accentColor : .clear)
                            .frame(height: 4)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    /// The buttons at the top right: the "…" menu and + New (or the selection's actions).
    @ViewBuilder
    private func actions(_ notes: [NotebookFolder.StoredNote]) -> some View {
        let chosen = notes.filter { selected.contains($0.url) }
        HStack(spacing: 18) {
            Spacer()
            if isSelecting {
                if inRecentlyDeleted {
                    Button("Restore") { Task { await library.restore(chosen); finishSelecting() } }
                        .disabled(chosen.isEmpty)
                    Button("Delete Forever", role: .destructive) { Task { await library.deleteForever(chosen); finishSelecting() } }
                        .disabled(chosen.isEmpty)
                } else {
                    Button("Favorite") { Task { await library.setFavorite(true, chosen); finishSelecting() } }
                        .disabled(chosen.isEmpty)
                    Button("Export") { exporting = chosen }
                        .disabled(chosen.isEmpty)
                    Button("Move") { moving = chosen }
                        .disabled(chosen.isEmpty)
                    Button("Delete", role: .destructive) { Task { await library.delete(chosen); finishSelecting() } }
                        .disabled(chosen.isEmpty)
                }
                Button("Done") { finishSelecting() }
                    .bold()
            } else {
                Menu {
                    Picker("Sort by", selection: $library.sort) {
                        ForEach(LibraryModel.Sort.allCases, id: \.self) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }
                    if !notes.isEmpty {
                        Button("Select Notes", systemImage: "checkmark.circle") { isSelecting = true }
                    }
                    if inRecentlyDeleted {
                        Button("Empty Recently Deleted", systemImage: "trash", role: .destructive) { confirmingEmpty = true }
                            .disabled(notes.isEmpty)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 26, weight: .light))
                        .frame(width: 44, height: 44)
                }
                .tint(.primary)
                .accessibilityLabel("More")
                if !inRecentlyDeleted {
                    Menu {
                        Button("Note", systemImage: "square.and.pencil") { newNote() }
                        Button("Import PDF…", systemImage: "doc.badge.plus") { model.isImportingPDF = true }
                        Button("Folder", systemImage: "folder.badge.plus") { creatingFolder = true }
                    } label: {
                        Label("New", systemImage: "plus")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 46)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .accessibilityLabel("New")
                }
            }
        }
        .font(.system(size: 17, weight: .medium))
        .frame(height: 56)
    }

    private func newNote() {
        Task {
            if let note = await library.createNote() {
                model.openNote(note)
            }
        }
    }

    private func card(_ note: NotebookFolder.StoredNote) -> some View {
        let showsFolder = library.section.isNoteTab || library.isSearching
        let view = NoteCard(
            note: note,
            thumbnail: library.thumbnails[note.record.id]?.image,
            folder: showsFolder ? library.snapshot.subject(containing: note.url) : nil,
            isDeleted: inRecentlyDeleted,
            isSelecting: isSelecting,
            isSelected: selected.contains(note.url)
        )
        .onAppear { library.requestThumbnail(for: note) }
        .onTapGesture { tap(note) }
        .contextMenu { menu(for: note) }
        return Group {
            if isSelecting || inRecentlyDeleted {
                view
            } else {
                view.draggable(note.url.path(percentEncoded: false)) {
                    NoteCard(note: note, thumbnail: library.thumbnails[note.record.id]?.image, folder: nil,
                             isDeleted: false, isSelecting: false, isSelected: false)
                        .frame(width: 160)
                }
            }
        }
    }

    private func tap(_ note: NotebookFolder.StoredNote) {
        if isSelecting {
            if selected.contains(note.url) { selected.remove(note.url) } else { selected.insert(note.url) }
        } else if inRecentlyDeleted {
            deletedNoteActions = note
        } else {
            model.openNote(note)
        }
    }

    @ViewBuilder
    private func menu(for note: NotebookFolder.StoredNote) -> some View {
        if inRecentlyDeleted {
            Button("Restore", systemImage: "arrow.uturn.backward") { Task { await library.restore([note]) } }
            Button("Delete Forever", systemImage: "trash", role: .destructive) { Task { await library.deleteForever([note]) } }
        } else {
            Button("Rename", systemImage: "pencil") {
                renameText = note.record.title
                renaming = note
            }
            if note.record.isFavorite {
                Button("Remove from Favorites", systemImage: "star.slash") { Task { await library.setFavorite(false, [note]) } }
            } else {
                Button("Add to Favorites", systemImage: "star") { Task { await library.setFavorite(true, [note]) } }
            }
            Button("Move to…", systemImage: "folder") { moving = [note] }
            Button("Duplicate", systemImage: "plus.square.on.square") { Task { await library.duplicate(note) } }
            Button("Export as PDF…", systemImage: "square.and.arrow.up") { exporting = [note] }
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await library.delete([note]) } }
        }
    }

    private func finishSelecting() {
        isSelecting = false
        selected = []
    }

    @ViewBuilder
    private var emptyState: some View {
        if library.isSearching {
            ContentUnavailableView.search(text: library.searchText)
        } else {
            switch library.section {
            case .recentlyDeleted:
                ContentUnavailableView("No Recently Deleted Notes", systemImage: "trash",
                                       description: Text("Deleted notes stay here for 30 days."))
            case .favorites:
                ContentUnavailableView("No Favorites Yet", systemImage: "star",
                                       description: Text("Long-press a note and choose Add to Favorites."))
            case .recents:
                ContentUnavailableView("Nothing Recent", systemImage: "clock",
                                       description: Text("Notes you open or change show up here."))
            default:
                ContentUnavailableView("No Notes Yet", systemImage: "square.and.pencil",
                                       description: Text("Tap + New to start a note."))
            }
        }
    }
}

/// A note in the grid: the top of its first page, then its title, date and folder.
private struct NoteCard: View {
    let note: NotebookFolder.StoredNote
    let thumbnail: CGImage?
    /// The folder tag (All Notes and the other tabs show where each note lives).
    let folder: NotebookFolder.Subject?
    let isDeleted: Bool
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.white
                .aspectRatio(1.05, contentMode: .fit)
                .overlay(alignment: .top) {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 2)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .background(Circle().fill(.white).padding(2))
                            .padding(10)
                    } else if note.record.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.yellow)
                            .shadow(color: .black.opacity(0.25), radius: 1)
                            .padding(10)
                    }
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(.separator).opacity(0.6)).frame(height: 0.5)
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(note.record.title)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(detail)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let folder {
                        FolderTag(subject: folder)
                            .layoutPriority(1)
                    }
                }
                .frame(height: 26)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color(.separator).opacity(0.35), lineWidth: isSelected ? 3 : 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var detail: String {
        if isDeleted, let deletedAt = note.record.deletedAt {
            let left = max(0, Int(ceil((LibraryLayout.keepDeletedFor - Date().timeIntervalSince(deletedAt)) / 86_400)))
            return "\(left) day\(left == 1 ? "" : "s") left"
        }
        return note.record.modifiedAt.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// The folder's name in a pill of its color.
private struct FolderTag: View {
    let subject: NotebookFolder.Subject

    var body: some View {
        let color = Color(cgColor: subject.color.cgColor)
        Text(subject.name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(color.opacity(0.22), in: Capsule())
            .overlay { Capsule().strokeBorder(color.opacity(0.7), lineWidth: 1.5) }
    }
}

private struct MoveNotesSheet: View {
    let library: LibraryModel
    let notes: [NotebookFolder.StoredNote]
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    destination("Unfiled", color: nil, subject: nil)
                    ForEach(library.snapshot.subjects) { subject in
                        destination(subject.name, color: subject.color, subject: subject.id)
                    }
                }
                ForEach(library.snapshot.dividers) { divider in
                    Section(divider.name) {
                        ForEach(divider.subjects) { subject in
                            destination(subject.name, color: subject.color, subject: subject.id)
                        }
                    }
                }
            }
            .navigationTitle(notes.count == 1 ? "Move “\(notes[0].record.title)”" : "Move \(notes.count) Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func destination(_ name: String, color: InkColor?, subject: String?) -> some View {
        Button {
            let notes = notes
            Task { await library.move(notes, toSubject: subject) }
            onDone()
            dismiss()
        } label: {
            Label {
                Text(name).foregroundStyle(.primary)
            } icon: {
                if let color {
                    Circle().fill(Color(cgColor: color.cgColor)).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "tray").foregroundStyle(.secondary)
                }
            }
        }
    }
}
#endif
