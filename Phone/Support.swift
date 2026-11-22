import SwiftUI

enum Theme {
    /// Projector-lamp gold, the one brand colour: the main action, progress and selection. 10.6:1 on black.
    static let gold = Color(red: 0.96, green: 0.73, blue: 0.29)
    static let goldUI = UIColor(red: 0.96, green: 0.73, blue: 0.29, alpha: 1)
    static let card = Color(white: 0.13)
}

struct CloudError: LocalizedError {
    let message: String
    var needsSignIn = false

    init(_ message: String, needsSignIn: Bool = false) {
        self.message = message
        self.needsSignIn = needsSignIn
    }

    var errorDescription: String? { message }
}

extension Int64 {
    var fileSize: String { formatted(.byteCount(style: .file)) }
}

extension Double {
    /// "2 h 25 min"
    var runtimeText: String {
        let minutes = Int(self / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(max(1, minutes)) min"
    }

    /// "1:02:03" or "2:03"
    var clockText: String {
        guard isFinite else { return "–:––" }
        let total = Int(max(0, self))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum Folders {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reel", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let downloads: URL = {
        var url = support.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Films can be downloaded again from Drive, so they don't belong in iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    static let artwork: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var freeSpace: Int64 {
        let values = try? support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

/// Saves a Codable value as JSON in Application Support.
enum Store {
    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) -> T? {
        guard let data = try? Data(contentsOf: Folders.support.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, as name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: Folders.support.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
