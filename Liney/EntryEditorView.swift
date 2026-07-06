import SwiftData
import SwiftUI

struct EntryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var entry: JournalEntry
    let isNew: Bool

    @State private var bodyText = ""
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
