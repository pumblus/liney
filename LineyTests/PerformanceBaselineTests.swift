import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Liney

extension JournalEntryFlowTests {
// MARK: Photo decode: baseline, cold bounded thumbnails, and warm cache

func testPhotoStorageThumbnailPerformanceOnSyntheticFixtures() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("LineyPhotoPerformance-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let storage = PhotoStorage(baseURL: rootURL)
    let sourceData = qualityPerfJPEGData(size: CGSize(width: 2_400, height: 1_800))
    let seedFileName = try storage.saveJPEG(from: sourceData)
    let seedURL = storage.url(for: seedFileName)
    let seedData = try Data(contentsOf: seedURL)

    let pathSets: [[String]] = try (0..<3).map { round in
        try (0..<50).map { index in
            let fileName = "fixture-\(round)-\(index).jpg"
            let destinationURL = storage.url(for: fileName)
            try FileManager.default.createDirectory(
                at: storage.photoDirectoryURL,
                withIntermediateDirectories: true
            )
            try seedData.write(to: destinationURL, options: .atomic)
            return fileName
        }
    }

    var baselineSamples: [Double] = []
    var coldThumbnailSamples: [Double] = []
    var warmThumbnailSamples: [Double] = []
    var baselineDecodedBytes = 0
    var coldDecodedBytes = 0
    var warmDecodedBytes = 0

    for fileNames in pathSets {
        var baselineBytes = 0
        let baselineStart = DispatchTime.now().uptimeNanoseconds
        for fileName in fileNames {
            if let image = storage.image(for: fileName) {
                baselineBytes += qualityPerfMaterialize(image)
            }
        }
        baselineSamples.append(qualityPerfMilliseconds(since: baselineStart))
        baselineDecodedBytes = baselineBytes

        var coldBytes = 0
        let coldStart = DispatchTime.now().uptimeNanoseconds
        for fileName in fileNames {
            if let image = storage.thumbnail(for: fileName, maxPixelSize: 160) {
                coldBytes += qualityPerfMaterialize(image)
            }
        }
        coldThumbnailSamples.append(qualityPerfMilliseconds(since: coldStart))
        coldDecodedBytes = coldBytes

        var warmBytes = 0
        let warmStart = DispatchTime.now().uptimeNanoseconds
        for fileName in fileNames {
            if let image = storage.thumbnail(for: fileName, maxPixelSize: 160) {
                warmBytes += qualityPerfMaterialize(image)
            }
        }
        warmThumbnailSamples.append(qualityPerfMilliseconds(since: warmStart))
        warmDecodedBytes = warmBytes
    }

    print("[PERF-photo] condition=iOS simulator; image=2400x1800; paths=50; rounds=3")
    print("[PERF-photo] baseline_image_for median_ms=\(qualityPerfMedian(baselineSamples)) p95_ms=\(qualityPerfP95(baselineSamples)) decoded_bytes_estimate=\(baselineDecodedBytes)")
    print("[PERF-photo] thumbnail_160_cold median_ms=\(qualityPerfMedian(coldThumbnailSamples)) p95_ms=\(qualityPerfP95(coldThumbnailSamples)) decoded_bytes_estimate=\(coldDecodedBytes)")
    print("[PERF-photo] thumbnail_160_warm median_ms=\(qualityPerfMedian(warmThumbnailSamples)) p95_ms=\(qualityPerfP95(warmThumbnailSamples)) decoded_bytes_estimate=\(warmDecodedBytes)")
}

// MARK: Timeline repository search baseline

func testTimelineSearchPerformanceOnSyntheticFixture() async throws {
    let calendar = Calendar(identifier: .gregorian)
    let startDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let commonText = String(repeating: "alpha beta gamma ", count: 256)

    for index in 0..<1_000 {
        let date = startDate.addingTimeInterval(TimeInterval(index * 60))
        let entry = JournalEntry(
            title: "Synthetic Entry \(index)",
            entryDate: date,
            createdAt: date
        )
        context.insert(entry)
        entry.setBody("\(commonText)needle-\(String(format: "%04d", index))", in: context)
    }
    try context.save()

    let repository = TimelineRepository(container: container)
    let reloadStart = DispatchTime.now().uptimeNanoseconds
    try await repository.reload()
    let reloadMilliseconds = qualityPerfMilliseconds(since: reloadStart)

    var searchSamples: [Double] = []
    var matchCount = 0
    var groupCount = 0

    for _ in 0..<3 {
        let searchStart = DispatchTime.now().uptimeNanoseconds
        let result = try await repository.search("needle", calendar: calendar)
        searchSamples.append(qualityPerfMilliseconds(since: searchStart))
        matchCount = result.days.reduce(0) { $0 + $1.entries.count }
        groupCount = result.days.count
    }

    XCTAssertEqual(matchCount, 1_000)
    XCTAssertGreaterThan(groupCount, 0)
    print("[PERF-search] entries=1000 body_bytes_each=4363 rounds=3 query=needle path=TimelineRepository")
    print("[PERF-search] reload_ms=\(reloadMilliseconds)")
    print("[PERF-search] search_and_group median_ms=\(qualityPerfMedian(searchSamples)) p95_ms=\(qualityPerfP95(searchSamples)) matches=\(matchCount) groups=\(groupCount)")
}

// MARK: Synchronous long-text save baseline

func testLongTextSavePerformanceOnSyntheticFixture() throws {
    let startDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let longText = String(repeating: "0123456789", count: 20_000)
    XCTAssertEqual(longText.utf8.count, 200_000)

    let entry = JournalEntry(entryDate: startDate, createdAt: startDate)
    context.insert(entry)
    entry.setBody(longText, in: context)
    try context.save()

    var samples: [Double] = []
    for index in 0..<50 {
        let start = DispatchTime.now().uptimeNanoseconds
        entry.setBody("\(longText)\(index % 10)", in: context)
        try saveEntryChanges(entry, in: context)
        samples.append(qualityPerfMilliseconds(since: start))
    }

    print("[PERF-save] text_bytes=200000 saves=50 model_context=in-memory synchronous")
    print("[PERF-save] save_change_like median_ms=\(qualityPerfMedian(samples)) p95_ms=\(qualityPerfP95(samples)) total_ms=\(String(format: "%.2f", samples.reduce(0, +)))")
}

// MARK: Helpers

private func qualityPerfJPEGData(size: CGSize) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.95) { rendererContext in
        UIColor.systemBlue.setFill()
        rendererContext.fill(CGRect(origin: .zero, size: size))
    }
}

private func qualityPerfMaterialize(_ image: UIImage) -> Int {
    guard let cgImage = image.cgImage,
          let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        return 0
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    return cgImage.width * cgImage.height * 4
}

private func qualityPerfMilliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func qualityPerfMedian(_ samples: [Double]) -> String {
    let sorted = samples.sorted()
    guard !sorted.isEmpty else { return "n/a" }
    return String(format: "%.2f", sorted[sorted.count / 2])
}

private func qualityPerfP95(_ samples: [Double]) -> String {
    let sorted = samples.sorted()
    guard !sorted.isEmpty else { return "n/a" }
    let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
    return String(format: "%.2f", sorted[index])
}

}
