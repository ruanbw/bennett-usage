import Foundation

/// A dotted numeric version (`1.2.0`) with an optional SemVer pre-release
/// suffix (`1.3.0-beta.1`).
///
/// The update checker compares the running bundle's version against the tags
/// published on GitHub, so parsing is deliberately lenient: a leading `v`,
/// surrounding whitespace, a missing patch component (`1.2`) and `+build`
/// metadata are all accepted instead of failing the whole check on a
/// hand-written tag. Components are normalized to at least three, so
/// `AppVersion("1.2") == AppVersion("1.2.0")` holds as well as `<` ordering.
public struct AppVersion: Equatable, Hashable, Sendable, Comparable, CustomStringConvertible {
    /// Numeric components in order (`[1, 2, 0]`). Missing trailing components
    /// are padded with zeros, so `1.2` and `1.2.0` are the same version.
    public let components: [Int]
    /// Dot-separated pre-release identifiers (`["beta", "1"]`); empty for a
    /// final release. A pre-release always sorts below its final release.
    public let prerelease: [String]

    /// The lowest possible version, used when no bundle version can be read.
    public static let unknown = AppVersion(uncheckedComponents: [0, 0, 0], prerelease: [])

    /// Normalized display form: `1.2.0`, or `1.3.0-beta.1` for a pre-release.
    public var description: String {
        let core = components.map(String.init).joined(separator: ".")
        guard !prerelease.isEmpty else { return core }
        return core + "-" + prerelease.joined(separator: ".")
    }

    /// True when this version carries a SemVer pre-release suffix.
    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// Parses `string`, returning `nil` when it holds no usable version.
    public init?(_ string: String) {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        // Build metadata never participates in precedence (SemVer §10).
        if let plus = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[trimmed.startIndex..<plus])
        }
        guard !trimmed.isEmpty else { return nil }

        let core: Substring
        let prereleasePart: Substring?
        if let dash = trimmed.firstIndex(of: "-") {
            core = trimmed[trimmed.startIndex..<dash]
            prereleasePart = trimmed[trimmed.index(after: dash)...]
        } else {
            core = Substring(trimmed)
            prereleasePart = nil
        }

        var parsed: [Int] = []
        for part in core.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Int(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            parsed.append(value)
        }
        guard !parsed.isEmpty else { return nil }
        while parsed.count < 3 { parsed.append(0) }

        let identifiers = (prereleasePart ?? "")
            .split(separator: ".", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        self.components = parsed
        self.prerelease = identifiers
    }

    private init(uncheckedComponents: [Int], prerelease: [String]) {
        self.components = uncheckedComponents
        self.prerelease = prerelease
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        // Equal cores: the pre-release is the lower version.
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        return Self.prereleaseIsOrderedBefore(lhs.prerelease, rhs.prerelease)
    }

    /// SemVer §11 identifier precedence: numeric identifiers compare
    /// numerically and rank below alphanumeric ones; a shorter identifier list
    /// ranks below a longer one when every shared identifier is equal.
    private static func prereleaseIsOrderedBefore(_ lhs: [String], _ rhs: [String]) -> Bool {
        for index in 0..<min(lhs.count, rhs.count) {
            let left = lhs[index]
            let right = rhs[index]
            if left == right { continue }
            switch (Int(left), Int(right)) {
            case let (leftNumber?, rightNumber?):
                return leftNumber < rightNumber
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return left < right
            }
        }
        return lhs.count < rhs.count
    }
}
