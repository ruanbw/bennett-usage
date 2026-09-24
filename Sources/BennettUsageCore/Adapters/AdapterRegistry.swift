import Foundation

public final class AdapterRegistry: @unchecked Sendable {
    public static let shared = AdapterRegistry()
    private var adapters: [String: AgentSourceAdapter] = [:]
    private var registrationOrder: [String] = []
    private let lock = NSLock()

    public init() {}

    public func register(_ adapter: AgentSourceAdapter) {
        lock.lock(); defer { lock.unlock() }
        if adapters[adapter.sourceId] == nil {
            registrationOrder.append(adapter.sourceId)
        }
        adapters[adapter.sourceId] = adapter
    }

    public func get(sourceId: String) -> AgentSourceAdapter? {
        lock.lock(); defer { lock.unlock() }
        return adapters[sourceId]
    }

    public func allAdapters() -> [AgentSourceAdapter] {
        lock.lock(); defer { lock.unlock() }
        return registrationOrder.compactMap { adapters[$0] }
    }
}
