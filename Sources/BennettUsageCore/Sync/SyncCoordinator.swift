import Foundation

public actor SyncCoordinator {
    private let database: DatabaseManager
    private let registry: AdapterRegistry
    private let pricingEngine: PricingEngine
    private var watcher: FSEventsWatcher?
    private var watchedPaths: [String] = []
    // Coalescing: while a sync is running, additional FSEvent-triggered
    // requests collapse into a single follow-up pass instead of queueing one
    // full-tree walk per event. Distinct changedPaths are accumulated so
    // concurrent events for other adapters are never lost. `nil` means full sync.
    private var isSyncing = false
    private var needsResync = false
    private var pendingChangedPaths: Set<String>? = Set<String>()
    // Throttle state for the UI-triggered entry point (`syncForUI`). Opening the
    // dashboard / popover fires a sync on every interaction, so a full pass is
    // coalesced to at most one per `minInterval` (U-01).
    private var lastUISyncAt: Date?
    private var syncStatus = SyncStatus()

    public init(
        database: DatabaseManager,
        registry: AdapterRegistry = .shared,
        pricingEngine: PricingEngine = .shared
    ) {
        self.database = database
        self.registry = registry
        self.pricingEngine = pricingEngine
    }

    @discardableResult
    public func syncAll(changedPaths: [String]? = nil) async throws -> Int {
        if isSyncing {
            needsResync = true
            if let changedPaths {
                if var pending = pendingChangedPaths {
                    pending.formUnion(changedPaths)
                    pendingChangedPaths = pending
                }
            } else {
                // At least one caller requested a full sync (nil changedPaths)
                pendingChangedPaths = nil
            }
            return 0
        }
        isSyncing = true
        pendingChangedPaths = Set<String>()
        let attemptAt = Date()
        syncStatus = SyncStatus(
            phase: .syncing,
            lastAttemptAt: attemptAt,
            lastSuccessfulAt: syncStatus.lastSuccessfulAt
        )
        Self.postSyncStatusDidChange()
        defer {
            isSyncing = false
            pendingChangedPaths = Set<String>()
        }

        var failures: [SyncFailureSummary] = []
        var currentPaths = changedPaths
        var total = 0
        do {
            repeat {
                needsResync = false
                let result = try await syncAllOnce(changedPaths: currentPaths)
                total += result.ingestedCount
                failures.append(contentsOf: result.failures)
                if needsResync {
                    currentPaths = pendingChangedPaths.map { Array($0) }
                    pendingChangedPaths = Set<String>()
                }
            } while needsResync

            let completedAt = Date()
            syncStatus = SyncStatus(
                phase: .idle,
                lastAttemptAt: attemptAt,
                lastSuccessfulAt: failures.isEmpty ? completedAt : syncStatus.lastSuccessfulAt,
                failures: failures
            )
            Self.postSyncStatusDidChange()
            return total
        } catch {
            syncStatus = SyncStatus(
                phase: .idle,
                lastAttemptAt: attemptAt,
                lastSuccessfulAt: syncStatus.lastSuccessfulAt,
                failures: failures
            )
            Self.postSyncStatusDidChange()
            throw error
        }
    }

    /// UI-triggered sync entry point.
    ///
    /// `syncAll(changedPaths: nil)` runs a full-tree enumeration + per-file
    /// `stat` for every adapter (~0.5–1 s on one core). Invoking it on every
    /// window open or status-item click is the U-01 regression, so those entry
    /// points go through here and bursts are coalesced to at most one full pass
    /// per `minInterval`.
    ///
    /// - Parameters:
    ///   - minInterval: minimum seconds between two UI-triggered full passes.
    ///   - force: bypasses the throttle for explicit user intent (e.g. a
    ///     “Sync Now” button), which must never be swallowed.
    @discardableResult
    public func syncForUI(minInterval: TimeInterval = 5, force: Bool = false) async throws -> Int {
        if !force, let last = lastUISyncAt, Date().timeIntervalSince(last) < minInterval {
            return 0
        }
        // Cooperates with `syncAll`'s own coalescing: if a pass is already
        // running, `syncAll` returns 0, sets `needsResync`, and the in-flight
        // pass re-runs — so the data still ends up fresh. On throw we leave
        // `lastUISyncAt` untouched so the next UI sync retries.
        let result = try await syncAll()
        lastUISyncAt = Date()
        return result
    }

    private func syncAllOnce(changedPaths: [String]? = nil) async throws -> (ingestedCount: Int, failures: [SyncFailureSummary]) {
        updateWatchingPathsIfNeeded()
        let eligible = eligibleAdapters(changedPaths: changedPaths)
        let result = await fetchEligibleAdapters(eligible)
        return await persist(fetched: result.fetched, failures: result.failures)
    }

    private func eligibleAdapters(changedPaths: [String]?) -> [(adapter: any AgentSourceAdapter, path: URL)] {
        // Phase 1 (actor, cheap): eligibility is a few path-prefix checks.
        var eligible: [(adapter: any AgentSourceAdapter, path: URL)] = []
        for adapter in registry.allAdapters() {
            guard let path = dataRoot(for: adapter) else { continue }
            // Event-driven sync: skip adapters whose primary or auxiliary trees
            // contain none of the changed paths — no new consumption there to read.
            let roots = watchDirectories(for: adapter, dataRoot: path)
            if let changedPaths, !changedPaths.isEmpty,
               !Self.isPathAffected(roots: roots, changedPaths: changedPaths) {
                continue
            }
            eligible.append((adapter, path))
        }
        return eligible
    }

    private struct Fetched: Sendable {
        let adapter: any AgentSourceAdapter
        let path: URL
        let cursor: SyncCursor?
        let records: [UnifiedTokenRecord]
        let newCursor: SyncCursor
    }

    private struct FetchBatch: Sendable {
        let fetched: [Fetched?]
        let failures: [SyncFailureSummary]
    }

    private func fetchEligibleAdapters(
        _ eligible: [(adapter: any AgentSourceAdapter, path: URL)]
    ) async -> FetchBatch {
        // `DatabaseManager` is lock-guarded and `fetchOffActor` is nonisolated,
        // so per-adapter enumeration + parse latencies overlap instead of
        // adding up. Only Sendable locals cross into the group, never `self`.
        let database = self.database
        var fetched: [Fetched?] = Array(repeating: nil, count: eligible.count)
        var fetchFailures: [SyncFailureSummary] = []
        await withTaskGroup(of: (Int, Fetched?).self) { group in
            for (index, item) in eligible.enumerated() {
                group.addTask {
                    do {
                        let cursor = try database.fetchCursor(for: item.adapter.sourceId)
                        let (records, newCursor) = try await Self.fetchOffActor(item.adapter, from: item.path, since: cursor)
                        return (index, Fetched(adapter: item.adapter, path: item.path, cursor: cursor, records: records, newCursor: newCursor))
                    } catch {
                        print("Error syncing adapter \(item.adapter.sourceId): \(error)")
                        return (index, nil)
                    }
                }
            }
            for await (index, result) in group {
                fetched[index] = result
                if result == nil {
                    let sourceId = eligible[index].adapter.sourceId
                    fetchFailures.append(SyncFailureSummary(sourceId: sourceId, stage: .fetch))
                }
            }
        }
        return FetchBatch(fetched: fetched, failures: fetchFailures)
    }

    private func persist(
        fetched: [Fetched?],
        failures initialFailures: [SyncFailureSummary]
    ) async -> (ingestedCount: Int, failures: [SyncFailureSummary]) {
        // Actor-serial, registry order: cutover handling, pricing,
        // persistence. Cursor writes stay ordered and deterministic.
        var totalIngested = 0
        var dataDidChange = false
        var failures = initialFailures
        for slot in fetched {
            guard let fetch = slot else { continue }
            let adapter = fetch.adapter
            do {
                let cursor = fetch.cursor
                let isCutover = Self.requiresCutover(from: cursor, to: fetch.newCursor)

                let finalRecords: [UnifiedTokenRecord]
                let finalCursor: SyncCursor
                if isCutover {
                    // Never delete the old source state before a complete fresh
                    // snapshot has been read and priced. Persistence below swaps
                    // records, rollups, and cursor in one transaction.
                    do {
                        (finalRecords, finalCursor) = try await Self.fetchCompleteSnapshotOffActor(adapter, from: fetch.path)
                    } catch {
                        print("Error syncing adapter \(adapter.sourceId): \(error)")
                        failures.append(SyncFailureSummary(sourceId: adapter.sourceId, stage: .completeSnapshot))
                        continue
                    }
                } else {
                    finalRecords = fetch.records
                    finalCursor = fetch.newCursor
                }

                // Attach pricing if missing, in place: rebuilding every
                // unpriced record copies all of its Strings field by field.
                var pricedRecords = finalRecords
                for i in pricedRecords.indices {
                    guard pricedRecords[i].rawCostUSD == nil else { continue }
                    pricedRecords[i].rawCostUSD = pricingEngine.calculateCost(
                        model: pricedRecords[i].model,
                        input: pricedRecords[i].inputTokens,
                        output: pricedRecords[i].outputTokens,
                        cacheRead: pricedRecords[i].cacheReadTokens,
                        cacheWrite: pricedRecords[i].cacheWriteTokens
                    )
                }

                // Persist and count only rows that actually changed. Immutable
                // adapters keep insert-and-ignore semantics; adapters that
                // explicitly opt in may correct an existing stable ID.
                var changed = 0
                if isCutover {
                    changed = try database.replaceSourceRecords(
                        pricedRecords,
                        sourceId: adapter.sourceId,
                        cursor: finalCursor
                    )
                    // A valid empty snapshot is still a source replacement: it
                    // removes old records/rollups and advances the cursor, so
                    // consumers must refresh even though the row count is zero.
                    dataDidChange = true
                } else if !pricedRecords.isEmpty || finalCursor != cursor {
                    changed = try database.insertRecords(
                        pricedRecords,
                        updateCursorFor: adapter.sourceId,
                        cursor: finalCursor,
                        updateExisting: adapter.supportsRecordCorrections
                    )
                    dataDidChange = dataDidChange || changed > 0
                }
                totalIngested += changed
            } catch {
                print("Error syncing adapter \(adapter.sourceId): \(error)")
                failures.append(SyncFailureSummary(sourceId: adapter.sourceId, stage: .persistence))
            }
        }
        if dataDidChange {
            let count = totalIngested
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .bennettUsageDataDidUpdate,
                    object: nil,
                    userInfo: ["ingested": count]
                )
            }
        }
        return (totalIngested, failures)
    }

    /// A changed database or file-generation identity invalidates an otherwise
    /// compatible watermark. Cross-representation changes are also unsafe: the
    /// old watermark cannot describe the source represented by the new cursor.
    private static func requiresCutover(from oldCursor: SyncCursor?, to newCursor: SyncCursor) -> Bool {
        switch (oldCursor, newCursor) {
        case (nil, _):
            return false
        case (.databaseIdentity(let oldIdentity, _), .databaseIdentity(let newIdentity, _)):
            return oldIdentity != newIdentity
        case (.fileGenerations(let oldGenerations), .fileGenerations(let newGenerations)):
            return newGenerations.contains { path, newGeneration in
                guard let oldGeneration = oldGenerations[path] else { return false }
                return oldGeneration.generation != newGeneration.generation
            }
        case (.rowId, .rowId),
             (.fileOffsets, .fileOffsets),
             (.timestamp, .timestamp):
            return false
        default:
            return true
        }
    }

    /// True when a changed path lies inside the adapter's watched root (or is
    /// the root itself, or a parent of it — FSEvents may coalesce upward).
    private static func isPathAffected(roots: [URL], changedPaths: [String]) -> Bool {
        let normalizedRoots = roots.map { normalizedPath($0.path) }
        let normalizedChanges = changedPaths.map(normalizedPath)
        return normalizedRoots.contains { root in
            normalizedChanges.contains { changed in
                changed == root
                    || changed.hasPrefix(root + "/")
                    || root.hasPrefix(changed + "/")
            }
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    public func currentWatchingPaths() -> [String] {
        return watchedPaths
    }

    public func currentSyncStatus() -> SyncStatus {
        return syncStatus
    }

    public func startWatching() {
        updateWatchingPathsIfNeeded()
    }

    /// Checks if any newly created adapter directories appeared since watching started,
    /// and restarts FSEventsWatcher with the expanded path list if needed.
    public func updateWatchingPathsIfNeeded() {
        let activePaths = registry.allAdapters().flatMap { adapter -> [String] in
            guard let root = dataRoot(for: adapter) else { return [] }
            return watchDirectories(for: adapter, dataRoot: root).map(\.path)
        }
        let uniquePaths = Array(Set(activePaths.map(Self.normalizedPath))).sorted()
        if uniquePaths != watchedPaths {
            watchedPaths = uniquePaths
            self.watcher = FSEventsWatcher(paths: uniquePaths) { [weak self] eventPaths in
                Task { [weak self] in
                    _ = try? await self?.syncAll(changedPaths: eventPaths)
                }
            }
        }
    }

    private nonisolated static func postSyncStatusDidChange() {
        NotificationCenter.default.post(
            name: .bennettUsageSyncStatusDidChange,
            object: nil
        )
    }

    private func watchDirectories(for adapter: any AgentSourceAdapter, dataRoot: URL) -> [URL] {
        let roots = ([dataRoot] + adapter.auxiliaryWatchRoots(for: dataRoot))
            .map { URL(fileURLWithPath: Self.normalizedPath($0.path)) }
        var seen = Set<String>()
        return roots.compactMap { root in
            let directory = Self.watchDirectory(for: root)
            return seen.insert(directory.path).inserted ? directory : nil
        }
    }

    /// FSEvents requires an existing directory. File roots use their parent;
    /// missing directory roots use the nearest existing ancestor so creation of
    /// the root is observed and the watcher can be refreshed on the next sync.
    private static func watchDirectory(for url: URL) -> URL {
        var candidate = url
        while true {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir) {
                if isDir.boolValue { return candidate }
                return candidate.deletingLastPathComponent()
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return candidate }
            candidate = parent
        }
    }

    /// Adapter fetches do full-tree enumeration + JSON parsing synchronously.
    /// Running them inside the actor stalled the cooperative pool for tens of
    /// seconds on first launch and queued UI refreshes; run the heavy section
    /// on a detached task and let the actor await only the result. Cursors and
    /// persistence stay on the actor.
    private nonisolated static func fetchOffActor(
        _ adapter: AgentSourceAdapter,
        from path: URL,
        since cursor: SyncCursor?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        try await Task.detached(priority: .userInitiated) {
            try await adapter.fetchIncrementalRecords(from: path, since: cursor)
        }.value
    }

    private nonisolated static func fetchCompleteSnapshotOffActor(
        _ adapter: AgentSourceAdapter,
        from path: URL
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        try await Task.detached(priority: .userInitiated) {
            try await adapter.fetchCompleteSnapshot(from: path)
        }.value
    }

    /// Directory the coordinator watches and enumerates for an adapter.
    /// - `isSyncStub` adapters (no fetch implementation) are skipped outright.
    /// - Otherwise the narrowed `syncRootPath` is used when it exists as a
    ///   directory (e.g. gemini → ~/.gemini/tmp).
    /// - Otherwise the adapter's own detection applies (preserves OmpAdapter's
    ///   stats.db fallback when the sessions directory is missing). Custom
    ///   adapters without narrowing knowledge are unaffected.
    private func dataRoot(for adapter: AgentSourceAdapter) -> URL? {
        if adapter.isSyncStub { return nil }
        if let raw = adapter.syncRootPath, !raw.isEmpty {
            let narrowed = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: narrowed.path, isDirectory: &isDir), isDir.boolValue {
                return narrowed
            }
        }
        return adapter.detectDefaultPath()
    }
}
