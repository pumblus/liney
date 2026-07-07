import SwiftUI
import UIKit

struct ExportJournalFlow: View {
    @Binding var isPresented: Bool
    let entries: [JournalEntry]

    @State private var presentation: ExportJournalPresentation?
    @State private var activeExport: JournalExport?
    @State private var exportError: ExportJournalAlert?
    @State private var exportTask: Task<Void, Never>?

    private let exporter = JournalExporter()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: isPresented) { _, isPresented in
                if isPresented {
                    startExport()
                }
            }
            .sheet(isPresented: exportSheetBinding) {
                switch presentation {
                case .preparing:
                    ExportPreparingView()
                        .interactiveDismissDisabled()
                case .sharing(let export):
                    ActivityViewController(activityItems: [export.url]) {
                        completeSharing(export)
                    }
                case nil:
                    EmptyView()
                }
            }
            .alert(item: $exportError) { error in
                Alert(
                    title: Text("Could Not Export Journal"),
                    message: Text(error.message),
                    dismissButton: .default(Text("OK"))
                )
            }
    }

    private var exportSheetBinding: Binding<Bool> {
        Binding(
            get: { presentation != nil },
            set: { isShowing in
                guard !isShowing else { return }
                finishExport()
            }
        )
    }

    @MainActor
    private func startExport() {
        guard exportTask == nil else { return }

        let exportEntries = entries
        presentation = .preparing
        exportTask = Task {
            defer { exportTask = nil }

            do {
                await Task.yield()
                let export = try exporter.export(entries: exportEntries)
                guard !Task.isCancelled else {
                    exporter.deleteExport(export)
                    return
                }

                activeExport = export
                presentation = .sharing(export)
            } catch {
                guard !Task.isCancelled else { return }
                presentation = nil
                isPresented = false
                exportError = ExportJournalAlert(message: error.localizedDescription)
            }
        }
    }

    private func completeSharing(_ export: JournalExport) {
        cleanup(export)
        presentation = nil
        isPresented = false
    }

    private func finishExport() {
        exportTask?.cancel()
        exportTask = nil
        if let activeExport {
            cleanup(activeExport)
        }
        isPresented = false
    }

    private func cleanup(_ export: JournalExport) {
        exporter.deleteExport(export)
        if activeExport?.id == export.id {
            activeExport = nil
        }
    }
}

private enum ExportJournalPresentation {
    case preparing
    case sharing(JournalExport)
}

private struct ExportPreparingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Preparing Export")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding()
    }
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    let completion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async {
                completion()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ExportJournalAlert: Identifiable {
    let id = UUID()
    let message: String
}
