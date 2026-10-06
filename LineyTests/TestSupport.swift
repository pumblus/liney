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
