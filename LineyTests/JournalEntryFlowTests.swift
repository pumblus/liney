import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Liney

@MainActor
final class JournalEntryFlowTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

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
        func descendants<T: UIView>(_ view: UIView, type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type: type) }
        }
        let input = try XCTUnwrap(descendants(editor.view, type: UITextView.self).first)
        input.text = "Updated through UIKit 中文"
        input.delegate?.textViewDidChange?(input)
        let dateEditor = EntryDateViewController(entry: editor.entry) { _ = editor.flush() }
        dateEditor.loadViewIfNeeded()
        let picker = try XCTUnwrap(descendants(dateEditor.view, type: UIDatePicker.self).first)
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

    func testUIKitOnboardingRendersAtAccessibilitySize() async throws {
        let controller = OnboardingController(container: container, finish: {})
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
        attachment.name = "UIKit onboarding accessibility"; attachment.lifetime = .keepAlways
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
        let expected = groupEntriesByDay(try context.fetch(FetchDescriptor<JournalEntry>()), calendar: calendar)
        XCTAssertEqual(result.days.map { $0.entries.map(\.id) }, expected.map { $0.entries.map(\.id) })
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
        let red = try storage.saveJPEG(from: makeJPEGData(color: .red))
        let green = try storage.saveJPEG(from: makeJPEGData(color: .green))
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
        let file = try storage.saveJPEG(from: makeJPEGData())
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
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
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
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
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
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
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
        let name = try storage.saveJPEG(from: qualityPerfJPEGData(size: CGSize(width: 800, height: 500)), id: id)
        _ = try other.saveJPEG(from: qualityPerfJPEGData(size: CGSize(width: 500, height: 800)), id: id)
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
        XCTAssertEqual(reopened.rowTitle, "Morning")
        XCTAssertEqual(reopened.rowSubtitle, "Coffee before the walk.")
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

        XCTAssertTrue(discardBlankNewEntry(entry, in: context))
        try context.save()

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

    func testTimelineGroupingAndDelete() throws {
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

        let groups = groupEntriesByDay([olderSameDay, newest, laterSameDay], calendar: calendar)
        XCTAssertEqual(groups.map(\.date), [
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7))),
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6)))
        ])
        XCTAssertEqual(groups[1].entries.map(\.rowTitle), ["Later", "Body summary"])

        context.delete(laterSameDay)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(remaining.map(\.rowTitle).sorted(), ["Body summary", "Newest"])
    }

    func testTimelineOrdersTimedEntriesByTimeAndAllDayEntriesByCreatedAt() throws {
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

        let groups = groupEntriesByDay([allDayOlder, timedMorning, allDayNewer, timedEvening], calendar: calendar)

        XCTAssertEqual(groups.flatMap { $0.entries.map(\.title) }, ["Evening", "Morning", "All Day Newer", "All Day Older"])
    }

    func testLocationDisplayTextRequiresMainLocationName() {
        let namedLocation = JournalEntry(locationName: "  Paris  ", locationLatitude: 48.8566, locationLongitude: 2.3522)
        XCTAssertEqual(namedLocation.locationDisplayText, "Paris")

        let coordinatesOnly = JournalEntry(locationLatitude: 48.8566, locationLongitude: 2.3522)
        XCTAssertNil(coordinatesOnly.locationDisplayText)

        let emptyLocation = JournalEntry(locationName: "   ")
        XCTAssertNil(emptyLocation.locationDisplayText)
    }

    func testSearchMatchesTitleAndBodyOnlyAndKeepsTimelineOrder() throws {
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

        let entries = [dateOnlyMatch, bodyMatch, titleMatch]
        let groups = groupEntriesByDay(searchJournalEntries(entries, matching: "TRAIN"), calendar: calendar)

        XCTAssertEqual(groups.flatMap { $0.entries.map(\.title) }, ["Lunch", "Train Notes"])
        XCTAssertTrue(groups[0].entries[0] === bodyMatch)
        XCTAssertTrue(searchJournalEntries(entries, matching: "2026").isEmpty)
        XCTAssertEqual(searchJournalEntries(entries, matching: "   ").count, 3)
    }

    func testInsertPhotoGroupSplitsFocusedTextBlockAndPreservesPhotoOrder() throws {
        let entry = JournalEntry()
        context.insert(entry)
        entry.setBody("Hello world", in: context)
        let textBlock = try XCTUnwrap(entry.textBlocks.first)

        let insertion = try XCTUnwrap(entry.insertPhotoGroup(
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
        XCTAssertEqual(insertion.followingTextBlock?.id, blocks[2].id)

        let reopened = try XCTUnwrap(try context.fetch(FetchDescriptor<JournalEntry>()).first)
        XCTAssertEqual(reopened.orderedBlocks.map(\.kind), [.text, .photoGroup, .text])
        XCTAssertEqual(reopened.photoGroupBlocks.first?.orderedPhotos.map(\.fileName), ["first.jpg", "second.jpg"])
    }

    func testInsertPhotoGroupAtFocusedEndAndWithoutFocusAppends() throws {
        let focusedEntry = JournalEntry()
        context.insert(focusedEntry)
        focusedEntry.setBody("End", in: context)
        let textBlock = try XCTUnwrap(focusedEntry.textBlocks.first)

        let focusedInsertion = try XCTUnwrap(focusedEntry.insertPhotoGroup(
            fileNames: ["end.jpg"],
            focusedTextBlockID: textBlock.id,
            cursorOffset: 3,
            in: context
        ))
        XCTAssertNil(focusedInsertion.followingTextBlock)
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
        XCTAssertEqual(entry.previewPhotos.map(\.fileName), ["1.jpg", "2.jpg", "3.jpg"])
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

    func testPhotoStorageCreatesJPEGAndReportsPartialFailure() throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = PhotoStorage(baseURL: baseURL)
        let validImageData = makeJPEGData()

        let result = storage.saveJPEGs(from: [validImageData, Data("not an image".utf8)])

        XCTAssertEqual(result.fileNames.count, 1)
        XCTAssertEqual(result.failedCount, 1)
        let copiedURL = storage.url(for: try XCTUnwrap(result.fileNames.first))
        XCTAssertEqual(copiedURL.pathExtension, "jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path))
        XCTAssertNotNil(CGImageSourceCreateWithURL(copiedURL as CFURL, nil))

        try storage.delete(fileName: try XCTUnwrap(result.fileNames.first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedURL.path))
    }

    func testPhotoStoragePreservesCaptureTimeAndGPSMetadata() throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = PhotoStorage(baseURL: baseURL)
        let imageData = makeJPEGData(
            capturedAtText: "2026:07:06 20:15:00",
            latitude: 48.8566,
            longitude: 2.3522
        )

        let result = storage.saveJPEGs(from: [imageData])
        let photo = try XCTUnwrap(result.photos.first)

        XCTAssertEqual(photo.capturedAt, exifDate("2026:07:06 20:15:00"))
        XCTAssertEqual(try XCTUnwrap(photo.locationLatitude), 48.8566, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(photo.locationLongitude), 2.3522, accuracy: 0.0001)
    }

    func testPhotoImportResultCreatesPartialFailureAlert() {
        XCTAssertNil(PhotoImportResult(fileNames: ["ok.jpg"], failedCount: 0).alert)
        XCTAssertEqual(PhotoImportResult(fileNames: ["ok.jpg"], failedCount: 1).alert?.failedCount, 1)
        XCTAssertEqual(PhotoImportResult(fileNames: ["ok.jpg"], failedCount: 2).alert?.failedCount, 2)
    }

    func testPhotoGroupLayoutThresholds() {
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 0), 1)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 1), 1)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 2), 2)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 3), 3)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 4), 2)
        XCTAssertEqual(photoGroupColumnCount(forPhotoCount: 5), 3)
    }

    func testPhotoGroupLayoutPlanUsesSquareCells() {
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 1).map(\.columnSpan), [1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 2).map(\.columnSpan), [1, 1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 3).map(\.columnSpan), [1, 1, 1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 4).map(\.columnSpan), [1, 1, 1, 1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 5).map(\.columnSpan), [1, 1, 1, 1, 1])

        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 1).map(\.aspectRatio), [1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 2).map(\.aspectRatio), [1, 1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 3).map(\.aspectRatio), [1, 1, 1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 4).map(\.aspectRatio), [1, 1, 1, 1])
        XCTAssertEqual(photoGroupLayoutPlan(forPhotoCount: 5).map(\.aspectRatio), [1, 1, 1, 1, 1])
    }

    func testThreePhotoLayoutSmokeRendersOnSimulator() async throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = PhotoStorage(baseURL: baseURL)
        let result = storage.saveJPEGs(from: [
            makeJPEGData(size: CGSize(width: 96, height: 48), color: .systemRed),
            makeJPEGData(size: CGSize(width: 48, height: 96), color: .systemGreen),
            makeJPEGData(size: CGSize(width: 96, height: 96), color: .systemBlue)
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

    func testPreviewThumbnailsStayInsideFixedBoxes() throws {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = PhotoStorage(baseURL: baseURL)
        let result = storage.saveJPEGs(from: [
            makeJPEGData(size: CGSize(width: 96, height: 48), color: .systemRed),
            makeJPEGData(size: CGSize(width: 48, height: 96), color: .systemGreen),
            makeJPEGData(size: CGSize(width: 96, height: 96), color: .systemBlue)
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

    private func makeJPEGData(size: CGSize = CGSize(width: 32, height: 24), color: UIColor = .systemBlue) -> Data {
        UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 1) { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
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

    private func makeJPEGData(capturedAtText: String, latitude: Double, longitude: Double) -> Data {
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

extension JournalEntryFlowTests {
// MARK: Photo decode: baseline, cold bounded thumbnails, and warm cache

func testPhotoStorageThumbnailPerformanceOnSyntheticFixtures() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("LineyPhotoPerformance-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let storage = PhotoStorage(baseURL: rootURL)
    let sourceData = qualityPerfJPEGData(size: CGSize(width: 2_400, height: 1_800))
    let seedFileName = try storage.saveJPEG(from: sourceData)
    let seedURL = storage.url(for: seedFileName)
    let seedData = try Data(contentsOf: seedURL)

    let pathSets: [[String]] = try (0..<3).map { round in
        try (0..<50).map { index in
            let fileName = "fixture-\(round)-\(index).jpg"
            let destinationURL = storage.url(for: fileName)
            try FileManager.default.createDirectory(
                at: storage.photoDirectoryURL,
                withIntermediateDirectories: true
            )
            try seedData.write(to: destinationURL, options: .atomic)
            return fileName
        }
    }

    var baselineSamples: [Double] = []
    var coldThumbnailSamples: [Double] = []
    var warmThumbnailSamples: [Double] = []
    var baselineDecodedBytes = 0
    var coldDecodedBytes = 0
    var warmDecodedBytes = 0

    for fileNames in pathSets {
        var baselineBytes = 0
        let baselineStart = DispatchTime.now().uptimeNanoseconds
        for fileName in fileNames {
            if let image = storage.image(for: fileName) {
                baselineBytes += qualityPerfMaterialize(image)
            }
        }
        baselineSamples.append(qualityPerfMilliseconds(since: baselineStart))
        baselineDecodedBytes = baselineBytes

        var coldBytes = 0
        let coldStart = DispatchTime.now().uptimeNanoseconds
        for fileName in fileNames {
            if let image = storage.thumbnail(for: fileName, maxPixelSize: 160) {
                coldBytes += qualityPerfMaterialize(image)
            }
        }
        coldThumbnailSamples.append(qualityPerfMilliseconds(since: coldStart))
        coldDecodedBytes = coldBytes

        var warmBytes = 0
        let warmStart = DispatchTime.now().uptimeNanoseconds
        for fileName in fileNames {
            if let image = storage.thumbnail(for: fileName, maxPixelSize: 160) {
                warmBytes += qualityPerfMaterialize(image)
            }
        }
        warmThumbnailSamples.append(qualityPerfMilliseconds(since: warmStart))
        warmDecodedBytes = warmBytes
    }

    print("[PERF-photo] condition=iOS simulator; image=2400x1800; paths=50; rounds=3")
    print("[PERF-photo] baseline_image_for median_ms=\(qualityPerfMedian(baselineSamples)) p95_ms=\(qualityPerfP95(baselineSamples)) decoded_bytes_estimate=\(baselineDecodedBytes)")
    print("[PERF-photo] thumbnail_160_cold median_ms=\(qualityPerfMedian(coldThumbnailSamples)) p95_ms=\(qualityPerfP95(coldThumbnailSamples)) decoded_bytes_estimate=\(coldDecodedBytes)")
    print("[PERF-photo] thumbnail_160_warm median_ms=\(qualityPerfMedian(warmThumbnailSamples)) p95_ms=\(qualityPerfP95(warmThumbnailSamples)) decoded_bytes_estimate=\(warmDecodedBytes)")
}

// MARK: Timeline/search pure-function baseline

func testTimelineSearchPerformanceOnSyntheticFixture() throws {
    let calendar = Calendar(identifier: .gregorian)
    let startDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let commonText = String(repeating: "alpha beta gamma ", count: 256)

    for index in 0..<1_000 {
        let date = startDate.addingTimeInterval(TimeInterval(index * 60))
        let entry = JournalEntry(
            title: "Synthetic Entry \(index)",
            entryDate: date,
            createdAt: date
        )
        context.insert(entry)
        entry.setBody("\(commonText)needle-\(String(format: "%04d", index))", in: context)
    }
    try context.save()

    let entries = try context.fetch(FetchDescriptor<JournalEntry>())
    XCTAssertEqual(entries.count, 1_000)

    var searchSamples: [Double] = []
    var groupingSamples: [Double] = []
    var matchCount = 0
    var groupCount = 0

    for _ in 0..<3 {
        let searchStart = DispatchTime.now().uptimeNanoseconds
        let matches = searchJournalEntries(entries, matching: "needle")
        searchSamples.append(qualityPerfMilliseconds(since: searchStart))
        matchCount = matches.count

        let groupingStart = DispatchTime.now().uptimeNanoseconds
        let groups = groupEntriesByDay(matches, calendar: calendar)
        groupingSamples.append(qualityPerfMilliseconds(since: groupingStart))
        groupCount = groups.count
    }

    XCTAssertEqual(matchCount, 1_000)
    XCTAssertGreaterThan(groupCount, 0)
    print("[PERF-search] entries=1000 body_bytes_each=4363 rounds=3 query=needle")
    print("[PERF-search] filter median_ms=\(qualityPerfMedian(searchSamples)) p95_ms=\(qualityPerfP95(searchSamples)) matches=\(matchCount)")
    print("[PERF-search] group_by_day median_ms=\(qualityPerfMedian(groupingSamples)) p95_ms=\(qualityPerfP95(groupingSamples)) groups=\(groupCount)")
}

// MARK: Synchronous long-text save baseline

func testLongTextSavePerformanceOnSyntheticFixture() throws {
    let startDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let longText = String(repeating: "0123456789", count: 20_000)
    XCTAssertEqual(longText.utf8.count, 200_000)

    let entry = JournalEntry(entryDate: startDate, createdAt: startDate)
    context.insert(entry)
    entry.setBody(longText, in: context)
    try context.save()

    var samples: [Double] = []
    for index in 0..<50 {
        let start = DispatchTime.now().uptimeNanoseconds
        entry.setBody("\(longText)\(index % 10)", in: context)
        try saveEntryChanges(entry, in: context)
        samples.append(qualityPerfMilliseconds(since: start))
    }

    print("[PERF-save] text_bytes=200000 saves=50 model_context=in-memory synchronous")
    print("[PERF-save] save_change_like median_ms=\(qualityPerfMedian(samples)) p95_ms=\(qualityPerfP95(samples)) total_ms=\(String(format: "%.2f", samples.reduce(0, +)))")
}

// MARK: Helpers

private func qualityPerfJPEGData(size: CGSize) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.95) { rendererContext in
        UIColor.systemBlue.setFill()
        rendererContext.fill(CGRect(origin: .zero, size: size))
    }
}

private func qualityPerfMaterialize(_ image: UIImage) -> Int {
    guard let cgImage = image.cgImage,
          let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        return 0
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    return cgImage.width * cgImage.height * 4
}

private func qualityPerfMilliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func qualityPerfMedian(_ samples: [Double]) -> String {
    let sorted = samples.sorted()
    guard !sorted.isEmpty else { return "n/a" }
    return String(format: "%.2f", sorted[sorted.count / 2])
}

private func qualityPerfP95(_ samples: [Double]) -> String {
    let sorted = samples.sorted()
    guard !sorted.isEmpty else { return "n/a" }
    let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
    return String(format: "%.2f", sorted[index])
}

}

/// This controller test drives navigation synchronously; animation timing belongs to UI acceptance.
private final class FixtureNavigationController: UINavigationController {
    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        super.pushViewController(viewController, animated: false)
    }
}
