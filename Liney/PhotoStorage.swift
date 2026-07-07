import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PhotoImportResult {
    let photos: [PhotoGroupItem]
    let failedCount: Int

    init(photos: [PhotoGroupItem], failedCount: Int) {
        self.photos = photos
        self.failedCount = failedCount
    }

    init(fileNames: [String], failedCount: Int) {
        self.init(photos: fileNames.map { PhotoGroupItem(fileName: $0) }, failedCount: failedCount)
    }

    var fileNames: [String] {
        photos.map(\.fileName)
    }

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
            var photos: [PhotoGroupItem] = []
            var failedCount = 0

            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        failedCount += 1
                        continue
                    }
                    photos.append(try storage.saveJPEGWithMetadata(from: data))
                } catch {
                    failedCount += 1
                }
            }

            return PhotoImportResult(photos: photos, failedCount: failedCount)
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

    func delete(fileName: String) throws {
        let fileURL = url(for: fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    func saveJPEGs(from imageData: [Data]) -> PhotoImportResult {
        var photos: [PhotoGroupItem] = []
        var failedCount = 0

        for data in imageData {
            do {
                photos.append(try saveJPEGWithMetadata(from: data))
            } catch {
                failedCount += 1
            }
        }

        return PhotoImportResult(photos: photos, failedCount: failedCount)
    }

    func saveJPEG(from data: Data, id: UUID = UUID()) throws -> String {
        try saveJPEGWithMetadata(from: data, id: id).fileName
    }

    func saveJPEGWithMetadata(from data: Data, id: UUID = UUID()) throws -> PhotoGroupItem {
        try fileManager.createDirectory(at: photoDirectoryURL, withIntermediateDirectories: true)

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoStorageError.unreadableImage
        }

        let metadata = Self.metadata(from: source)

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

        return PhotoGroupItem(
            fileName: fileName,
            capturedAt: metadata.capturedAt,
            locationLatitude: metadata.locationLatitude,
            locationLongitude: metadata.locationLongitude
        )
    }

    private static func metadata(from source: CGImageSource) -> (
        capturedAt: Date?,
        locationLatitude: Double?,
        locationLongitude: Double?
    ) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil, nil)
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dateText = exif?[kCGImagePropertyExifDateTimeOriginal] as? String ??
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String ??
            tiff?[kCGImagePropertyTIFFDateTime] as? String
        let capturedAt = dateText.flatMap { exifDateFormatter.date(from: $0) }

        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let latitude = signedCoordinate(
            gps?[kCGImagePropertyGPSLatitude],
            reference: gps?[kCGImagePropertyGPSLatitudeRef],
            negativeReference: "S"
        )
        let longitude = signedCoordinate(
            gps?[kCGImagePropertyGPSLongitude],
            reference: gps?[kCGImagePropertyGPSLongitudeRef],
            negativeReference: "W"
        )

        return (capturedAt, latitude, longitude)
    }

    private static var exifDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }

    private static func signedCoordinate(_ value: Any?, reference: Any?, negativeReference: String) -> Double? {
        guard var coordinate = doubleValue(value) else { return nil }
        if (reference as? String)?.uppercased() == negativeReference {
            coordinate = -coordinate
        }
        return coordinate
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}

struct StoredPhotoThumbnail: View {
    let photo: EntryPhoto
    let storage: PhotoStorage
    var cornerRadius: CGFloat = 8
    var contentMode: ContentMode = .fill

    var body: some View {
        Group {
            if let image = storage.image(for: photo.fileName) {
                resizedImage(image)
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

    @ViewBuilder
    private func resizedImage(_ image: UIImage) -> some View {
        switch contentMode {
        case .fit:
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        case .fill:
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        }
    }
}
