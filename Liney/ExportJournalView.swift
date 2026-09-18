import SwiftData
import UIKit

@MainActor
final class ExportJournalFlow {
    private weak var presenter: UIViewController?
    private let container: ModelContainer
    private let appLock: AppLockModel
    private let exporter = JournalExporter()
    private var task: Task<Void, Never>?
    var onFinished: (() -> Void)?
    init(presenter: UIViewController, container: ModelContainer, appLock: AppLockModel) {
        self.presenter = presenter; self.container = container; self.appLock = appLock
    }
    func start() {
        guard task == nil else { return }
        task = Task { [self] in
            guard await appLock.authenticateForExport(requiresLock: UserDefaults.standard.bool(forKey: "liney.requiresAppLock")),
                  let presenter else { onFinished?(); return }
            let progress = MessageController(title: String(localized: "Export Journal"), message: String(localized: "Preparing Export"))
            progress.isModalInPresentation = true
            presenter.present(progress, animated: true)
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
                    let activity = UIActivityViewController(activityItems: [export.url], applicationActivities: nil)
                    activity.popoverPresentationController?.sourceView = presenter.view
                    activity.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
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
