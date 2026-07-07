import Foundation
import ZIPFoundation

struct JournalExport: Identifiable {
    let id = UUID()
    let url: URL
    let directoryURL: URL
}

enum JournalExportError: LocalizedError {
    case missingPhoto

    var errorDescription: String? {
        switch self {
        case .missingPhoto:
            String(localized: "A copied photo file is missing.")
        }
    }
}

struct JournalExporter {
    private let fileManager: FileManager
    private let photoStorage: PhotoStorage
    private let exportRootURL: URL
    private var calendar: Calendar

    init(
        fileManager: FileManager = .default,
        photoStorage: PhotoStorage = PhotoStorage(),
        exportRootURL: URL? = nil,
        calendar: Calendar = .current
    ) {
        self.fileManager = fileManager
        self.photoStorage = photoStorage
        self.exportRootURL = exportRootURL ?? fileManager.temporaryDirectory
            .appendingPathComponent("LineyExports", isDirectory: true)
        self.calendar = calendar
    }

    func export(entries: [JournalEntry], exportedAt: Date = .now) throws -> JournalExport {
        let directoryURL = exportRootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let archiveURL = directoryURL
            .appendingPathComponent("liney-export-\(dateOnlyString(exportedAt)).zip")
        do {
            let archive = try Archive(url: archiveURL, accessMode: .create, pathEncoding: nil)
            for entry in sortedEntries(entries) {
                try add(entry, to: archive)
            }
            return JournalExport(url: archiveURL, directoryURL: directoryURL)
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    func deleteExport(_ export: JournalExport) {
        try? fileManager.removeItem(at: export.directoryURL)
    }

    private func add(_ entry: JournalEntry, to archive: Archive) throws {
        let slug = entrySlug(for: entry)
        let markdown = try markdownData(for: entry, slug: slug, archive: archive)
        try add(markdown, path: "entries/\(slug).md", to: archive)
    }

    private func markdownData(for entry: JournalEntry, slug: String, archive: Archive) throws -> Data {
        var lines: [String] = [
            "---",
            "date: \(quoted(dateString(for: entry)))",
            "all_day: \(entry.isAllDay ? "true" : "false")"
        ]

        if let location = entry.locationDisplayText {
            lines.append("location: \(quoted(location))")
        }
        if let latitude = entry.locationLatitude {
            lines.append("latitude: \(latitude)")
        }
        if let longitude = entry.locationLongitude {
            lines.append("longitude: \(longitude)")
        }

        lines.append("---")
        lines.append("")

        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            lines.append("# \(title)")
            lines.append("")
        }

        var photoNumber = 0
        for block in entry.orderedBlocks {
            switch block.kind {
            case .text:
                guard !block.text.isEmpty else { continue }
                lines.append(block.text)
                lines.append("")
            case .photoGroup:
                for photo in block.orderedPhotos {
                    photoNumber += 1
                    let photoFileName = String(format: "photo-%03d.jpg", photoNumber)
                    let exportPath = "media/\(slug)/\(photoFileName)"
                    try addPhoto(photo, path: exportPath, to: archive)
                    lines.append("![Photo \(photoNumber)](../\(exportPath))")
                    lines.append("")
                }
            }
        }

        return Data(lines.joined(separator: "\n").utf8)
    }

    private func addPhoto(_ photo: EntryPhoto, path: String, to archive: Archive) throws {
        let sourceURL = photoStorage.url(for: photo.fileName)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw JournalExportError.missingPhoto
        }
        try add(Data(contentsOf: sourceURL), path: path, to: archive)
    }

    private func add(_ data: Data, path: String, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count)
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    private func sortedEntries(_ entries: [JournalEntry]) -> [JournalEntry] {
        entries.sorted {
            if $0.entryDate != $1.entryDate {
                return $0.entryDate > $1.entryDate
            }
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func entrySlug(for entry: JournalEntry) -> String {
        "\(compactDateTimeString(entry.entryDate))-\(entry.id.uuidString.lowercased())"
    }

    private func dateString(for entry: JournalEntry) -> String {
        entry.isAllDay ? dateOnlyString(entry.entryDate) : isoDateString(entry.entryDate)
    }

    private func dateOnlyString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func compactDateTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    private func isoDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
