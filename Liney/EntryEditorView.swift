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
    private let titleField = EntryTitleView()
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
            stack.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor, constant: -40),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)
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
        rebuild()
        NotificationCenter.default.addObserver(self, selector: #selector(flushBeforeSceneDeactivation(_:)), name: UIScene.willDeactivateNotification, object: nil)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if !finished {
            view.endEditing(true)
            _ = flush()
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isMovingFromParent || navigationController == nil, !finished else { return }
        do {
            try saveEntryChanges(entry, in: context, discardIfBlank: isNew)
            finished = true
            saveTask?.cancel()
            NotificationCenter.default.post(name: .journalDidChange, object: entry.id)
        } catch { saveError() }
    }

    @objc private func flushBeforeSceneDeactivation(_ notification: Notification) {
        // Each iPad window has its own lifecycle and editor context.
        guard let scene = notification.object as? UIWindowScene,
              scene === viewIfLoaded?.window?.windowScene, !finished else { return }
        view.endEditing(true)
        _ = flush()
    }

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
        // Only the final writing field absorbs spare height; earlier blocks keep their size.
        textViews.last?.setContentHuggingPriority(UILayoutPriority(249), for: .vertical)
        updateTextSpacing()
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
        if textView === titleField { titleField.refreshPlaceholder() }
        (textView as? BlockTextView)?.refreshChecklist()
        updateTextSpacing()
        synchronizeText()
        scheduleSave()
    }
    private func updateTextSpacing() {
        let views = stack.arrangedSubviews
        views.forEach { stack.setCustomSpacing(UIStackView.spacingUseDefault, after: $0) }
        // Keep the 44-point insertion target, without adding two more gaps around an empty field.
        for (index, view) in views.enumerated() {
            guard let text = view as? BlockTextView, text.text.isEmpty else { continue }
            if index > 0 { stack.setCustomSpacing(0, after: views[index - 1]) }
            stack.setCustomSpacing(0, after: text)
        }
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
        importPhotos { await PhotoPickerImporter(storage: self.storage).importItems(results) }
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
    func confirmDeleteEntry() {
        guard !addingPhotos, !finished, flush() else { return }
        confirmDeletion(title: String(localized: "Delete Entry"), message: String(localized: "This entry and its photos will be permanently deleted.")) { [weak self] in
            guard let self else { return }
            do {
                let id = self.entry.id
                let files = try deleteEntryAndSave(self.entry, in: self.context)
                self.finished = true; self.saveTask?.cancel()
                NotificationCenter.default.post(name: .journalDidChange, object: id)
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
    var blockID: UUID?
    var previousBlockID: UUID?
    private let placeholder = UILabel()
    private var checklistButtons: [(range: NSRange, button: UIButton)] = []
    private var formattedText: String?
    private var formattedCategory: UIContentSizeCategory?
    private var minimumHeight: NSLayoutConstraint!
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
        checklistButtons.forEach { $0.button.removeFromSuperview() }
        checklistButtons.removeAll()
        accessibilityCustomActions = nil
        let bodyFont = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.beginEditing()
        textStorage.setAttributes([.font: bodyFont, .foregroundColor: UIColor.label], range: fullRange)
        let source = textStorage.string as NSString
        for match in Self.listPattern.matches(in: source as String, range: fullRange) {
            let style = NSMutableParagraphStyle()
            style.headIndent = (source.substring(with: match.range) as NSString).size(withAttributes: [.font: bodyFont]).width
            textStorage.addAttribute(.paragraphStyle, value: style, range: source.paragraphRange(for: match.range))
        }
        var actions: [UIAccessibilityCustomAction] = []
        for match in Self.checklistPattern.matches(in: source as String, range: fullRange) {
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
    init(block: EntryBlock, storage: PhotoStorage, deferLoading: Bool = false, open: @escaping (EntryPhoto) -> Void) {
        super.init(frame: .zero)
        axis = .vertical; spacing = 4
        let photos = block.orderedPhotos
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
        installStack([image, bodyLabel(info, style: .footnote)])
        image.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.6).isActive = true
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
