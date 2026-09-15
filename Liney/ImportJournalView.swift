import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ImportJournalFlow: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Binding var isPresented: Bool
    var onFinished: (() -> Void)?

    @State private var showFileImporter = false
    @State private var showImportSheet = false
    @State private var pendingPlan: DayOneImportPlan?
    @State private var progress = DayOneImportProgress(processedEntries: 0, totalEntries: 0)
    @State private var summary: DayOneImportSummary?
    @State private var isPreparing = false
    @State private var isImporting = false
    @State private var importTask: Task<Void, Never>?
    @State private var importError: ImportJournalError?

    private let importer = DayOneImporter()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: isPresented) { _, isPresented in
                if isPresented { showImportSheet = true }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { importTask?.cancel() }
            }
            .sheet(isPresented: $showImportSheet, onDismiss: reset) {
                Group {
                    if isPreparing {
                        NavigationStack {
                            ProgressView("Preparing Archive…")
                                .navigationTitle("Import from Day One")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("Cancel") { importTask?.cancel() }
                                    }
                                }
                        }
                    } else if let pendingPlan {
                        ImportJournalConfirmationView(plan: pendingPlan,
                            confirm: { startImport(pendingPlan) }, cancel: { showImportSheet = false })
                    } else if isImporting || summary != nil {
                        ImportJournalProgressView(isImporting: isImporting, progress: progress,
                            summary: summary, cancel: { importTask?.cancel() }, done: finishImport)
                    } else {
                        NavigationStack {
                            List {
                                Section {
                                    Text("In Day One, open Settings → Import/Export, choose JSON, and include media. On Mac, choose File → Export → JSON. Select the exported zip here.")
                                    Text("Automatic backups may omit photos. Keep the original export until you have checked the imported entries.")
                                }
                                ImportScopeSection()
                                Section {
                                    Button("Choose JSON Zip") { showFileImporter = true }
                                }
                            }
                            .navigationTitle("Import from Day One")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Cancel") { showImportSheet = false }
                                }
                            }
                        }
                    }
                }
                .interactiveDismissDisabled(isPreparing || isImporting)
                .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.zip],
                              allowsMultipleSelection: false, onCompletion: handleFileImport)
                .alert(item: $importError) { error in
                    Alert(title: Text("Could Not Import Journal"), message: Text(error.message),
                          dismissButton: .default(Text("OK")))
                }
            }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isPreparing = true
            importTask = Task {
                do {
                    pendingPlan = try await importer.prepareImportInBackground(from: url)
                } catch is CancellationError {
                    pendingPlan = nil
                } catch {
                    importError = ImportJournalError(message: error.localizedDescription)
                }
                isPreparing = false
                importTask = nil
            }
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                importError = ImportJournalError(message: error.localizedDescription)
            }
        }
    }

    private func startImport(_ plan: DayOneImportPlan) {
        pendingPlan = nil
        progress = DayOneImportProgress(processedEntries: 0, totalEntries: plan.entryCount)
        summary = nil
        isImporting = true
        importTask = Task {
            summary = await importer.importPreparedArchive(plan, into: modelContext) { progress = $0 }
            isImporting = false
            importTask = nil
        }
    }

    private func reset() {
        importTask?.cancel()
        if let pendingPlan { importer.deleteTemporaryArchive(pendingPlan) }
        pendingPlan = nil
        summary = nil
        isPresented = false
    }

    private func finishImport() {
        let didImport = (summary?.importedEntries ?? 0) + (summary?.repairedEntries ?? 0) > 0
        showImportSheet = false
        if didImport { onFinished?() }
    }
}

private struct ImportScopeSection: View {
    var body: some View {
        Section("What Will Be Imported") {
            Text("Text, photos, entry dates and available locations are imported into one timeline. Formatting becomes plain text. Photos are saved as compressed JPEGs up to 2400 pixels on the long edge.")
            Text("Videos, audio, PDFs, other attachments, tags, weather and other Day One metadata are not kept. Original journal divisions are not kept. Timed entries use your device’s time zone.")
            Text("Keep Liney open during import. Cancelling keeps saved entries. Import the zip again to continue or recover failed photos; existing text and edits are kept. Older imports without recovery information are skipped.")
        }
    }
}

struct ImportJournalConfirmationView: View {
    let plan: DayOneImportPlan
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Entries", value: "\(plan.entryCount)")
                    LabeledContent("Photos", value: "\(plan.photoCount)")
                    LabeledContent("Unsupported Media", value: "\(plan.unsupportedMediaCount)")
                    LabeledContent("Unsupported Metadata", value: "\(plan.ignoredMetadataCount)")
                }
                ImportScopeSection()
            }
            .navigationTitle("Import from Day One")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Import", action: confirm) }
            }
        }
    }
}

struct ImportJournalProgressView: View {
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
                        ProgressView(value: Double(progress.processedEntries), total: Double(max(progress.totalEntries, 1))) {
                            Text("Importing...")
                        } currentValueLabel: {
                            LabeledContent("Entries", value: "\(progress.processedEntries)/\(progress.totalEntries)")
                        }
                        Text("Keep Liney open. Cancelling keeps saved entries.")
                    }
                } else if let summary {
                    if summary.failedEntries > 0 || summary.failedPhotos > 0 {
                        Section {
                            Text("Import Needs Review").font(.headline).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if summary.wasCancelled {
                        Section {
                            Text("Import Cancelled").font(.headline).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Section {
                        LabeledContent("Imported", value: "\(summary.importedEntries)")
                        LabeledContent("Repaired Entries", value: "\(summary.repairedEntries)")
                        LabeledContent("Recovered Photos", value: "\(summary.recoveredPhotos)")
                        LabeledContent("Skipped Duplicates", value: "\(summary.skippedDuplicates)")
                        LabeledContent("Failed Entries", value: "\(summary.failedEntries)")
                        LabeledContent("Failed Photos", value: "\(summary.failedPhotos)")
                        LabeledContent("Unsupported Media", value: "\(summary.skippedMedia)")
                        LabeledContent("Unsupported Metadata", value: "\(summary.ignoredMetadata)")
                    }
                    if !summary.issues.isEmpty {
                        Section("Entries to Check") {
                            ForEach(summary.issues) { issue in
                                VStack(alignment: .leading, spacing: 6) {
                                    if issue.entryNumber > 0 {
                                        Text("Entry \(issue.entryNumber)").font(.headline)
                                    }
                                    if let date = issue.entryDate { Text(date, format: .dateTime).font(.subheadline) }
                                    if let sourceID = issue.sourceID {
                                        LabeledContent("Day One ID", value: sourceID).textSelection(.enabled)
                                    }
                                    Text(LocalizedStringKey(issue.reason.message)).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if summary.failedPhotos > 0 || summary.wasCancelled {
                        Section {
                            Text("Export again with media included, then import the zip to retry. Existing entries and your edits are kept.")
                        }
                    }
                }
            }
            .navigationTitle(isImporting ? "Importing..." : (summary?.wasCancelled == true ? "Import Cancelled" :
                ((summary?.failedEntries ?? 0) > 0 || (summary?.failedPhotos ?? 0) > 0 ? "Import Needs Review" : "Import Complete")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isImporting { Button("Cancel", action: cancel) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !isImporting { Button("Done", action: done) }
                }
            }
        }
    }
}

private struct ImportJournalError: Identifiable {
    let id = UUID()
    let message: String
}
