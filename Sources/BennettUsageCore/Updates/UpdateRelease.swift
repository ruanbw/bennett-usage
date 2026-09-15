import Foundation

/// One downloadable file attached to a release (the DMGs published by
/// `scripts/package-dmg.sh`).
public struct UpdateAsset: Equatable, Sendable {
    public let name: String
    public let downloadURL: URL?
    public let sizeBytes: Int

    public init(name: String, downloadURL: URL?, sizeBytes: Int) {
        self.name = name
        self.downloadURL = downloadURL
        self.sizeBytes = sizeBytes
    }
}

/// A published release, projected from the GitHub Releases API down to what
/// the app needs to decide “is this newer?” and to point the user at the right
/// download.
public struct UpdateRelease: Equatable, Sendable {
    public let version: AppVersion
    public let tagName: String
    public let title: String
    public let notes: String
    public let pageURL: URL
    public let publishedAt: Date?
    public let isPrerelease: Bool
    public let assets: [UpdateAsset]

    public init(
        version: AppVersion,
        tagName: String,
        title: String,
        notes: String,
        pageURL: URL,
        publishedAt: Date?,
        isPrerelease: Bool,
        assets: [UpdateAsset]
    ) {
        self.version = version
        self.tagName = tagName
        self.title = title
        self.notes = notes
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.assets = assets
    }

    /// Architecture of the running binary, matching the `-<arch>` suffix the
    /// packaging script puts on each DMG.
    public static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "universal"
        #endif
    }

    /// The DMG a user on `architecture` should get: the arch-specific build
    /// when the release has one, else the universal build, else any DMG. This
    /// keeps a universal app running under Rosetta on the Intel image instead
    /// of handing it the arm64 image it cannot mount.
    public func preferredAsset(for architecture: String = UpdateRelease.currentArchitecture) -> UpdateAsset? {
        let images = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        guard !images.isEmpty else { return nil }
        let wanted = architecture.lowercased()
        if let exact = images.first(where: { $0.name.lowercased().contains("-\(wanted).") || $0.name.lowercased().contains("-\(wanted)") }) {
            return exact
        }
        if let universal = images.first(where: { $0.name.lowercased().contains("universal") }) {
            return universal
        }
        return images.first
    }
}

/// Decodes the GitHub Releases REST payload (`GET /repos/:owner/:repo/releases`)
/// into `UpdateRelease` values.
///
/// Only fields the app actually renders are required: a release whose tag is
/// not a parseable version is dropped rather than failing the whole check, so
/// one hand-written odd tag cannot hide a real update.
public enum GitHubReleaseFeed {
    public static func releases(from data: Data) throws -> [UpdateRelease] {
        let payloads = try JSONDecoder().decode([Payload].self, from: data)
        return payloads.compactMap { $0.release }
    }

    struct Payload: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL
        let publishedAt: String?
        let prerelease: Bool
        let draft: Bool
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL?
            let size: Int?

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
                case size
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case prerelease
            case draft
            case assets
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try container.decode(String.self, forKey: .tagName)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            body = try container.decodeIfPresent(String.self, forKey: .body)
            htmlURL = try container.decode(URL.self, forKey: .htmlURL)
            publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
            prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
            draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
            assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        }

        var release: UpdateRelease? {
            guard !draft, let version = AppVersion(tagName) else { return nil }
            let displayTitle = (name?.isEmpty == false) ? name ?? tagName : tagName
            return UpdateRelease(
                version: version,
                tagName: tagName,
                title: displayTitle,
                notes: body ?? "",
                pageURL: htmlURL,
                publishedAt: Self.parseDate(publishedAt),
                isPrerelease: prerelease,
                assets: assets.map {
                    UpdateAsset(name: $0.name, downloadURL: $0.browserDownloadURL, sizeBytes: $0.size ?? 0)
                }
            )
        }

        /// GitHub emits `published_at` with second precision, but the feed is
        /// not guaranteed to stay fractional-second free, so both forms are
        /// accepted; an unparseable timestamp only costs the “published …”
        /// label, never the update itself.
        static func parseDate(_ raw: String?) -> Date? {
            guard let raw, !raw.isEmpty else { return nil }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: raw) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: raw)
        }
    }
}
