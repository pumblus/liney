import SwiftData
import UIKit

@MainActor
final class ExportJournalFlow {
    private weak var presenter: UIViewController?
    private let container: ModelContainer
    private let appLock: AppLockModel
    private let exporter = JournalExporter()
    private let sourceBarButtonItem: UIBarButtonItem?
    private var task: Task<Void, Never>?
    var onFinished: (() -> Void)?
    init(presenter: UIViewController, container: ModelContainer, appLock: AppLockModel,
         sourceBarButtonItem: UIBarButtonItem? = nil) {
        self.presenter = presenter; self.container = container; self.appLock = appLock
        self.sourceBarButtonItem = sourceBarButtonItem
    }

    func makeShareController(for url: URL) -> UIActivityViewController {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let sourceBarButtonItem {
            activity.popoverPresentationController?.barButtonItem = sourceBarButtonItem
        } else if let presenter {
            activity.popoverPresentationController?.sourceView = presenter.view
            activity.popoverPresentationController?.sourceRect = CGRect(
                x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1
            )
        }
        return activity
    }
    func start() {
        guard task == nil else { return }
        task = Task { [self] in
            guard await appLock.authenticateForExport(requiresLock: UserDefaults.standard.bool(forKey: "liney.requiresAppLock")),
                  let presenter else { onFinished?(); return }
            let progress = ProcessingViewController(title: String(localized: "Export Journal"), message: String(localized: "Preparing Export"))
            // Even a tiny export must not dismiss a sheet that is still being presented.
            await withCheckedContinuation { continuation in
                presenter.present(progress, animated: true) { continuation.resume() }
            }
            do {
                let container = self.container
                let exporter = self.exporter
                let export = try await Task.detached(priority: .userInitiated) {
                    let context = ModelContext(container)
                    let entries = try context.fetch(FetchDescriptor<JournalEntry>(sortBy: [SortDescriptor(\.entryDate, order: .reverse)]))
                    return try exporter.export(entries: entries.map(JournalExportEntry.init))
                }.value
                progress.dismiss(animated: true) { [weak self, weak presenter] in
                    guard let self, let presenter else { exporter.deleteExport(export); return }
                    let activity = self.makeShareController(for: export.url)
                    activity.completionWithItemsHandler = { [weak self] _, _, _, _ in
                        exporter.deleteExport(export)
                        Task { @MainActor in self?.onFinished?() }
                    }
                    presenter.present(activity, animated: true)
                }
            } catch {
                progress.dismiss(animated: true) { [weak self, weak presenter] in
                    presenter?.showError(String(localized: "Could Not Export Journal"), message: error.localizedDescription)
                    self?.onFinished?()
                }
            }
        }
    }
}
