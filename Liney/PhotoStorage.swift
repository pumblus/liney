import Foundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct PhotoImportResult {
    let photos: [PhotoGroupItem]
    let failedCount: Int
    let storageWasFull: Bool

    init(photos: [PhotoGroupItem], failedCount: Int, storageWasFull: Bool = false) {
        self.photos = photos
        self.failedCount = failedCount
        self.storageWasFull = storageWasFull
    }

    var fileNames: [String] {
        photos.map(\.fileName)
    }

    var failureMessage: String? {
        guard failedCount > 0 else { return nil }
        if storageWasFull { return outOfSpaceMessage }
        return failedCount == 1 ?
        String(localized: "One selected photo could not be added.") :
        String(localized: "Some selected photos could not be added.")
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
    static let quarantineRetentionDays = 30

    private let fileManager: FileManager
    private let baseURL: URL
    private let writeFile: @Sendable (Data, URL) throws -> Void

    private static let thumbnailCache = PhotoThumbnailCache()

    /// Fixtures replace `writeFile` to simulate a full disk.
    init(fileManager: FileManager = .default, baseURL: URL? = nil,
         writeFile: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.fileManager = fileManager
        self.writeFile = writeFile
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

    /// Holds Orphaned Photo Files in one subfolder per sweep day, named `yyyy-MM-dd`.
    var photoQuarantineURL: URL {
        baseURL.appendingPathComponent("PhotoQuarantine", isDirectory: true)
    }

    func url(for fileName: String) -> URL {
        photoDirectoryURL.appendingPathComponent(fileName)
    }

    static func referencedFileNames(in context: ModelContext) throws -> Set<String> {
        Set(try context.fetch(FetchDescriptor<EntryPhoto>()).map(\.fileName))
    }

    /// Moves Orphaned Photo Files into today's Photo Quarantine and deletes quarantine days older than `quarantineRetentionDays`.
    /// Only files modified before `launchedAt` are candidates, so copies made by this process are never moved.
    /// Does nothing when `referencedFileNames` throws or when more than half of the photo files are candidates.
    func sweepOrphanedPhotoFiles(
        launchedAt: Date,
        now: Date = .now,
        calendar: Calendar = .current,
        referencedFileNames: () throws -> Set<String>
    ) {
        guard let referenced = try? referencedFileNames() else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = (try? fileManager.contentsOfDirectory(at: photoDirectoryURL, includingPropertiesForKeys: Array(keys))) ?? []
        let candidates = files.filter { file in
            guard Self.isStoredPhotoName(file.lastPathComponent),
                  !referenced.contains(file.lastPathComponent),
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { return false }
            return modified < launchedAt
        }
        // A mass of candidates means the reference fetch is wrong, not that most photos are orphaned.
        let isMostlyOrphaned = candidates.count * 2 > files.count
        guard !isMostlyOrphaned else { return }

        let dayFormatter = Self.quarantineDayFormatter(calendar: calendar)
        let today = calendar.startOfDay(for: now)
        purgeQuarantine(olderThan: Self.quarantineRetentionDays, today: today, calendar: calendar, dayFormatter: dayFormatter)
        guard !candidates.isEmpty else { return }

        let dayURL = photoQuarantineURL.appendingPathComponent(dayFormatter.string(from: today), isDirectory: true)
        do {
            try fileManager.createDirectory(at: dayURL, withIntermediateDirectories: true)
            var quarantineURL = photoQuarantineURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try quarantineURL.setResourceValues(values)
        } catch { return }
        for file in candidates {
            do {
                try fileManager.moveItem(at: file, to: dayURL.appendingPathComponent(file.lastPathComponent))
                Self.thumbnailCache.remove(path: file.path)
            } catch {
                // A file that cannot be moved stays a candidate for the next launch.
                continue
            }
        }
    }

    private func purgeQuarantine(olderThan days: Int, today: Date, calendar: Calendar, dayFormatter: DateFormatter) {
        let dayFolders = (try? fileManager.contentsOfDirectory(at: photoQuarantineURL, includingPropertiesForKeys: nil)) ?? []
        for folder in dayFolders {
            guard let day = dayFormatter.date(from: folder.lastPathComponent),
                  let age = calendar.dateComponents([.day], from: day, to: today).day,
                  age > days else { continue }
            try? fileManager.removeItem(at: folder)
        }
    }

    /// Matches the `<UUID>.jpg` names `saveJPEG` writes, so no other file is ever swept.
    private static func isStoredPhotoName(_ name: String) -> Bool {
        guard name.hasSuffix(".jpg") else { return false }
        let stem = String(name.dropLast(4))
        return UUID(uuidString: stem)?.uuidString == stem
    }

    private static func quarantineDayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
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

    func thumbnail(for fileName: String, maxPixelSize: Int) -> UIImage? {
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

    /// Saves one photo at a time so peak memory stays bounded; a loader or save that throws counts as one failure.
    func savePhotos(_ loaders: [() async throws -> Data]) async -> PhotoImportResult {
        var photos: [PhotoGroupItem] = []
        var failedCount = 0
        var storageWasFull = false

        for load in loaders {
            do {
                let data = try await load()
                // Detached so a call from the main actor does not encode on the main thread.
                photos.append(try await Task.detached(priority: .userInitiated) {
                    try saveJPEG(from: data)
                }.value)
            } catch {
                failedCount += 1
                storageWasFull = storageWasFull || error.isOutOfSpace
            }
        }

        return PhotoImportResult(photos: photos, failedCount: failedCount, storageWasFull: storageWasFull)
    }

    func saveJPEG(from data: Data, id: UUID = UUID()) throws -> PhotoGroupItem {
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
        // Encoding in memory and writing atomically means a full disk leaves no truncated file
        // and surfaces the real write error.
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            jpeg as CFMutableData,
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
        try writeFile(jpeg as Data, destinationURL)

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
