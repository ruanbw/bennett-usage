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
    /// Roots resolved for the most recent pass, reused for a short window so a
    /// no-op sync does not re-probe the filesystem for all adapters twice.
    private var cachedContexts: [AdapterContext]?
    private var cachedContextsAt: Date?
    /// How long a resolved context set is reused before adapter roots are
    /// re-probed for directories that did not exist yet.
    private static let contextValidity: TimeInterval = 60
    /// When the last unfiltered sweep ran. Bounds how often the heartbeat
    /// re-enumerates every source tree.
    private var lastFullSweepAt: Date?

    /// One adapter's resolved data root and watch roots for a pass. Resolving a
    /// root costs filesystem probes (`detectDefaultPath` plus an ancestor walk
    /// per watch root), so the watcher refresh and the eligibility check share
    /// one resolution instead of each performing its own.
    private struct AdapterContext {
        let adapter: any AgentSourceAdapter
        let dataRoot: URL
        let watchRoots: [URL]
    }

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

    /// Periodic safety-net sync used by the status item's heartbeat.
    ///
    /// FSEvents already reports every change (and a dropped-event batch forces a
    /// full rescan), so re-enumerating every source tree on each tick bought
    /// nothing — it is what made an otherwise idle process walk
    /// `~/.pi/agent/sessions` and every other root twice a minute. The heartbeat
    /// therefore runs a full sweep only when the last one is older than
    /// `fullSweepEvery`, and otherwise returns without touching the sources.
    /// Callers still refresh their presentation surfaces.
    @discardableResult
    public func syncHeartbeat(
        minInterval: TimeInterval = 10,
        fullSweepEvery: TimeInterval = 300
    ) async throws -> Int {
        // Keep the watcher current even on ticks that skip the sweep, so a
        // newly installed agent's directory starts being watched promptly
        // instead of waiting for the next full sweep.
        updateWatchingPathsIfNeeded()
        if let lastFullSweepAt, Date().timeIntervalSince(lastFullSweepAt) < fullSweepEvery {
            return 0
        }
        return try await syncForUI(minInterval: minInterval)
    }

    private func syncAllOnce(changedPaths: [String]? = nil) async throws -> (ingestedCount: Int, failures: [SyncFailureSummary]) {
        let contexts = resolvedContexts(force: false)
        updateWatcher(for: contexts)
        if changedPaths == nil {
            // Recorded here so `syncHeartbeat` can tell how stale the last
            // unfiltered sweep is without re-deriving it.
            lastFullSweepAt = Date()
        }
        let eligible = eligibleAdapters(from: contexts, changedPaths: changedPaths)
        let result = await fetchEligibleAdapters(eligible, changedPaths: changedPaths)
        return await persist(fetched: result.fetched, failures: result.failures)
    }

    private func eligibleAdapters(
        from contexts: [AdapterContext],
        changedPaths: [String]?
    ) -> [(adapter: any AgentSourceAdapter, path: URL)] {
        // Eligibility is a few path-prefix checks against roots that were
        // already resolved for the watcher refresh above.
        var eligible: [(adapter: any AgentSourceAdapter, path: URL)] = []
        for context in contexts {
            // Event-driven sync: skip adapters whose primary or auxiliary trees
            // contain none of the changed paths — no new consumption there to read.
            if let changedPaths, !changedPaths.isEmpty,
               !Self.isPathAffected(roots: context.watchRoots, changedPaths: changedPaths) {
                continue
            }
            eligible.append((context.adapter, context.dataRoot))
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
        _ eligible: [(adapter: any AgentSourceAdapter, path: URL)],
        changedPaths: [String]?
    ) async -> FetchBatch {
        // `DatabaseManager` is lock-guarded and `fetchOffActor` is nonisolated,
        // so per-adapter enumeration + parse latencies overlap instead of
        // adding up. Only Sendable locals cross into the group, never `self`.
        let database = self.database
        // Normalized once so every adapter compares like-for-like paths. An
        // empty batch means "full sweep" and is preserved as `nil` so adapters
        // keep their unfiltered code path.
        let scopedPaths = Self.normalizedChangedPaths(changedPaths)
        var fetched: [Fetched?] = Array(repeating: nil, count: eligible.count)
        var fetchFailures: [SyncFailureSummary] = []
        await withTaskGroup(of: (Int, Fetched?).self) { group in
            for (index, item) in eligible.enumerated() {
                group.addTask {
                    do {
                        let cursor = try database.fetchCursor(for: item.adapter.sourceId)
                        let (records, newCursor) = try await Self.fetchOffActor(
                            item.adapter,
                            from: item.path,
                            since: cursor,
                            changedPaths: scopedPaths
                        )
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
                    // Store the watermark only when it actually moved. A large
                    // `fileOffsets` cursor re-encoded on a pass that added no new
                    // consumption was pure write amplification.
                    changed = try database.insertRecords(
                        pricedRecords,
                        updateCursorFor: adapter.sourceId,
                        cursor: finalCursor != cursor ? finalCursor : nil,
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
            // A changed `generation` means the file was replaced. A changed
            // `prefixHash` means the bytes already consumed were rewritten in
            // place: the adapter rescans from zero and mints fresh ids, so the
            // rows ingested from the old prefix have to be replaced rather than
            // left behind to count the same usage twice.
            return newGenerations.contains { path, newGeneration in
                guard let oldGeneration = oldGenerations[path] else { return false }
                if oldGeneration.generation != newGeneration.generation { return true }
                switch (oldGeneration.prefixHash, newGeneration.prefixHash) {
                case let (old?, new?):
                    return old != new
                default:
                    // A cursor written before prefix hashing is treated as
                    // compatible, exactly as it was before this check existed.
                    return false
                }
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
    ///
    /// Always re-resolves: callers use this to observe a root that was just
    /// created. The per-pass refresh goes through `resolvedContexts(force:)`
    /// instead, which reuses a recent resolution.
    public func updateWatchingPathsIfNeeded() {
        updateWatcher(for: resolvedContexts(force: true))
    }

    private func updateWatcher(for contexts: [AdapterContext]) {
        let activePaths = contexts.flatMap { $0.watchRoots.map(\.path) }
        let uniquePaths = Array(Set(activePaths.map(Self.normalizedPath))).sorted()
        guard uniquePaths != watchedPaths else { return }
        watchedPaths = uniquePaths
        self.watcher = FSEventsWatcher(paths: uniquePaths) { [weak self] batch in
            Task { [weak self] in
                await self?.handleWatcherBatch(batch)
            }
        }
    }

    /// Routes one FSEvents batch to the right kind of sweep.
    ///
    /// A dropped-event batch carries an incomplete path list, so the only safe
    /// response is a full sweep. Otherwise the batch names exactly which files
    /// changed and adapters may read just those.
    func handleWatcherBatch(_ batch: FSEventsChangeBatch) async {
        if batch.requiresFullRescan {
            _ = try? await syncAll()
        } else {
            _ = try? await syncAll(changedPaths: batch.paths)
        }
    }

    /// Resolves every adapter's data and watch roots.
    ///
    /// Resolution is filesystem work (`detectDefaultPath` plus an ancestor walk
    /// per watch root). It used to happen twice on every pass — once for the
    /// watcher refresh, once for eligibility — so even a pass that ingested
    /// nothing probed all 18 adapters. `force` bypasses the reuse window for
    /// callers that must see a just-created directory immediately.
    private func resolvedContexts(force: Bool) -> [AdapterContext] {
        if !force, let cachedContexts, let cachedContextsAt,
           Date().timeIntervalSince(cachedContextsAt) < Self.contextValidity {
            return cachedContexts
        }
        var contexts: [AdapterContext] = []
        for adapter in registry.allAdapters() {
            guard let root = dataRoot(for: adapter) else { continue }
            contexts.append(
                AdapterContext(
                    adapter: adapter,
                    dataRoot: root,
                    watchRoots: watchDirectories(for: adapter, dataRoot: root)
                )
            )
        }
        cachedContexts = contexts
        cachedContextsAt = Date()
        return contexts
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
    private static func normalizedChangedPaths(_ changedPaths: [String]?) -> [String]? {
        guard let changedPaths, !changedPaths.isEmpty else { return nil }
        return Array(Set(changedPaths.map(normalizedPath)))
    }

    private nonisolated static func fetchOffActor(
        _ adapter: AgentSourceAdapter,
        from path: URL,
        since cursor: SyncCursor?,
        changedPaths: [String]?
    ) async throws -> (records: [UnifiedTokenRecord], newCursor: SyncCursor) {
        try await Task.detached(priority: .userInitiated) {
            try await adapter.fetchIncrementalRecords(from: path, since: cursor, changedPaths: changedPaths)
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
