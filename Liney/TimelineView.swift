import SwiftData
import SwiftUI
import UIKit

struct TimelineShellView: View {
    @Binding var requiresAppLock: Bool
    @ObservedObject var appLock: AppLockModel

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            NavigationSplitView {
                TimelineView(requiresAppLock: $requiresAppLock, appLock: appLock)
            } detail: {
                ContentUnavailableView(
                    "No Entry Selected",
                    systemImage: "book.closed",
                    description: Text("Choose an entry from the timeline once entries exist.")
                )
            }
        } else {
            NavigationStack {
                TimelineView(requiresAppLock: $requiresAppLock, appLock: appLock)
            }
        }
    }
}

struct TimelineView: View {
    @Binding var requiresAppLock: Bool
    @ObservedObject var appLock: AppLockModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [
        SortDescriptor(\JournalEntry.entryDate, order: .reverse),
        SortDescriptor(\JournalEntry.createdAt, order: .reverse)
    ]) private var entries: [JournalEntry]

    @State private var newEntry: JournalEntry?
    @State private var searchText = ""
    @State private var isImportingJournal = false
    @State private var isExportingJournal = false
    @State private var isShowingSettings = false

    private var timelineEntries: [JournalEntry] {
        searchJournalEntries(entries, matching: searchText)
    }

    var body: some View {
        List {
            ForEach(groupEntriesByDay(timelineEntries)) { group in
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
            } else if timelineEntries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle("Journal")
        .searchable(text: $searchText, prompt: "Search Entries")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: createNewEntry) {
                    Label("New Entry", systemImage: "square.and.pencil")
                }

                Menu {
                    Button {
                        isImportingJournal = true
                    } label: {
                        Label("Import Journal", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        isExportingJournal = true
                    } label: {
                        Label("Export Journal", systemImage: "square.and.arrow.up")
                    }

                    Divider()

                    Button {
                        isShowingSettings = true
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
        .navigationDestination(isPresented: $isShowingSettings) {
            SettingsView(requiresAppLock: $requiresAppLock, appLock: appLock)
        }
        .background {
            ImportJournalFlow(isPresented: $isImportingJournal)
            ExportJournalFlow(isPresented: $isExportingJournal, entries: entries) {
                await appLock.authenticateForExport(requiresLock: requiresAppLock)
            }
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
                    isImportingJournal = true
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: JournalEntry
    private let photoStorage = PhotoStorage()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.rowTitle)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)

                if let rowSubtitle = entry.rowSubtitle {
                    Text(rowSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                }
            }

            if !entry.previewPhotos.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.previewPhotos) { photo in
                        Color.clear
                            .frame(width: 48, height: 48)
                            .overlay {
                                StoredPhotoThumbnail(photo: photo, storage: photoStorage, cornerRadius: 6, maxPixelSize: 160)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Entry Photos")
                .accessibilityValue(Text("\(entry.photoCount)"))
            }
        }
        .padding(.vertical, 4)
    }
}
