import Foundation

public actor SyncCoordinator {
    private let database: DatabaseManager
    private let registry: AdapterRegistry
    private let pricingEngine: PricingEngine
    private var watcher: FSEventsWatcher?
    // Coalescing: while a sync is running, additional FSEvent-triggered
    // requests collapse into a single follow-up pass instead of queueing one
    // full-tree walk per event.
    private var isSyncing = false
    private var needsResync = false
    // Throttle state for the UI-triggered entry point (`syncForUI`). Opening the
    // dashboard / popover fires a sync on every interaction, so a full pass is
    // coalesced to at most one per `minInterval` (U-01).
    private var lastUISyncAt: Date?

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
            return 0
        }
        isSyncing = true
        defer { isSyncing = false }
        var total = 0
        repeat {
            needsResync = false
            total += try await syncAllOnce(changedPaths: changedPaths)
        } while needsResync
        return total
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

    private func syncAllOnce(changedPaths: [String]? = nil) async throws -> Int {
        // Phase 1 (actor, cheap): eligibility is a few path-prefix checks.
        var eligible: [(adapter: any AgentSourceAdapter, path: URL)] = []
        for adapter in registry.allAdapters() {
            guard let path = dataRoot(for: adapter) else { continue }
            // Event-driven sync: skip adapters whose watched tree contains
            // none of the changed paths — no new consumption there to read.
            if let changedPaths, !changedPaths.isEmpty,
               !Self.isPathAffected(root: path.path, changedPaths: changedPaths) {
                continue
            }
            eligible.append((adapter, path))
        }

        // Phase 2 (concurrent): cursor reads + the heavy fetch per adapter.
        // `DatabaseManager` is lock-guarded and `fetchOffActor` is nonisolated,
        // so per-adapter enumeration + parse latencies overlap instead of
        // adding up. Only Sendable locals cross into the group, never `self`.
        struct Fetched: Sendable {
            let adapter: any AgentSourceAdapter
            let path: URL
            let cursor: SyncCursor?
            let records: [UnifiedTokenRecord]
            let newCursor: SyncCursor
        }
        let database = self.database
        var fetched: [Fetched?] = Array(repeating: nil, count: eligible.count)
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
            }
        }

        // Phase 3 (actor, serial, registry order): cutover handling, pricing,
        // persistence. Cursor writes stay ordered and deterministic.
        var totalIngested = 0
        for slot in fetched {
            guard let fetch = slot else { continue }
            let adapter = fetch.adapter
            do {
                let cursor = fetch.cursor
                let isCutover: Bool
                switch (cursor, fetch.newCursor) {
                case (.rowId, .fileOffsets):
                    isCutover = true
                case (.fileOffsets, .rowId):
                    isCutover = true
                default:
                    isCutover = false
                }

                let finalRecords: [UnifiedTokenRecord]
                let finalCursor: SyncCursor
                if isCutover {
                    try database.resetRecords(for: adapter.sourceId)
                    let (freshRecords, freshCursor) = try await Self.fetchOffActor(adapter, from: fetch.path, since: nil)
                    finalRecords = freshRecords
                    finalCursor = freshCursor
                } else {
                    finalRecords = fetch.records
                    finalCursor = fetch.newCursor
                }

                // Attach pricing if missing, in place: rebuilding every
                // unpriced record copies all of its Strings field by field.
                var pricedRecords = finalRecords
                for i in pricedRecords.indices {
                    guard pricedRecords[i].rawCostUSD == nil || pricedRecords[i].rawCostUSD == 0.0 else { continue }
                    pricedRecords[i].rawCostUSD = pricingEngine.calculateCost(
                        model: pricedRecords[i].model,
                        input: pricedRecords[i].inputTokens,
                        output: pricedRecords[i].outputTokens,
                        cacheRead: pricedRecords[i].cacheReadTokens,
                        cacheWrite: pricedRecords[i].cacheWriteTokens
                    )
                }

                // Persist and count only the rows actually inserted (U-12).
                // `INSERT OR IGNORE` drops re-parsed duplicates, so the parsed
                // count would over-report and post a no-op refresh notification
                // (a full ~194 ms dashboard recompute) even when nothing
                // changed. No new records and an unchanged cursor → nothing to
                // persist (inserted stays 0).
                var inserted = 0
                if !pricedRecords.isEmpty || finalCursor != cursor {
                    inserted = try database.insertRecords(
                        pricedRecords,
                        updateCursorFor: adapter.sourceId,
                        cursor: finalCursor
                    )
                }
                totalIngested += inserted
            } catch {
                print("Error syncing adapter \(adapter.sourceId): \(error)")
            }
        }
        if totalIngested > 0 {
            let count = totalIngested
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .bennettUsageDataDidUpdate,
                    object: nil,
                    userInfo: ["ingested": count]
                )
            }
        }
        return totalIngested
    }

    /// True when a changed path lies inside the adapter's watched root (or is
    /// the root itself, or a parent of it — FSEvents may coalesce upward).
    private static func isPathAffected(root: String, changedPaths: [String]) -> Bool {
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        for changed in changedPaths {
            let normalized = changed.hasSuffix("/") ? String(changed.dropLast()) : changed
            if normalized == normalizedRoot
                || normalized.hasPrefix(normalizedRoot + "/")
                || normalizedRoot.hasPrefix(normalized + "/") {
                return true
            }
        }
        return false
    }

    public func startWatching() {
        let paths = registry.allAdapters().compactMap { dataRoot(for: $0)?.path }
        self.watcher = FSEventsWatcher(paths: paths) { [weak self] eventPaths in
            Task { [weak self] in
                _ = try? await self?.syncAll(changedPaths: eventPaths)
            }
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
