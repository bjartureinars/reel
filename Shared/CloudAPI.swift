import Foundation

/// What Reel Server tells the Apple TV about a film from the drop folder or Google Drive.
/// The API is on `Reel.controlPort`; it accepts the same Jellyfin token the TV already has.
struct FilmStatus: Codable, Equatable {
    enum Phase: String, Codable {
        /// Still only in the drop folder: not uploaded or not verified yet.
        case local
        /// Safe in Drive, not on the Mac.
        case cloud
        case downloading
        /// Safe in Drive, with a copy on the Mac.
        case downloaded
    }

    let phase: Phase
    let size: Int64
    /// A short line like "Uploading to Google Drive, 42%".
    let detail: String
    /// 0...1 while downloading.
    let progress: Double?
    let megabitsPerSecond: Double?
    let secondsLeft: Double?
    let error: String?
}

/// Where a play should read from.
enum PlaybackSource: String, Codable {
    case stream, mac

    var label: String {
        switch self {
        case .stream: return "Google Drive, through your Mac"
        case .mac: return "Downloaded on your Mac"
        }
    }
}
