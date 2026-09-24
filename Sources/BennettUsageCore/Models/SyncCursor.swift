import Foundation

public struct FileGeneration: Codable, Sendable, Equatable {
    public let generation: String
    public let offset: Int64
    public let size: Int64
    /// SHA-256 of the complete wire prefix consumed at `offset`.
    ///
    /// This is optional so cursors written before prefix hashing was added
    /// remain readable and can be safely rescanned once.
    public let prefixHash: String?

    public init(
        generation: String,
        offset: Int64,
        size: Int64,
        prefixHash: String? = nil
    ) {
        self.generation = generation
        self.offset = offset
        self.size = size
        self.prefixHash = prefixHash
    }
}

public enum SyncCursor: Codable, Sendable, Equatable {
    case rowId(Int64)
    case fileOffsets([String: Int64])
    case fileGenerations([String: FileGeneration])
    case databaseIdentity(String, Int64)
    case timestamp(Date)
}
