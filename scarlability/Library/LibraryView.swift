#if os(iOS)
import ScarlabilityKit
import SwiftUI

/// Notability-style library: Dividers and Subjects in the sidebar, the selected section's notes
/// as a thumbnail grid.
struct LibraryView: View {
    @Bindable var library: LibraryModel

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(library: library)
        } detail: {
            NotesGrid(library: library)
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

// MARK: - Sidebar

private struct LibrarySidebar: View {
    @Bindable var library: LibraryModel

    @State private var creatingSubjectIn: DividerChoice?
    @State private var showsNewDivider = false
    @State private var newDividerName = ""
    @State private var renaming: FolderTarget?
    @State private var renameText = ""
    @State private var deleting: FolderTarget?

    /// Which divider a new subject goes in (nil: none).
    private struct DividerChoice: Identifiable {
        var divider: String?
        var id: String { divider ?? "" }
    }

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

    var body: some View {
        let snapshot = library.snapshot
        List(selection: Binding<LibraryModel.Section?>(get: { library.section }, set: { if let section = $0 { library.section = section } })) {
            Section {
                Label("All Notes", systemImage: "tray.full")
                    .badge(snapshot.allNotes.count)
                    .tag(LibraryModel.Section.allNotes)
                Label("Unfiled", systemImage: "tray")
                    .badge(snapshot.unfiled.count)
                    .tag(LibraryModel.Section.unfiled)
                    .dropDestination(for: String.self) { paths, _ in drop(paths, onto: nil) }
                ForEach(snapshot.subjects) { subject in
                    subjectRow(subject)
                }
            }
            ForEach(snapshot.dividers) { divider in
                Section(isExpanded: expanded(divider.id)) {
                    ForEach(divider.subjects) { subject in
                        subjectRow(subject)
                    }
                } header: {
                    Text(divider.name)
                        .contextMenu {
                            Button("New Subject Here", systemImage: "plus") { creatingSubjectIn = DividerChoice(divider: divider.id) }
                            Button("Rename", systemImage: "pencil") { startRenaming(.divider(divider)) }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = .divider(divider) }
                        }
                }
            }
            Section {
                Label("Recently Deleted", systemImage: "trash")
                    .badge(snapshot.recentlyDeleted.count)
                    .tag(LibraryModel.Section.recentlyDeleted)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Scarlability")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Subject", systemImage: "folder.badge.plus") { creatingSubjectIn = DividerChoice(divider: nil) }
                    Button("New Divider", systemImage: "rectangle.stack.badge.plus") {
                        newDividerName = ""
                        showsNewDivider = true
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(item: $creatingSubjectIn) { choice in
            NewSubjectSheet(library: library, divider: choice.divider)
        }
        .alert("New Divider", isPresented: $showsNewDivider) {
            TextField("Name", text: $newDividerName)
            Button("Create") {
                let name = newDividerName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await library.createDivider(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Dividers group subjects, like a semester or a project.")
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

    private func subjectRow(_ subject: NotebookFolder.Subject) -> some View {
        Label {
            Text(subject.name)
        } icon: {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color(cgColor: subject.color.cgColor))
        }
        .badge(subject.notes.count)
        .tag(LibraryModel.Section.subject(subject.id))
        .dropDestination(for: String.self) { paths, _ in drop(paths, onto: subject.id) }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { startRenaming(.subject(subject)) }
            Menu("Color", systemImage: "paintpalette") {
                ForEach(InkColor.subjectColors, id: \.self) { color in
                    Button {
                        Task { await library.setColor(color, ofSubject: subject.id) }
                    } label: {
                        Image(systemName: color == subject.color ? "checkmark.circle.fill" : "circle.fill")
                            .foregroundStyle(Color(cgColor: color.cgColor))
                    }
                }
            }
            Menu("Move to Divider", systemImage: "rectangle.stack") {
                Button("No Divider") { Task { await library.moveSubject(subject.id, toDivider: nil) } }
                ForEach(library.snapshot.dividers) { divider in
                    Button(divider.name) { Task { await library.moveSubject(subject.id, toDivider: divider.id) } }
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = .subject(subject) }
        }
    }

    private func expanded(_ divider: String) -> Binding<Bool> {
        Binding(
            get: { !library.collapsedDividers.contains(divider) },
            set: { isExpanded in
                if isExpanded { library.collapsedDividers.remove(divider) } else { library.collapsedDividers.insert(divider) }
            }
        )
    }

    private func startRenaming(_ target: FolderTarget) {
        renameText = target.name
        renaming = target
    }

    private func drop(_ paths: [String], onto subject: String?) {
        Task { _ = await library.moveDropped(paths, toSubject: subject) }
    }
}

private struct NewSubjectSheet: View {
    let library: LibraryModel
    @State var divider: String?
    @State private var name = ""
    @State private var color = InkColor.subjectColors[5]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Subject name", text: $name)
                Section("Color") {
                    HStack(spacing: 12) {
                        ForEach(InkColor.subjectColors, id: \.self) { option in
                            Circle()
                                .fill(Color(cgColor: option.cgColor))
                                .frame(width: 30, height: 30)
                                .padding(3)
                                .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(option == color ? 1 : 0) }
                                .onTapGesture { color = option }
                        }
                    }
                }
                Picker("Divider", selection: $divider) {
                    Text("None").tag(String?.none)
                    ForEach(library.snapshot.dividers) { divider in
                        Text(divider.name).tag(String?.some(divider.id))
                    }
                }
            }
            .navigationTitle("New Subject")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = name.trimmingCharacters(in: .whitespaces)
                        let divider = divider, color = color
                        Task { await library.createSubject(named: name, color: color, inDivider: divider) }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Notes grid

private struct NotesGrid: View {
    @Bindable var library: LibraryModel
    @Environment(AppModel.self) private var model

    @State private var isSelecting = false
    @State private var selected: Set<URL> = []
    @State private var renaming: NotebookFolder.StoredNote?
    @State private var renameText = ""
    @State private var moving: [NotebookFolder.StoredNote] = []
    @State private var confirmingEmpty = false
    @State private var deletedNoteActions: NotebookFolder.StoredNote?

    private var inRecentlyDeleted: Bool { library.section == .recentlyDeleted }

    var body: some View {
        let notes = library.notes
        ScrollView {
            if notes.isEmpty {
                emptyState
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 24)], spacing: 28) {
                    ForEach(notes) { note in
                        card(note)
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle(isSelecting ? "\(selected.count) Selected" : library.title)
        .searchable(text: $library.searchText, prompt: "Search titles")
        .toolbar { toolbar(notes) }
        .refreshable { await library.reload() }
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

    private func card(_ note: NotebookFolder.StoredNote) -> some View {
        let subject = library.section == .allNotes ? library.snapshot.subject(containing: note.url) : nil
        let view = NoteCard(
            note: note,
            thumbnail: library.thumbnails[note.record.id]?.image,
            subject: subject,
            showsSubject: library.section == .allNotes,
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
                    NoteCard(note: note, thumbnail: library.thumbnails[note.record.id]?.image, subject: nil,
                             isDeleted: false, isSelecting: false, isSelected: false)
                        .frame(width: 150)
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
            Button("Move to…", systemImage: "folder") { moving = [note] }
            Button("Duplicate", systemImage: "plus.square.on.square") { Task { await library.duplicate(note) } }
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await library.delete([note]) } }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ notes: [NotebookFolder.StoredNote]) -> some ToolbarContent {
        let chosen = notes.filter { selected.contains($0.url) }
        if isSelecting {
            ToolbarItemGroup(placement: .primaryAction) {
                if inRecentlyDeleted {
                    Button("Restore") { Task { await library.restore(chosen); finishSelecting() } }
                        .disabled(chosen.isEmpty)
                    Button("Delete Forever", role: .destructive) { Task { await library.deleteForever(chosen); finishSelecting() } }
                        .disabled(chosen.isEmpty)
                } else {
                    Button("Move") { moving = chosen }
                        .disabled(chosen.isEmpty)
                    Button("Delete", role: .destructive) { Task { await library.delete(chosen); finishSelecting() } }
                        .disabled(chosen.isEmpty)
                }
                Button("Done") { finishSelecting() }
                    .bold()
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Sort by", selection: $library.sort) {
                        ForEach(LibraryModel.Sort.allCases, id: \.self) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                if !notes.isEmpty {
                    Button("Select") { isSelecting = true }
                }
                if inRecentlyDeleted {
                    Button("Empty", role: .destructive) { confirmingEmpty = true }
                        .disabled(notes.isEmpty)
                } else {
                    Button {
                        Task {
                            if let note = await library.createNote() {
                                model.openNote(note)
                            }
                        }
                    } label: {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                }
            }
        }
    }

    private func finishSelecting() {
        isSelecting = false
        selected = []
    }

    @ViewBuilder
    private var emptyState: some View {
        if !library.searchText.isEmpty {
            ContentUnavailableView.search(text: library.searchText)
        } else if inRecentlyDeleted {
            ContentUnavailableView("No Recently Deleted Notes", systemImage: "trash",
                                   description: Text("Deleted notes stay here for 30 days."))
        } else {
            ContentUnavailableView("No Notes Yet", systemImage: "square.and.pencil",
                                   description: Text("Tap the pencil button to start a new note."))
        }
    }
}

private struct NoteCard: View {
    let note: NotebookFolder.StoredNote
    let thumbnail: CGImage?
    /// Shown in All Notes, so you can tell where a note lives.
    let subject: NotebookFolder.Subject?
    /// Whether to show which subject the note is in (All Notes shows it).
    var showsSubject = false
    let isDeleted: Bool
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 2)
                            .resizable()
                    } else {
                        Rectangle().fill(.white)
                    }
                }
                .aspectRatio(PageSize.a4.width / PageSize.a4.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.08)) }
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 3).opacity(isSelected ? 1 : 0)
                }
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .background(Circle().fill(.white).padding(2))
                        .padding(8)
                }
            }
            Text(note.record.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if showsSubject {
                HStack(spacing: 5) {
                    Circle()
                        .fill(subject.map { Color(cgColor: $0.color.cgColor) } ?? Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(subject?.name ?? "Unfiled")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        if isDeleted, let deletedAt = note.record.deletedAt {
            let left = max(0, Int(ceil((LibraryLayout.keepDeletedFor - Date().timeIntervalSince(deletedAt)) / 86_400)))
            return "\(left) day\(left == 1 ? "" : "s") left"
        }
        return note.record.modifiedAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
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
                    destination("Unfiled", systemImage: "tray", color: nil, subject: nil)
                    ForEach(library.snapshot.subjects) { subject in
                        destination(subject.name, systemImage: "folder.fill", color: subject.color, subject: subject.id)
                    }
                }
                ForEach(library.snapshot.dividers) { divider in
                    Section(divider.name) {
                        ForEach(divider.subjects) { subject in
                            destination(subject.name, systemImage: "folder.fill", color: subject.color, subject: subject.id)
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

    private func destination(_ name: String, systemImage: String, color: InkColor?, subject: String?) -> some View {
        Button {
            let notes = notes
            Task { await library.move(notes, toSubject: subject) }
            onDone()
            dismiss()
        } label: {
            Label {
                Text(name).foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(color.map { Color(cgColor: $0.cgColor) } ?? .secondary)
            }
        }
    }
}
#endif
