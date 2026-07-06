import SwiftData
import SwiftUI

struct EntryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var entry: JournalEntry
    let isNew: Bool

    @State private var bodyText = ""
    @State private var isShowingDateEditor = false
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                isShowingDateEditor = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .accessibilityHidden(true)
                    Text(entryDateText)
                    if entry.isAllDay {
                        Text("All-day")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit Entry Date")
            .accessibilityValue(entry.isAllDay ? "\(entryDateText), \(String(localized: "All-day"))" : entryDateText)

            if let locationText = entry.locationDisplayText {
                Label {
                    Text(locationText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location")
                .accessibilityValue(locationText)
            }

            TextField("Title", text: titleBinding, prompt: Text("Title"))
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .accessibilityLabel("Title")

            ZStack(alignment: .topLeading) {
                if bodyText.isEmpty {
                    Text("Write something...")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }

                TextEditor(text: bodyBinding)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Body")
            }
        }
        .padding()
        .navigationTitle(entry.entryDate.formatted(.dateTime.month(.wide).day().year()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        isShowingDeleteConfirmation = true
                    } label: {
                        Label("Delete Entry", systemImage: "trash")
                    }
                } label: {
                    Label("Entry Actions", systemImage: "ellipsis.circle")
                }

                Button("Done", action: finish)
            }
        }
        .sheet(isPresented: $isShowingDateEditor) {
            NavigationStack {
                EntryDateEditorView(entry: entry, saveChange: saveChange)
            }
        }
        .confirmationDialog(
            "Delete Entry?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Entry", role: .destructive, action: deleteEntry)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This entry will be removed from this device.")
        }
        .onAppear {
            bodyText = entry.plainTextBody
        }
    }

    private var entryDateText: String {
        if entry.isAllDay {
            return entry.entryDate.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        }
        return entry.entryDate.formatted(.dateTime.weekday(.wide).month(.wide).day().year().hour().minute())
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { entry.title },
            set: { newValue in
                entry.title = newValue
                saveChange()
            }
        )
    }

    private var bodyBinding: Binding<String> {
        Binding(
            get: { bodyText },
            set: { newValue in
                bodyText = newValue
                entry.setBody(newValue, in: modelContext)
                saveChange()
            }
        )
    }

    private func saveChange() {
        entry.updatedAt = .now
        try? modelContext.save()
    }

    private func finish() {
        if isNew {
            _ = discardBlankNewEntry(entry, in: modelContext)
        }
        try? modelContext.save()
        dismiss()
    }

    private func deleteEntry() {
        modelContext.delete(entry)
        try? modelContext.save()
        dismiss()
    }
}

private struct EntryDateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var entry: JournalEntry
    let saveChange: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("All-day", isOn: allDayBinding)

                DatePicker(
                    "Date",
                    selection: entryDateBinding,
                    displayedComponents: entry.isAllDay ? .date : [.date, .hourAndMinute]
                )
                .id(entry.isAllDay)
            }
        }
        .navigationTitle("Entry Date")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    private var allDayBinding: Binding<Bool> {
        Binding(
            get: { entry.isAllDay },
            set: { newValue in
                entry.setAllDay(newValue)
                saveChange()
            }
        )
    }

    private var entryDateBinding: Binding<Date> {
        Binding(
            get: { entry.entryDate },
            set: { newValue in
                entry.setEntryDate(newValue)
                saveChange()
            }
        )
    }
}
