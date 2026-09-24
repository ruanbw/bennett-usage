import Foundation

public struct FileGeneration: Codable, Sendable, Equatable {
    public let generation: String
    public let offset: Int64
    public let size: Int64

    public init(generation: String, offset: Int64, size: Int64) {
        self.generation = generation
        self.offset = offset
        self.size = size
    }
}

public enum SyncCursor: Codable, Sendable, Equatable {
    case rowId(Int64)
    case fileOffsets([String: Int64])
    case fileGenerations([String: FileGeneration])
    case databaseIdentity(String, Int64)
    case timestamp(Date)
}
