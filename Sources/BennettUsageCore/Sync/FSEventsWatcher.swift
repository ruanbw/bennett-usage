import Foundation
import CoreServices

/// One coalesced batch of filesystem changes reported by FSEvents.
///
/// `requiresFullRescan` is set when the kernel or this client dropped events, so
/// `paths` is known to be incomplete. Consumers must then fall back to a full
/// enumeration instead of trusting the incremental path list, which is what
/// makes event-scoped reads safe.
public struct FSEventsChangeBatch: Sendable {
    public let paths: [String]
    public let requiresFullRescan: Bool

    public init(paths: [String], requiresFullRescan: Bool) {
        self.paths = paths
        self.requiresFullRescan = requiresFullRescan
    }
}

public final class FSEventsWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let callback: @Sendable (FSEventsChangeBatch) -> Void
    private let queue = DispatchQueue(label: "com.bennett.usage.fsevents")

    /// Flags that invalidate the individual paths carried by the same batch.
    private static let fullRescanFlags: FSEventStreamEventFlags =
        FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)

    public init(
        paths: [String],
        debounce: TimeInterval = 1.5,
        callback: @escaping @Sendable (FSEventsChangeBatch) -> Void
    ) {
        self.callback = callback
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let cfPaths = paths as CFArray
        // `latency` (the `debounce` argument) is the only thing that coalesces a
        // burst of writes into one callback. `kFSEventStreamCreateFlagNoDefer`
        // used to be set here, which explicitly defeats that coalescing and
        // delivered a batch per written file — with an agent writing transcripts
        // continuously that meant a full sync pass every few seconds. Keeping
        // `FileEvents` means each batch still carries exact file paths, so an
        // event-scoped pass can read just those files.
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)

        let streamCallback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

            var requiresFullRescan = false
            for index in 0..<numEvents where (eventFlags[index] & FSEventsWatcher.fullRescanFlags) != 0 {
                requiresFullRescan = true
                break
            }
            watcher.callback(
                FSEventsChangeBatch(paths: pathsArray, requiresFullRescan: requiresFullRescan)
            )
        }

        self.stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            streamCallback,
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce,
            flags
        )

        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream = stream {
            queue.sync {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }
    }
}
