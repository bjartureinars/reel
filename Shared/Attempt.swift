import Foundation
import os

/// For work whose failure shouldn't stop what's going on, but mustn't vanish either: saves, deletions, Drive and Jellyfin
/// changes. `try?` on its own threw the reason away (that hid the Mac app saving nothing at all, 2026-11-26).
/// Failures go to the system log under category "failures":
///     log show --last 1h --predicate 'category == "failures"'
private let failures = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bjartur.reel", category: "failures")

/// Runs `body`; on failure, logs what was being done and why, and returns nil.
@discardableResult
func attempt<T>(_ what: @autoclosure () -> String, file: String = #fileID, line: Int = #line,
                _ body: () throws -> T) -> T? {
    do {
        return try body()
    } catch {
        logFailure(what(), error, file: file, line: line)
        return nil
    }
}

/// The async form of `attempt`.
@discardableResult
func attempt<T>(_ what: @autoclosure () -> String, file: String = #fileID, line: Int = #line,
                _ body: () async throws -> T) async -> T? {
    do {
        return try await body()
    } catch {
        logFailure(what(), error, file: file, line: line)
        return nil
    }
}

func logFailure(_ what: String, _ error: Error, file: String = #fileID, line: Int = #line) {
    // Cancelling is how work is stopped on purpose; that isn't a failure.
    if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
    failures.error("\(what, privacy: .public) failed (\(file, privacy: .public):\(line)): \(String(describing: error), privacy: .public)")
}

/// Deletes a file or folder if it's there. Already gone is fine; anything else is logged.
func removeIfPresent(_ url: URL, file: String = #fileID, line: Int = #line) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch CocoaError.fileNoSuchFile {
    } catch {
        logFailure("Deleting \(url.lastPathComponent)", error, file: file, line: line)
    }
}
