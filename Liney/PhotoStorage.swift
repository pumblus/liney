import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PhotoImportResult {
    let fileNames: [String]
    let failedCount: Int

    var alert: PhotoImportAlert? {
        failedCount > 0 ? PhotoImportAlert(failedCount: failedCount) : nil
    }
}

struct PhotoImportAlert: Identifiable, Equatable {
    let id = UUID()
    let failedCount: Int

    var message: String {
        failedCount == 1 ?
        String(localized: "One selected photo could not be added.") :
        String(localized: "Some selected photos could not be added.")
    }
}

struct PhotoPickerImporter {
    let storage: PhotoStorage

    func importItems(_ items: [PhotosPickerItem]) async -> PhotoImportResult {
        await Task.detached(priority: .userInitiated) {
            var fileNames: [String] = []
            var failedCount = 0

            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        failedCount += 1
                        continue
                    }
                    fileNames.append(try storage.saveJPEG(from: data))
                } catch {
                    failedCount += 1
                }
            }

            return PhotoImportResult(fileNames: fileNames, failedCount: failedCount)
        }.value
    }
}

enum PhotoStorageError: Error {
    case unreadableImage
    case cannotCreateDestination
    case cannotWriteImage
}

struct PhotoStorage: @unchecked Sendable {
    static let targetLongEdge = 2400
    static let jpegQuality = 0.85

    private let fileManager: FileManager
    private let baseURL: URL

    init(fileManager: FileManager = .default, baseURL: URL? = nil) {
        self.fileManager = fileManager
        if let baseURL {
            self.baseURL = baseURL
        } else {
            self.baseURL = (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? fileManager.temporaryDirectory
        }
    }

    var photoDirectoryURL: URL {
        baseURL.appendingPathComponent("Photos", isDirectory: true)
    }

    func url(for fileName: String) -> URL {
        photoDirectoryURL.appendingPathComponent(fileName)
    }

    func image(for fileName: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: fileName).path)
    }

    func saveJPEGs(from imageData: [Data]) -> PhotoImportResult {
        var fileNames: [String] = []
        var failedCount = 0

        for data in imageData {
            do {
                fileNames.append(try saveJPEG(from: data))
            } catch {
                failedCount += 1
            }
        }

        return PhotoImportResult(fileNames: fileNames, failedCount: failedCount)
    }

    func saveJPEG(from data: Data, id: UUID = UUID()) throws -> String {
        try fileManager.createDirectory(at: photoDirectoryURL, withIntermediateDirectories: true)

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoStorageError.unreadableImage
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.targetLongEdge
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw PhotoStorageError.unreadableImage
        }

        let fileName = "\(id.uuidString).jpg"
        let destinationURL = url(for: fileName)
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoStorageError.cannotCreateDestination
        }

        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: Self.jpegQuality
        ]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw PhotoStorageError.cannotWriteImage
        }

        return fileName
    }
}

struct StoredPhotoThumbnail: View {
    let photo: EntryPhoto
    let storage: PhotoStorage
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let image = storage.image(for: photo.fileName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel("Photo")
    }
}
