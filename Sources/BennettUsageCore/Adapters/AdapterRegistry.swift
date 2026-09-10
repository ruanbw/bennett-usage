import Foundation

public final class AdapterRegistry: @unchecked Sendable {
    public static let shared = AdapterRegistry()
    private var adapters: [String: AgentSourceAdapter] = [:]
    private let lock = NSLock()

    public init() {}

    public func register(_ adapter: AgentSourceAdapter) {
        lock.lock(); defer { lock.unlock() }
        adapters[adapter.sourceId] = adapter
    }

    public func get(sourceId: String) -> AgentSourceAdapter? {
        lock.lock(); defer { lock.unlock() }
        return adapters[sourceId]
    }

    public func allAdapters() -> [AgentSourceAdapter] {
        lock.lock(); defer { lock.unlock() }
        return Array(adapters.values)
    }
}
