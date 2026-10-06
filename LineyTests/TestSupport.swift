import SwiftData
import Testing
import UIKit
@testable import Liney

// Fixture helpers shared by every suite. Add new cross-suite helpers here.

struct SyntheticFailure: Error { }

struct ApprovingAuthenticator: AppAuthenticating {
    func authenticate(reason: String) async -> Bool { true }
}

struct DenyingAuthenticator: AppAuthenticating {
    func authenticate(reason: String) async -> Bool { false }
}

func makeInMemoryContainer() throws -> ModelContainer {
    try ModelContainer(for: JournalEntry.self, EntryBlock.self, EntryPhoto.self,
                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

/// A solid-color JPEG of exactly `size` pixels.
func makeJPEGData(size: CGSize = CGSize(width: 32, height: 24), color: UIColor = .systemBlue) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 1) { context in
        color.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}

/// Every view of type `T` in `view`'s hierarchy, `view` included, in depth-first order.
func descendants<T: UIView>(_ view: UIView, as type: T.Type) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, as: type) }
}

/// The alert presented above `controller`'s window root, waiting up to ten seconds.
@MainActor
func waitForAlert(from controller: UIViewController) async throws -> UIAlertController {
    for _ in 0..<500 {
        if let alert = presentedAlert(from: controller) { return alert }
        try await Task.sleep(for: .milliseconds(20))
    }
    return try #require(presentedAlert(from: controller))
}

@MainActor
func presentedAlert(from controller: UIViewController) -> UIAlertController? {
    var root = controller
    while let parent = root.parent { root = parent }
    var presented = root.presentedViewController
    while let current = presented {
        if let alert = current as? UIAlertController { return alert }
        presented = current.presentedViewController
    }
    return nil
}

// Fixture builders: production writes blocks through the editor and importer instead.
extension JournalEntry {
    func setBody(_ body: String, in context: ModelContext) {
        let existingTextBlocks = textBlocks
        func remove(_ block: EntryBlock) { blocks.removeAll { $0.id == block.id }; context.delete(block) }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            existingTextBlocks.forEach(remove)
        } else if let block = existingTextBlocks.first {
            block.text = body
            existingTextBlocks.dropFirst().forEach(remove)
        } else {
            let block = EntryBlock(sortIndex: 0, text: body, entry: self)
            blocks.append(block)
            context.insert(block)
        }
        normalizeBlocks(in: context)
    }

    @discardableResult
    func insertPhotoGroup(fileNames: [String], focusedTextBlockID: UUID? = nil, cursorOffset: Int? = nil,
                          in context: ModelContext) -> PhotoGroupInsertion? {
        insertPhotoGroup(photos: fileNames.map { PhotoGroupItem(fileName: $0) },
                         focusedTextBlockID: focusedTextBlockID, cursorOffset: cursorOffset, in: context)
    }
}
