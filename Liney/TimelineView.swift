import SwiftData
import SwiftUI
import UIKit

struct TimelineShellView: View {
    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            NavigationSplitView {
                TimelineView()
            } detail: {
                ContentUnavailableView(
                    "No Entry Selected",
                    systemImage: "book.closed",
                    description: Text("Choose an entry from the timeline once entries exist.")
                )
            }
        } else {
            NavigationStack {
                TimelineView()
            }
        }
    }
}

struct TimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [
        SortDescriptor(\JournalEntry.entryDate, order: .reverse),
        SortDescriptor(\JournalEntry.createdAt, order: .reverse)
    ]) private var entries: [JournalEntry]

    @State private var placeholderAction: PlaceholderAction?
    @State private var newEntry: JournalEntry?

    var body: some View {
        List {
            ForEach(groupEntriesByDay(entries)) { group in
                Section {
                    ForEach(group.entries) { entry in
                        NavigationLink {
                            EntryEditorView(entry: entry, isNew: false)
                        } label: {
                            EntryRowView(entry: entry)
                        }
                    }
                } header: {
                    Text(group.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                emptyState
            }
        }
        .navigationTitle("Journal")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: createNewEntry) {
                    Label("New Entry", systemImage: "square.and.pencil")
                }

                Menu {
                    Button {
                        placeholderAction = .importJournal
                    } label: {
                        Label("Import Journal", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        placeholderAction = .exportJournal
                    } label: {
                        Label("Export Journal", systemImage: "square.and.arrow.up")
                    }

                    Divider()

                    Button {
                        placeholderAction = .settings
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $newEntry) { entry in
            NavigationStack {
                EntryEditorView(entry: entry, isNew: true)
            }
            .interactiveDismissDisabled()
        }
        .alert(item: $placeholderAction) { action in
            action.alert
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Entries", systemImage: "book.closed")
        } description: {
            Text("Start your private journal or import an existing journal.")
        } actions: {
            VStack(spacing: 10) {
                Button(action: createNewEntry) {
                    Label("New Entry", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    placeholderAction = .importJournal
                } label: {
                    Label("Import Journal", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func createNewEntry() {
        let entry = JournalEntry()
        modelContext.insert(entry)
        newEntry = entry
    }
}

private struct EntryRowView: View {
    let entry: JournalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.rowTitle)
                .font(.headline)
                .lineLimit(1)

            if let rowSubtitle = entry.rowSubtitle {
                Text(rowSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
