import SwiftData
import UIKit
import UniformTypeIdentifiers

final class ImportJournalViewController: UITableViewController, UIDocumentPickerDelegate {
    private let context: ModelContext
    private let importer = DayOneImporter()
    private var plan: DayOneImportPlan?
    private var summary: DayOneImportSummary?
    private var task: Task<Void, Never>?
    private var busy = false
    private var progress = DayOneImportProgress(processedEntries: 0, totalEntries: 0)
    private struct Row {
        let text: String
        var value: String? = nil
    }
    private var rows: [Row] = []
    private var footer: String?
    private let onFinished: (() -> Void)?

    init(container: ModelContainer, plan: DayOneImportPlan? = nil, summary: DayOneImportSummary? = nil, onFinished: (() -> Void)? = nil) {
        context = ModelContext(container); context.autosaveEnabled = false
        self.onFinished = onFinished
        self.plan = plan; self.summary = summary
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.sectionFooterHeight = UITableView.automaticDimension
        tableView.estimatedSectionFooterHeight = 240
        NotificationCenter.default.addObserver(self, selector: #selector(cancelInBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: ImportJournalViewController, _: UITraitCollection) in
            controller.tableView.reloadData()
        }
        render()
    }
    @objc private func cancelInBackground() { task?.cancel() }
    private var scope: [String] { [
        String(localized: "Text, photos, entry dates and available locations are imported into one timeline. Leading titles and checklist states are preserved; other formatting becomes plain text. Photos are saved as compressed JPEGs up to 2400 pixels on the long edge."),
        String(localized: "Videos, audio, PDFs, other attachments, tags, weather and other Day One metadata are not kept. Original journal divisions are not kept. Timed entries use your device’s time zone."),
        String(localized: "Keep Liney open during import. Cancelling keeps saved entries. Import the zip again to continue or recover failed photos; existing text and edits are kept. Older imports without recovery information are skipped.")
    ] }
    private func render() {
        navigationController?.isModalInPresentation = busy
        title = String(localized: "Import from Day One")
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: String(localized: "Cancel"), primaryAction: UIAction { [weak self] _ in self?.cancel() })
        navigationItem.rightBarButtonItem = nil
        footer = nil
        if busy {
            rows = [progress.totalEntries == 0 ? String(localized: "Preparing Archive…") : String(localized: "Importing..."),
                    "\(progress.processedEntries)/\(progress.totalEntries)", String(localized: "Keep Liney open. Cancelling keeps saved entries.")].map { Row(text: $0) }
        } else if let summary {
            title = summary.wasCancelled ? String(localized: "Import Cancelled") : (summary.failedEntries > 0 || summary.failedPhotos > 0 ? String(localized: "Import Needs Review") : String(localized: "Import Complete"))
            rows = Self.summaryRows(summary).map { Row(text: $0) }
            navigationItem.leftBarButtonItem = nil
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: String(localized: "Done"), primaryAction: UIAction { [weak self] _ in self?.finish() })
        } else if let plan {
            rows = [Row(text: String(localized: "Entries"), value: plan.entryCount.formatted()),
                    Row(text: String(localized: "Photos"), value: plan.photoCount.formatted()),
                    Row(text: String(localized: "Unsupported Media"), value: plan.unsupportedMediaCount.formatted()),
                    Row(text: String(localized: "Unsupported Metadata"), value: plan.ignoredMetadataCount.formatted())]
            footer = scope.joined(separator: "\n\n")
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: String(localized: "Import"), primaryAction: UIAction { [weak self] _ in self?.startImport() })
        } else {
            rows = ([String(localized: "In Day One, open Settings → Import/Export, choose JSON, and include media. On Mac, choose File → Export → JSON. Select the exported zip here."),
                    String(localized: "Automatic backups may omit photos. Keep the original export until you have checked the imported entries.")] + scope + [String(localized: "Choose JSON Zip")]).map { Row(text: $0) }
        }
        tableView.reloadData()
    }
    static func summaryRows(_ summary: DayOneImportSummary) -> [String] {
        var rows = [
            "\(String(localized: "Imported")): \(summary.importedEntries)",
            "\(String(localized: "Repaired Entries")): \(summary.repairedEntries)",
            "\(String(localized: "Recovered Photos")): \(summary.recoveredPhotos)",
            "\(String(localized: "Skipped Duplicates")): \(summary.skippedDuplicates)",
            "\(String(localized: "Failed Entries")): \(summary.failedEntries)",
            "\(String(localized: "Failed Photos")): \(summary.failedPhotos)",
            "\(String(localized: "Unsupported Media")): \(summary.skippedMedia)",
            "\(String(localized: "Unsupported Metadata")): \(summary.ignoredMetadata)"
        ]
        for issue in summary.issues {
            rows.append([issue.entryNumber > 0 ? String(localized: "Entry \(issue.entryNumber)") : nil,
                         issue.entryDate?.formatted(), issue.sourceID.map { String(localized: "Day One ID") + ": " + $0 },
                         String(localized: String.LocalizationValue(issue.reason.message))].compactMap { $0 }.joined(separator: "\n"))
        }
        if summary.failedPhotos > 0 || summary.wasCancelled { rows.append(String(localized: "Export again with media included, then import the zip to retry. Existing entries and your edits are kept.")) }
        return rows
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row") ?? UITableViewCell(style: .default, reuseIdentifier: "row")
        let row = rows[indexPath.row]
        var config = row.value == nil ? cell.defaultContentConfiguration() : UIListContentConfiguration.valueCell()
        config.text = row.text
        config.secondaryText = row.value
        config.textProperties.numberOfLines = 0
        config.secondaryTextProperties.numberOfLines = 0
        config.prefersSideBySideTextAndSecondaryText = !traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let isChoose = !busy && plan == nil && summary == nil && indexPath.row == rows.count - 1
        config.textProperties.color = isChoose ? view.tintColor : .label
        cell.contentConfiguration = config; cell.selectionStyle = isChoose ? .default : .none
        cell.accessibilityTraits = isChoose ? .button : .staticText
        return cell
    }
    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard let footer else { return nil }
        let view = tableView.dequeueReusableHeaderFooterView(withIdentifier: "notes")
            ?? UITableViewHeaderFooterView(reuseIdentifier: "notes")
        var config = UIListContentConfiguration.groupedFooter()
        config.text = footer
        config.textProperties.color = .secondaryLabel
        config.textProperties.numberOfLines = 0
        view.contentConfiguration = config
        return view
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !busy, plan == nil, summary == nil, indexPath.row == rows.count - 1 else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.zip], asCopy: false)
        picker.delegate = self
        present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        busy = true; render()
        task = Task {
            do { plan = try await importer.prepareImportInBackground(from: url) }
            catch is CancellationError { }
            catch { showError(String(localized: "Could Not Import Journal"), message: error.localizedDescription) }
            busy = false; task = nil; render()
        }
    }
    private func startImport() {
        guard let plan else { return }
        self.plan = nil; busy = true
        progress = DayOneImportProgress(processedEntries: 0, totalEntries: plan.entryCount)
        render()
        task = Task {
            summary = await importer.importPreparedArchive(plan, into: context) { [weak self] value in
                self?.progress = value; self?.render()
            }
            busy = false; task = nil
            NotificationCenter.default.post(name: .journalDidChange, object: nil)
            render()
        }
    }
    private func cancel() {
        if busy { task?.cancel(); return }
        if let plan { importer.deleteTemporaryArchive(plan); self.plan = nil }
        dismiss(animated: true)
    }
    private func finish() {
        let imported = (summary?.importedEntries ?? 0) + (summary?.repairedEntries ?? 0) > 0
        dismiss(animated: true) { [onFinished] in if imported { onFinished?() } }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.presentingViewController == nil, !busy, let plan {
            importer.deleteTemporaryArchive(plan); self.plan = nil
        }
    }
}
