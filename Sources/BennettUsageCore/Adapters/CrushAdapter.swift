import Foundation
import SQLite3

/// Reads Crush's per-project cumulative SQLite usage without modifying it.
///
/// Crush keeps a project registry in `projects.json`; every registered
/// `data_dir` can contain a `crush.db`. The database stores cumulative usage on
/// top-level sessions, so every scan compares the current snapshot with the
/// cursor and emits either a first full snapshot or a non-negative delta. The
/// per-database/per-session state is encoded in `fileOffsets`; database
/// replacement is surfaced as `databaseIdentity` so SyncCoordinator performs
/// its existing cutover before any new records are ingested.
public struct CrushAdapter: AgentSourceAdapter, @unchecked Sendable {
    public let sourceId: String = "crush"
    public let displayName: String = "Crush"
    public let brandColorHex: String = "#E34D8A"
    public let sfSymbolIcon: String = "heart.fill"
    public let defaultPath: String = "~/Library/Application Support/crush"

    private struct Project: Sendable {
        let path: String
        let dataDirectory: URL
    }

    private struct Database: Sendable {
        let url: URL
        let projectPath: String
        let identity: Int64
        let sessions: [Session]
    }

    private struct Session: Sendable {
        let id: String
        let promptTokens: Int64
        let completionTokens: Int64
        let costMicros: Int64
        let rawCost: Double
        let updatedAt: Int64
        let createdAt: Int64
    }

    private static let identityKey = "crush.identity"
    private static let sessionPrefix = "crush.session."

    public init() {}

    // MARK: - Global and project paths

    /// Resolve Crush's global data directory. `CRUSH_GLOBAL_DATA` is already
    /// the directory containing `crush.json`/`projects.json`; XDG's base gets
    /// a `crush` child, while macOS uses Application Support.
    static func resolveGlobalRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL? = nil
    ) -> URL {
        let resolvedHome = home ?? URL(fileURLWithPath: NSHomeDirectory())
        if let explicit = environment["CRUSH_GLOBAL_DATA"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
                .standardizedFileURL
        }
        if let xdg = environment["XDG_DATA_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
            return Self.withCrushDirectory(URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath))
        }
        return resolvedHome
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("crush", isDirectory: true)
    }

    private static func withCrushDirectory(_ base: URL) -> URL {
        // Some Crush/XDG versions already append the application name, with
        // either case. Avoid producing `.../crush/crush` for those roots.
        if base.lastPathComponent.lowercased() == "crush" {
            return base.standardizedFileURL
        }
        return base.appendingPathComponent("crush", isDirectory: true).standardizedFileURL
    }

    /// Locate `projects.json`, accepting a file root and lower/upper-case Crush
    /// directory spellings. Existing exact paths win; the case variants are
    /// compatibility fallbacks for older platform layouts.
    static func projectsFileURL(under root: URL) -> URL {
        let normalized = root.standardizedFileURL
        if normalized.lastPathComponent.lowercased() == "projects.json" {
            return normalized
        }
        let exact = normalized.appendingPathComponent("projects.json")
        if FileManager.default.fileExists(atPath: exact.path) {
            return exact
        }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: normalized, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        if let crushDirectory = children.first(where: {
            $0.lastPathComponent.lowercased() == "crush" && !$0.lastPathComponent.isEmpty
        }) {
            return crushDirectory.appendingPathComponent("projects.json")
        }
        return exact
    }

    public func detectDefaultPath() -> URL? {
        let resolved = Self.resolveGlobalRoot()
        let projects = Self.projectsFileURL(under: resolved)
        if FileManager.default.fileExists(atPath: projects.path) {
            return projects.deletingLastPathComponent()
        }
        // Keep discovery useful when the registry has not been created yet but
        // its nearest directory already exists; Coordinator watches the nearest
        // existing ancestor and will refresh when Crush appears.
        var candidate = resolved
        while candidate.path != candidate.deletingLastPathComponent().path {
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    public func auxiliaryWatchRoots(for dataRoot: URL) -> [URL] {
        let projects = parseProjects(at: Self.projectsFileURL(under: dataRoot))
        var seen = Set<String>()
        return projects.compactMap { project in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: project.dataDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return seen.insert(project.dataDirectory.standardizedFileURL.path).inserted
                ? project.dataDirectory
                : nil
        }
    }

    private func parseProjects(at projectsFile: URL) -> [Project] {
        guard let data = try? Data(contentsOf: projectsFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["projects"] as? [[String: Any]] else {
            return []
        }
        let globalRoot = projectsFile.deletingLastPathComponent()
        return entries.compactMap { entry in
            guard let rawDataDirectory = entry["data_dir"] as? String,
                  !rawDataDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let rawProject = (entry["path"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let projectPath = rawProject.isEmpty ? "" :
                URL(fileURLWithPath: (rawProject as NSString).expandingTildeInPath)
                    .standardizedFileURL.path
            let expanded = URL(fileURLWithPath: (rawDataDirectory as NSString).expandingTildeInPath)
            let dataDirectory: URL
            if expanded.path.hasPrefix("/") {
                dataDirectory = expanded.standardizedFileURL
            } else if !projectPath.isEmpty {
                dataDirectory = URL(fileURLWithPath: projectPath)
                    .appendingPathComponent(expanded.path).standardizedFileURL
            } else {
                dataDirectory = globalRoot.appendingPathComponent(expanded.path).standardizedFileURL
            }
            return Project(path: projectPath, dataDirectory: dataDirectory)
        }
    }

    // MARK: - Cumulative session scan

    public func fetchIncrementalRecords(
        from directory: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        var offsets: [String: Int64] = [:]
        if case .fileOffsets(let stored) = cursor { offsets = stored }

        let projects = parseProjects(at: Self.projectsFileURL(under: directory))
        var databases: [Database] = []
        var seenDatabaseKeys = Set<String>()

        for project in projects {
            let databaseURL = project.dataDirectory.appendingPathComponent("crush.db").standardizedFileURL
            guard Self.isRegularFile(databaseURL) else { continue }
            let pathHash = Self.stableHash(databaseURL.path)
            let identityKey = Self.databaseIdentityKey(pathHash: pathHash)
            seenDatabaseKeys.insert(identityKey)
            guard let (identity, sessions) = Self.readDatabase(at: databaseURL) else {
                // A transient lock or an in-flight database replacement must
                // not advance this database's state. Keep its prior identity in
                // the aggregate so another readable project can still sync.
                if let previousIdentity = offsets[identityKey] {
                    databases.append(Database(
                        url: databaseURL,
                        projectPath: project.path,
                        identity: previousIdentity,
                        sessions: []
                    ))
                }
                continue
            }
            databases.append(Database(
                url: databaseURL,
                projectPath: project.path,
                identity: identity,
                sessions: sessions
            ))
        }
        if databases.isEmpty, Self.hasAnyStoredDatabaseState(offsets) {
            return ([], .fileOffsets(offsets))
        }

        // A changed database set, path mapping, inode, or schema requires the
        // coordinator's existing databaseIdentity cutover. Do not emit a delta
        // in the same fetch: the coordinator refetches from nil after clearing.
        let currentIdentity = Self.aggregateIdentity(databases)
        if let previousIdentity = offsets[Self.identityKey], previousIdentity != currentIdentity,
           Self.hasAnyStoredDatabaseState(offsets) {
            return ([], .databaseIdentity(String(currentIdentity), 0))
        }

        var records: [UnifiedTokenRecord] = []
        var nextOffsets = offsets
        for database in databases {
            let pathHash = Self.stableHash(database.url.path)
            for session in database.sessions {
                let prefix = Self.sessionPrefix(pathHash: pathHash, sessionID: session.id)
                let previousPrompt = nextOffsets[prefix + "prompt"]
                let previousCompletion = nextOffsets[prefix + "completion"]
                let previousCost = nextOffsets[prefix + "costMicros"]
                let hasPrevious = previousPrompt != nil && previousCompletion != nil && previousCost != nil
                let decreased = hasPrevious && (
                    session.promptTokens < previousPrompt! || session.completionTokens < previousCompletion!
                        || session.costMicros < previousCost!
                )
                let generation = (nextOffsets[prefix + "generation"] ?? 0) + (decreased ? 1 : 0)
                let input: Int64
                let output: Int64
                let cost: Double
                if !hasPrevious || decreased {
                    input = session.promptTokens
                    output = session.completionTokens
                    cost = session.rawCost
                } else {
                    let promptDelta = session.promptTokens - previousPrompt!
                    let completionDelta = session.completionTokens - previousCompletion!
                    let costDelta = session.costMicros - previousCost!
                    if promptDelta == 0 && completionDelta == 0 && costDelta == 0 {
                        nextOffsets[prefix + "updated"] = session.updatedAt
                        continue
                    }
                    input = promptDelta
                    output = completionDelta
                    cost = Double(costDelta) / 1_000_000.0
                }

                let timestampSeconds = session.updatedAt > 0 ? session.updatedAt : session.createdAt
                let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampSeconds))
                let cumulative = "\(session.promptTokens):\(session.completionTokens):\(session.costMicros)"
                let fingerprint = Self.stableHash(cumulative)
                let recordID = "crush:v1:\(pathHash):\(session.id):g\(generation):u\(session.updatedAt):\(fingerprint)"
                records.append(UnifiedTokenRecord(
                    id: recordID,
                    sourceId: sourceId,
                    timestamp: timestamp,
                    timestampSource: .sourceModified,
                    sessionKey: session.id,
                    projectFolder: database.projectPath.isEmpty ? nil : database.projectPath,
                    // A session can contain messages from different models, so
                    // never attribute its cumulative total to any one message.
                    model: "crush",
                    provider: nil,
                    inputTokens: Self.safeInt(input),
                    outputTokens: Self.safeInt(output),
                    rawCostUSD: cost
                ))

                nextOffsets[prefix + "prompt"] = session.promptTokens
                nextOffsets[prefix + "completion"] = session.completionTokens
                nextOffsets[prefix + "costMicros"] = session.costMicros
                nextOffsets[prefix + "updated"] = session.updatedAt
                nextOffsets[prefix + "generation"] = generation
            }
        }

        // Missing databases are transiently absent rather than replacements;
        // retain their state until they reappear. Removed sessions likewise
        // emit no negative/tombstone record because UnifiedTokenRecord storage
        // is append-only.
        nextOffsets = nextOffsets.filter { key, _ in
            if key == Self.identityKey || key.hasPrefix("crush.db.identity.") {
                return seenDatabaseKeys.contains(key) || databases.isEmpty
            }
            return key.hasPrefix(Self.sessionPrefix)
        }
        nextOffsets[Self.identityKey] = currentIdentity
        for database in databases {
            let pathHash = Self.stableHash(database.url.path)
            nextOffsets[Self.databaseIdentityKey(pathHash: pathHash)] = database.identity
        }
        return (records, .fileOffsets(nextOffsets))
    }

    // MARK: - SQLite read-only plumbing

    private struct ReadOnlyDatabase {
        let handle: OpaquePointer
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func readDatabase(at url: URL) -> (Int64, [Session])? {
        guard let database = openReadOnly(url) else { return nil }
        defer { sqlite3_close_v2(database.handle) }
        guard let sessions = readSessions(from: database) else { return nil }
        if sessions.isEmpty {
            // An empty but valid sessions table is still a valid database. Probe
            // table existence to distinguish it from a corrupt/unrelated file.
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database.handle,
                "SELECT 1 FROM sessions LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
            let result = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard result == SQLITE_ROW || result == SQLITE_DONE else { return nil }
        }
        let schemaVersion = scalarInt(database.handle, "PRAGMA schema_version") ?? 0
        let fileIdentifier = (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?
            .fileResourceIdentifier
        let identityMaterial = "\(fileIdentifier.map(String.init(describing:)) ?? url.path):\(schemaVersion)"
        return (Int64(bitPattern: stableHash(identityMaterial)), sessions)
    }

    private static func openReadOnly(_ url: URL) -> ReadOnlyDatabase? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK,
              let handle else { return nil }
        sqlite3_busy_timeout(handle, 1_000)
        guard sqlite3_exec(handle, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close_v2(handle)
            return nil
        }
        return ReadOnlyDatabase(handle: handle)
    }

    private static func readSessions(from database: ReadOnlyDatabase) -> [Session]? {
        let sql = """
            SELECT id, prompt_tokens, completion_tokens, cost, updated_at, created_at
            FROM sessions
            WHERE parent_session_id IS NULL
            ORDER BY id ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database.handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var sessions: [Session] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return sessions }
            guard result == SQLITE_ROW else { return nil }
            guard let idPointer = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idPointer)
            let rawCost = sqlite3_column_double(statement, 3)
            let safeRawCost = rawCost.isFinite && rawCost >= 0 ? rawCost : 0
            sessions.append(Session(
                id: id,
                promptTokens: max(0, sqlite3_column_int64(statement, 1)),
                completionTokens: max(0, sqlite3_column_int64(statement, 2)),
                costMicros: costMicros(safeRawCost),
                rawCost: safeRawCost,
                updatedAt: sqlite3_column_int64(statement, 4),
                createdAt: sqlite3_column_int64(statement, 5)
            ))
        }
    }

    private static func scalarInt(_ handle: OpaquePointer, _ sql: String) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private static func costMicros(_ cost: Double) -> Int64 {
        let scaled = (cost * 1_000_000.0).rounded(.toNearestOrAwayFromZero)
        if scaled >= Double(Int64.max) { return Int64.max }
        if scaled <= Double(Int64.min) { return 0 }
        return Int64(scaled)
    }

    private static func safeInt(_ value: Int64) -> Int {
        if value > Int64(Int.max) { return Int.max }
        if value < 0 { return 0 }
        return Int(value)
    }

    // MARK: - Stable state keys

    private static func databaseIdentityKey(pathHash: UInt64) -> String {
        "crush.db.identity.\(pathHash)"
    }

    private static func sessionPrefix(pathHash: UInt64, sessionID: String) -> String {
        "\(sessionPrefix)\(pathHash).\(stableHash(sessionID))."
    }

    private static func hasAnyStoredDatabaseState(_ offsets: [String: Int64]) -> Bool {
        offsets.keys.contains { $0.hasPrefix("crush.db.identity.") }
    }

    private static func aggregateIdentity(_ databases: [Database]) -> Int64 {
        let material = databases
            .map { "\($0.url.path):\($0.projectPath):\($0.identity)" }
            .sorted()
            .joined(separator: "\u{0}")
        return Int64(bitPattern: stableHash(material))
    }

    private static func stableHash(_ value: String) -> UInt64 {
        stableHash(Data(value.utf8))
    }

    private static func stableHash(_ data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
