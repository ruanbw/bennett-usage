import Foundation

public enum SyncCursor: Codable, Sendable, Equatable {
    case rowId(Int64)
    case fileOffsets([String: Int64])
    case timestamp(Date)
}
