import Testing
import UIKit
@testable import Liney

/// A window shape photo detail can be shown in.
struct PhotoDetailWindow: Sendable, CustomTestStringConvertible {
    let size: CGSize
    let horizontal: UIUserInterfaceSizeClass
    let vertical: UIUserInterfaceSizeClass
    var testDescription: String { "\(Int(size.width))x\(Int(size.height)) h\(horizontal.rawValue) v\(vertical.rawValue)" }

    /// Large iPhone landscape, then iPad and iPhone Duo inner display landscape.
    static let wide = [PhotoDetailWindow(size: CGSize(width: 932, height: 430), horizontal: .regular, vertical: .compact),
                       PhotoDetailWindow(size: CGSize(width: 1194, height: 834), horizontal: .regular, vertical: .regular)]
    /// iPhone portrait, iPhone landscape (compact width), and iPad portrait.
    static let today = [PhotoDetailWindow(size: CGSize(width: 390, height: 844), horizontal: .compact, vertical: .regular),
                        PhotoDetailWindow(size: CGSize(width: 844, height: 390), horizontal: .compact, vertical: .compact),
                        PhotoDetailWindow(size: CGSize(width: 834, height: 1194), horizontal: .regular, vertical: .regular)]
}

/// Photo detail layout per window shape. Laptop pose needs a real fold, so it is checked in Device Hub.
@Suite(.serialized)
@MainActor
struct PhotoDetailArrangementTests {
    // UIKit window and layout state is exercised serially; photo files are fixture-local.

    @available(iOS 27.1, *)
    @Test(arguments: PhotoDetailWindow.wide)
    func `wide photo detail shows the photo beside its Photo Info and actions`(window: PhotoDetailWindow) async throws {
        let shown = try await PhotoDetailFixture(window)
        defer { shown.close() }
        let photo = try #require(shown.visible(StoredPhotoView.self).first)
        let info = try #require(shown.visibleLabel(shown.infoText))
        let use = try #require(shown.visibleButton(String(localized: "Use as Entry Info")))
        let delete = try #require(shown.visibleButton(String(localized: "Delete Photo")))
        for pane in [info, use, delete] {
            #expect(shown.frame(of: photo).maxX <= shown.frame(of: pane).minX)
        }
        for view in [photo, info, use, delete] {
            #expect(shown.window.bounds.contains(shown.frame(of: view)))
        }
        #expect(shown.visible(StoredPhotoView.self).count == 1)
        #expect(shown.detail.navigationItem.rightBarButtonItems?.count == 1)
    }

    @available(iOS 27.1, *)
    @Test(arguments: PhotoDetailWindow.wide)
    func `actions work beside the photo`(window: PhotoDetailWindow) async throws {
        let shown = try await PhotoDetailFixture(window)
        defer { shown.close() }
        var usedInfo = 0
        shown.detail.useInfo = { usedInfo += 1 }
        try #require(shown.visibleButton(String(localized: "Use as Entry Info"))).sendActions(for: .touchUpInside)
        #expect(usedInfo == 1)
        try #require(shown.visibleButton(String(localized: "Delete Photo"))).sendActions(for: .touchUpInside)
        let alert = try await waitForAlert(from: shown.detail)
        #expect(alert.title == String(localized: "Delete Photo"))
        #expect(alert.actions.map(\.style) == [.cancel, .destructive])
        alert.dismiss(animated: false)
    }

    @Test(arguments: PhotoDetailWindow.today)
    func `portrait and compact windows keep today's photo detail`(window: PhotoDetailWindow) async throws {
        try await expectTodaysLayout(in: window)
    }

    @Test(.enabled(if: !arrangementAvailable), arguments: PhotoDetailWindow.wide)
    func `before iOS 27.1 wide windows keep today's photo detail`(window: PhotoDetailWindow) async throws {
        try await expectTodaysLayout(in: window)
    }

    @Test
    func `a fold across the window places the photo above it`() {
        let laptop = CGSize(width: 669, height: 951)
        let fold = EditorFoldRule.Division(frame: CGRect(x: 0, y: 455, width: 669, height: 40), isActive: true)
        #expect(PhotoDetailLayout(size: laptop, horizontalSizeClass: .regular, divisions: [fold]) == .aroundFold)
        #expect(PhotoDetailLayout(size: laptop, horizontalSizeClass: .regular, divisions: []) == .stacked)
        let book = EditorFoldRule.Division(frame: CGRect(x: 455, y: 0, width: 40, height: 669), isActive: true)
        #expect(PhotoDetailLayout(size: CGSize(width: 951, height: 669), horizontalSizeClass: .regular, divisions: [book]) == .sideBySide)
    }

    @Test
    func `an inactive fold across the window keeps today's photo detail`() {
        let flat = EditorFoldRule.Division(frame: CGRect(x: 0, y: 455, width: 669, height: 40), isActive: false)
        #expect(PhotoDetailLayout(size: CGSize(width: 669, height: 951), horizontalSizeClass: .regular, divisions: [flat]) == .stacked)
    }

    /// The 1.0 layout: the photo is 60% of the height, and the actions sit in the Photo Actions menu.
    private func expectTodaysLayout(in window: PhotoDetailWindow) async throws {
        let shown = try await PhotoDetailFixture(window)
        defer { shown.close() }
        let photos = shown.visible(StoredPhotoView.self)
        #expect(photos.count == 1)
        #expect(abs((photos.first?.bounds.height ?? 0) - window.size.height * 0.6) < 1)
        #expect(shown.visibleButton(String(localized: "Delete Photo")) == nil)
        let items = try #require(shown.detail.navigationItem.rightBarButtonItems)
        #expect(items.count == 2)
        let menu = try #require(items.last?.menu)
        #expect(menu.children.map(\.title) == [String(localized: "Use as Entry Info"), String(localized: "Delete Photo")])
        #expect((menu.children.last as? UIAction)?.attributes.contains(.destructive) == true)
    }

    nonisolated private static var arrangementAvailable: Bool {
        if #available(iOS 27.1, *) { true } else { false }
    }
}

/// A photo detail screen mounted at a fixed window shape, as it is presented from the editor.
@MainActor
private struct PhotoDetailFixture {
    let window: UIWindow
    let detail: PhotoDetailViewController
    let directory: URL
    let infoText: String

    init(_ shape: PhotoDetailWindow) async throws {
        let (storage, directory) = makeTemporaryPhotoStorage()
        self.directory = directory
        let name = try storage.saveJPEG(from: makeJPEGData()).fileName
        let photo = EntryPhoto(fileName: name, displayOrder: 0)
        photo.capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        photo.placeName = "Synthetic Place"
        infoText = [photo.capturedAt?.formatted(date: .long, time: .shortened), photo.placeDisplayText]
            .compactMap { $0 }.joined(separator: "\n")
        detail = PhotoDetailViewController(photo: photo, storage: storage)
        let navigation = UINavigationController(rootViewController: detail)
        navigation.traitOverrides.horizontalSizeClass = shape.horizontal
        navigation.traitOverrides.verticalSizeClass = shape.vertical
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: shape.size)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        // Let the arrangement finish its first layout pass.
        try await Task.sleep(for: .milliseconds(50))
        window.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        try? FileManager.default.removeItem(at: directory)
    }

    func frame(of view: UIView) -> CGRect { view.convert(view.bounds, to: window) }

    /// Views a person can see: unhidden up to the window, and with a size.
    func visible<T: UIView>(_ type: T.Type) -> [T] {
        descendants(window, as: type).filter { view in
            var current: UIView? = view
            while let ancestor = current {
                if ancestor.isHidden || ancestor.alpha == 0 { return false }
                current = ancestor.superview
            }
            return !view.bounds.isEmpty
        }
    }

    func visibleLabel(_ text: String) -> UILabel? { visible(UILabel.self).first { $0.text == text } }
    func visibleButton(_ title: String) -> UIButton? { visible(UIButton.self).first { $0.configuration?.title == title } }
}
