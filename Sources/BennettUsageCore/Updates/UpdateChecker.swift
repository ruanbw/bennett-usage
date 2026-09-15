import Foundation
import Combine

/// Why an update check could not produce a version to compare against.
///
/// The checker stays UI-agnostic: it reports the reason, and the settings view
/// maps it onto a localized sentence.
public enum UpdateCheckFailure: Equatable, Sendable {
    /// The request never completed (offline, DNS, TLS, timeout).
    case network
    /// The API answered with a non-2xx status (rate limit, proxy, outage).
    case server(statusCode: Int)
    /// The API answered, but not with the release feed shape we expect.
    case decoding
    /// The feed was readable but held no usable published release.
    case noReleases
}

public enum UpdateCheckStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate(version: AppVersion, checkedAt: Date)
    case updateAvailable(UpdateRelease)
    case failed(UpdateCheckFailure)
}

/// Minimal transport seam for the update check so tests can drive every
/// outcome (newer release, 403 rate limit, garbage body, offline) without
/// touching the network.
public struct UpdateHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol UpdateHTTPClient: Sendable {
    func get(_ url: URL) async throws -> UpdateHTTPResponse
}

public struct URLSessionUpdateHTTPClient: UpdateHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(_ url: URL) async throws -> UpdateHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // The GitHub API answers 403 to requests that carry no User-Agent.
        request.setValue("BennettUsage/\(BennettUsageCore.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        return UpdateHTTPResponse(statusCode: statusCode, data: data)
    }
}

/// Checks GitHub Releases for a newer build than the one running.
///
/// The app is a long-lived menu bar agent, so the checker is deliberately
/// conservative: the automatic path runs at most once per `checkInterval`
/// (state persisted, so relaunching does not re-check) and honours the user's
/// preference, while an explicit “Check for Updates” click always goes out.
/// Nothing about the local usage data is transmitted — the request is a plain
/// unauthenticated `GET` of the public release feed.
@MainActor
public final class UpdateChecker: ObservableObject {
    public static let shared = UpdateChecker()

    public static let autoCheckDefaultsKey = "bennett_auto_check_updates"
    public static let lastCheckDefaultsKey = "bennett_last_update_check"
    public static let skippedVersionDefaultsKey = "bennett_skipped_update_version"

    /// Cadence of the automatic (launch / timer) check.
    public nonisolated static let defaultCheckInterval: TimeInterval = 24 * 60 * 60
    public nonisolated static let defaultEndpoint = URL(
        string: "https://api.github.com/repos/ruanbw/bennett-usage/releases?per_page=15"
    )!
    public nonisolated static let releasesPageURL = URL(
        string: "https://github.com/ruanbw/bennett-usage/releases"
    )!

    @Published public private(set) var status: UpdateCheckStatus = .idle
    @Published public private(set) var lastCheckAt: Date?
    @Published public private(set) var skippedVersion: AppVersion?

    /// Persisted user preference backing the “Automatically Check for Updates”
    /// switch. Defaults to on for a fresh install.
    @Published public var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            userDefaults.set(automaticallyChecksForUpdates, forKey: Self.autoCheckDefaultsKey)
        }
    }

    /// Version of the running build (bundle short version, falling back to the
    /// compiled-in constant), i.e. the left-hand side of every comparison.
    public let currentVersion: AppVersion
    public let endpoint: URL
    public let checkInterval: TimeInterval

    private let client: any UpdateHTTPClient
    private let userDefaults: UserDefaults
    private var isCheckInFlight = false

    public init(
        client: any UpdateHTTPClient = URLSessionUpdateHTTPClient(),
        userDefaults: UserDefaults = .standard,
        currentVersion: AppVersion = UpdateChecker.bundledVersion(),
        endpoint: URL = UpdateChecker.defaultEndpoint,
        checkInterval: TimeInterval = UpdateChecker.defaultCheckInterval
    ) {
        self.client = client
        self.userDefaults = userDefaults
        self.currentVersion = currentVersion
        self.endpoint = endpoint
        self.checkInterval = checkInterval
        // `UserDefaults.bool(forKey:)` cannot distinguish “off” from “unset”,
        // so an absent key has to mean “on”.
        self.automaticallyChecksForUpdates = userDefaults.object(forKey: Self.autoCheckDefaultsKey) as? Bool ?? true
        self.lastCheckAt = userDefaults.object(forKey: Self.lastCheckDefaultsKey) as? Date
        if let raw = userDefaults.string(forKey: Self.skippedVersionDefaultsKey) {
            self.skippedVersion = AppVersion(raw)
        }
    }

    /// Version stamped into the running bundle by `scripts/package-dmg.sh`
    /// (`CFBundleShortVersionString`), falling back to the compiled-in
    /// constant when the executable runs outside an app bundle (tests, `swift
    /// run`).
    nonisolated public static func bundledVersion(bundle: Bundle = .main) -> AppVersion {
        if let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let parsed = AppVersion(raw) {
            return parsed
        }
        return AppVersion(BennettUsageCore.version) ?? .unknown
    }

    public var isChecking: Bool {
        if case .checking = status { return true }
        return false
    }

    /// The update the UI should surface: an available release the user has not
    /// explicitly skipped. A skipped version stays quiet until a newer one is
    /// published.
    public var availableUpdate: UpdateRelease? {
        guard case .updateAvailable(let release) = status, release.version != skippedVersion else { return nil }
        return release
    }

    public var hasAvailableUpdate: Bool { availableUpdate != nil }

    /// Automatic entry point: safe to call on every launch and from a
    /// repeating timer — it returns immediately when the preference is off or
    /// the cadence window has not elapsed.
    public func checkAutomatically() async {
        await check(force: false)
    }

    /// - Parameter force: `true` for an explicit “Check for Updates” click. It
    ///   bypasses the preference and the throttle, because a deliberate
    ///   refresh must never be swallowed, but it still coalesces with a check
    ///   that is already in flight.
    public func check(force: Bool = true) async {
        guard !isCheckInFlight else { return }
        if !force {
            guard automaticallyChecksForUpdates else { return }
            if let lastCheckAt, Date().timeIntervalSince(lastCheckAt) < checkInterval { return }
        }

        isCheckInFlight = true
        status = .checking
        defer { isCheckInFlight = false }

        do {
            let response = try await client.get(endpoint)
            guard (200..<300).contains(response.statusCode) else {
                status = .failed(.server(statusCode: response.statusCode))
                return
            }
            let releases = try GitHubReleaseFeed.releases(from: response.data)
            let checkedAt = Date()
            // Stamp the cadence only on a real answer: a failed check must not
            // mute the next attempt for a whole day.
            lastCheckAt = checkedAt
            userDefaults.set(checkedAt, forKey: Self.lastCheckDefaultsKey)
            guard let newest = Self.newestRelease(in: releases, currentVersion: currentVersion) else {
                status = .failed(.noReleases)
                return
            }
            status = newest.version > currentVersion
                ? .updateAvailable(newest)
                : .upToDate(version: currentVersion, checkedAt: checkedAt)
        } catch is DecodingError {
            status = .failed(.decoding)
        } catch {
            status = .failed(.network)
        }
    }

    /// Suppresses `release` until a newer version is published.
    public func skip(_ release: UpdateRelease) {
        skippedVersion = release.version
        userDefaults.set(release.version.description, forKey: Self.skippedVersionDefaultsKey)
    }

    /// Clears a previous “Skip This Version”, so the pending update is offered
    /// again on the next check.
    public func clearSkippedVersion() {
        skippedVersion = nil
        userDefaults.removeObject(forKey: Self.skippedVersionDefaultsKey)
    }

    /// Highest published version eligible for this build. Pre-releases are
    /// ignored unless the running build is itself a pre-release, so release
    /// users are never pushed onto an alpha while alpha users still get one.
    nonisolated static func newestRelease(in releases: [UpdateRelease], currentVersion: AppVersion) -> UpdateRelease? {
        let eligible = releases.filter { !$0.isPrerelease || currentVersion.isPrerelease }
        return eligible.max { $0.version < $1.version }
    }
}
