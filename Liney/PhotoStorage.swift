import Foundation
import ImageIO
import PhotosUI
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

    func importItems(_ items: [PHPickerResult]) async -> PhotoImportResult {
        var photos: [PhotoGroupItem] = []
        var failedCount = 0
        for item in items {
            do {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    item.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                        if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: error ?? PhotoStorageError.unreadableImage) }
                    }
                }
                let photo = try await Task.detached(priority: .userInitiated) {
                    try storage.saveJPEGWithMetadata(from: data)
                }.value
                photos.append(photo)
            } catch { failedCount += 1 }
        }
        return PhotoImportResult(photos: photos, failedCount: failedCount)
    }

}

enum PhotoStorageError: Error {
    case unreadableImage
    case cannotCreateDestination
    case cannotWriteImage
}

private final class PhotoThumbnailCache: @unchecked Sendable {
    private final class Variants: @unchecked Sendable {
        var values: [Int: (image: UIImage, cost: Int)] = [:]

        var totalCost: Int {
            values.values.reduce(0) { $0 + $1.cost }
        }
    }

    private let cache: NSCache<NSString, Variants> = {
        let cache = NSCache<NSString, Variants>()
        cache.countLimit = 128
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private let lock = NSLock()

    func image(forPath path: String, maxPixelSize: Int) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: path as NSString)?.values[maxPixelSize]?.image
    }

    func insert(
        _ image: UIImage,
        forPath path: String,
        maxPixelSize: Int,
        cost: Int,
        fileExists: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard fileExists else { return }
        let variants = cache.object(forKey: path as NSString) ?? Variants()
        variants.values[maxPixelSize] = (image, cost)
        cache.setObject(variants, forKey: path as NSString, cost: variants.totalCost)
    }

    func remove(path: String) {
        lock.lock()
        cache.removeObject(forKey: path as NSString)
        lock.unlock()
    }
}

struct PhotoStorage: @unchecked Sendable {
    static let targetLongEdge = 2400
    static let jpegQuality = 0.85
    static let defaultThumbnailMaxPixelSize = 1200

    private let fileManager: FileManager
    private let baseURL: URL

    private static let thumbnailCache = PhotoThumbnailCache()

    init(fileManager: FileManager = .default, baseURL: URL? = nil) {
        self.fileManager = fileManager
        if let baseURL {
            self.baseURL = baseURL
        } else {
            self.baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
                URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
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

    /// Main-thread safe: returns only an already decoded image and never touches the file.
    func cachedThumbnail(for fileName: String, maxPixelSize: Int) -> UIImage? {
        Self.thumbnailCache.image(forPath: url(for: fileName).path, maxPixelSize: max(1, maxPixelSize))
    }

    /// Reads the image header without decoding. Stored photos are already upright JPEGs.
    func pixelSize(for fileName: String) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url(for: fileName) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    func thumbnail(for fileName: String, maxPixelSize: Int = PhotoStorage.defaultThumbnailMaxPixelSize) -> UIImage? {
        let fileURL = url(for: fileName)
        let pixelSize = max(1, maxPixelSize)

        if let cached = Self.thumbnailCache.image(forPath: fileURL.path, maxPixelSize: pixelSize) {
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixelSize
                ] as CFDictionary
              ) else {
            return nil
        }

        let thumbnail = UIImage(cgImage: image)
        Self.thumbnailCache.insert(
            thumbnail,
            forPath: fileURL.path,
            maxPixelSize: pixelSize,
            cost: image.width * image.height * 4,
            fileExists: fileManager.fileExists(atPath: fileURL.path)
        )
        return thumbnail
    }

    func delete(fileName: String) throws {
        let fileURL = url(for: fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            Self.thumbnailCache.remove(path: fileURL.path)
            return
        }
        try fileManager.removeItem(at: fileURL)
        Self.thumbnailCache.remove(path: fileURL.path)
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
        Self.thumbnailCache.remove(path: destinationURL.path)
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

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

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
