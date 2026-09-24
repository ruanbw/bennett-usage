import Foundation
import XCTest
@testable import BennettUsageCore

final class SyncCursorTests: XCTestCase {
    func testDecodesLegacyRowIDJSON() throws {
        let data = Data(#"{"rowId":{"_0":42}}"#.utf8)

        XCTAssertEqual(try JSONDecoder().decode(SyncCursor.self, from: data), .rowId(42))
    }

    func testDecodesLegacyFileOffsetsJSON() throws {
        let data = Data(#"{"fileOffsets":{"_0":{"/tmp/session.jsonl":128}}}"#.utf8)

        XCTAssertEqual(
            try JSONDecoder().decode(SyncCursor.self, from: data),
            .fileOffsets(["/tmp/session.jsonl": 128])
        )
    }

    func testFileGenerationsCursorRoundTrips() throws {
        let cursor = SyncCursor.fileGenerations([
            "/tmp/audit-wire.jsonl": FileGeneration(generation: "gen-1", offset: 512, size: 1024)
        ])

        let data = try JSONEncoder().encode(cursor)

        XCTAssertEqual(try JSONDecoder().decode(SyncCursor.self, from: data), cursor)
    }
}
