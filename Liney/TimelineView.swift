import SwiftData
import UIKit

/// The journal's timeline: every entry in an entry list, with search, New Entry, and the More menu.
final class TimelineViewController: EntryListViewController, UISearchResultsUpdating {
    let appLock: AppLockModel
    private var searchTask: Task<Void, Never>?
    private let search = UISearchController(searchResultsController: nil)
    private var exportFlow: ExportJournalFlow?
    enum Mode { case list, calendar }
    private(set) var mode = Mode.list
    /// The Calendar View, made the first time Calendar is chosen.
    private(set) var calendarView: CalendarViewController?
    /// Where the list was scrolled when Calendar was chosen, restored once List is shown again.
    private var listOffset: CGPoint?
    private lazy var modeControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [String(localized: "List"), String(localized: "Calendar")])
        control.selectedSegmentIndex = 0
        control.addAction(UIAction { [unowned self] _ in
            self.setMode(self.modeControl.selectedSegmentIndex == 1 ? .calendar : .list)
        }, for: .valueChanged)
        return control
    }()

    /// Fixtures replace `saveContext` to simulate a full disk; editors opened here inherit it.
    init(container: ModelContainer, appLock: AppLockModel, storage: PhotoStorage = PhotoStorage(),
         editors: SceneEditors? = nil,
         saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.appLock = appLock
        super.init(container: container, storage: storage, editors: editors, saveContext: saveContext)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Journal")
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Entries")
        navigationItem.searchController = search
        navigationItem.titleView = modeControl
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
    }
    override var searchText: String { search.searchBar.text ?? "" }
    func updateSearchResults(for searchController: UISearchController) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            self?.refresh(reload: false)
        }
    }
    /// Swaps the column between the timeline and the Calendar View once the next refresh lands; Calendar has no search.
    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        modeControl.selectedSegmentIndex = mode == .calendar ? 1 : 0
        if mode == .calendar {
            search.isActive = false
            navigationItem.searchController = nil
            listOffset = tableView.contentOffset
            setContentScrollView((calendarView ?? embedCalendarView()).collectionView, for: .top)
        } else {
            navigationItem.searchController = search
            setContentScrollView(tableView, for: .top)
        }
        // The calendar covers the table, which must not scroll or answer the status bar tap underneath it.
        tableView.isScrollEnabled = mode == .list
        tableView.scrollsToTop = mode == .list
        refresh(reload: false)
    }
    /// The calendar fills the table's frame, over the column's own background.
    private func embedCalendarView() -> CalendarViewController {
        let calendarView = CalendarViewController(storage: storage)
        addChild(calendarView)
        calendarView.view.translatesAutoresizingMaskIntoConstraints = false
        calendarView.view.isHidden = true
        tableView.addSubview(calendarView.view)
        NSLayoutConstraint.activate([
            calendarView.view.leadingAnchor.constraint(equalTo: tableView.frameLayoutGuide.leadingAnchor),
            calendarView.view.trailingAnchor.constraint(equalTo: tableView.frameLayoutGuide.trailingAnchor),
            calendarView.view.topAnchor.constraint(equalTo: tableView.frameLayoutGuide.topAnchor),
            calendarView.view.bottomAnchor.constraint(equalTo: tableView.frameLayoutGuide.bottomAnchor)
        ])
        calendarView.didMove(toParent: self)
        self.calendarView = calendarView
        return calendarView
    }
    // Under the calendar the table lists nothing: system sidebar rows would draw through it.
    override var listsEntries: Bool { mode == .list }
    override func didRefresh(_ repository: TimelineRepository, isCurrent: @escaping () -> Bool) async throws {
        guard let calendarView else { return }
        guard mode == .calendar else {
            calendarView.view.isHidden = true
            if let offset = listOffset {
                listOffset = nil
                tableView.layoutIfNeeded()
                let maximum = max(tableView.contentSize.height + tableView.adjustedContentInset.bottom - tableView.bounds.height,
                                  -tableView.adjustedContentInset.top)
                tableView.setContentOffset(CGPoint(x: offset.x, y: min(offset.y, maximum)), animated: false)
            }
            return
        }
        let calendar = try await repository.monthCalendar()
        guard isCurrent(), mode == .calendar else { return }
        calendarView.apply(calendar)
        calendarView.view.isHidden = false
    }
    /// The timeline's rows and row actions limited to the entries of `day`'s calendar day.
    func dayList(for day: Date) -> EntryListViewController {
        EntryListViewController(container: container, storage: storage, editors: editors, saveContext: saveContext, day: day)
    }
    /// Reopens the entry this window had selected before relaunch, unless it was deleted or another window has it.
    func restoreEntry(_ id: UUID) {
        guard editors?.isOpenAnywhere(id) != true else { return }
        let context = ModelContext(container)
        guard let entry = try? context.entry(id: id) else { return }
        show(entry, in: context, animated: false)
        if root?.showsEntryColumn == true { selectRow(for: id) }
    }
    /// The New Entry action.
    private func createEntry() {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let entry = JournalEntry()
        context.insert(entry)
        let editor = EntryEditorViewController(entry: entry, isNew: true, context: context, storage: storage,
                                               editors: editors, saveContext: saveContext)
        if let root { root.showNewEntry(editor) } else { navigationController?.pushViewController(editor, animated: true) }
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

/// Entry rows grouped by day, with their row actions: open, swipe to delete with confirmation,
/// Open in New Window from the row menu, and row drag. Lists every day, or only `day`'s entries.
class EntryListViewController: UITableViewController {
    let container: ModelContainer
    /// The calendar day this list is limited to; nil lists every day.
    let day: Date?
    let storage: PhotoStorage
    let saveContext: (ModelContext) throws -> Void
    /// This scene's editors in the app-wide coordinator; fixtures without one skip the one-editor rule.
    let editors: SceneEditors?
    private var totalCount = 0
    private var entriesByID: [UUID: TimelineEntry] = [:]
    private lazy var dataSource = TimelineDataSource(tableView: tableView) { [unowned self] tableView, indexPath, id in
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry", for: indexPath) as! EntryCell
        if let entry = self.entriesByID[id] { cell.configure(entry, storage: self.storage) }
        return cell
    }
    private let repository: TimelineRepository
    private var loadTask: Task<Void, Never>?
    private var revision = 0

    init(container: ModelContainer, storage: PhotoStorage, editors: SceneEditors?,
         saveContext: @escaping (ModelContext) throws -> Void, day: Date? = nil) {
        self.container = container; self.day = day
        self.storage = storage; self.editors = editors; self.saveContext = saveContext
        repository = TimelineRepository(container: container)
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// The scene root; fixtures that mount the list in a bare stack have none.
    var root: JournalSplitViewController? { splitViewController as? JournalSplitViewController }
    /// The text rows are filtered by; only the timeline searches.
    var searchText: String { "" }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Beside an open entry its row stays selected; in one stack, returning from an entry clears it.
        if root?.showsEntryColumn != true, let selected = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: selected, animated: animated)
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        clearsSelectionOnViewWillAppear = false
        tableView.register(EntryCell.self, forCellReuseIdentifier: "entry")
        tableView.dataSource = dataSource
        tableView.dragDelegate = self
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: EntryListViewController, _: UITraitCollection) in
            var snapshot = controller.dataSource.snapshot()
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            controller.dataSource.apply(snapshot, animatingDifferences: false)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(journalChanged(_:)), name: .journalDidChange, object: nil)
        // Load once; every journal mutation posts journalDidChange, so returning here needs no refetch.
        reloadEntries()
    }
    func reloadEntries() { refresh(reload: true) }
    @objc private func journalChanged(_ notification: Notification) {
        refresh(reload: notification.object as? UUID == nil, changedID: notification.object as? UUID)
    }
    fileprivate func refresh(reload: Bool, changedID: UUID? = nil) {
        revision += 1
        let revision = revision
        // Do not cancel incremental updates; every saved entry must reach the snapshot.
        loadTask = Task { [weak self, repository] in
            do {
                if reload { try await repository.reload() }
                else if let changedID { try await repository.update(id: changedID) }
                guard let self, revision == self.revision else { return }
                let result = try await repository.search(self.searchText)
                guard revision == self.revision else { return }
                self.apply(result, animated: changedID != nil)
                try await self.didRefresh(repository) { [weak self] in revision == self?.revision }
            } catch is CancellationError { }
            catch { self?.showError(String(localized: "Could Not Load Journal"), message: error.localizedDescription) }
        }
    }
    /// Whether the table shows its rows; the timeline lists none while the Calendar View covers it.
    var listsEntries: Bool { true }
    /// Runs right after each refresh applies its rows; `isCurrent` turns false once a newer refresh starts.
    func didRefresh(_ repository: TimelineRepository, isCurrent: @escaping () -> Bool) async throws { }
    private func apply(_ result: TimelineResult, animated: Bool) {
        let days = day.map { day in result.days.filter { Calendar.current.isDate($0.date, inSameDayAs: day) } } ?? result.days
        let previous = entriesByID
        totalCount = result.totalCount
        entriesByID = Dictionary(days.flatMap(\.entries).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<Date, UUID>()
        for day in days where listsEntries {
            snapshot.appendSections([day.date])
            snapshot.appendItems(day.entries.map(\.id), toSection: day.date)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { previous[$0].map { $0 != entriesByID[$0.id] } ?? false })
        dataSource.apply(snapshot, animatingDifferences: animated)
        // A restored entry opens before its row is listed; beside the list, its row is selected once listed.
        if root?.showsEntryColumn == true, tableView.indexPathForSelectedRow == nil, let open = root?.openEditor {
            selectRow(for: open.entry.id)
        }
        if days.isEmpty, listsEntries {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "book.closed")
            configuration.text = totalCount == 0 || day != nil ? String(localized: "No Entries") : String(localized: "No Results")
            configuration.secondaryText = day != nil ? nil : totalCount == 0 ? String(localized: "Start writing, or import an existing journal.") : searchText
            contentUnavailableConfiguration = configuration
        } else { contentUnavailableConfiguration = nil }
    }
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete Entry")) { [weak self] _, _, completion in
            // Close the swipe without removing the row before confirmation and persistence.
            completion(false)
            self?.confirmDeleteEntry(id: id)
        }
        delete.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [delete])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
    func confirmDeleteEntry(id: UUID) {
        if let editor = root?.openEditor, editor.entry.id == id {
            editor.confirmDeleteEntry()
            return
        }
        confirmDeletion(title: String(localized: "Delete Entry"), message: String(localized: "This entry and its photos will be permanently deleted.")) { [weak self] in
            self?.deleteEntry(id: id)
        }
    }
    func deleteEntry(id: UUID) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            guard let entry = try context.entry(id: id) else { reloadEntries(); return }
            let files = try deleteEntryAndSave(entry, in: context) { [saveContext] in try saveContext(context) }
            NotificationCenter.default.post(name: .journalDidChange, object: id)
            editors?.entryDeleted(id)
            var cleanupFailed = false
            for file in files {
                do { try storage.delete(fileName: file) } catch { cleanupFailed = true }
            }
            if cleanupFailed {
                showError(String(localized: "Photo File Couldn’t Be Deleted"), message: String(localized: "Some photo files could not be deleted from storage."))
            }
        } catch {
            showError(String(localized: "Could Not Save Entry"), message: writeFailureMessage(for: error, otherwise: String(localized: "Your changes could not be saved. Please try again.")))
        }
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        // An entry edited in another window is edited there; this window keeps what it shows.
        if editors?.activateOtherScene(editing: id) == true {
            selectRow(for: root?.openEditor?.entry.id)
            return
        }
        if let editor = root?.openEditor, !editor.prepareForReplacement() { return }
        guard let entry = entriesByID[id] else { return }
        let context = ModelContext(container)
        guard let editable = context.model(for: entry.persistentModelID) as? JournalEntry else { return }
        show(editable, in: context)
    }
    fileprivate func show(_ entry: JournalEntry, in context: ModelContext, animated: Bool = true) {
        let editor = EntryEditorViewController(entry: entry, isNew: false, context: context, storage: storage,
                                               editors: editors, saveContext: saveContext)
        if let root { root.showEntry(editor, animated: animated) } else { navigationController?.pushViewController(editor, animated: animated) }
    }
    /// Marks the row of the entry open beside the list; nil, or an entry not yet listed, selects nothing.
    func selectRow(for id: UUID?) {
        tableView.selectRow(at: id.flatMap { dataSource.indexPath(for: $0) }, animated: false, scrollPosition: .none)
    }
    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = rowMenu(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
    /// A row's menu: only Open in New Window, which the system hides where new windows are unavailable.
    func rowMenu(at indexPath: IndexPath) -> UIMenu? {
        guard let editors, let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        // A nil title is the system's Open in New Window; with no alternate, it hides where windows are unavailable.
        return UIMenu(children: [UIWindowScene.ActivationAction(alternate: nil) { [weak self] _ in
            guard let activity = editors.newWindowActivity(for: id) else { return nil }
            let options = UIWindowScene.ActivationRequestOptions()
            options.requestingScene = self?.view.window?.windowScene
            return UIWindowScene.ActivationConfiguration(userActivity: activity, options: options)
        }])
    }
}

extension EntryListViewController: UITableViewDragDelegate {
    /// Dragging a row out creates a window for that entry; the system creates none where new windows are unavailable.
    func tableView(_ tableView: UITableView, itemsForBeginning session: any UIDragSession,
                   at indexPath: IndexPath) -> [UIDragItem] {
        guard editors != nil, let id = dataSource.itemIdentifier(for: indexPath) else { return [] }
        return [UIDragItem(itemProvider: NSItemProvider(object: WindowRestoration.entryWindow(id).activity))]
    }
}

private final class TimelineDataSource: UITableViewDiffableDataSource<Date, UUID> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
    // Diffable data sources disable editing by default, which would hide the swipe Delete action.
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { true }
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
    func configure(_ entry: TimelineEntry, storage: PhotoStorage) {
        heading.text = entry.rowTitle; subtitle.text = entry.rowSubtitle
        subtitle.isHidden = entry.rowSubtitle == nil
        heading.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 3 : 1
        subtitle.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 4 : 2
        let previews = entry.previewFiles
        photos.isHidden = previews.isEmpty
        for (index, image) in thumbnails.enumerated() {
            image.cancel(); image.isHidden = index >= previews.count
            if index < previews.count { image.load(previews[index], storage: storage, pixels: 160) }
        }
        photos.isAccessibilityElement = true
        photos.accessibilityLabel = String(localized: "Entry Photos")
        photos.accessibilityValue = String(entry.photoCount)
    }
    override func prepareForReuse() { super.prepareForReuse(); thumbnails.forEach { $0.cancel() } }
}
