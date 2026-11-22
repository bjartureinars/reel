import Foundation

/// A film as Google holds it: one file, or consecutive pieces from a fast upload.
struct RemoteFile: Equatable {
    struct Piece: Equatable {
        let id: String
        let offset: Int64
        let size: Int64
    }

    let pieces: [Piece]

    var key: String { pieces.first?.id ?? "" }

    /// True only if the pieces cover every byte of a film of `size` exactly once, in order.
    func covers(_ size: Int64) -> Bool {
        var next: Int64 = 0
        for piece in pieces {
            guard piece.offset == next, piece.size > 0 else { return false }
            next += piece.size
        }
        return !pieces.isEmpty && next == size && Set(pieces.map(\.id)).count == pieces.count
    }
}

/// One piece of a fast upload.
struct UploadPart: Codable, Equatable {
    let offset: Int64
    let size: Int64
    var uploadURL: URL?
    var received: Int64 = 0
    var driveID: String?

    mutating func reset() {
        uploadURL = nil
        received = 0
        driveID = nil
    }
}

extension DriveClient {
    func read(_ remote: RemoteFile, offset: Int64, count: Int, attempts: Int = 5) async throws -> Data {
        let end = offset + Int64(count)
        var result = Data()
        for piece in remote.pieces where piece.offset < end && piece.offset + piece.size > offset {
            let from = max(offset, piece.offset)
            let to = min(end, piece.offset + piece.size)
            result.append(try await read(piece.id, offset: from - piece.offset, count: Int(to - from), attempts: attempts))
        }
        guard result.count == count else { throw CloudError("A piece of the film is missing from Google Drive.") }
        return result
    }
}
