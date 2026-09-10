import XCTest
@testable import BennettUsageCore

final class AdditionalAdaptersTests: XCTestCase {
    func testClaudeAndCodexAdaptersConformToProtocol() {
        let claude = ClaudeAdapter()
        let codex = CodexAdapter()

        XCTAssertEqual(claude.sourceId, "claude")
        XCTAssertEqual(codex.sourceId, "codex")
        XCTAssertEqual(claude.displayName, "Claude Code")
        XCTAssertEqual(codex.displayName, "OpenAI Codex")
        XCTAssertEqual(claude.brandColorHex, "#D97706")
        XCTAssertEqual(codex.brandColorHex, "#10A37F")
        XCTAssertEqual(claude.sfSymbolIcon, "brain.head.profile")
        XCTAssertEqual(codex.sfSymbolIcon, "chevron.left.forwardslash.chevron.right")
    }

    func testDefaultPathDetection() {
        let claude = ClaudeAdapter()
        let codex = CodexAdapter()

        // Should return URL if exists or nil, must not crash
        _ = claude.detectDefaultPath()
        _ = codex.detectDefaultPath()
    }

    func testFetchIncrementalRecords() async throws {
        let claude = ClaudeAdapter()
        let codex = CodexAdapter()

        let tempDir = FileManager.default.temporaryDirectory
        let (claudeRecords, claudeCursor) = try await claude.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertTrue(claudeRecords.isEmpty)
        if case .timestamp = claudeCursor {
            // expected
        } else {
            XCTFail("Expected timestamp cursor")
        }

        let (codexRecords, codexCursor) = try await codex.fetchIncrementalRecords(from: tempDir, since: nil)
        XCTAssertTrue(codexRecords.isEmpty)
        if case .timestamp = codexCursor {
            // expected
        } else {
            XCTFail("Expected timestamp cursor")
        }
    }
}
