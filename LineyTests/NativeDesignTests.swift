import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Liney

@Suite(.serialized)
@MainActor
struct NativeDesignTests {
    // UIKit trait/layout state is exercised serially; stores and media are fixture-local.
    @Test(arguments: [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge])
    func checklistTargetsDoNotOverlapText(category: UIContentSizeCategory) throws {
        let controller = UIViewController()
        controller.traitOverrides.preferredContentSizeCategory = category
        let input = BlockTextView()
        controller.view.addSubview(input)
        input.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        input.text = "☐ First item with enough text to wrap onto another line\n☑ 第二项"
        input.layoutIfNeeded()
        let buttons = input.subviews.compactMap { $0 as? UIButton }
        #expect(buttons.count == 2)
        for button in buttons {
            #expect(button.bounds.width >= 44)
            #expect(button.bounds.height >= 44)
            #expect(button.frame.minX >= 0)
            #expect(input.bounds.contains(button.frame))
            let nearLeftEdge = CGPoint(x: button.frame.minX + 1, y: button.frame.midY)
            #expect(input.hitTest(nearLeftEdge, with: nil) === button)
        }
        let first = try #require(buttons.first)
        let start = try #require(input.position(from: input.beginningOfDocument, offset: 2))
        let end = try #require(input.position(from: start, offset: 1))
        let range = try #require(input.textRange(from: start, to: end))
        #expect(input.firstRect(for: range).minX >= first.frame.maxX - 0.5)
    }

    @Test
    func photoPressAndUnavailableState() async throws {
        let (storage, directory) = makeTemporaryPhotoStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let block = EntryBlock(kind: .photoGroup)
        block.photos = [EntryPhoto(fileName: "missing.jpg", displayOrder: 0, block: block)]
        let group = PhotoGroupView(block: block, storage: storage) { _ in }
        let image = try #require(group.photoViews.first)
        let button = try #require(image.superview as? UIButton)
        #expect(button.isAccessibilityElement)
        #expect(!image.isAccessibilityElement)
        let label = button.accessibilityLabel
        button.isHighlighted = true
        #expect(image.alpha < 1)
        button.isHighlighted = false
        #expect(image.alpha == 1)
        for _ in 0..<100 {
            if button.accessibilityValue != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(button.accessibilityValue == String(localized: "Photo unavailable"))
        #expect(button.accessibilityLabel == label)
        // Recovering a file must clear the stale failure on the accessible parent too.
        let data = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let item = try storage.saveJPEG(from: data)
        image.load(item.fileName, storage: storage)
        for _ in 0..<100 {
            if button.accessibilityValue == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(button.accessibilityValue == nil)
        #expect(button.accessibilityLabel == label)
    }

    @Test
    func slowPhotoTransferShowsStatusAndRestoresEditor() async throws {
        let store = try makeInMemoryContainer()
        let context = ModelContext(store)
        let entry = JournalEntry(title: "Synthetic transfer")
        context.insert(entry)
        try context.save()
        let editor = EntryEditorViewController(entry: entry, isNew: false, context: context)
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        var continuation: CheckedContinuation<PhotoImportResult, Never>?
        editor.importPhotos {
            await withCheckedContinuation { continuation = $0 }
        }
        let processing = try #require(editor.children.first as? ProcessingViewController)
        #expect(processing.view.accessibilityViewIsModal)
        #expect(descendants(processing.view, as: UIActivityIndicatorView.self).first?.isAnimating == true)
        #expect(descendants(processing.view, as: UILabel.self).contains { $0.text == String(localized: "Adding Photos…") })
        #expect(editor.navigationItem.rightBarButtonItems?.allSatisfy { !$0.isEnabled } == true)
        #expect(!editor.prepareForReplacement())
        var secondLoadStarted = false
        editor.importPhotos {
            secondLoadStarted = true
            return PhotoImportResult(fileNames: [], failedCount: 0)
        }
        for _ in 0..<100 {
            if continuation != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pending = try #require(continuation)
        pending.resume(returning: PhotoImportResult(fileNames: [], failedCount: 0))
        for _ in 0..<100 {
            if editor.children.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!secondLoadStarted)
        #expect(editor.children.isEmpty)
        #expect(editor.navigationItem.rightBarButtonItems?.allSatisfy(\.isEnabled) == true)
        #expect(editor.prepareForReplacement())
        let scroll = try #require(editor.view.subviews.first as? UIScrollView)
        #expect(scroll.isUserInteractionEnabled)
        #expect(!scroll.accessibilityElementsHidden)
        #expect(entry.title == "Synthetic transfer")
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark], [UIAccessibilityContrast.normal, .high])
    func accentHasReadableContrast(style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast) throws {
        let traits = UITraitCollection {
            $0.userInterfaceStyle = style
            $0.accessibilityContrast = contrast
        }
        let accent = try #require(UIColor(named: "LineyAqua"))
        let foreground = luminance(accent.resolvedColor(with: traits))
        for background in [UIColor.systemBackground, .secondarySystemBackground, .systemGroupedBackground] {
            let behind = luminance(background.resolvedColor(with: traits))
            let ratio = (max(foreground, behind) + 0.05) / (min(foreground, behind) + 0.05)
            #expect(ratio >= 4.5)
        }
        // Native tinted buttons blend the accent into their background, reducing contrast.
        // Check that actual rendered surface too, rather than assuming it is white/black.
        let controller = UIViewController()
        controller.overrideUserInterfaceStyle = style
        controller.traitOverrides.accessibilityContrast = contrast
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        controller.view.backgroundColor = .systemBackground
        controller.view.tintColor = accent
        let button = actionButton("TEST") {}
        button.frame = CGRect(x: 10, y: 10, width: 300, height: 100)
        controller.view.addSubview(button)
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { renderer in
            controller.view.layer.render(in: renderer.cgContext)
        }
        let backgroundPixel = try #require(rendered.cgImage?.cropping(to: CGRect(x: 30, y: 60, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let bitmap = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                                           bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(backgroundPixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let background = UIColor(red: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255,
                                 blue: CGFloat(bytes[2]) / 255, alpha: 1)
        let textColor = try #require(button.titleLabel?.textColor).resolvedColor(with: traits)
        let text = luminance(textColor)
        let behind = luminance(background)
        #expect((max(text, behind) + 0.05) / (min(text, behind) + 0.05) >= 4.5)
    }

    private func luminance(_ color: UIColor) -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
