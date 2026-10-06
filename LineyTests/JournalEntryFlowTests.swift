import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Liney

@MainActor
final class JournalEntryFlowTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: JournalEntry.self,
            EntryBlock.self,
            EntryPhoto.self,
            configurations: configuration
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    func testPhotoDetailLoadsWithoutConstraintException() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PhotoStorage(baseURL: root)
        let name = try storage.saveJPEG(from: makeJPEGData()).fileName
        for file in [name, "missing-fixture.jpg"] {
            let photo = EntryPhoto(fileName: file, displayOrder: 0)
            let detail = PhotoDetailViewController(photo: photo, storage: storage)
            detail.loadViewIfNeeded()
            detail.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            detail.view.layoutIfNeeded()
            func images(in view: UIView) -> [StoredPhotoView] {
                (view as? StoredPhotoView).map { [$0] } ?? view.subviews.flatMap { images(in: $0) }
            }
            let image = try XCTUnwrap(images(in: detail.view).first)
            XCTAssertEqual(image.bounds.height, 844 * 0.6, accuracy: 1)
            if file == name {
                for _ in 0..<100 {
                    if image.image != nil { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertNotNil(image.image)
            }
            XCTAssertEqual(detail.navigationItem.rightBarButtonItems?.count, 2)
        }
    }

    func testNativeDesignRendering() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.tintColor = UIColor(named: "LineyAqua")
        defer { window.isHidden = true }
        for style in [UIUserInterfaceStyle.light, .dark] {
            for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
                let entry = JournalEntry(title: "Native design fixture 原生界面")
                context.insert(entry)
                entry.setBody("☐ A checklist item that wraps naturally with larger text\n☑ 已完成的测试事项\nPlain text remains selectable.", in: context)
                let editor = EntryEditorViewController(entry: entry, isNew: false, context: context)
                let navigation = UINavigationController(rootViewController: editor)
                navigation.traitOverrides.preferredContentSizeCategory = category
                navigation.overrideUserInterfaceStyle = style
                window.rootViewController = navigation
                window.makeKeyAndVisible()
                window.layoutIfNeeded()
                // Allow native symbol layers to finish their first display pass before capture.
                try await Task.sleep(for: .milliseconds(50))
                let suffix = "\(style.rawValue)-\(category.rawValue)"
                let editorImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let editorAttachment = XCTAttachment(image: editorImage)
                editorAttachment.name = "Native editor \(suffix)"
                editorAttachment.lifetime = .keepAlways
                add(editorAttachment)

                let progress = ProcessingViewController(title: String(localized: "Insert Photos"), message: String(localized: "Adding Photos…"))
                progress.traitOverrides.preferredContentSizeCategory = category
                progress.overrideUserInterfaceStyle = style
                window.rootViewController = progress
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                let statusImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let statusAttachment = XCTAttachment(image: statusImage)
                statusAttachment.name = "Native processing \(suffix)"
                statusAttachment.lifetime = .keepAlways
                add(statusAttachment)

                let locked = LockedJournalController(appLock: AppLockModel(), unlock: {})
                locked.traitOverrides.preferredContentSizeCategory = category
                locked.overrideUserInterfaceStyle = style
                window.rootViewController = locked
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                let lockImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let lockAttachment = XCTAttachment(image: lockImage)
                lockAttachment.name = "Native lock \(suffix)"
                lockAttachment.lifetime = .keepAlways
                add(lockAttachment)
            }
        }
    }

    func testChecklistButtonsTogglePersistAndPreserveSurroundingText() throws {
        let entry = JournalEntry(title: "Checklist fixture")
        context.insert(entry)
        entry.setBody("Introduction\n☐ Testing 中文\n☑ Finished\nClosing", in: context)
        try context.save()
        let editor = EntryEditorViewController(entry: entry, isNew: false, context: context)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = editor
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        editor.view.layoutIfNeeded()
        let input = try XCTUnwrap(descendants(editor.view, as: BlockTextView.self).first)
        let buttons = descendants(input, as: UIButton.self).filter { $0.accessibilityIdentifier == "checklist-toggle" }
        XCTAssertEqual(buttons.count, 2)
        let first = try XCTUnwrap(buttons.first)
        first.sendActions(for: .touchUpInside)
        XCTAssertTrue(editor.flush())
        let saved = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(saved.plainTextBody, "Introduction\n☑ Testing 中文\n☑ Finished\nClosing")
        XCTAssertFalse(input.isFirstResponder, "Toggling must not summon the keyboard")
        XCTAssertEqual(input.accessibilityCustomActions?.count, 2)
        input.undoManager?.undo()
        XCTAssertTrue(editor.flush())
        XCTAssertEqual(entry.plainTextBody, "Introduction\n☐ Testing 中文\n☑ Finished\nClosing")
        input.undoManager?.redo()
        XCTAssertTrue(editor.flush())
        XCTAssertEqual(entry.plainTextBody, "Introduction\n☑ Testing 中文\n☑ Finished\nClosing")
        first.sendActions(for: .touchUpInside)
        XCTAssertTrue(editor.flush())
        XCTAssertEqual(entry.plainTextBody, "Introduction\n☐ Testing 中文\n☑ Finished\nClosing")
    }

    func testChecklistControlsFollowEditingAndMultilineTitle() throws {
        let entry = JournalEntry(title: String(repeating: "A long title 中文 ", count: 5))
        context.insert(entry)
        entry.setBody("☐ Original\n☑ Finished", in: context)
        let editor = EntryEditorViewController(entry: entry, isNew: false, context: context)
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.view.layoutIfNeeded()
        func inputs(in view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { inputs(in: $0) }
        }
        let title = try XCTUnwrap(inputs(in: editor.view).first { !($0 is BlockTextView) })
        XCTAssertGreaterThan(title.bounds.height, (title.font?.lineHeight ?? 0) * 2)
        let body = try XCTUnwrap(inputs(in: editor.view).compactMap { $0 as? BlockTextView }.first)
        body.text = "New paragraph\n☐ Changed 中文\nA normal line"
        body.delegate?.textViewDidChange?(body)
        body.layoutIfNeeded()
        let buttons = body.subviews.compactMap { $0 as? UIButton }
        XCTAssertEqual(buttons.count, 1)
        XCTAssertEqual(buttons.first?.accessibilityLabel, "Changed 中文")
        let selection = NSRange(location: 3, length: 0)
        body.selectedRange = selection
        buttons.first?.sendActions(for: .touchUpInside)
        XCTAssertEqual(body.selectedRange, selection)
        XCTAssertTrue(editor.flush())
        XCTAssertEqual(entry.plainTextBody, "New paragraph\n☑ Changed 中文\nA normal line")
        body.text = "No tasks remain"
        body.delegate?.textViewDidChange?(body)
        body.layoutIfNeeded()
        XCTAssertFalse(body.subviews.contains { $0 is UIButton })
        XCTAssertNil(body.accessibilityCustomActions)
    }

    func testSceneLaunchContractAndResizableIPadConfiguration() throws {
        // Read the shipped plist: Bundle resolves device-qualified keys for the current idiom.
        let data = try Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertNotNil(info["UIApplicationSceneManifest"] as? [String: Any])
        XCTAssertNotNil(info["UILaunchScreen"] as? [String: Any])
        XCTAssertNotEqual(info["UIRequiresFullScreen"] as? Bool, true)
        XCTAssertEqual(Set(try XCTUnwrap(info["UISupportedInterfaceOrientations~ipad"] as? [String])), Set([
            "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"
        ]))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        XCTAssertTrue(scene.delegate is JournalSceneDelegate)
        let root = try XCTUnwrap((scene.delegate as? JournalSceneDelegate)?.window?.rootViewController)
        let navigation: UINavigationController?
        if UIDevice.current.userInterfaceIdiom == .pad {
            navigation = (root as? UISplitViewController)?.viewController(for: .primary) as? UINavigationController
        } else {
            navigation = root as? UINavigationController
        }
        XCTAssertTrue(navigation?.viewControllers.first is TimelineViewController)
    }

    func testEditorSavesImmediatelyWhenItsSceneDeactivates() throws {
        let entry = JournalEntry(title: "Scene fixture")
        context.insert(entry)
        entry.setBody("Before editing", in: context)
        try context.save()
        let editorContext = ModelContext(container)
        let editable = try XCTUnwrap(editorContext.model(for: entry.persistentModelID) as? JournalEntry)
        let editor = EntryEditorViewController(entry: editable, isNew: false, context: editorContext)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = editor
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        editor.loadViewIfNeeded()
        func textView(in view: UIView) -> UITextView? {
            (view as? BlockTextView) ?? view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let input = try XCTUnwrap(textView(in: editor.view))
        input.text = "Saved before scene inactivity 中文"
        input.delegate?.textViewDidChange?(input)
        XCTAssertTrue(editorContext.hasChanges)

        // An unrelated lifecycle notification must not flush this editor.
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: NSObject())
        XCTAssertTrue(editorContext.hasChanges)
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        XCTAssertFalse(editorContext.hasChanges)
        let reloaded = try ModelContext(container).fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(reloaded.first?.plainTextBody, "Saved before scene inactivity 中文")
    }

    func testNativeNavigationSavesEditorBeforeSwitchingEntries() async throws {
        let first = JournalEntry(title: "Synthetic first", entryDate: Date(timeIntervalSince1970: 1_700_100_000))
        let second = JournalEntry(title: "Synthetic second", entryDate: Date(timeIntervalSince1970: 1_700_000_000))
        context.insert(first); context.insert(second)
        first.setBody("Original fixture", in: context)
        try context.save()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let timeline = TimelineViewController(container: container, appLock: AppLockModel())
        let navigation = FixtureNavigationController(rootViewController: timeline)
        if UIDevice.current.userInterfaceIdiom == .pad {
            let split = UISplitViewController(style: .doubleColumn)
            split.preferredDisplayMode = .oneBesideSecondary
            split.setViewController(navigation, for: .primary)
            split.setViewController(UINavigationController(rootViewController: UIViewController()), for: .secondary)
            window.rootViewController = split
        } else { window.rootViewController = navigation }
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<100 {
            if timeline.tableView.numberOfSections == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(timeline.tableView.numberOfSections, 2)
        guard timeline.tableView.numberOfSections == 2 else { return }
        func currentEditor() -> EntryEditorViewController? {
            if let split = timeline.splitViewController, !split.isCollapsed {
                return (split.viewController(for: .secondary) as? UINavigationController)?.topViewController as? EntryEditorViewController
            }
            return navigation.topViewController as? EntryEditorViewController
        }
        timeline.tableView(timeline.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        let editor = try XCTUnwrap(currentEditor())
        XCTAssertEqual(editor.entry.id, first.id)
        XCTAssertFalse(editor.context === context)
        editor.loadViewIfNeeded()
        let input = try XCTUnwrap(descendants(editor.view, as: BlockTextView.self).first)
        input.text = "Updated through UIKit 中文"
        input.delegate?.textViewDidChange?(input)
        let dateEditor = EntryDateViewController(entry: editor.entry) { _ = editor.flush() }
        dateEditor.loadViewIfNeeded()
        let picker = try XCTUnwrap(descendants(dateEditor.view, as: UIDatePicker.self).first)
        let adjusted = first.entryDate.addingTimeInterval(60)
        picker.date = adjusted
        picker.sendActions(for: .valueChanged)
        if timeline.splitViewController?.isCollapsed != false {
            XCTAssertTrue(editor.prepareForReplacement())
            navigation.popViewController(animated: false)
        }
        timeline.tableView(timeline.tableView, didSelectRowAt: IndexPath(row: 0, section: 1))
        XCTAssertEqual(currentEditor()?.entry.id, second.id)
        let reloaded = try ModelContext(container).fetch(FetchDescriptor<JournalEntry>())
        let saved = try XCTUnwrap(reloaded.first { $0.id == first.id })
        XCTAssertEqual(saved.plainTextBody, "Updated through UIKit 中文")
        XCTAssertEqual(saved.entryDate.timeIntervalSince1970, adjusted.timeIntervalSince1970, accuracy: 1)
    }

    func testUIKitTimelineRendersAtAccessibilitySize() async throws {
        let controller = TimelineViewController(container: container, appLock: AppLockModel())
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        controller.overrideUserInterfaceStyle = .dark
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutIfNeeded()
        XCTAssertFalse(controller.view.hasAmbiguousLayout)
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            XCTAssertTrue(controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "UIKit timeline accessibility"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBackgroundTimelinePreservesSearchOrderingAndIncrementalUpdates() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        for index in 0..<1_000 {
            let entry = JournalEntry(title: "Synthetic \(index)", entryDate: base.addingTimeInterval(Double(index * 60)),
                                     isAllDay: index % 20 == 0, createdAt: base.addingTimeInterval(Double(index)))
            context.insert(entry)
            entry.setBody(index == 42 ? "Needle 中文 🌿" : "Fixture body", in: context)
        }
        try context.save()
        let repository = TimelineRepository(container: container)
        let start = ContinuousClock.now
        try await repository.reload()
        let result = try await repository.search("", calendar: calendar)
        XCTAssertEqual(result.totalCount, 1_000)
        XCTAssertEqual(result.days.map(\.date), result.days.map(\.date).sorted(by: >))
        for day in result.days {
            let timed = day.entries.prefix { !$0.isAllDay }
            XCTAssertTrue(day.entries.dropFirst(timed.count).allSatisfy(\.isAllDay), "Timed entries precede all-day entries")
            XCTAssertEqual(timed.map(\.entryDate), timed.map(\.entryDate).sorted(by: >))
            let allDay = day.entries.dropFirst(timed.count)
            XCTAssertEqual(allDay.map(\.createdAt), allDay.map(\.createdAt).sorted(by: >))
        }
        let matching = try await repository.search(" needle 中文 ", calendar: calendar)
        XCTAssertEqual(matching.days.flatMap(\.entries).count, 1)
        let value = try XCTUnwrap(matching.days.first?.entries.first)
        let entry = try XCTUnwrap(context.model(for: value.persistentModelID) as? JournalEntry)
        entry.setBody("Updated fixture", in: context)
        try context.save()
        try await repository.update(id: entry.id)
        let removedMatch = try await repository.search("needle")
        XCTAssertTrue(removedMatch.days.isEmpty)
        let id = entry.id
        context.delete(entry); try context.save()
        try await repository.update(id: id)
        let afterDelete = try await repository.search("")
        XCTAssertEqual(afterDelete.totalCount, 999)
        let attachment = XCTAttachment(string: "1,000 synthetic entries: reload, search, update and delete completed in \(start.duration(to: .now)). Simulator timing is diagnostic, not a device performance gate.")
        attachment.name = "UIKit timeline fixture timing"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testReusedPhotoViewIgnoresCancelledImageRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = PhotoStorage(baseURL: directory)
        let red = try storage.saveJPEG(from: makeJPEGData(color: .red)).fileName
        let green = try storage.saveJPEG(from: makeJPEGData(color: .green)).fileName
        let imageView = StoredPhotoView()
        imageView.load(red, storage: storage, pixels: 32)
        imageView.load(green, storage: storage, pixels: 32)
        for _ in 0..<100 {
            if imageView.image != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let image = try XCTUnwrap(imageView.image)
        let pixel = try rgbaPixel(in: image, x: 10, y: 10)
        XCTAssertGreaterThan(pixel[1], pixel[0])
        imageView.load(red, storage: storage, pixels: 32)
        imageView.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(imageView.image)
    }

    func testOffscreenPhotoViewsReleaseDecodedImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = PhotoStorage(baseURL: directory)
        let file = try storage.saveJPEG(from: makeJPEGData()).fileName
        let image = StoredPhotoView()
        image.deferLoading(file, storage: storage, pixels: 32)
        XCTAssertNil(image.image)
        image.updateVisibility(true)
        for _ in 0..<100 {
            if image.image != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(image.image)
        image.updateVisibility(false)
        XCTAssertNil(image.image)
        image.updateVisibility(true)
        for _ in 0..<100 {
            if image.image != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(image.image)
    }

    func testEditorFlushPersistsImmediatelyWithoutWaitingForDebounce() throws {
        let entry = JournalEntry()
        context.insert(entry)
        let editor = EntryEditorViewController(entry: entry, isNew: true, context: context)
        editor.loadViewIfNeeded()
        func textViews(_ view: UIView) -> [UITextView] {
            (view as? BlockTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        let input = try XCTUnwrap(textViews(editor.view).first)
        input.text = "Immediate synthetic save 中文"
        input.delegate?.textViewDidChange?(input)
        XCTAssertTrue(editor.flush())
        let saved = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(saved.plainTextBody, "Immediate synthetic save 中文")
    }

    func testReopenedPhotoOnlyEntryCanContinueWriting() async throws {
        context = container.mainContext
        let entry = JournalEntry()
        context.insert(entry)
        _ = entry.insertPhotoGroup(fileNames: ["synthetic-missing.jpg"], in: context)
        try context.save()

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: EntryEditorViewController(entry: entry, isNew: false, context: context))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(150))
        window.rootViewController?.view.layoutIfNeeded()

        func textViews(in view: UIView) -> [UITextView] {
            (view as? BlockTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
        }
        let textView = try XCTUnwrap(textViews(in: window).last,
                                    "A reopened photo-only entry must expose a body input after the photo group")
        for value in ["S", "Synthetic", "Synthetic continuation 中文 🌿"] {
            textView.text = value
            textView.delegate?.textViewDidChange?(textView)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(textViews(in: window).last === textView)
        }
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(entry.orderedBlocks.map(\.kind), [.photoGroup, .text])
        XCTAssertEqual(entry.plainTextBody, "Synthetic continuation 中文 🌿")
        let reopenedContext = ModelContext(container)
        let reopened = try XCTUnwrap(try reopenedContext.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(reopened.plainTextBody, "Synthetic continuation 中文 🌿")
    }

    func testRapidTypingIntoEmptyEntryDoesNotAppendIntermediateValues() async throws {
        context = container.mainContext
        let entry = JournalEntry()
        context.insert(entry)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: EntryEditorViewController(entry: entry, isNew: true, context: context))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(150))
        window.rootViewController?.view.layoutIfNeeded()
        func textViews(in view: UIView) -> [UITextView] {
            (view as? BlockTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
        }
        let textView = try XCTUnwrap(textViews(in: window).first)
        for value in ["S", "Sy", "Synthetic"] {
            textView.text = value
            textView.delegate?.textViewDidChange?(textView)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(textViews(in: window).first === textView,
                          "Promoting transient text must preserve the native input identity")
        }
        textView.delegate?.textViewDidEndEditing?(textView)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(entry.plainTextBody, "Synthetic")
        XCTAssertEqual(entry.orderedBlocks.count, 1)
        let reopened = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(reopened.plainTextBody, "Synthetic")
    }

    func testFailedSaveRetainsPendingTextAndCanRetry() throws {
        let entry = JournalEntry(title: "Synthetic")
        context.insert(entry)
        try context.save()
        entry.setBody("Pending synthetic edit", in: context)
        XCTAssertThrowsError(try saveEntryChanges(entry, in: context, save: { throw CocoaError(.fileWriteOutOfSpace) }))
        XCTAssertEqual(entry.plainTextBody, "Pending synthetic edit")
        try saveEntryChanges(entry, in: context)
        let reopened = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(reopened.plainTextBody, "Pending synthetic edit")
    }

    func testFailedDeletionRestoresEntryAndSuccessfulDeletionReturnsPhotoFiles() throws {
        let entry = JournalEntry(title: "Synthetic")
        context.insert(entry)
        _ = entry.insertPhotoGroup(fileNames: ["synthetic.jpg"], in: context)
        try context.save()
        XCTAssertThrowsError(try deleteEntryAndSave(entry, in: context, save: { throw CocoaError(.fileWriteOutOfSpace) }))
        let restored = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(restored.photoGroupBlocks.first?.orderedPhotos.first?.fileName, "synthetic.jpg")
        XCTAssertEqual(try deleteEntryAndSave(restored, in: context), ["synthetic.jpg"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<JournalEntry>()).isEmpty)
    }

    func testThumbnailSizeAspectRatioRootsAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PhotoStorage(baseURL: root.appendingPathComponent("one"))
        let other = PhotoStorage(baseURL: root.appendingPathComponent("two"))
        let id = UUID()
        let name = try storage.saveJPEG(from: makeJPEGData(size: CGSize(width: 800, height: 500)), id: id).fileName
        _ = try other.saveJPEG(from: makeJPEGData(size: CGSize(width: 500, height: 800)), id: id)
        let image = try XCTUnwrap(storage.thumbnail(for: name, maxPixelSize: 160)?.cgImage)
        let portrait = try XCTUnwrap(other.thumbnail(for: name, maxPixelSize: 160)?.cgImage)
        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(image.height, 100)
        XCTAssertEqual(portrait.width, 100)
        XCTAssertEqual(portrait.height, 160)
        try storage.delete(fileName: name)
        XCTAssertNil(storage.thumbnail(for: name, maxPixelSize: 160))
        XCTAssertNotNil(other.thumbnail(for: name, maxPixelSize: 160))
        try Data("invalid".utf8).write(to: storage.url(for: name))
        XCTAssertNil(storage.thumbnail(for: name, maxPixelSize: 160))
    }

    func testCreateEditAndReopenEntry() throws {
        let entryDate = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9)))
        let entry = JournalEntry(entryDate: entryDate)
        context.insert(entry)

        entry.title = "Morning"
        entry.setBody("Coffee before the walk.", in: context)
        try context.save()

        let reopened = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(reopened.title, "Morning")
        XCTAssertEqual(reopened.plainTextBody, "Coffee before the walk.")
        XCTAssertEqual(TimelineEntry(reopened).rowTitle, "Morning")
        XCTAssertEqual(TimelineEntry(reopened).rowSubtitle, "Coffee before the walk.")
    }

    func testLocalizationCatalogCoversEnglishAndSimplifiedChinese() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Liney/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["sourceLanguage"] as? String, "en")

        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        var failures: [String] = []
        for (key, rawValue) in strings.sorted(by: { $0.key < $1.key }) {
            guard let value = rawValue as? [String: Any] else {
                failures.append("\(key): invalid entry")
                continue
            }
            if value["extractionState"] as? String == "stale" {
                failures.append("\(key): stale")
            }
            let localizations = value["localizations"] as? [String: Any]
            for locale in ["en", "zh-Hans"] {
                guard let localizedValue = localizations?[locale] as? [String: Any],
                      let stringUnit = localizedValue["stringUnit"] as? [String: Any],
                      stringUnit["state"] as? String == "translated",
                      let text = stringUnit["value"] as? String,
                      !text.isEmpty else {
                    failures.append("\(key): missing \(locale)")
                    continue
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testBlankNewEntryIsDiscarded() throws {
        let entry = JournalEntry(title: "   ")
        context.insert(entry)

        try saveEntryChanges(entry, in: context, discardIfBlank: true)

        XCTAssertEqual(try context.fetch(FetchDescriptor<JournalEntry>()).count, 0)
    }

    func testEntryDateEditsPreserveTimedDateAndNormalizeAllDayDate() throws {
        let calendar = Calendar(identifier: .gregorian)
        let entry = JournalEntry(
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9, minute: 30)))
        )

        let timedDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 20, minute: 15)))
        entry.setEntryDate(timedDate, calendar: calendar)
        XCTAssertFalse(entry.isAllDay)
        XCTAssertEqual(entry.entryDate, timedDate)

        entry.setAllDay(true, calendar: calendar)
        XCTAssertTrue(entry.isAllDay)
        XCTAssertEqual(entry.entryDate, try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6))))

        let allDayDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 17, minute: 45)))
        entry.setEntryDate(allDayDate, calendar: calendar)
        XCTAssertEqual(entry.entryDate, try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 8))))

        entry.setAllDay(false, calendar: calendar)
        entry.setEntryDate(allDayDate, calendar: calendar)
        XCTAssertEqual(entry.entryDate, allDayDate)
    }

    func testTimelineGroupingAndDelete() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let newest = JournalEntry(
            title: "Newest",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 9))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 9)))
        )
        let olderSameDay = JournalEntry(
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 8))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 8)))
        )
        let laterSameDay = JournalEntry(
            title: "Later",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 20))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 20)))
        )

        [olderSameDay, newest, laterSameDay].forEach { context.insert($0) }
        olderSameDay.setBody("Body summary", in: context)
        try context.save()

        let repository = TimelineRepository(container: container)
        try await repository.reload()
        let groups = try await repository.search("", calendar: calendar).days
        XCTAssertEqual(groups.map(\.date), [
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7))),
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6)))
        ])
        XCTAssertEqual(groups[1].entries.map(\.rowTitle), ["Later", "Body summary"])

        let deletedID = laterSameDay.id
        context.delete(laterSameDay)
        try context.save()
        try await repository.update(id: deletedID)

        let remaining = try await repository.search("", calendar: calendar).days.flatMap(\.entries)
        XCTAssertEqual(remaining.map(\.rowTitle).sorted(), ["Body summary", "Newest"])
    }

    func testTimelineOrdersTimedEntriesByTimeAndAllDayEntriesByCreatedAt() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let timedMorning = JournalEntry(
            title: "Morning",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9)))
        )
        let timedEvening = JournalEntry(
            title: "Evening",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 20))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 20)))
        )
        let allDayOlder = JournalEntry(
            title: "All Day Older",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 12))),
            isAllDay: true,
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 10)))
        )
        let allDayNewer = JournalEntry(
            title: "All Day Newer",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 12))),
            isAllDay: true,
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 11)))
        )

        [allDayOlder, timedMorning, allDayNewer, timedEvening].forEach { context.insert($0) }
        try context.save()
        let repository = TimelineRepository(container: container)
        try await repository.reload()
        let groups = try await repository.search("", calendar: calendar).days

        XCTAssertEqual(groups.flatMap { $0.entries.map(\.rowTitle) }, ["Evening", "Morning", "All Day Newer", "All Day Older"])
    }

    func testLocationDisplayTextRequiresMainLocationName() {
        let namedLocation = JournalEntry(locationName: "  Paris  ", locationLatitude: 48.8566, locationLongitude: 2.3522)
        XCTAssertEqual(namedLocation.locationDisplayText, "Paris")

        let coordinatesOnly = JournalEntry(locationLatitude: 48.8566, locationLongitude: 2.3522)
        XCTAssertNil(coordinatesOnly.locationDisplayText)

        let emptyLocation = JournalEntry(locationName: "   ")
        XCTAssertNil(emptyLocation.locationDisplayText)
    }

    func testSearchMatchesTitleAndBodyOnlyAndKeepsTimelineOrder() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let titleMatch = JournalEntry(
            title: "Train Notes",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9)))
        )
        let bodyMatch = JournalEntry(
            title: "Lunch",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 9))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 9)))
        )
        let dateOnlyMatch = JournalEntry(
            title: "Picnic",
            entryDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 9))),
            createdAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 9)))
        )

        [titleMatch, bodyMatch, dateOnlyMatch].forEach { context.insert($0) }
        bodyMatch.setBody("Found a quiet train station.", in: context)
        dateOnlyMatch.setBody("River walk.", in: context)
        try context.save()

        let repository = TimelineRepository(container: container)
        try await repository.reload()
        let groups = try await repository.search("TRAIN", calendar: calendar).days

        XCTAssertEqual(groups.flatMap { $0.entries.map(\.rowTitle) }, ["Lunch", "Train Notes"])
        XCTAssertEqual(groups[0].entries[0].id, bodyMatch.id)
        let dateOnly = try await repository.search("2026", calendar: calendar)
        XCTAssertTrue(dateOnly.days.isEmpty)
        let blank = try await repository.search("   ", calendar: calendar)
        XCTAssertEqual(blank.days.flatMap(\.entries).count, 3)
    }

    func testInsertPhotoGroupSplitsFocusedTextBlockAndPreservesPhotoOrder() throws {
        let entry = JournalEntry()
        context.insert(entry)
        entry.setBody("Hello world", in: context)
        let textBlock = try XCTUnwrap(entry.textBlocks.first)

        let photoBlock = try XCTUnwrap(entry.insertPhotoGroup(
            fileNames: ["first.jpg", "second.jpg"],
            focusedTextBlockID: textBlock.id,
            cursorOffset: 5,
            in: context
        ))
        try context.save()

        let blocks = entry.orderedBlocks
        XCTAssertEqual(blocks.map(\.kind), [.text, .photoGroup, .text])
        XCTAssertEqual(blocks[0].text, "Hello")
        XCTAssertEqual(blocks[1].orderedPhotos.map(\.fileName), ["first.jpg", "second.jpg"])
        XCTAssertEqual(blocks[2].text, " world")
        XCTAssertEqual(photoBlock.id, blocks[1].id)

        let reopened = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(reopened.orderedBlocks.map(\.kind), [.text, .photoGroup, .text])
        XCTAssertEqual(reopened.photoGroupBlocks.first?.orderedPhotos.map(\.fileName), ["first.jpg", "second.jpg"])
    }

    func testInsertPhotoGroupAtFocusedEndAndWithoutFocusAppends() throws {
        let focusedEntry = JournalEntry()
        context.insert(focusedEntry)
        focusedEntry.setBody("End", in: context)
        let textBlock = try XCTUnwrap(focusedEntry.textBlocks.first)

        _ = try XCTUnwrap(focusedEntry.insertPhotoGroup(
            fileNames: ["end.jpg"],
            focusedTextBlockID: textBlock.id,
            cursorOffset: 3,
            in: context
        ))
        XCTAssertEqual(focusedEntry.orderedBlocks.map(\.kind), [.text, .photoGroup])

        let noFocusEntry = JournalEntry()
        context.insert(noFocusEntry)
        noFocusEntry.setBody("Body", in: context)
        _ = noFocusEntry.insertPhotoGroup(fileNames: ["tail.jpg"], in: context)

        XCTAssertEqual(noFocusEntry.orderedBlocks.map(\.kind), [.text, .photoGroup])
        XCTAssertEqual(noFocusEntry.photoGroupBlocks.first?.orderedPhotos.first?.fileName, "tail.jpg")
    }

    func testNormalizeBlocksDropsEmptyTextAndMergesAdjacentText() throws {
        let entry = JournalEntry()
        let first = EntryBlock(sortIndex: 0, text: "First", entry: entry)
        let empty = EntryBlock(sortIndex: 1, text: "   ", entry: entry)
        let second = EntryBlock(sortIndex: 2, text: "Second", entry: entry)
        entry.blocks = [first, empty, second]
        context.insert(entry)
        [first, empty, second].forEach { context.insert($0) }

        entry.normalizeBlocks(in: context)
        try context.save()

        XCTAssertEqual(entry.orderedBlocks.count, 1)
        XCTAssertEqual(entry.orderedBlocks.first?.text, "First\nSecond")
    }

    func testPhotoOnlyEntryIsNotBlankAndPreviewsThreePhotos() throws {
        let entry = JournalEntry()
        context.insert(entry)

        _ = entry.insertPhotoGroup(fileNames: ["1.jpg", "2.jpg", "3.jpg", "4.jpg"], in: context)
        try context.save()

        XCTAssertFalse(entry.isBlank)
        XCTAssertEqual(TimelineEntry(entry).previewFiles, ["1.jpg", "2.jpg", "3.jpg"])
    }

    func testPhotoMetadataVisibilityRequiresCaptureTimeOrPlaceText() {
        XCTAssertFalse(EntryPhoto(fileName: "plain.jpg").hasVisibleMetadata)
        let coordinatesOnly = EntryPhoto(fileName: "gps.jpg", locationLatitude: 48.8566, locationLongitude: 2.3522)
        XCTAssertFalse(coordinatesOnly.hasVisibleMetadata)
        XCTAssertTrue(coordinatesOnly.hasUsableEntryInfo)

        let captured = EntryPhoto(fileName: "captured.jpg", capturedAt: Date())
        XCTAssertTrue(captured.hasVisibleMetadata)
        XCTAssertTrue(captured.hasUsableEntryInfo)

        let placed = EntryPhoto(fileName: "placed.jpg", placeName: "  Paris  ")
        XCTAssertEqual(placed.placeDisplayText, "Paris")
        XCTAssertTrue(placed.hasVisibleMetadata)
    }

    func testApplyPhotoInfoUpdatesEntryDateAndNamedLocation() throws {
        let calendar = Calendar(identifier: .gregorian)
        let originalDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        let capturedAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 20, minute: 15)))
        let entry = JournalEntry(entryDate: originalDate, isAllDay: true)
        let photo = EntryPhoto(
            fileName: "paris.jpg",
            capturedAt: capturedAt,
            placeName: "  Paris  ",
            locationLatitude: 48.8566,
            locationLongitude: 2.3522
        )

        entry.applyInfo(from: photo)

        XCTAssertFalse(entry.isAllDay)
        XCTAssertEqual(entry.entryDate, capturedAt)
        XCTAssertEqual(entry.locationName, "Paris")
        XCTAssertEqual(entry.locationLatitude, 48.8566)
        XCTAssertEqual(entry.locationLongitude, 2.3522)
    }

    func testPhotoInfoPromptUsesTimeAndLocationThresholds() throws {
        let calendar = Calendar(identifier: .gregorian)
        let entryDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9)))
        let entry = JournalEntry(
            entryDate: entryDate,
            locationName: "Paris",
            locationLatitude: 48.8566,
            locationLongitude: 2.3522
        )

        let exactlyTwelveHours = EntryPhoto(
            fileName: "same-day.jpg",
            capturedAt: entryDate.addingTimeInterval(12 * 60 * 60),
            placeName: "Paris",
            locationLatitude: 48.8567,
            locationLongitude: 2.3523
        )
        XCTAssertFalse(entry.shouldPromptForPhotoInfo(from: exactlyTwelveHours))

        let moreThanTwelveHours = EntryPhoto(
            fileName: "different-time.jpg",
            capturedAt: entryDate.addingTimeInterval(12 * 60 * 60 + 1)
        )
        XCTAssertTrue(entry.shouldPromptForPhotoInfo(from: moreThanTwelveHours))

        let farLocation = EntryPhoto(
            fileName: "london.jpg",
            placeName: "London",
            locationLatitude: 51.5074,
            locationLongitude: -0.1278
        )
        XCTAssertTrue(entry.shouldPromptForPhotoInfo(from: farLocation))

        let farCoordinatesOnly = EntryPhoto(
            fileName: "gps-only.jpg",
            locationLatitude: 51.5074,
            locationLongitude: -0.1278
        )
        XCTAssertTrue(entry.shouldPromptForPhotoInfo(from: farCoordinatesOnly))
    }

    func testPhotoInfoPromptUsesMissingEntryLocationAndKeepsGeocodeFailureCoordinatesInternal() {
        let missingLocationEntry = JournalEntry()
        let placedPhoto = EntryPhoto(
            fileName: "placed.jpg",
            placeName: "Paris",
            locationLatitude: 48.8566,
            locationLongitude: 2.3522
        )
        XCTAssertTrue(missingLocationEntry.shouldPromptForPhotoInfo(from: placedPhoto))

        let coordinatesOnlyPhoto = EntryPhoto(
            fileName: "coordinates-only.jpg",
            locationLatitude: 48.8566,
            locationLongitude: 2.3522
        )
        XCTAssertTrue(missingLocationEntry.shouldPromptForPhotoInfo(from: coordinatesOnlyPhoto))

        missingLocationEntry.applyInfo(from: coordinatesOnlyPhoto)
        XCTAssertNil(missingLocationEntry.locationDisplayText)
        XCTAssertEqual(missingLocationEntry.locationLatitude, 48.8566)
        XCTAssertEqual(missingLocationEntry.locationLongitude, 2.3522)

        let namedLocationEntry = JournalEntry(locationName: "Paris")
        namedLocationEntry.applyInfo(from: coordinatesOnlyPhoto)
        XCTAssertNil(namedLocationEntry.locationDisplayText)
        XCTAssertEqual(namedLocationEntry.locationLatitude, 48.8566)
        XCTAssertEqual(namedLocationEntry.locationLongitude, 2.3522)

        missingLocationEntry.hasShownPhotoInfoPrompt = true
        XCTAssertFalse(missingLocationEntry.shouldPromptForPhotoInfo(from: placedPhoto))
    }

    func testPhotoInfoPromptCandidateOnlyConsidersFirstAddedPhoto() {
        let entry = JournalEntry(locationName: "Paris", locationLatitude: 48.8566, locationLongitude: 2.3522)
        let firstPhoto = EntryPhoto(fileName: "first.jpg", placeName: "Paris", locationLatitude: 48.8567, locationLongitude: 2.3523)
        let laterDifferentPhoto = EntryPhoto(fileName: "later.jpg", placeName: "London", locationLatitude: 51.5074, locationLongitude: -0.1278)

        XCTAssertNil(entry.photoInfoPromptCandidate(from: [firstPhoto, laterDifferentPhoto]))
        XCTAssertTrue(entry.photoInfoPromptCandidate(from: [laterDifferentPhoto, firstPhoto]) === laterDifferentPhoto)
    }

    func testDeletePhotoRemovesPhotoAndReindexesGroup() throws {
        let entry = JournalEntry()
        context.insert(entry)
        _ = entry.insertPhotoGroup(fileNames: ["1.jpg", "2.jpg", "3.jpg"], in: context)
        let block = try XCTUnwrap(entry.photoGroupBlocks.first)
        let deletedPhoto = block.orderedPhotos[1]

        let deletedFileName = entry.deletePhoto(deletedPhoto, in: context)
        try context.save()

        XCTAssertEqual(deletedFileName, "2.jpg")
        XCTAssertEqual(entry.photoGroupBlocks.count, 1)
        XCTAssertEqual(block.orderedPhotos.map(\.fileName), ["1.jpg", "3.jpg"])
        XCTAssertEqual(block.orderedPhotos.map(\.displayOrder), [0, 1])
    }

    func testDeleteLastPhotoRemovesEmptyPhotoGroup() throws {
        let entry = JournalEntry()
        context.insert(entry)
        _ = entry.insertPhotoGroup(fileNames: ["only.jpg"], in: context)
        let photo = try XCTUnwrap(entry.photoGroupBlocks.first?.orderedPhotos.first)

        entry.deletePhoto(photo, in: context)
        try context.save()

        XCTAssertTrue(entry.photoGroupBlocks.isEmpty)
        XCTAssertTrue(entry.orderedBlocks.isEmpty)
    }

    func testPhotoStorageCreatesJPEGAndReportsPartialFailure() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = PhotoStorage(baseURL: baseURL)
        let validImageData = makeJPEGData()

        let result = await storage.savePhotos([{ validImageData }, { Data("not an image".utf8) }])

        XCTAssertEqual(result.fileNames.count, 1)
        XCTAssertEqual(result.failedCount, 1)
        let copiedURL = storage.url(for: try XCTUnwrap(result.fileNames.first))
        XCTAssertEqual(copiedURL.pathExtension, "jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path))
        XCTAssertNotNil(CGImageSourceCreateWithURL(copiedURL as CFURL, nil))

        try storage.delete(fileName: try XCTUnwrap(result.fileNames.first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedURL.path))
    }

    func testPhotoStorageCountsLoaderThatThrowsAsFailure() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = PhotoStorage(baseURL: baseURL)
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let validImageData = makeJPEGData()

        let result = await storage.savePhotos([{ throw PhotoStorageError.unreadableImage }, { validImageData }])

        XCTAssertEqual(result.fileNames.count, 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertFalse(result.storageWasFull)
    }

    func testPhotoStoragePreservesCaptureTimeAndGPSMetadata() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = PhotoStorage(baseURL: baseURL)
        let imageData = makeLocatedJPEGData(
            capturedAtText: "2026:07:06 20:15:00",
            latitude: 48.8566,
            longitude: 2.3522
        )

        let result = await storage.savePhotos([{ imageData }])
        let photo = try XCTUnwrap(result.photos.first)

        XCTAssertEqual(photo.capturedAt, exifDate("2026:07:06 20:15:00"))
        XCTAssertEqual(try XCTUnwrap(photo.locationLatitude), 48.8566, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(photo.locationLongitude), 2.3522, accuracy: 0.0001)
    }

    func testPhotoGroupLayoutThresholds() {
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 0), 1)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 1), 1)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 2), 2)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 3), 3)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 4), 2)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 5), 3)
    }

    func testSinglePortraitPhotoUsesItsAspectRatio() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = PhotoStorage(baseURL: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let item = try storage.saveJPEG(from: makeJPEGData(size: CGSize(width: 200, height: 300)))
        let block = EntryBlock(kind: .photoGroup)
        block.photos = [EntryPhoto(fileName: item.fileName, displayOrder: 0, block: block)]
        let group = PhotoGroupView(block: block, storage: storage) { _ in }
        let wrapper = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 700))
        group.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(group)
        NSLayoutConstraint.activate([
            group.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            group.topAnchor.constraint(equalTo: wrapper.topAnchor),
            group.widthAnchor.constraint(equalToConstant: 320)
        ])
        for _ in 0..<100 {
            if group.photoViews.first?.image != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        wrapper.layoutIfNeeded()
        XCTAssertNotNil(group.photoViews.first?.image)
        XCTAssertEqual(group.bounds.height, 480, accuracy: 1, "Portrait photos should not sit in a landscape letterbox")
    }

    func testThreePhotoLayoutSmokeRendersOnSimulator() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = PhotoStorage(baseURL: baseURL)
        let result = await storage.savePhotos([
            { makeJPEGData(size: CGSize(width: 96, height: 48), color: .systemRed) },
            { makeJPEGData(size: CGSize(width: 48, height: 96), color: .systemGreen) },
            { makeJPEGData(size: CGSize(width: 96, height: 96), color: .systemBlue) }
        ])
        XCTAssertEqual(result.failedCount, 0)

        let block = EntryBlock(kind: .photoGroup)
        block.photos = result.photos.enumerated().map { index, photo in
            EntryPhoto(fileName: photo.fileName, displayOrder: index, block: block)
        }

        let group = PhotoGroupView(block: block, storage: storage) { _ in }
        group.backgroundColor = .white
        group.frame = CGRect(x: 0, y: 0, width: 320, height: 104)
        group.layoutIfNeeded()
        func images(in view: UIView) -> [StoredPhotoView] {
            (view as? StoredPhotoView).map { [$0] } ?? view.subviews.flatMap { images(in: $0) }
        }
        for _ in 0..<100 {
            if images(in: group).allSatisfy({ $0.image != nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(images(in: group).filter { $0.image != nil }.count, 3)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: group.bounds, format: format).image { ctx in
            group.layer.render(in: ctx.cgContext)
        }
        XCTAssertEqual(image.size.height, 104, accuracy: 1)
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 106, y: 52)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 214, y: 52)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 0, y: 0)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 108, y: 0)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 216, y: 0)))
        let attachment = XCTAttachment(image: image)
        attachment.name = "Three-photo layout smoke"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPreviewThumbnailsStayInsideFixedBoxes() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = PhotoStorage(baseURL: baseURL)
        let result = await storage.savePhotos([
            { makeJPEGData(size: CGSize(width: 96, height: 48), color: .systemRed) },
            { makeJPEGData(size: CGSize(width: 48, height: 96), color: .systemGreen) },
            { makeJPEGData(size: CGSize(width: 96, height: 96), color: .systemBlue) }
        ])
        XCTAssertEqual(result.failedCount, 0)
        let photos = result.photos.enumerated().map { index, photo in
            EntryPhoto(fileName: photo.fileName, displayOrder: index)
        }

        let row = UIStackView()
        row.spacing = 6; row.backgroundColor = .white
        for photo in photos {
            let image = StoredPhotoView()
            image.layer.cornerRadius = 6
            image.widthAnchor.constraint(equalToConstant: 48).isActive = true
            image.heightAnchor.constraint(equalToConstant: 48).isActive = true
            image.load(photo.fileName, storage: storage)
            row.addArrangedSubview(image)
        }
        row.frame = CGRect(x: 0, y: 0, width: 156, height: 48)
        row.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: row.bounds, format: format).image { ctx in
            row.layer.render(in: ctx.cgContext)
        }
        XCTAssertEqual(image.size.height, 48, accuracy: 1)
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 51, y: 24)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 105, y: 24)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 0, y: 0)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 54, y: 0)))
        XCTAssertTrue(isWhite(try rgbaPixel(in: image, x: 108, y: 0)))
    }

    private func rgbaPixel(in image: UIImage, x: Int, y: Int) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        try pixel.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.translateBy(x: CGFloat(-x), y: CGFloat(y + 1 - cgImage.height))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }

        return pixel
    }

    private func isWhite(_ pixel: [UInt8]) -> Bool {
        pixel[0] > 245 && pixel[1] > 245 && pixel[2] > 245
    }

    private func makeLocatedJPEGData(capturedAtText: String, latitude: Double, longitude: Double) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: capturedAtText
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: abs(latitude),
                kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(longitude),
                kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E"
            ]
        ]
        CGImageDestinationAddImage(destination, image.cgImage!, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func exifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}

/// This controller test drives navigation synchronously; animation timing belongs to UI acceptance.
private final class FixtureNavigationController: UINavigationController {
    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        super.pushViewController(viewController, animated: false)
    }
}
