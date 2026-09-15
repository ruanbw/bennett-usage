import XCTest
import SwiftUI
import AppKit
@testable import BennettUsageCore

// MARK: - Doubles

/// Thread-safe box: the URLProtocol handler and the recording client run off
/// the test's actor, so plain captured `var`s would be a data race.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

/// Answers a canned body/status (or throws) and records every requested URL,
/// so a test can assert both the outcome and whether the network was touched.
private struct StubUpdateClient: UpdateHTTPClient {
    let requests: LockedBox<[URL]>
    let statusCode: Int
    let body: Data
    let error: (any Error)?

    init(statusCode: Int = 200, body: Data, error: (any Error)? = nil, requests: LockedBox<[URL]> = LockedBox([])) {
        self.statusCode = statusCode
        self.body = body
        self.error = error
        self.requests = requests
    }

    init(body: String, statusCode: Int = 200, requests: LockedBox<[URL]> = LockedBox([])) {
        self.init(statusCode: statusCode, body: Data(body.utf8), requests: requests)
    }

    func get(_ url: URL) async throws -> UpdateHTTPResponse {
        requests.mutate { $0.append(url) }
        if let error { throw error }
        return UpdateHTTPResponse(statusCode: statusCode, data: body)
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Fixtures

private func releaseDictionary(
    tag: String,
    name: String = "",
    body: String = "",
    draft: Bool = false,
    prerelease: Bool = false,
    publishedAt: String = "2026-09-16T03:57:12Z",
    assets: [(name: String, url: String)] = []
) -> [String: Any] {
    [
        "tag_name": tag,
        "name": name,
        "body": body,
        "html_url": "https://github.com/ruanbw/bennett-usage/releases/tag/\(tag)",
        "published_at": publishedAt,
        "prerelease": prerelease,
        "draft": draft,
        "assets": assets.map {
            ["name": $0.name, "browser_download_url": $0.url, "size": 1024]
        }
    ]
}

private func feedData(_ releases: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: releases)
}

private func dmgAssets(version: String) -> [(name: String, url: String)] {
    ["arm64", "x86_64", "universal"].map {
        (
            name: "BennettUsage-\(version)-\($0).dmg",
            url: "https://github.com/ruanbw/bennett-usage/releases/download/v\(version)/BennettUsage-\(version)-\($0).dmg"
        )
    }
}

private func makeRelease(_ version: String, prerelease: Bool = false) -> UpdateRelease {
    UpdateRelease(
        version: AppVersion(version)!,
        tagName: "v\(version)",
        title: "v\(version)",
        notes: "",
        pageURL: URL(string: "https://github.com/ruanbw/bennett-usage/releases/tag/v\(version)")!,
        publishedAt: nil,
        isPrerelease: prerelease,
        assets: dmgAssets(version: version).map {
            UpdateAsset(name: $0.name, downloadURL: URL(string: $0.url), sizeBytes: 1024)
        }
    )
}

// MARK: - Version parsing and ordering

final class AppVersionTests: XCTestCase {
    func testParsesPlainDottedVersion() {
        let version = AppVersion("1.2.3")
        XCTAssertEqual(version?.components, [1, 2, 3])
        XCTAssertEqual(version?.prerelease, [])
        XCTAssertEqual(version?.description, "1.2.3")
        XCTAssertEqual(version?.isPrerelease, false)
    }

    func testParsesReleaseTagForms() {
        XCTAssertEqual(AppVersion("v1.2.0")?.components, [1, 2, 0])
        XCTAssertEqual(AppVersion("V1.2.0")?.components, [1, 2, 0])
        XCTAssertEqual(AppVersion(" 1.2.0 ")?.components, [1, 2, 0])
        XCTAssertEqual(AppVersion("1.2.0+build.7")?.description, "1.2.0")
    }

    func testParsesPrereleaseIdentifiers() {
        let version = AppVersion("v1.3.0-beta.1")
        XCTAssertEqual(version?.components, [1, 3, 0])
        XCTAssertEqual(version?.prerelease, ["beta", "1"])
        XCTAssertEqual(version?.description, "1.3.0-beta.1")
        XCTAssertEqual(version?.isPrerelease, true)
    }

    func testPadsMissingComponentsSoEqualityMatchesOrdering() {
        XCTAssertEqual(AppVersion("1.2"), AppVersion("1.2.0"))
        XCTAssertEqual(AppVersion("1")?.components, [1, 0, 0])
        XCTAssertFalse(AppVersion("1.2")! < AppVersion("1.2.0")!)
        XCTAssertFalse(AppVersion("1.2.0")! < AppVersion("1.2")!)
    }

    func testRejectsUnparseableStrings() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("   "))
        XCTAssertNil(AppVersion("v"))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1.x.0"))
        XCTAssertNil(AppVersion("1..0"))
        XCTAssertNil(AppVersion("release-2026"))
    }

    func testComparesNumericComponents() {
        XCTAssertTrue(AppVersion("1.2.0")! < AppVersion("1.2.1")!)
        XCTAssertTrue(AppVersion("1.9.9")! < AppVersion("1.10.0")!)
        XCTAssertTrue(AppVersion("1.2.0")! < AppVersion("2.0.0")!)
        XCTAssertFalse(AppVersion("1.2.0")! < AppVersion("1.2.0")!)
    }

    func testPrereleaseSortsBeforeFinalRelease() {
        XCTAssertTrue(AppVersion("1.0.0-alpha")! < AppVersion("1.0.0")!)
        XCTAssertFalse(AppVersion("1.0.0")! < AppVersion("1.0.0-alpha")!)
    }

    /// SemVer §11 example ordering.
    func testPrereleaseIdentifierPrecedence() {
        let ordered = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0"
        ].map { AppVersion($0)! }

        for (earlier, later) in zip(ordered, ordered.dropFirst()) {
            XCTAssertTrue(earlier < later, "\(earlier) should sort before \(later)")
            XCTAssertFalse(later < earlier, "\(later) should not sort before \(earlier)")
        }
    }

    func testSortingPicksTheHighestVersion() {
        let versions = ["1.2.0", "1.10.0", "1.9.9", "v1.10.0-beta.1"].compactMap { AppVersion($0) }
        XCTAssertEqual(versions.max()?.description, "1.10.0")
    }
}

// MARK: - GitHub feed decoding

final class GitHubReleaseFeedTests: XCTestCase {
    func testDecodesReleasesWithAssets() throws {
        let data = feedData([
            releaseDictionary(
                tag: "v1.3.0",
                name: "v1.3.0 — Update check",
                body: "Release notes",
                assets: dmgAssets(version: "1.3.0")
            )
        ])

        let releases = try GitHubReleaseFeed.releases(from: data)
        XCTAssertEqual(releases.count, 1)
        let release = try XCTUnwrap(releases.first)
        XCTAssertEqual(release.version, AppVersion("1.3.0"))
        XCTAssertEqual(release.tagName, "v1.3.0")
        XCTAssertEqual(release.title, "v1.3.0 — Update check")
        XCTAssertEqual(release.notes, "Release notes")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/ruanbw/bennett-usage/releases/tag/v1.3.0")
        XCTAssertNotNil(release.publishedAt)
        XCTAssertEqual(release.assets.count, 3)
        XCTAssertEqual(release.assets.first?.sizeBytes, 1024)
    }

    func testFallsBackToTagWhenNameIsEmpty() throws {
        let data = feedData([releaseDictionary(tag: "v1.2.1", name: "")])
        let release = try XCTUnwrap(try GitHubReleaseFeed.releases(from: data).first)
        XCTAssertEqual(release.title, "v1.2.1")
    }

    func testSkipsDraftsAndUnparseableTags() throws {
        let data = feedData([
            releaseDictionary(tag: "nightly"),
            releaseDictionary(tag: "v1.4.0", draft: true),
            releaseDictionary(tag: "v1.3.1")
        ])

        let releases = try GitHubReleaseFeed.releases(from: data)
        XCTAssertEqual(releases.map(\.version.description), ["1.3.1"])
    }

    func testKeepsPrereleaseFlag() throws {
        let data = feedData([releaseDictionary(tag: "v2.0.0-beta.1", prerelease: true)])
        let release = try XCTUnwrap(try GitHubReleaseFeed.releases(from: data).first)
        XCTAssertTrue(release.isPrerelease)
    }

    func testToleratesMissingOptionalFields() throws {
        let data = Data(#"[{"tag_name":"v1.0.0","html_url":"https://example.com/r"}]"#.utf8)
        let release = try XCTUnwrap(try GitHubReleaseFeed.releases(from: data).first)
        XCTAssertEqual(release.title, "v1.0.0")
        XCTAssertEqual(release.notes, "")
        XCTAssertNil(release.publishedAt)
        XCTAssertTrue(release.assets.isEmpty)
        XCTAssertFalse(release.isPrerelease)
    }

    func testParsesFractionalSecondTimestamps() throws {
        let data = feedData([releaseDictionary(tag: "v1.0.0", publishedAt: "2026-09-16T03:57:12.512Z")])
        let release = try XCTUnwrap(try GitHubReleaseFeed.releases(from: data).first)
        XCTAssertNotNil(release.publishedAt)
    }

    func testThrowsOnNonArrayPayload() {
        XCTAssertThrowsError(try GitHubReleaseFeed.releases(from: Data(#"{"message":"Not Found"}"#.utf8)))
    }

    func testEmptyFeedDecodesToNoReleases() throws {
        XCTAssertTrue(try GitHubReleaseFeed.releases(from: Data("[]".utf8)).isEmpty)
    }
}

// MARK: - Asset selection

final class UpdateAssetSelectionTests: XCTestCase {
    func testPrefersTheAssetBuiltForThisArchitecture() {
        let release = makeRelease("1.3.0")
        XCTAssertEqual(release.preferredAsset(for: "arm64")?.name, "BennettUsage-1.3.0-arm64.dmg")
        XCTAssertEqual(release.preferredAsset(for: "x86_64")?.name, "BennettUsage-1.3.0-x86_64.dmg")
    }

    func testFallsBackToUniversalWhenArchAssetIsMissing() {
        let release = UpdateRelease(
            version: AppVersion("1.3.0")!,
            tagName: "v1.3.0",
            title: "v1.3.0",
            notes: "",
            pageURL: URL(string: "https://example.com")!,
            publishedAt: nil,
            isPrerelease: false,
            assets: [UpdateAsset(name: "BennettUsage-1.3.0-universal.dmg", downloadURL: nil, sizeBytes: 0)]
        )
        XCTAssertEqual(release.preferredAsset(for: "arm64")?.name, "BennettUsage-1.3.0-universal.dmg")
    }

    func testFallsBackToAnyDMGWhenNamesCarryNoArchitecture() {
        let release = UpdateRelease(
            version: AppVersion("1.3.0")!,
            tagName: "v1.3.0",
            title: "v1.3.0",
            notes: "",
            pageURL: URL(string: "https://example.com")!,
            publishedAt: nil,
            isPrerelease: false,
            assets: [
                UpdateAsset(name: "BennettUsage-1.3.0.zip", downloadURL: nil, sizeBytes: 0),
                UpdateAsset(name: "BennettUsage-1.3.0.dmg", downloadURL: nil, sizeBytes: 0)
            ]
        )
        XCTAssertEqual(release.preferredAsset(for: "arm64")?.name, "BennettUsage-1.3.0.dmg")
    }

    func testReturnsNilWithoutAnyDMG() {
        let release = UpdateRelease(
            version: AppVersion("1.3.0")!,
            tagName: "v1.3.0",
            title: "v1.3.0",
            notes: "",
            pageURL: URL(string: "https://example.com")!,
            publishedAt: nil,
            isPrerelease: false,
            assets: [UpdateAsset(name: "source.tar.gz", downloadURL: nil, sizeBytes: 0)]
        )
        XCTAssertNil(release.preferredAsset(for: "arm64"))
    }

    func testCurrentArchitectureMatchesTheCompiledSlice() {
        #if arch(arm64)
        XCTAssertEqual(UpdateRelease.currentArchitecture, "arm64")
        #elseif arch(x86_64)
        XCTAssertEqual(UpdateRelease.currentArchitecture, "x86_64")
        #endif
    }
}

// MARK: - Checker behaviour

final class UpdateCheckerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "UpdateCheckerTests_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    @MainActor
    private func makeChecker(
        currentVersion: String = "1.2.0",
        statusCode: Int = 200,
        feed: [[String: Any]] = [],
        error: (any Error)? = nil,
        checkInterval: TimeInterval = 24 * 60 * 60,
        requests: LockedBox<[URL]> = LockedBox([])
    ) -> (checker: UpdateChecker, requests: LockedBox<[URL]>) {
        let client = StubUpdateClient(
            statusCode: statusCode,
            body: feedData(feed),
            error: error,
            requests: requests
        )
        let checker = UpdateChecker(
            client: client,
            userDefaults: defaults,
            currentVersion: AppVersion(currentVersion)!,
            checkInterval: checkInterval
        )
        return (checker, requests)
    }

    // MARK: Outcomes

    @MainActor
    func testReportsNewerRelease() async {
        let (checker, requests) = makeChecker(feed: [
            releaseDictionary(tag: "v1.2.0", assets: dmgAssets(version: "1.2.0")),
            releaseDictionary(tag: "v1.3.0", name: "v1.3.0", assets: dmgAssets(version: "1.3.0"))
        ])

        await checker.check()

        XCTAssertEqual(requests.value.count, 1)
        XCTAssertEqual(checker.availableUpdate?.version, AppVersion("1.3.0"))
        XCTAssertTrue(checker.hasAvailableUpdate)
        XCTAssertFalse(checker.isChecking)
        guard case .updateAvailable(let release) = checker.status else {
            return XCTFail("expected an available update, got \(checker.status)")
        }
        XCTAssertEqual(release.preferredAsset(for: "arm64")?.downloadURL?.lastPathComponent, "BennettUsage-1.3.0-arm64.dmg")
    }

    @MainActor
    func testReportsUpToDateWhenCurrentVersionIsTheNewest() async {
        let (checker, _) = makeChecker(feed: [releaseDictionary(tag: "v1.2.0")])

        await checker.check()

        XCTAssertNil(checker.availableUpdate)
        guard case .upToDate(let version, _) = checker.status else {
            return XCTFail("expected up to date, got \(checker.status)")
        }
        XCTAssertEqual(version, AppVersion("1.2.0"))
    }

    @MainActor
    func testUpToDateWhenCurrentVersionIsAheadOfTheFeed() async {
        let (checker, _) = makeChecker(currentVersion: "1.4.0", feed: [releaseDictionary(tag: "v1.3.0")])
        await checker.check()
        XCTAssertNil(checker.availableUpdate)
    }

    @MainActor
    func testIgnoresPrereleasesForReleaseBuilds() async {
        let (checker, _) = makeChecker(feed: [
            releaseDictionary(tag: "v1.2.0"),
            releaseDictionary(tag: "v1.4.0-beta.1", prerelease: true)
        ])

        await checker.check()

        XCTAssertNil(checker.availableUpdate)
        guard case .upToDate = checker.status else {
            return XCTFail("expected up to date, got \(checker.status)")
        }
    }

    @MainActor
    func testOffersPrereleaseToPrereleaseBuilds() async {
        let (checker, _) = makeChecker(currentVersion: "1.4.0-beta.1", feed: [
            releaseDictionary(tag: "v1.3.0"),
            releaseDictionary(tag: "v1.4.0-beta.2", prerelease: true)
        ])

        await checker.check()

        XCTAssertEqual(checker.availableUpdate?.version, AppVersion("1.4.0-beta.2"))
    }

    @MainActor
    func testFailsOnServerError() async {
        let (checker, _) = makeChecker(statusCode: 403, feed: [])
        await checker.check()
        XCTAssertEqual(checker.status, .failed(.server(statusCode: 403)))
        XCTAssertNil(checker.availableUpdate)
    }

    @MainActor
    func testFailsOnUnreadablePayload() async {
        let client = StubUpdateClient(body: #"{"message":"Not Found"}"#)
        let checker = UpdateChecker(
            client: client,
            userDefaults: defaults,
            currentVersion: AppVersion("1.2.0")!
        )
        await checker.check()
        XCTAssertEqual(checker.status, .failed(.decoding))
    }

    @MainActor
    func testFailsWhenNetworkIsUnreachable() async {
        let (checker, _) = makeChecker(error: URLError(.notConnectedToInternet))
        await checker.check()
        XCTAssertEqual(checker.status, .failed(.network))
    }

    @MainActor
    func testFailsWhenFeedHasNoUsableRelease() async {
        let (checker, _) = makeChecker(feed: [releaseDictionary(tag: "nightly")])
        await checker.check()
        XCTAssertEqual(checker.status, .failed(.noReleases))
    }

    // MARK: Throttling and preference

    @MainActor
    func testAutomaticCheckHonoursDisabledPreference() async {
        defaults.set(false, forKey: UpdateChecker.autoCheckDefaultsKey)
        let (checker, requests) = makeChecker(feed: [releaseDictionary(tag: "v1.3.0")])

        XCTAssertFalse(checker.automaticallyChecksForUpdates)
        await checker.checkAutomatically()

        XCTAssertTrue(requests.value.isEmpty)
        XCTAssertEqual(checker.status, .idle)
    }

    @MainActor
    func testPreferenceDefaultsToOnAndPersists() async {
        let (checker, _) = makeChecker()
        XCTAssertTrue(checker.automaticallyChecksForUpdates)

        checker.automaticallyChecksForUpdates = false

        let reloaded = UpdateChecker(client: StubUpdateClient(body: "[]"), userDefaults: defaults, currentVersion: AppVersion("1.2.0")!)
        XCTAssertFalse(reloaded.automaticallyChecksForUpdates)
    }

    @MainActor
    func testAutomaticCheckIsThrottledWithinTheInterval() async {
        let (checker, requests) = makeChecker(feed: [releaseDictionary(tag: "v1.3.0")], checkInterval: 3600)

        await checker.checkAutomatically()
        await checker.checkAutomatically()

        XCTAssertEqual(requests.value.count, 1)
        XCTAssertNotNil(checker.lastCheckAt)
    }

    @MainActor
    func testAutomaticCheckRunsAgainOnceTheIntervalElapsed() async {
        defaults.set(Date().addingTimeInterval(-7200), forKey: UpdateChecker.lastCheckDefaultsKey)
        let (checker, requests) = makeChecker(feed: [releaseDictionary(tag: "v1.3.0")], checkInterval: 3600)

        await checker.checkAutomatically()

        XCTAssertEqual(requests.value.count, 1)
        XCTAssertEqual(defaults.object(forKey: UpdateChecker.lastCheckDefaultsKey) as? Date, checker.lastCheckAt)
    }

    @MainActor
    func testForcedCheckBypassesTheThrottle() async {
        defaults.set(Date(), forKey: UpdateChecker.lastCheckDefaultsKey)
        let (checker, requests) = makeChecker(feed: [releaseDictionary(tag: "v1.3.0")], checkInterval: 3600)

        await checker.check(force: true)
        await checker.check(force: true)

        XCTAssertEqual(requests.value.count, 2)
    }

    @MainActor
    func testFailedCheckDoesNotArmTheThrottle() async {
        let (failing, _) = makeChecker(error: URLError(.timedOut), checkInterval: 3600)
        await failing.checkAutomatically()
        XCTAssertNil(failing.lastCheckAt)

        // A later attempt in the same session still goes out.
        let (checker, requests) = makeChecker(feed: [releaseDictionary(tag: "v1.3.0")], checkInterval: 3600)
        await checker.checkAutomatically()
        XCTAssertEqual(requests.value.count, 1)
    }

    // MARK: Skipping

    @MainActor
    func testSkippingHidesTheUpdateAndPersists() async {
        let (checker, _) = makeChecker(feed: [releaseDictionary(tag: "v1.3.0")])
        await checker.check()
        let release = try! XCTUnwrap(checker.availableUpdate)

        checker.skip(release)

        XCTAssertNil(checker.availableUpdate)
        XCTAssertFalse(checker.hasAvailableUpdate)
        XCTAssertEqual(checker.skippedVersion, AppVersion("1.3.0"))
        XCTAssertEqual(defaults.string(forKey: UpdateChecker.skippedVersionDefaultsKey), "1.3.0")

        let reloaded = UpdateChecker(
            client: StubUpdateClient(body: "[]"),
            userDefaults: defaults,
            currentVersion: AppVersion("1.2.0")!
        )
        XCTAssertEqual(reloaded.skippedVersion, AppVersion("1.3.0"))
    }

    @MainActor
    func testSkippedVersionIsStillSuppressedOnTheNextCheck() async {
        let (checker, _) = makeChecker(feed: [releaseDictionary(tag: "v1.3.0")])
        await checker.check()
        checker.skip(try! XCTUnwrap(checker.availableUpdate))

        await checker.check(force: true)

        XCTAssertNil(checker.availableUpdate)
        guard case .updateAvailable = checker.status else {
            return XCTFail("the underlying status should still hold the release")
        }
    }

    @MainActor
    func testNewerReleaseOverridesASkip() async {
        let (checker, _) = makeChecker(feed: [releaseDictionary(tag: "v1.3.0")])
        await checker.check()
        checker.skip(try! XCTUnwrap(checker.availableUpdate))

        let (newer, _) = makeChecker(feed: [releaseDictionary(tag: "v1.4.0")])
        await newer.check()
        XCTAssertEqual(newer.availableUpdate?.version, AppVersion("1.4.0"))
    }

    @MainActor
    func testClearingSkipRestoresTheUpdate() async {
        let (checker, _) = makeChecker(feed: [releaseDictionary(tag: "v1.3.0")])
        await checker.check()
        checker.skip(try! XCTUnwrap(checker.availableUpdate))
        XCTAssertNil(checker.availableUpdate)

        checker.clearSkippedVersion()

        XCTAssertEqual(checker.availableUpdate?.version, AppVersion("1.3.0"))
        XCTAssertNil(defaults.string(forKey: UpdateChecker.skippedVersionDefaultsKey))
    }

    // MARK: Version resolution

    func testBundledVersionReadsTheShortVersionString() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BennettUsageVersionTest-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.ruanbw.bennett-usage.versiontest",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "9.9.9"
        ]
        try (plist as NSDictionary).write(to: bundleURL.appendingPathComponent("Info.plist"))

        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        XCTAssertEqual(UpdateChecker.bundledVersion(bundle: bundle), AppVersion("9.9.9"))
    }

    func testBundledVersionFallsBackToTheCompiledConstant() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BennettUsageVersionTest-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.ruanbw.bennett-usage.versiontest",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "not-a-version"
        ]
        try (plist as NSDictionary).write(to: bundleURL.appendingPathComponent("Info.plist"))

        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        XCTAssertEqual(UpdateChecker.bundledVersion(bundle: bundle), AppVersion(BennettUsageCore.version))
        XCTAssertNotEqual(UpdateChecker.bundledVersion(bundle: bundle), .unknown)
    }

    func testDefaultEndpointTargetsThePublicReleaseFeed() {
        XCTAssertEqual(UpdateChecker.defaultEndpoint.host, "api.github.com")
        XCTAssertEqual(UpdateChecker.defaultEndpoint.path, "/repos/ruanbw/bennett-usage/releases")
        XCTAssertEqual(UpdateChecker.defaultCheckInterval, 24 * 60 * 60)
    }
}

// MARK: - URLSession transport

final class URLSessionUpdateHTTPClientTests: XCTestCase {
    func testSendsGitHubHeadersAndMapsStatus() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let seen = LockedBox<URLRequest?>(nil)
        MockURLProtocol.handler = { request in
            seen.value = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data("[]".utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let client = URLSessionUpdateHTTPClient(session: session)
        let response = try await client.get(UpdateChecker.defaultEndpoint)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.data, Data("[]".utf8))
        XCTAssertEqual(seen.value?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(seen.value?.value(forHTTPHeaderField: "User-Agent"), "BennettUsage/\(BennettUsageCore.version)")
    }
}

// MARK: - View integration

final class UpdateSettingsViewTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "UpdateSettingsViewTests_\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    @MainActor
    private func makeChecker(feed: [[String: Any]] = [], statusCode: Int = 200, error: (any Error)? = nil) -> UpdateChecker {
        UpdateChecker(
            client: StubUpdateClient(statusCode: statusCode, body: feedData(feed), error: error),
            userDefaults: defaults,
            currentVersion: AppVersion("1.2.0")!
        )
    }

    /// Hosts a view so the body really runs — a `String(format:)` mismatch or a
    /// broken branch would otherwise never be exercised.
    @MainActor
    @discardableResult
    private func host(_ view: some View) -> NSHostingView<AnyView> {
        let root = AnyView(view.frame(width: 750, height: 510))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 750, height: 510)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    @MainActor
    func testAboutPaneRendersIdleState() {
        let localization = LocalizationManager(userDefaults: defaults)
        let view = SettingsContentView(
            localization: localization,
            updateChecker: makeChecker(),
            initialCategory: .about
        )
        XCTAssertNotNil(view.body)
        host(view)
    }

    @MainActor
    func testAboutPaneRendersUpToDateState() async {
        let localization = LocalizationManager(userDefaults: defaults)
        let checker = makeChecker(feed: [releaseDictionary(tag: "v1.2.0")])
        await checker.check()

        host(SettingsContentView(localization: localization, updateChecker: checker, initialCategory: .about))

        guard case .upToDate = checker.status else { return XCTFail("expected up to date") }
    }

    @MainActor
    func testAboutPaneRendersUpdateAvailableState() async {
        let localization = LocalizationManager(userDefaults: defaults)
        let checker = makeChecker(feed: [releaseDictionary(tag: "v1.3.0", name: "v1.3.0", assets: dmgAssets(version: "1.3.0"))])
        await checker.check()

        host(SettingsContentView(localization: localization, updateChecker: checker, initialCategory: .about))

        XCTAssertEqual(checker.availableUpdate?.version, AppVersion("1.3.0"))
    }

    @MainActor
    func testAboutPaneRendersSkippedAndFailedStates() async {
        let localization = LocalizationManager(userDefaults: defaults)

        let skipped = makeChecker(feed: [releaseDictionary(tag: "v1.3.0")])
        await skipped.check()
        skipped.skip(try! XCTUnwrap(skipped.availableUpdate))
        host(SettingsContentView(localization: localization, updateChecker: skipped, initialCategory: .about))

        let failed = makeChecker(error: URLError(.notConnectedToInternet))
        await failed.check()
        host(SettingsContentView(localization: localization, updateChecker: failed, initialCategory: .about))
        XCTAssertEqual(failed.status, .failed(.network))
    }

    @MainActor
    func testGeneralPaneRendersAutoCheckToggle() {
        let localization = LocalizationManager(userDefaults: defaults)
        let checker = makeChecker()
        host(SettingsContentView(localization: localization, updateChecker: checker, initialCategory: .general))

        checker.automaticallyChecksForUpdates = false
        XCTAssertFalse(defaults.bool(forKey: UpdateChecker.autoCheckDefaultsKey))
    }

    @MainActor
    func testPopoverRendersUpdateBanner() async {
        let localization = LocalizationManager(userDefaults: defaults)
        let checker = makeChecker(feed: [releaseDictionary(tag: "v1.3.0", name: "v1.3.0 — Update check")])
        await checker.check()

        let view = MenuBarPopoverView(
            model: StatusSummaryModel(summary: TodaySummary(
                totalTokens: 1_000,
                totalCostUSD: 0.5,
                toolTokens: ["claude": 1_000],
                toolCosts: ["claude": 0.5]
            )),
            localization: localization,
            updateChecker: checker,
            onOpenDashboard: {},
            onSyncNow: {},
            onQuit: {}
        )
        host(view)

        XCTAssertEqual(MenuBarPopoverView.activeTools(for: view.summary).count, 1)
    }

    @MainActor
    func testUpdateStringsFormatInBothLanguages() {
        let localization = LocalizationManager(userDefaults: defaults)

        localization.setLanguage(.en)
        let en = localization.localized(.updateAvailableTitle, arguments: "1.3.0")
        XCTAssertEqual(en, "v1.3.0 is now available")
        XCTAssertEqual(localization.localized(.updateCurrentVersion, arguments: "1.2.0"), "Version v1.2.0")
        XCTAssertEqual(localization.localized(.updateLastChecked, arguments: "just now"), "Last checked just now")
        XCTAssertEqual(localization.localized(.updateErrorServer, arguments: 403), "The update server returned HTTP 403.")

        localization.setLanguage(.zh)
        let zh = localization.localized(.updateAvailableTitle, arguments: "1.3.0")
        XCTAssertEqual(zh, "发现新版本 v1.3.0")
        XCTAssertEqual(localization.localized(.updateCurrentVersion, arguments: "1.2.0"), "当前版本 v1.2.0")
        XCTAssertEqual(localization.localized(.updateLastChecked, arguments: "刚刚"), "上次检查：刚刚")
        XCTAssertEqual(localization.localized(.updateErrorServer, arguments: 403), "更新服务器返回 HTTP 403。")
    }
}
