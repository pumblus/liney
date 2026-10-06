import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Liney

@MainActor
struct PhotoDisplayTests {
    private func storedPhoto(size: CGSize) throws -> (PhotoStorage, String, URL) {
        let (storage, base) = makeTemporaryPhotoStorage()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = try #require(UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.9))
        return (storage, try storage.saveJPEG(from: data).fileName, base)
    }

    @Test func singlePhotoUsesHeaderAspectBeforeDecoding() throws {
        let (storage, fileName, base) = try storedPhoto(size: CGSize(width: 200, height: 300))
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(storage.pixelSize(for: fileName) == CGSize(width: 200, height: 300))
        let block = EntryBlock(kind: .photoGroup)
        block.photos = [EntryPhoto(fileName: fileName, displayOrder: 0, block: block)]
        let group = PhotoGroupView(block: block, storage: storage, deferLoading: true) { _ in }
        group.translatesAutoresizingMaskIntoConstraints = false
        let wrapper = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 700))
        wrapper.addSubview(group)
        NSLayoutConstraint.activate([
            group.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            group.topAnchor.constraint(equalTo: wrapper.topAnchor),
            group.widthAnchor.constraint(equalToConstant: 320)
        ])
        wrapper.layoutIfNeeded()
        #expect(group.photoViews.first?.image == nil)
        #expect(abs(group.bounds.height - 480) < 1)
    }

    @Test func missingHeaderHasNoPixelSize() {
        let storage = makeTemporaryPhotoStorage().storage
        #expect(storage.pixelSize(for: "missing.jpg") == nil)
    }

    @Test func cachedThumbnailAppearsSynchronously() throws {
        let (storage, fileName, base) = try storedPhoto(size: CGSize(width: 64, height: 48))
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(storage.cachedThumbnail(for: fileName, maxPixelSize: 160) == nil)
        _ = try #require(storage.thumbnail(for: fileName, maxPixelSize: 160))
        let view = StoredPhotoView()
        var available: Bool?
        view.onAvailabilityChange = { available = $0 }
        view.load(fileName, storage: storage, pixels: 160)
        #expect(view.image != nil)
        #expect(available == true)
    }
}
