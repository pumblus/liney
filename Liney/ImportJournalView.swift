import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ImportJournalFlow: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var isPresented: Bool
    var onFinished: (() -> Void)?

    @State private var showFileImporter = false
    @State private var pendingPlan: DayOneImportPlan?
    @State private var progress = DayOneImportProgress(processedEntries: 0, totalEntries: 0)
    @State private var summary: DayOneImportSummary?
    @State private var isImporting = false
    @State private var importTask: Task<Void, Never>?
    @State private var importError: ImportJournalError?

    private let importer = DayOneImporter()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .confirmationDialog("Import Journal", isPresented: $isPresented) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Day One Export (.zip)", systemImage: "doc.zipper")
                }
                Button("Cancel", role: .cancel) {}
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.zip],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .sheet(item: $pendingPlan) { plan in
                ImportJournalConfirmationView(
                    plan: plan,
                    confirm: { startImport(plan) },
                    cancel: { cancelPendingImport(plan) }
                )
                .interactiveDismissDisabled()
            }
            .sheet(isPresented: importSheetBinding) {
                ImportJournalProgressView(
                    isImporting: isImporting,
                    progress: progress,
                    summary: summary,
                    cancel: cancelRunningImport,
                    done: finishImport
                )
                .interactiveDismissDisabled(isImporting)
            }
            .alert(item: $importError) { error in
                Alert(
                    title: Text("Could Not Import Journal"),
                    message: Text(error.message),
                    dismissButton: .default(Text("OK"))
                )
            }
    }

    private var importSheetBinding: Binding<Bool> {
        Binding(
            get: { isImporting || summary != nil },
            set: { isShowing in
                guard !isShowing, !isImporting else { return }
                summary = nil
            }
        )
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                pendingPlan = try importer.prepareImport(from: url)
            } catch {
                importError = ImportJournalError(message: error.localizedDescription)
            }
        case .failure(let error):
            importError = ImportJournalError(message: error.localizedDescription)
        }
    }

    private func startImport(_ plan: DayOneImportPlan) {
        pendingPlan = nil
        progress = DayOneImportProgress(processedEntries: 0, totalEntries: plan.entryCount)
        summary = nil
        isImporting = true
        importTask = Task {
            let result = await importer.importPreparedArchive(plan, into: modelContext) { newProgress in
                progress = newProgress
            }
            summary = result
            isImporting = false
            importTask = nil
        }
    }

    private func cancelPendingImport(_ plan: DayOneImportPlan) {
        importer.deleteTemporaryArchive(plan)
        pendingPlan = nil
    }

    private func cancelRunningImport() {
        importTask?.cancel()
    }

    private func finishImport() {
        let didImportEntries = (summary?.importedEntries ?? 0) > 0
        summary = nil
        if didImportEntries {
            onFinished?()
        }
    }
}

private struct ImportJournalConfirmationView: View {
    let plan: DayOneImportPlan
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Entries", value: "\(plan.entryCount)")
                    LabeledContent("Photos", value: "\(plan.photoCount)")
                    LabeledContent("Skipped Media", value: "\(plan.unsupportedMediaCount)")
                } footer: {
                    Text("Ready to import this Day One export.")
                }
            }
            .navigationTitle("Import Day One")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: confirm)
                }
            }
        }
    }
}

private struct ImportJournalProgressView: View {
    let isImporting: Bool
    let progress: DayOneImportProgress
    let summary: DayOneImportSummary?
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if isImporting {
                    Section {
                        ProgressView(
                            value: Double(progress.processedEntries),
                            total: Double(max(progress.totalEntries, 1))
                        ) {
                            Text("Importing...")
                        } currentValueLabel: {
                            LabeledContent("Entries", value: "\(progress.processedEntries)/\(progress.totalEntries)")
                        }
                    }
                } else if let summary {
                    Section {
                        LabeledContent("Imported", value: "\(summary.importedEntries)")
                        LabeledContent("Skipped Duplicates", value: "\(summary.skippedDuplicates)")
                        LabeledContent("Failed Entries", value: "\(summary.failedEntries)")
                        LabeledContent("Skipped Media", value: "\(summary.skippedMedia)")
                    } footer: {
                        Text(summary.wasCancelled ? "Import was cancelled." : "Import finished.")
                    }
                }
            }
            .navigationTitle(isImporting ? "Importing..." : "Import Complete")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isImporting {
                        Button("Cancel", action: cancel)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !isImporting {
                        Button("Done", action: done)
                    }
                }
            }
        }
    }
}

private struct ImportJournalError: Identifiable {
    let id = UUID()
    let message: String
}
