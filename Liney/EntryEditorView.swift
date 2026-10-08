import PhotosUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

/// Owns one editing context; failed photo mutations cannot roll back another screen's work.
final class EntryEditorViewController: UIViewController, UITextViewDelegate, PHPickerViewControllerDelegate, UIScrollViewDelegate {
    let entry: JournalEntry
    let context: ModelContext
    let isNew: Bool
    private let storage: PhotoStorage
    private let saveContext: (ModelContext) throws -> Void
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let titleField = EntryTitleView()
    private var dateButton: UIButton!
    private let placeLabel = bodyLabel("", style: .footnote)
    private var textViews: [BlockTextView] = []
    private var photoGroups: [PhotoGroupView] = []
    private weak var focusedText: BlockTextView?
    private var saveTask: Task<Void, Never>?
    private var addingPhotos = false
    private var finished = false
    private var insertButton: UIBarButtonItem!
    private var doneButton: UIBarButtonItem!
    private var pendingBlockID: UUID?
    private var pendingOffset: Int?
    private var foldAvoidance: EditorFoldAvoidance?
    /// Set while a resize moves this editor to another column, until it appears there; the move
    /// is not leaving the entry, so it never saves or discards.
    private var columnMove: ColumnMove?
    private struct ColumnMove {
        let focus: UITextView?
        let selection: NSRange
        /// The editor can finish an earlier appearance before it leaves its old column.
        var hasLeft = false
    }

    /// Fixtures replace `saveContext` to simulate a full disk.
    init(entry: JournalEntry, isNew: Bool, context: ModelContext, storage: PhotoStorage = PhotoStorage(),
         saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.entry = entry; self.isNew = isNew; self.context = context
        self.storage = storage; self.saveContext = saveContext
        context.autosaveEnabled = false
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        scroll.keyboardDismissMode = .interactive
        scroll.delegate = self
        stack.axis = .vertical; stack.spacing = 16
        scroll.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        // One centred reading column: 16 pt margins until it reaches 700 pt. The system readable
        // width is far narrower, which wastes wide windows such as iPhone Duo in laptop pose.
        let column = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)
        column.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerXAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor, constant: -40),
            stack.widthAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 700), column
        ])
        titleField.accessibilityLabel = String(localized: "Title (optional)")
        titleField.font = .preferredFont(forTextStyle: .title2)
        titleField.adjustsFontForContentSizeCategory = true
        titleField.delegate = self
        insertButton = UIBarButtonItem(image: UIImage(systemName: "photo.on.rectangle"), primaryAction: UIAction { [weak self] _ in self?.pickPhotos() })
        insertButton.accessibilityLabel = String(localized: "Insert Photos")
        doneButton = UIBarButtonItem(title: String(localized: "Done"), primaryAction: UIAction { [weak self] _ in self?.finish() })
        let delete = UIBarButtonItem(image: UIImage(systemName: "trash"), primaryAction: UIAction { [weak self] _ in self?.confirmDeleteEntry() })
        delete.accessibilityLabel = String(localized: "Delete Entry")
        navigationItem.rightBarButtonItems = [doneButton, insertButton, delete]
        navigationItem.backButtonDisplayMode = .minimal
        dateButton = actionButton("") { [weak self] in self?.editDate() }
        dateButton.accessibilityLabel = String(localized: "Edit Entry Date")
        stack.addArrangedSubview(dateButton); stack.addArrangedSubview(placeLabel); stack.addArrangedSubview(titleField)
        render()
        NotificationCenter.default.addObserver(self, selector: #selector(flushBeforeSceneDeactivation(_:)), name: UIScene.willDeactivateNotification, object: nil)
        foldAvoidance = EditorFoldAvoidance(editorView: view, writingArea: scroll)
    }
    /// Called by the scene root before a resize moves this editor to another column: keeps the
    /// unsaved edits unsaved and returns the focus, caret, and keyboard once it appears there.
    func beginColumnMove() {
        guard columnMove == nil else { return }
        let focus = ([titleField] + textViews).first { $0.isFirstResponder }
        columnMove = ColumnMove(focus: focus, selection: focus?.selectedRange ?? NSRange())
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if columnMove != nil {
            columnMove?.hasLeft = true
        } else if !finished {
            view.endEditing(true)
            _ = flush()
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let move = columnMove, move.hasLeft else { return }
        columnMove = nil
        if let focus = move.focus, focus.becomeFirstResponder() { focus.selectedRange = move.selection }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isMovingFromParent || navigationController == nil, !finished, columnMove == nil else { return }
        do {
            try saveEntryChanges(entry, in: context, discardIfBlank: isNew, save: save)
            finished = true
            saveTask?.cancel()
            NotificationCenter.default.post(name: .journalDidChange, object: entry.id)
        } catch { saveError(error) }
    }

    @objc private func flushBeforeSceneDeactivation(_ notification: Notification) {
        // Each iPad window has its own lifecycle and editor context.
        guard let scene = notification.object as? UIWindowScene,
              scene === viewIfLoaded?.window?.windowScene, !finished else { return }
        view.endEditing(true)
        _ = flush()
    }

    /// Reconciles views with the entry by block identity, so unaffected text keeps its
    /// selection, undo history and IME state, and unaffected photos keep their images.
    private func render(focusAfter: UUID? = nil) {
        title = entry.entryDate.formatted(.dateTime.month(.wide).day().year())
        let dateText = entry.isAllDay ? entry.entryDate.formatted(date: .long, time: .omitted) + " · " + String(localized: "All-day") : entry.entryDate.formatted(date: .long, time: .shortened)
        dateButton.configuration?.title = dateText
        dateButton.accessibilityValue = dateText
        placeLabel.text = entry.locationDisplayText
        placeLabel.isHidden = entry.locationDisplayText == nil
        if titleField.markedTextRange == nil, titleField.text != entry.title { titleField.text = entry.title }

        var reusableText = Dictionary(textViews.map { ($0.slotKey, $0) }, uniquingKeysWith: { first, _ in first })
        var reusablePhotos = Dictionary(photoGroups.map { ($0.blockID, $0) }, uniquingKeysWith: { first, _ in first })
        var views: [UIView] = [dateButton, placeLabel, titleField]
        textViews = []; photoGroups = []
        func addText(block: EntryBlock?, after previous: EntryBlock?) {
            let key = block.map { BlockTextView.SlotKey.block($0.id) } ?? .transient(after: previous?.id)
            let text = reusableText.removeValue(forKey: key) ?? makeTextView()
            text.blockID = block?.id; text.previousBlockID = previous?.id
            if let block, text.markedTextRange == nil, text.text != block.text { text.text = block.text }
            text.setContentHuggingPriority(.defaultLow, for: .vertical)
            textViews.append(text); views.append(text)
        }
        var previous: EntryBlock?
        for block in entry.orderedBlocks {
            if block.kind == .text {
                addText(block: block, after: previous)
            } else {
                if previous == nil || previous?.kind == .photoGroup { addText(block: nil, after: previous) }
                let fileNames = block.orderedPhotos.map(\.fileName)
                let photos: PhotoGroupView
                if let reused = reusablePhotos.removeValue(forKey: block.id), reused.fileNames == fileNames { photos = reused }
                else { photos = PhotoGroupView(block: block, storage: storage, deferLoading: true) { [weak self] photo in self?.openPhoto(photo) } }
                photoGroups.append(photos); views.append(photos)
            }
            previous = block
        }
        if previous == nil || previous?.kind == .photoGroup { addText(block: nil, after: previous) }
        let kept = Set(views.map(ObjectIdentifier.init))
        for view in stack.arrangedSubviews where !kept.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        for (index, view) in views.enumerated() where index >= stack.arrangedSubviews.count || stack.arrangedSubviews[index] !== view {
            stack.insertArrangedSubview(view, at: index)
        }
        // Only the final writing field absorbs spare height; earlier blocks keep their size.
        textViews.last?.setContentHuggingPriority(UILayoutPriority(249), for: .vertical)
        updateTextSpacing()
        if let focusAfter, let text = textViews.first(where: { $0.previousBlockID == focusAfter }) {
            text.becomeFirstResponder(); text.selectedRange = NSRange(location: 0, length: 0)
            scroll.layoutIfNeeded()
            scroll.scrollRectToVisible(text.convert(text.bounds, to: scroll), animated: true)
        }
    }
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Safe-area height, not the area above the keyboard, so photos keep their size while typing.
        let visibleHeight = view.bounds.inset(by: view.safeAreaInsets).height
        for group in photoGroups { group.maximumPhotoHeight = visibleHeight > 0 ? visibleHeight * 0.7 : nil }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        foldAvoidance?.update()
        refreshVisiblePhotos()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { refreshVisiblePhotos() }
    private func refreshVisiblePhotos() {
        let visible = scroll.bounds.insetBy(dx: 0, dy: -scroll.bounds.height / 2)
        for image in photoGroups.flatMap(\.photoViews) {
            image.updateVisibility(image.window != nil && visible.intersects(image.convert(image.bounds, to: scroll)))
        }
    }
    private func makeTextView() -> BlockTextView {
        let text = BlockTextView()
        text.delegate = self
        return text
    }
    func textViewDidBeginEditing(_ textView: UITextView) { focusedText = textView as? BlockTextView }
    func textViewDidChange(_ textView: UITextView) {
        textView.invalidateIntrinsicContentSize()
        guard textView.markedTextRange == nil else { return }
        if textView === titleField { titleField.refreshPlaceholder() }
        (textView as? BlockTextView)?.refreshChecklist()
        updateTextSpacing()
        synchronize(textView)
        scheduleSave()
    }
    private func updateTextSpacing() {
        let views = stack.arrangedSubviews
        views.forEach { stack.setCustomSpacing(UIStackView.spacingUseDefault, after: $0) }
        // Keep the 44-point insertion target, without adding two more gaps around an empty field.
        for (index, view) in views.enumerated() {
            guard let text = view as? BlockTextView, !text.hasText else { continue }
            if index > 0 { stack.setCustomSpacing(0, after: views[index - 1]) }
            stack.setCustomSpacing(0, after: text)
        }
    }
    func textViewDidEndEditing(_ textView: UITextView) {
        synchronize(textView)
        // Leaving the window during a column move is not the end of editing.
        if columnMove == nil { scheduleSave() }
    }
    private func synchronizeText() {
        synchronize(titleField)
        textViews.forEach(synchronize)
    }
    /// Writes only changed values, so unchanged blocks are not dirtied or re-saved.
    private func synchronize(_ view: UITextView) {
        guard view.markedTextRange == nil else { return }
        if view === titleField {
            let title = titleField.text ?? ""
            if entry.title != title { entry.title = title }
            return
        }
        guard let text = view as? BlockTextView else { return }
        if let id = text.blockID, let block = entry.blocks.first(where: { $0.id == id }) {
            if block.text != text.text { block.text = text.text }
        } else if !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let previous = entry.blocks.first { $0.id == text.previousBlockID }
            // A transient editor before the first photo must insert at the beginning.
            if previous == nil, let first = entry.orderedBlocks.first {
                let block = EntryBlock(sortIndex: first.sortIndex - 1, text: text.text, entry: entry)
                context.insert(block); entry.blocks.append(block); text.blockID = block.id
            } else {
                text.blockID = entry.insertTextBlock(text.text, after: previous, in: context)?.id
            }
        }
    }
    private func scheduleSave() {
        guard !finished else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            _ = self?.flush()
        }
    }
    /// Avoid normalization during typing: it would invalidate live block identities and IME selections.
    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel(); saveTask = nil
        synchronizeText()
        guard context.hasChanges else { return true }
        entry.updatedAt = .now
        do {
            try save()
            NotificationCenter.default.post(name: .journalDidChange, object: entry.id)
            return true
        } catch { saveError(error); return false }
    }
    private func save() throws { try saveContext(context) }
    /// Unsaved edits stay in the context, so the user can retry once space is available.
    private func saveError(_ error: any Error) {
        guard presentedViewController == nil else { return }
        showError(String(localized: "Could Not Save Entry"), message: writeFailureMessage(for: error, otherwise: String(localized: "Your changes could not be saved. Please try again.")))
    }
    func prepareForReplacement() -> Bool {
        guard !addingPhotos, !finished else { return !addingPhotos }
        view.endEditing(true)
        return flush()
    }

    /// The Done action: saves, discards a blank new entry, and closes the editor.
    func finish() {
        guard !addingPhotos else { return }
        view.endEditing(true)
        guard flush() else { return }
        do {
            try saveEntryChanges(entry, in: context, discardIfBlank: isNew, save: save)
            finished = true; saveTask?.cancel()
            NotificationCenter.default.post(name: .journalDidChange, object: entry.id)
            closeEditor()
        } catch { saveError(error) }
    }
    private func closeEditor() {
        if navigationController?.presentingViewController != nil { dismiss(animated: true) }
        else if let root = splitViewController as? JournalSplitViewController { root.closeEntry(self) }
        else if (navigationController?.viewControllers.count ?? 0) > 1 { navigationController?.popViewController(animated: true) }
    }
    private func pickPhotos() {
        guard flush() else { return }
        if let text = focusedText, text.blockID == nil {
            let previous = entry.blocks.first { $0.id == text.previousBlockID }
            let block = EntryBlock(sortIndex: (previous?.sortIndex ?? -1) + 1, entry: entry)
            for other in entry.blocks where other.sortIndex >= block.sortIndex { other.sortIndex += 1 }
            context.insert(block); entry.blocks.append(block); text.blockID = block.id
        }
        pendingBlockID = focusedText?.blockID
        if let text = focusedText {
            let offset = min(text.selectedRange.location, text.text.utf16.count)
            let utf16Index = text.text.utf16.index(text.text.utf16.startIndex, offsetBy: offset)
            pendingOffset = String.Index(utf16Index, within: text.text).map { text.text.distance(from: text.text.startIndex, to: $0) }
        } else { pendingOffset = nil }
        var config = PHPickerConfiguration()
        config.filter = .images; config.selectionLimit = 0; config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) { [weak self] in self?.importPhotos(results) }
    }
    private func importPhotos(_ results: [PHPickerResult]) {
        guard !results.isEmpty else { return }
        let loaders: [() async throws -> Data] = results.map { result in { try await Self.imageData(from: result.itemProvider) } }
        importPhotos { await self.storage.savePhotos(loaders) }
    }
    private static func imageData(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? PhotoStorageError.unreadableImage) }
            }
        }
    }

    /// The loader boundary also lets fixtures exercise slow transfers without opening Photos.
    func importPhotos(using load: @escaping () async -> PhotoImportResult) {
        guard !addingPhotos, !finished else { return }
        view.endEditing(true)
        addingPhotos = true
        navigationItem.hidesBackButton = true
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = false }
        let progress = ProcessingViewController(title: String(localized: "Insert Photos"), message: String(localized: "Adding Photos…"))
        addChild(progress)
        progress.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progress.view)
        NSLayoutConstraint.activate([
            progress.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.view.topAnchor.constraint(equalTo: view.topAnchor),
            progress.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        progress.didMove(toParent: self)
        scroll.isUserInteractionEnabled = false
        scroll.accessibilityElementsHidden = true
        UIAccessibility.post(notification: .layoutChanged, argument: progress.view)
        Task {
            let result = await load()
            progress.willMove(toParent: nil)
            progress.view.removeFromSuperview()
            progress.removeFromParent()
            scroll.isUserInteractionEnabled = true
            scroll.accessibilityElementsHidden = false
            defer {
                addingPhotos = false
                navigationItem.hidesBackButton = false
                navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = true }
                if presentedViewController == nil {
                    UIAccessibility.post(notification: .layoutChanged, argument: insertButton)
                }
            }
            guard let photoBlock = entry.insertPhotoGroup(photos: result.photos, focusedTextBlockID: pendingBlockID, cursorOffset: pendingOffset, in: context) else {
                if let failureMessage = result.failureMessage { showError(String(localized: "Some Photos Couldn’t Be Added"), message: failureMessage) }
                return
            }
            do {
                try saveEntryChanges(entry, in: context, save: save)
                NotificationCenter.default.post(name: .journalDidChange, object: entry.id)
                render(focusAfter: photoBlock.id)
                let prompt = entry.photoInfoPromptCandidate(from: photoBlock.orderedPhotos)
                if let failureMessage = result.failureMessage {
                    showError(String(localized: "Some Photos Couldn’t Be Added"), message: failureMessage) { self.promptPhotoInfo(prompt) }
                } else { promptPhotoInfo(prompt) }
            } catch {
                rollBackChanges(to: entry, in: context)
                let removed = removeFiles(result.fileNames)
                render()
                showError(String(localized: "Some Photos Couldn’t Be Added"), message: removed ? writeFailureMessage(for: error, otherwise: String(localized: "Some selected photos could not be added.")) : String(localized: "Some copied photo files could not be deleted."))
            }
        }
    }
    private func promptPhotoInfo(_ photo: EntryPhoto?) {
        guard let photo else { return }
        let alert = UIAlertController(title: String(localized: "Use Photo Info?"), message: String(localized: "Use this photo’s date and location for the entry?"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Use Photo Info"), style: .default) { [weak self] _ in self?.usePhotoInfo(photo) })
        alert.addAction(UIAlertAction(title: String(localized: "Keep Entry Info"), style: .cancel) { [weak self] _ in
            self?.entry.hasShownPhotoInfoPrompt = true; _ = self?.flush()
        })
        present(alert, animated: true)
    }
    private func usePhotoInfo(_ photo: EntryPhoto) {
        entry.applyInfo(from: photo); entry.hasShownPhotoInfoPrompt = true
        _ = flush(); render()
    }
    private func editDate() {
        guard flush() else { return }
        let controller = EntryDateViewController(entry: entry) { [weak self] in _ = self?.flush() }
        controller.onDone = { [weak self] in self?.render() }
        present(UINavigationController(rootViewController: controller), animated: true)
    }
    private func openPhoto(_ photo: EntryPhoto) {
        guard flush() else { return }
        let controller = PhotoDetailViewController(photo: photo, storage: storage)
        controller.useInfo = { [weak self] in self?.usePhotoInfo(photo) }
        controller.deletePhoto = { [weak self] in self?.deletePhoto(photo) ?? .failed }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }
    private func deletePhoto(_ photo: EntryPhoto) -> PhotoDeletionResult {
        let name = entry.deletePhoto(photo, in: context)
        do {
            try saveEntryChanges(entry, in: context, save: save)
            NotificationCenter.default.post(name: .journalDidChange, object: entry.id)
            render()
            return removeFiles([name]) ? .deleted : .fileCleanupFailed
        } catch { rollBackChanges(to: entry, in: context); render(); return .failed }
    }
    private func removeFiles(_ names: [String]) -> Bool {
        var success = true
        for name in names { do { try storage.delete(fileName: name) } catch { success = false } }
        return success
    }
    func confirmDeleteEntry() {
        guard !addingPhotos, !finished, flush() else { return }
        confirmDeletion(title: String(localized: "Delete Entry"), message: String(localized: "This entry and its photos will be permanently deleted.")) { [weak self] in
            guard let self else { return }
            do {
                let id = self.entry.id
                let files = try deleteEntryAndSave(self.entry, in: self.context, save: self.save)
                self.finished = true; self.saveTask?.cancel()
                NotificationCenter.default.post(name: .journalDidChange, object: id)
                if self.removeFiles(files) { self.closeEditor() }
                else {
                    let alert = UIAlertController(title: String(localized: "Photo File Couldn’t Be Deleted"), message: String(localized: "Some copied photo files could not be deleted."), preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in self.closeEditor() })
                    self.present(alert, animated: true)
                }
            } catch { self.saveError(error) }
        }
    }
}

private final class EntryTitleView: UITextView {
    private let placeholder = UILabel()
    override var text: String! { didSet { refreshPlaceholder() } }
    init() {
        super.init(frame: .zero, textContainer: nil)
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        placeholder.text = String(localized: "Title (optional)")
        placeholder.font = .preferredFont(forTextStyle: .title2)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.isAccessibilityElement = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: placeholder.heightAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refreshPlaceholder() { placeholder.isHidden = !text.isEmpty }
}

final class BlockTextView: UITextView {
    enum SlotKey: Hashable { case block(UUID), transient(after: UUID?) }
    var blockID: UUID?
    var previousBlockID: UUID?
    var slotKey: SlotKey { blockID.map(SlotKey.block) ?? .transient(after: previousBlockID) }
    private let placeholder = UILabel()
    private var checklistButtons: [(range: NSRange, button: UIButton)] = []
    private var formattedText: String?
    private var formattedCategory: UIContentSizeCategory?
    private var minimumHeight: NSLayoutConstraint!
    private var hasFormatting = false
    private static let checklistPattern = try! NSRegularExpression(pattern: #"(?m)^[\t ]*[☐☑] "#)
    private static let listPattern = try! NSRegularExpression(pattern: #"(?m)^[\t ]*(?:• |[0-9]+[.)] )"#)
    override var text: String! {
        didSet { formattedText = nil; setNeedsLayout() }
    }
    init() {
        super.init(frame: .zero, textContainer: nil)
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        backgroundColor = .clear; isScrollEnabled = false
        textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textContainer.lineFragmentPadding = 0
        accessibilityLabel = String(localized: "Body")
        accessibilityHint = String(localized: "Write something...")
        minimumHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        minimumHeight.isActive = true
        placeholder.text = String(localized: "Write something...")
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.numberOfLines = 0
        placeholder.isAccessibilityElement = false
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            heightAnchor.constraint(greaterThanOrEqualTo: placeholder.heightAnchor, constant: 16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The stored text stays portable. Only its leading checklist markers receive native controls.
    func refreshChecklist() {
        placeholder.isHidden = !text.isEmpty
        guard markedTextRange == nil,
              formattedText != text || formattedCategory != traitCollection.preferredContentSizeCategory else { return }
        formattedText = text
        formattedCategory = traitCollection.preferredContentSizeCategory
        minimumHeight.constant = text.isEmpty ? 44 : 0
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let source = textStorage.string as NSString
        let listMatches = Self.listPattern.matches(in: source as String, range: fullRange)
        let checklistMatches = Self.checklistPattern.matches(in: source as String, range: fullRange)
        // Plain prose keeps UIKit's own attributes: restyling it would relayout the whole
        // document on every keystroke. Formatted text is restyled once more when markers vanish.
        // Note: formatted text still restyles in full; restyle only edited paragraphs if long checklists lag.
        guard hasFormatting || !listMatches.isEmpty || !checklistMatches.isEmpty else { return }
        hasFormatting = !listMatches.isEmpty || !checklistMatches.isEmpty
        checklistButtons.forEach { $0.button.removeFromSuperview() }
        checklistButtons.removeAll()
        accessibilityCustomActions = nil
        let bodyFont = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        textStorage.beginEditing()
        textStorage.setAttributes([.font: bodyFont, .foregroundColor: UIColor.label], range: fullRange)
        for match in listMatches {
            let style = NSMutableParagraphStyle()
            style.headIndent = (source.substring(with: match.range) as NSString).size(withAttributes: [.font: bodyFont]).width
            textStorage.addAttribute(.paragraphStyle, value: style, range: source.paragraphRange(for: match.range))
        }
        var actions: [UIAccessibilityCustomAction] = []
        for match in checklistMatches {
            let marker = NSRange(location: NSMaxRange(match.range) - 2, length: 1)
            let paragraph = source.paragraphRange(for: marker)
            let style = NSMutableParagraphStyle()
            let targetSize = max(44, ceil(bodyFont.lineHeight))
            style.minimumLineHeight = targetSize
            let indentation = source.substring(with: NSRange(location: match.range.location, length: marker.location - match.range.location))
            let markerWidth = (source.substring(with: marker) as NSString).size(withAttributes: [.font: bodyFont]).width
            let spaceWidth = (" " as NSString).size(withAttributes: [.font: bodyFont]).width
            // Reserve the whole touch target before the text, including at accessibility sizes.
            style.headIndent = (indentation as NSString).size(withAttributes: [.font: bodyFont]).width + max(targetSize, markerWidth + spaceWidth)
            textStorage.addAttribute(.paragraphStyle, value: style, range: paragraph)
            textStorage.addAttributes([.foregroundColor: UIColor.clear, .kern: max(0, targetSize - markerWidth - spaceWidth)], range: marker)
            let checked = source.substring(with: marker) == "☑"
            let labelRange = NSRange(location: NSMaxRange(match.range), length: NSMaxRange(paragraph) - NSMaxRange(match.range))
            let label = source.substring(with: labelRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: checked ? "checkmark.square.fill" : "square"), for: .normal)
            button.setPreferredSymbolConfiguration(.init(pointSize: bodyFont.pointSize + 2), forImageIn: .normal)
            button.accessibilityIdentifier = "checklist-toggle"
            button.accessibilityLabel = label
            button.accessibilityValue = checked ? String(localized: "Completed") : String(localized: "Not completed")
            button.accessibilityTraits = checked ? [.button, .selected] : [.button]
            button.addAction(UIAction { [weak self] _ in self?.toggleChecklist(at: marker.location) }, for: .touchUpInside)
            addSubview(button)
            checklistButtons.append((marker, button))
            let actionName = String(checklistButtons.count) + ". " + (checked ? String(localized: "Mark incomplete") : String(localized: "Mark complete")) + ": " + label
            actions.append(UIAccessibilityCustomAction(name: actionName) { [weak self] _ in
                self?.toggleChecklist(at: marker.location) ?? false
            })
        }
        textStorage.endEditing()
        // New typing must never inherit the hidden marker or checklist-only indentation.
        typingAttributes = [.font: bodyFont, .foregroundColor: UIColor.label]
        accessibilityCustomActions = actions.isEmpty ? nil : actions
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    @discardableResult
    private func toggleChecklist(at location: Int) -> Bool {
        guard markedTextRange == nil, location < textStorage.length else { return false }
        let range = NSRange(location: location, length: 1)
        let old = (textStorage.string as NSString).substring(with: range)
        guard old == "☐" || old == "☑" else { return false }
        let replacement = old == "☐" ? "☑" : "☐"
        guard delegate?.textView?(self, shouldChangeTextIn: range, replacementText: replacement) != false else { return false }
        let selection = selectedRange
        undoManager?.registerUndo(withTarget: self) { target in target.toggleChecklist(at: location) }
        textStorage.replaceCharacters(in: range, with: replacement)
        selectedRange = selection
        refreshChecklist()
        delegate?.textViewDidChange?(self)
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshChecklist()
        for (range, button) in checklistButtons {
            guard let start = position(from: beginningOfDocument, offset: range.location),
                  let end = position(from: start, offset: 1),
                  let textRange = self.textRange(from: start, to: end) else { continue }
            let rect = firstRect(for: textRange)
            // UIKit places glyphs on the lower baseline of a minimum-height line.
            // Match that baseline instead of the center of the expanded line fragment.
            let fontHeight = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection).lineHeight
            let targetSize = max(44, ceil(fontHeight))
            let baselineOffset = max(0, targetSize - fontHeight) / 2
            button.frame = CGRect(x: max(0, rect.minX), y: rect.midY - targetSize / 2 + baselineOffset, width: targetSize, height: targetSize)
        }
    }
}

/// The photo is a subview rather than a UIButton image, so highlight it explicitly.
private final class PhotoButton: UIButton {
    let photoView: StoredPhotoView

    init(photoView: StoredPhotoView) {
        self.photoView = photoView
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        addSubview(photoView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { photoView.alpha = isHighlighted ? 0.6 : 1 }
    }
}

final class PhotoGroupView: UIStackView {
    private(set) var photoViews: [StoredPhotoView] = []
    let blockID: UUID
    let fileNames: [String]
    private var heightCap: NSLayoutConstraint?
    /// The tallest a single photo may be; groups of several photos keep their grid.
    var maximumPhotoHeight: CGFloat? {
        didSet {
            guard let heightCap, maximumPhotoHeight != oldValue else { return }
            heightCap.constant = maximumPhotoHeight ?? 0
            heightCap.isActive = maximumPhotoHeight != nil
        }
    }
    init(block: EntryBlock, storage: PhotoStorage, deferLoading: Bool = false, open: @escaping (EntryPhoto) -> Void) {
        let photos = block.orderedPhotos
        blockID = block.id; fileNames = photos.map(\.fileName)
        super.init(frame: .zero)
        axis = .vertical; spacing = 4
        let columns = photoGroupColumnCount(forPhotoCount: photos.count)
        for start in stride(from: 0, to: photos.count, by: max(1, columns)) {
            let row = UIStackView(); row.spacing = 4; row.distribution = .fillEqually
            for index in start..<min(start + columns, photos.count) {
                let photo = photos[index]
                let image = StoredPhotoView(); image.isAccessibilityElement = false
                let button = PhotoButton(photoView: image)
                image.contentMode = photos.count == 1 ? .scaleAspectFit : .scaleAspectFill
                image.translatesAutoresizingMaskIntoConstraints = false
                image.onAvailabilityChange = { [weak button] available in
                    button?.accessibilityValue = available ? nil : String(localized: "Photo unavailable")
                }
                // Size a single photo from its header before first layout; decoding only confirms it.
                let initialRatio = photos.count == 1 ? storage.pixelSize(for: photo.fileName).map { min(2, max(0.5, $0.height / $0.width)) } ?? 0.75 : 1
                let aspect = button.heightAnchor.constraint(equalTo: button.widthAnchor, multiplier: initialRatio)
                aspect.identifier = "photo-aspect"
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: button.leadingAnchor), image.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                    image.topAnchor.constraint(equalTo: button.topAnchor), image.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                    aspect
                ])
                if photos.count == 1 {
                    image.onImageSize = { [weak button] size in
                        guard let button, size.width > 0 else { return }
                        // Keep unusually tall scans/panoramas bounded; normal photos retain their ratio.
                        let ratio = min(2, max(0.5, size.height / size.width))
                        guard let old = button.constraints.first(where: { $0.identifier == "photo-aspect" }),
                              abs(old.multiplier - ratio) > 0.001 else { return }
                        old.isActive = false
                        let updated = button.heightAnchor.constraint(equalTo: button.widthAnchor, multiplier: ratio)
                        updated.identifier = "photo-aspect"
                        updated.isActive = true
                    }
                }
                button.accessibilityLabel = String(localized: "Open Photo \(index + 1) of \(photos.count)")
                button.addAction(UIAction { _ in open(photo) }, for: .touchUpInside)
                photoViews.append(image)
                let pixels = photos.count == 1 ? 1200 : 600
                if deferLoading { image.deferLoading(photo.fileName, storage: storage, pixels: pixels) }
                else { image.load(photo.fileName, storage: storage, pixels: pixels) }
                row.addArrangedSubview(button)
            }
            if photos.count > 1 {
                for _ in min(start + columns, photos.count)..<(start + columns) { row.addArrangedSubview(UIView()) }
            }
            addArrangedSubview(row)
        }
        if photos.count == 1, let button = photoViews.first?.superview {
            // A capped photo narrows to keep its ratio and stays centred instead of letterboxing.
            alignment = .center
            let fill = button.widthAnchor.constraint(equalTo: widthAnchor)
            fill.priority = .required - 1
            fill.isActive = true
            heightCap = button.heightAnchor.constraint(lessThanOrEqualToConstant: 0)
        }
        accessibilityLabel = String(localized: "Photo Group")
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class EntryDateViewController: UIViewController {
    let entry: JournalEntry
    let save: () -> Void
    var onDone: (() -> Void)?
    init(entry: JournalEntry, save: @escaping () -> Void) {
        self.entry = entry; self.save = save
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Entry Date")
        let toggle = UISwitch(); toggle.isOn = entry.isAllDay; toggle.accessibilityLabel = String(localized: "All-day")
        let row = UIStackView(arrangedSubviews: [bodyLabel(String(localized: "All-day")), toggle])
        let picker = UIDatePicker(); picker.date = entry.entryDate
        picker.datePickerMode = entry.isAllDay ? .date : .dateAndTime
        picker.preferredDatePickerStyle = .compact; picker.accessibilityLabel = String(localized: "Date")
        toggle.addAction(UIAction { [weak self, weak toggle, weak picker] _ in
            guard let self, let toggle, let picker else { return }
            self.entry.setAllDay(toggle.isOn)
            picker.datePickerMode = toggle.isOn ? .date : .dateAndTime
            picker.date = self.entry.entryDate; self.save()
        }, for: .valueChanged)
        picker.addAction(UIAction { [weak self, weak picker] _ in
            if let picker { self?.entry.setEntryDate(picker.date); self?.save() }
        }, for: .valueChanged)
        installStack([row, picker])
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: String(localized: "Done"), primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); onDone?() }
}

enum PhotoDeletionResult { case deleted, fileCleanupFailed, failed }

final class PhotoDetailViewController: UIViewController {
    let photo: EntryPhoto
    let storage: PhotoStorage
    var useInfo: (() -> Void)?
    var deletePhoto: (() -> PhotoDeletionResult)?
    private var layout = PhotoDetailLayout.stacked
    private var stacked: UIView?
    private var arranged: UIViewController?  // The iOS 27.1 UIArrangementViewController, made on first use.
    private lazy var doneItem = UIBarButtonItem(title: String(localized: "Done"), primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    private lazy var moreItem: UIBarButtonItem = {
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: actions.map(\.menuAction)))
        more.accessibilityLabel = String(localized: "Photo Actions")
        return more
    }()
    private var info: String {
        [photo.capturedAt?.formatted(date: .long, time: .shortened), photo.placeDisplayText].compactMap { $0 }.joined(separator: "\n")
    }
    private var actions: [PhotoDetailAction] {
        var actions: [PhotoDetailAction] = []
        if photo.hasUsableEntryInfo {
            actions.append(PhotoDetailAction(title: String(localized: "Use as Entry Info"), isDestructive: false) { [weak self] in self?.useInfo?() })
        }
        actions.append(PhotoDetailAction(title: String(localized: "Delete Photo"), isDestructive: true) { [weak self] in self?.confirmPhotoDeletion() })
        return actions
    }
    init(photo: EntryPhoto, storage: PhotoStorage) {
        self.photo = photo; self.storage = storage
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Photo Detail")
        let image = StoredPhotoView(); image.contentMode = .scaleAspectFit
        image.load(photo.fileName, storage: storage, pixels: PhotoStorage.targetLongEdge)
        installStack([image, bodyLabel(info, style: .footnote)])
        stacked = view.subviews.last
        image.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.6).isActive = true
        navigationItem.rightBarButtonItems = [doneItem, moreItem]
        if #available(iOS 27.1, *) {
            // A pose change can move the fold without resizing the window.
            view.addInteraction(UIHingeInteraction { [weak self] _, _ in self?.view.setNeedsLayout() })
            registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in self.view.setNeedsLayout() }
        }
    }
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard #available(iOS 27.1, *) else { return }
        let divisions = view.reservedRegions(kind: .division).map(\.frame)
        show(PhotoDetailLayout(size: view.bounds.size, horizontalSizeClass: traitCollection.horizontalSizeClass, divisions: divisions))
    }
    @available(iOS 27.1, *)
    private func show(_ next: PhotoDetailLayout) {
        guard next != layout else { return }
        layout = next
        let isArranged = next != .stacked
        if isArranged {
            let arrangement = arranged as? UIArrangementViewController ?? addArrangement()
            arrangement.arrangePhoto(next)
        }
        stacked?.isHidden = isArranged
        arranged?.view.isHidden = !isArranged
        navigationItem.rightBarButtonItems = isArranged ? [doneItem] : [doneItem, moreItem]
    }
    @available(iOS 27.1, *)
    private func addArrangement() -> UIArrangementViewController {
        let arrangement = makePhotoArrangement(photo: photo, storage: storage, info: info, actions: actions)
        addChild(arrangement)
        arrangement.view.frame = view.bounds
        arrangement.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arrangement.view)
        arrangement.didMove(toParent: self)
        arranged = arrangement
        return arrangement
    }
    private func confirmPhotoDeletion() {
        confirmDeletion(title: String(localized: "Delete Photo"), message: String(localized: "This photo will be removed from this entry.")) { [weak self] in
            guard let self else { return }
            switch self.deletePhoto?() ?? .failed {
            case .deleted: self.dismiss(animated: true)
            case .failed: self.showError(String(localized: "Photo Couldn’t Be Deleted"), message: String(localized: "Try deleting the photo again."))
            case .fileCleanupFailed:
                let alert = UIAlertController(title: String(localized: "Photo File Couldn’t Be Deleted"), message: String(localized: "The photo was removed from this entry, but its copied file could not be deleted."), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in self.dismiss(animated: true) })
                self.present(alert, animated: true)
            }
        }
    }
}
