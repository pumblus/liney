import PhotosUI
import SwiftData
import UIKit

/// Owns one editing context; failed photo mutations cannot roll back another screen's work.
final class EntryEditorViewController: UIViewController, UITextViewDelegate, PHPickerViewControllerDelegate, UIScrollViewDelegate {
    let entry: JournalEntry
    let context: ModelContext
    let isNew: Bool
    private let storage = PhotoStorage()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let titleField = UITextField()
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

    init(entry: JournalEntry, isNew: Bool, context: ModelContext) {
        self.entry = entry; self.isNew = isNew; self.context = context
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
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)
        ])
        titleField.placeholder = String(localized: "Title")
        titleField.accessibilityLabel = String(localized: "Title")
        titleField.font = .preferredFont(forTextStyle: .title2)
        titleField.adjustsFontForContentSizeCategory = true
        titleField.addAction(UIAction { [weak self] _ in self?.scheduleSave() }, for: .editingChanged)
        insertButton = UIBarButtonItem(image: UIImage(systemName: "photo.on.rectangle"), primaryAction: UIAction { [weak self] _ in self?.pickPhotos() })
        insertButton.accessibilityLabel = String(localized: "Insert Photos")
        doneButton = UIBarButtonItem(title: String(localized: "Done"), primaryAction: UIAction { [weak self] _ in self?.finish() })
        let delete = UIBarButtonItem(image: UIImage(systemName: "trash"), primaryAction: UIAction { [weak self] _ in self?.confirmDeleteEntry() })
        delete.accessibilityLabel = String(localized: "Delete Entry")
        navigationItem.rightBarButtonItems = [doneButton, insertButton, delete]
        // Done is the explicit save boundary, including iPad detail replacement.
        navigationItem.hidesBackButton = true
        rebuild()
        NotificationCenter.default.addObserver(self, selector: #selector(flushBeforeBackground), name: UIApplication.willResignActiveNotification, object: nil)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if !finished { _ = flush() }
    }
    @objc private func flushBeforeBackground() { if !finished { view.endEditing(true); _ = flush() } }

    private func rebuild(focusAfter: UUID? = nil) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        textViews = []; photoGroups = []
        title = entry.entryDate.formatted(.dateTime.month(.wide).day().year())
        let dateText = entry.isAllDay ? entry.entryDate.formatted(date: .long, time: .omitted) + " · " + String(localized: "All-day") : entry.entryDate.formatted(date: .long, time: .shortened)
        let date = actionButton(dateText) { [weak self] in self?.editDate() }
        date.accessibilityLabel = String(localized: "Edit Entry Date"); date.accessibilityValue = dateText
        stack.addArrangedSubview(date)
        if let place = entry.locationDisplayText { stack.addArrangedSubview(bodyLabel(place, style: .footnote)) }
        titleField.text = entry.title; stack.addArrangedSubview(titleField)
        let blocks = entry.orderedBlocks
        var previous: EntryBlock?
        for block in blocks {
            if block.kind == .text {
                addText(block: block, after: previous)
            } else {
                if previous == nil || previous?.kind == .photoGroup { addText(block: nil, after: previous) }
                let photos = PhotoGroupView(block: block, storage: storage, deferLoading: true) { [weak self] photo in self?.openPhoto(photo) }
                photoGroups.append(photos)
                stack.addArrangedSubview(photos)
            }
            previous = block
        }
        if previous == nil || previous?.kind == .photoGroup { addText(block: nil, after: previous) }
        if let focusAfter, let text = textViews.first(where: { $0.previousBlockID == focusAfter }) {
            text.becomeFirstResponder(); text.selectedRange = NSRange(location: 0, length: 0)
            scroll.layoutIfNeeded()
            scroll.scrollRectToVisible(text.convert(text.bounds, to: scroll), animated: true)
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshVisiblePhotos()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { refreshVisiblePhotos() }
    private func refreshVisiblePhotos() {
        let visible = scroll.bounds.insetBy(dx: 0, dy: -scroll.bounds.height / 2)
        for image in photoGroups.flatMap(\.photoViews) {
            image.updateVisibility(image.window != nil && visible.intersects(image.convert(image.bounds, to: scroll)))
        }
    }
    private func addText(block: EntryBlock?, after previous: EntryBlock?) {
        let text = BlockTextView()
        text.blockID = block?.id; text.previousBlockID = previous?.id
        text.text = block?.text ?? ""
        text.delegate = self
        textViews.append(text); stack.addArrangedSubview(text)
    }
    func textViewDidBeginEditing(_ textView: UITextView) { focusedText = textView as? BlockTextView }
    func textViewDidChange(_ textView: UITextView) {
        textView.invalidateIntrinsicContentSize()
        guard textView.markedTextRange == nil else { return }
        synchronizeText()
        scheduleSave()
    }
    func textViewDidEndEditing(_ textView: UITextView) { synchronizeText(); scheduleSave() }
    private func synchronizeText() {
        if titleField.markedTextRange == nil { entry.title = titleField.text ?? "" }
        for text in textViews where text.markedTextRange == nil {
            if let id = text.blockID, let block = entry.blocks.first(where: { $0.id == id }) {
                block.text = text.text
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
            try context.save()
            NotificationCenter.default.post(name: .journalDidChange, object: entry.id)
            return true
        } catch { saveError(); return false }
    }
    private func saveError() {
        guard presentedViewController == nil else { return }
        showError(String(localized: "Could Not Save Entry"), message: String(localized: "Your changes could not be saved. Please try again."))
    }
    func prepareForReplacement() -> Bool {
        guard !addingPhotos, !finished else { return !addingPhotos }
        view.endEditing(true)
        return flush()
    }

    private func finish() {
        guard !addingPhotos else { return }
        view.endEditing(true)
        guard flush() else { return }
        do {
            try saveEntryChanges(entry, in: context, discardIfBlank: isNew)
            finished = true; saveTask?.cancel()
            NotificationCenter.default.post(name: .journalDidChange, object: entry.id)
            closeEditor()
        } catch { saveError() }
    }
    private func closeEditor() {
        if navigationController?.presentingViewController != nil { dismiss(animated: true) }
        else if (navigationController?.viewControllers.count ?? 0) > 1 { navigationController?.popViewController(animated: true) }
        else if let splitViewController {
            splitViewController.setViewController(UINavigationController(rootViewController: MessageController(title: String(localized: "No Entry Selected"), message: String(localized: "Choose an entry from the timeline once entries exist."))), for: .secondary)
        }
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
        addingPhotos = true; insertButton.isEnabled = false; doneButton.isEnabled = false
        view.isUserInteractionEnabled = false
        Task {
            let result = await PhotoPickerImporter(storage: storage).importItems(results)
            defer { addingPhotos = false; insertButton.isEnabled = true; doneButton.isEnabled = true; view.isUserInteractionEnabled = true }
            guard let insertion = entry.insertPhotoGroup(photos: result.photos, focusedTextBlockID: pendingBlockID, cursorOffset: pendingOffset, in: context) else {
                if let alert = result.alert { showError(String(localized: "Some Photos Couldn’t Be Added"), message: alert.message) }
                return
            }
            do {
                try saveEntryChanges(entry, in: context)
                NotificationCenter.default.post(name: .journalDidChange, object: entry.id)
                rebuild(focusAfter: insertion.photoBlock.id)
                let prompt = entry.photoInfoPromptCandidate(from: insertion.photoBlock.orderedPhotos)
                if let alert = result.alert {
                    let message = UIAlertController(title: String(localized: "Some Photos Couldn’t Be Added"), message: alert.message, preferredStyle: .alert)
                    message.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in self.promptPhotoInfo(prompt) })
                    present(message, animated: true)
                } else { promptPhotoInfo(prompt) }
            } catch {
                context.rollback()
                let removed = removeFiles(result.fileNames)
                rebuild()
                showError(String(localized: "Some Photos Couldn’t Be Added"), message: removed ? String(localized: "Some selected photos could not be added.") : String(localized: "Some copied photo files could not be deleted."))
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
        _ = flush(); rebuild()
    }
    private func editDate() {
        guard flush() else { return }
        let controller = EntryDateViewController(entry: entry) { [weak self] in _ = self?.flush() }
        controller.onDone = { [weak self] in self?.rebuild() }
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
            try saveEntryChanges(entry, in: context)
            NotificationCenter.default.post(name: .journalDidChange, object: entry.id)
            rebuild()
            return removeFiles([name]) ? .deleted : .fileCleanupFailed
        } catch { context.rollback(); rebuild(); return .failed }
    }
    private func removeFiles(_ names: [String]) -> Bool {
        var success = true
        for name in names { do { try storage.delete(fileName: name) } catch { success = false } }
        return success
    }
    private func confirmDeleteEntry() {
        guard !addingPhotos, flush() else { return }
        confirmDeletion(title: String(localized: "Delete Entry"), message: String(localized: "This entry and its photos will be permanently deleted.")) { [weak self] in
            guard let self else { return }
            do {
                let files = try deleteEntryAndSave(self.entry, in: self.context)
                self.finished = true; self.saveTask?.cancel()
                NotificationCenter.default.post(name: .journalDidChange, object: self.entry.id)
                if self.removeFiles(files) { self.closeEditor() }
                else {
                    let alert = UIAlertController(title: String(localized: "Photo File Couldn’t Be Deleted"), message: String(localized: "Some copied photo files could not be deleted."), preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in self.closeEditor() })
                    self.present(alert, animated: true)
                }
            } catch { self.saveError() }
        }
    }
}

private final class BlockTextView: UITextView {
    var blockID: UUID?
    var previousBlockID: UUID?
    init() {
        super.init(frame: .zero, textContainer: nil)
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        backgroundColor = .clear; isScrollEnabled = false
        textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textContainer.lineFragmentPadding = 0
        accessibilityLabel = String(localized: "Body")
        accessibilityHint = String(localized: "Write something...")
        heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class PhotoGroupView: UIStackView {
    private(set) var photoViews: [StoredPhotoView] = []
    init(block: EntryBlock, storage: PhotoStorage, deferLoading: Bool = false, open: @escaping (EntryPhoto) -> Void) {
        super.init(frame: .zero)
        axis = .vertical; spacing = 4
        let photos = block.orderedPhotos
        let columns = photoGroupColumnCount(forPhotoCount: photos.count)
        for start in stride(from: 0, to: photos.count, by: max(1, columns)) {
            let row = UIStackView(); row.spacing = 4; row.distribution = .fillEqually
            for index in start..<min(start + columns, photos.count) {
                let photo = photos[index]
                let button = UIButton(type: .custom)
                let image = StoredPhotoView(); image.isAccessibilityElement = false
                image.contentMode = photos.count == 1 ? .scaleAspectFit : .scaleAspectFill
                image.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(image)
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: button.leadingAnchor), image.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                    image.topAnchor.constraint(equalTo: button.topAnchor), image.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                    button.heightAnchor.constraint(equalTo: button.widthAnchor, multiplier: photos.count == 1 ? 0.75 : 1)
                ])
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
            self?.dismiss(animated: true); self?.onDone?()
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
        let info = [photo.capturedAt?.formatted(date: .long, time: .shortened), photo.placeDisplayText].compactMap { $0 }.joined(separator: "\n")
        image.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.6).isActive = true
        installStack([image, bodyLabel(info, style: .footnote)])
        var actions: [UIAction] = []
        if photo.hasUsableEntryInfo { actions.append(UIAction(title: String(localized: "Use as Entry Info")) { [weak self] _ in self?.useInfo?() }) }
        actions.append(UIAction(title: String(localized: "Delete Photo"), attributes: .destructive) { [weak self] _ in
            self?.confirmDeletion(title: String(localized: "Delete Photo"), message: String(localized: "This photo will be removed from this entry.")) { [weak self] in
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
        })
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: actions))
        more.accessibilityLabel = String(localized: "Photo Actions")
        navigationItem.rightBarButtonItems = [UIBarButtonItem(title: String(localized: "Done"), primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }), more]
    }
}
