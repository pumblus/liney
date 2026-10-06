import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Liney

@MainActor
struct EditorUsabilityTests {

    @Test func emptyBodyFillsWritingAreaAndNavigationRemainsNative() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let entry = JournalEntry(title: "Fixture title")
        context.insert(entry)
        let editor = EntryEditorViewController(entry: entry, isNew: true, context: context)
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(editor, animated: false)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        editor.view.layoutIfNeeded()
        let body = try #require(descendants(editor.view, as: BlockTextView.self).last)
        #expect(body.bounds.height > 200)
        #expect(descendants(body, as: UILabel.self).contains { $0.text == String(localized: "Write something...") && !$0.isHidden })
        #expect(!editor.navigationItem.hidesBackButton)
        #expect(body.becomeFirstResponder())
        body.text = "Fixture body"
        editor.textViewDidChange(body)
        #expect(editor.flush())
        #expect(entry.plainTextBody == "Fixture body")
        navigation.popViewController(animated: false)
        #expect(try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).first?.plainTextBody == "Fixture body")

        let blank = JournalEntry()
        context.insert(blank)
        let blankEditor = EntryEditorViewController(entry: blank, isNew: true, context: context)
        navigation.pushViewController(blankEditor, animated: false)
        navigation.popViewController(animated: false)
        #expect(try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).count == 1)
    }

    @Test func leavingAllDayUsesCurrentTimeOnSelectedDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let day = try #require(calendar.date(from: DateComponents(year: 2020, month: 3, day: 8, hour: 13)))
        let entry = JournalEntry(entryDate: day)
        entry.setAllDay(true, calendar: calendar)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 19, minute: 38)))
        entry.setAllDay(false, calendar: calendar, now: now)
        #expect(calendar.isDate(entry.entryDate, inSameDayAs: day))
        let actual = calendar.dateComponents([.hour, .minute], from: entry.entryDate)
        #expect(actual == calendar.dateComponents([.hour, .minute], from: now))
    }

    @Test func lockButtonHasCompactHeight() throws {
        let controller = LockedJournalController(appLock: AppLockModel(), unlock: {})
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        let button = try #require(descendants(controller.view, as: UIButton.self).first)
        #expect(button.bounds.height >= 44)
        #expect(button.bounds.height < 100)
    }

    @Test func insertingPhotosKeepsExistingBlockViews() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let entry = JournalEntry(title: "Fixture title")
        context.insert(entry)
        entry.insertTextBlock("Fixture paragraph", in: context)
        let editor = EntryEditorViewController(entry: entry, isNew: false, context: context)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let paragraph = try #require(descendants(editor.view, as: BlockTextView.self).first { $0.text == "Fixture paragraph" })

        func insert(_ fileName: String) async {
            editor.importPhotos { PhotoImportResult(photos: [PhotoGroupItem(fileName: fileName)], failedCount: 0) }
            while editor.navigationItem.hidesBackButton { await Task.yield() }
        }
        await insert("first-missing.jpg")
        let firstGroup = try #require(descendants(editor.view, as: PhotoGroupView.self).first)
        await insert("second-missing.jpg")

        let groups = descendants(editor.view, as: PhotoGroupView.self)
        #expect(groups.count == 2)
        #expect(groups.first === firstGroup)
        #expect(descendants(editor.view, as: BlockTextView.self).contains { $0 === paragraph })
        #expect(entry.photoGroupBlocks.count == 2)
    }
}
