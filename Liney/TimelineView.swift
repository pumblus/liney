import SwiftData
import UIKit

final class TimelineViewController: UITableViewController, UISearchResultsUpdating {
    let container: ModelContainer
    let appLock: AppLockModel
    private var totalCount = 0
    private var groups: [TimelineDay] = []
    private let repository: TimelineRepository
    private var loadTask: Task<Void, Never>?
    private var revision = 0
    private var searchTask: Task<Void, Never>?
    private let search = UISearchController(searchResultsController: nil)
    private var exportFlow: ExportJournalFlow?

    init(container: ModelContainer, appLock: AppLockModel) {
        self.container = container; self.appLock = appLock
        repository = TimelineRepository(container: container)
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Journal")
        tableView.register(EntryCell.self, forCellReuseIdentifier: "entry")
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: TimelineViewController, _: UITraitCollection) in
            controller.tableView.reloadData()
        }
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Entries")
        navigationItem.searchController = search
        let new = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), primaryAction: UIAction { [weak self] _ in self?.createEntry() })
        new.accessibilityLabel = String(localized: "New Entry")
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: nil)
        more.menu = UIMenu(children: [
            UIAction(title: String(localized: "Import Journal"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in self?.importJournal() },
            UIAction(title: String(localized: "Export Journal"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self, weak more] _ in self?.exportJournal(sourceBarButtonItem: more) },
            UIAction(title: String(localized: "Settings"), image: UIImage(systemName: "gearshape")) { [weak self] _ in
                guard let self else { return }
                self.navigationController?.pushViewController(SettingsViewController(appLock: self.appLock), animated: true)
            }
        ])
        more.accessibilityLabel = String(localized: "More")
        navigationItem.rightBarButtonItems = [more, new]
        NotificationCenter.default.addObserver(self, selector: #selector(journalChanged(_:)), name: .journalDidChange, object: nil)
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reloadEntries() }
    func reloadEntries() { refresh(reload: true) }
    @objc private func journalChanged(_ notification: Notification) {
        refresh(reload: notification.object as? UUID == nil, changedID: notification.object as? UUID)
    }
    private func refresh(reload: Bool, changedID: UUID? = nil) {
        revision += 1
        let revision = revision
        // Do not cancel incremental updates; every saved entry must reach the snapshot.
        loadTask = Task { [weak self, repository] in
            do {
                if reload { try await repository.reload() }
                else if let changedID { try await repository.update(id: changedID) }
                guard let self, revision == self.revision else { return }
                let result = try await repository.search(self.search.searchBar.text ?? "")
                guard revision == self.revision else { return }
                self.apply(result)
            } catch is CancellationError { }
            catch { self?.showError(String(localized: "Could Not Load Journal"), message: error.localizedDescription) }
        }
    }
    func updateSearchResults(for searchController: UISearchController) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            self?.refresh(reload: false)
        }
    }
    private func apply(_ result: TimelineResult) {
        totalCount = result.totalCount; groups = result.days
        tableView.reloadData()
        if groups.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "book.closed")
            configuration.text = totalCount == 0 ? String(localized: "No Entries") : String(localized: "No Results")
            configuration.secondaryText = totalCount == 0 ? String(localized: "Start your private journal or import an existing journal.") : search.searchBar.text
            contentUnavailableConfiguration = configuration
        } else { contentUnavailableConfiguration = nil }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { groups[section].entries.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        groups[section].date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry", for: indexPath) as! EntryCell
        cell.configure(groups[indexPath.section].entries[indexPath.row])
        return cell
    }
    override func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? EntryCell)?.cancelImages()
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if let detail = splitViewController?.viewController(for: .secondary) as? UINavigationController,
           let editor = detail.topViewController as? EntryEditorViewController, !editor.prepareForReplacement() { return }
        let entry = groups[indexPath.section].entries[indexPath.row]
        let context = ModelContext(container)
        guard let editable = context.model(for: entry.persistentModelID) as? JournalEntry else { return }
        let editor = EntryEditorViewController(entry: editable, isNew: false, context: context)
        if let splitViewController, !splitViewController.isCollapsed {
            splitViewController.setViewController(UINavigationController(rootViewController: editor), for: .secondary)
            splitViewController.show(.secondary)
        } else { navigationController?.pushViewController(editor, animated: true) }
    }
    private func createEntry() {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let entry = JournalEntry()
        context.insert(entry)
        let editor = EntryEditorViewController(entry: entry, isNew: true, context: context)
        let navigation = UINavigationController(rootViewController: editor)
        navigation.isModalInPresentation = true
        present(navigation, animated: true)
    }
    private func importJournal() {
        present(UINavigationController(rootViewController: ImportJournalViewController(container: container)), animated: true)
    }
    private func exportJournal(sourceBarButtonItem: UIBarButtonItem?) {
        guard exportFlow == nil else { return }
        let flow = ExportJournalFlow(presenter: self, container: container, appLock: appLock,
                                     sourceBarButtonItem: sourceBarButtonItem)
        exportFlow = flow
        flow.onFinished = { [weak self] in self?.exportFlow = nil }
        flow.start()
    }
}

private final class EntryCell: UITableViewCell {
    private let heading = bodyLabel("", style: .headline)
    private let subtitle = bodyLabel("", style: .subheadline)
    private let photos = UIStackView()
    private var thumbnails: [StoredPhotoView] = []
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        let stack = UIStackView(arrangedSubviews: [heading, subtitle, photos])
        stack.axis = .vertical; stack.spacing = 8
        photos.spacing = 6; photos.alignment = .leading
        subtitle.textColor = .secondaryLabel
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
        ])
        for _ in 0..<3 {
            let image = StoredPhotoView()
            image.widthAnchor.constraint(equalToConstant: 48).isActive = true
            image.heightAnchor.constraint(equalToConstant: 48).isActive = true
            photos.addArrangedSubview(image); thumbnails.append(image)
        }
        photos.addArrangedSubview(UIView())
        accessoryType = .disclosureIndicator
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ entry: TimelineEntry) {
        heading.text = entry.rowTitle; subtitle.text = entry.rowSubtitle
        subtitle.isHidden = entry.rowSubtitle == nil
        heading.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 3 : 1
        subtitle.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 4 : 2
        let previews = entry.previewFiles
        photos.isHidden = previews.isEmpty
        for (index, image) in thumbnails.enumerated() {
            image.cancel(); image.isHidden = index >= previews.count
            if index < previews.count { image.load(previews[index], pixels: 160) }
        }
        photos.isAccessibilityElement = true
        photos.accessibilityLabel = String(localized: "Entry Photos")
        photos.accessibilityValue = String(entry.photoCount)
    }
    func cancelImages() { thumbnails.forEach { $0.cancel() } }
    override func prepareForReuse() { super.prepareForReuse(); cancelImages() }
}
