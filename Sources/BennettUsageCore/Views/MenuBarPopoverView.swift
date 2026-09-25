import SwiftUI
import AppKit

/// Shared summary state for the menu bar popover: the popover's hosting
/// controller is built once and stays alive; publishing a new summary here
/// refreshes the view in place instead of rebuilding the whole hierarchy.
@MainActor
public final class StatusSummaryModel: ObservableObject {
    @Published public var summary: TodaySummary?
    /// Database read timestamp retained for callers that need to distinguish a
    /// cached read from a source sync. It is deliberately not used as proof of
    /// a successful source refresh, and deliberately not `@Published`: no view
    /// reads it, so publishing it invalidated the popover's SwiftUI view graph —
    /// and re-ran its layout — on every completed read, for a value nothing
    /// displays.
    public var lastRefreshedAt: Date?
    /// Source-sync facts published by StatusItemController. A database read can
    /// succeed while every source sync is stale or failed, so presentation code
    /// must use this model for success/failure messaging.
    @Published public var freshness: SyncFreshnessModel
    @Published public var trendPoints: [TrendPoint]?
    public init(
        summary: TodaySummary? = nil,
        lastRefreshedAt: Date? = nil,
        trendPoints: [TrendPoint]? = nil,
        freshness: SyncFreshnessModel = .unknown
    ) {
        self.summary = summary
        self.lastRefreshedAt = lastRefreshedAt
        self.trendPoints = trendPoints
        self.freshness = freshness
    }

    /// Yesterday's total, published by the status item controller alongside the
    /// trend. nil when the comparison is unavailable.
    @Published public var yesterdayTotal: Int?

    /// True when the last attempt to read the local database failed.
    ///
    /// A failed read leaves the previous snapshot on screen, and the sync
    /// freshness above it says nothing about the database: without this flag the
    /// popover kept a green "just updated" capsule over numbers it could no
    /// longer read. Published only on transition, so the view tree is not
    /// invalidated on every read.
    @Published public var dataReadFailed: Bool = false

    /// Cache-hit rate for the popover's ring, or nil when nothing was
    /// cacheable today.
    ///
    /// This used to be a hard-coded `0`, described as an honest “not measured
    /// here” — but a zero renders as a drawn empty ring with an amber warning
    /// dot, which claims “cache is failing”. `TodaySummary` now carries the
    /// rate from the rollups it already read, so the popover and the Dashboard
    /// state the same number for the same day.
    public var cacheHitRate: Double? { summary?.cacheHitRate }

    /// Whether the numbers on screen are current enough to act on.
    public var freshnessLevel: StateCapsule.Level {
        if freshness.isRefreshing { return .syncing }
        if freshness.partialFailure != nil { return .error }
        guard let completedAt = freshness.lastSuccessful?.completedAt else { return .stale }
        return Int(Date().timeIntervalSince(completedAt) / 60) < 60 ? .ok : .stale
    }

    /// Today's change against yesterday, or an honest "no comparison".
    ///
    /// The popover used to show yesterday's total as a bare second number with
    /// no reference period attached, which is a difference the reader has to
    /// guess at. This states the comparison instead of implying one.
    public var freshnessDeltaText: String {
        let localization = LocalizationManager.shared
        guard let yesterday = yesterdayTotal, yesterday > 0,
              let today = summary?.totalTokens, today > 0 else {
            return localization.localized(.noComparablePeriod)
        }
        let change = (Double(today) - Double(yesterday)) / Double(yesterday)
        let sign = change >= 0 ? "+" : ""
        return String(
            format: localization.localized(.vsPreviousPeriod),
            String(format: "%+.0f%%", change * 100)
        )
    }
}

public struct MenuBarPopoverView: View {
    @ObservedObject public var model: StatusSummaryModel
    @ObservedObject public var updateChecker: UpdateChecker
    @ObservedObject var pricingEngine: PricingEngine
    public let onOpenDashboard: () -> Void
    public let onSyncNow: () -> Void
    public let onQuit: () -> Void
    public let onOpenSettings: (() -> Void)?
    @ObservedObject public var localization: LocalizationManager
    @AppStorage(AppThemeMode.storageKey) private var themeMode: AppThemeMode = .dark

    public var summary: TodaySummary? { model.summary }

    public init(
        model: StatusSummaryModel,
        localization: LocalizationManager = .shared,
        updateChecker: UpdateChecker = .shared,
        onOpenDashboard: @escaping () -> Void,
        onSyncNow: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onOpenSettings: (() -> Void)? = nil,
        pricingEngine: PricingEngine = .shared
    ) {
        self.model = model
        self.localization = localization
        self.updateChecker = updateChecker
        self.pricingEngine = pricingEngine
        self.onOpenDashboard = onOpenDashboard
        self.onSyncNow = onSyncNow
        self.onQuit = onQuit
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        let active = Self.activeTools(for: summary)
        let toolColors = ChartPalette.shared.colors(for: active.map(\.id))

        // Three layers, and the count is the design. A popover that answers
        // "how much today, what did it cost, who spent it, and now do I do
        // anything" is really four surfaces competing inside 360pt, and the
        // layer that loses is always the one the user came for.
        return VStack(alignment: .leading, spacing: 0) {
            // ① Today's total, its change, and the cache ring.
            todayConclusion(active: active)

            InlineDivider()

            // ② Cost, source count, and how fresh the data is.
            glanceFacts(active: active)

            if let update = updateChecker.availableUpdate {
                InlineDivider()
                updateBanner(update)
                    .padding(.horizontal, DesignTokens.Metrics.windowPadding)
                    .padding(.vertical, DesignTokens.Metrics.modulePaddingTight)
            } else {
                updateStatusNotice
            }

            InlineDivider()

            // ③ The two heaviest sources. A full ranking here would push the
            // primary action below the fold on a menu bar panel.
            topSources(active: active, toolColors: toolColors)
                .padding(.horizontal, DesignTokens.Metrics.windowPadding)
                .padding(.vertical, DesignTokens.Metrics.modulePaddingTight)

            InlineDivider()
            actionBar
        }
        .frame(width: 360)
        .background(DesignTokens.Surfaces.elevated)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.localized(.quickGlance))
        .preferredColorScheme(themeMode.colorScheme)
    }

    /// ① Today at a glance: the total, the cache ring, and the trend that
    /// explains the total's shape.
    ///
    /// Spend is a value, not a health state. It used to render in the success
    /// green, which made a routine $0.18 read as a status light and competed
    /// with the freshness marker for the same hue.
    private func todayConclusion(active: [ActiveTool]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.modulePaddingTight) {
            RegionLabel(localization.localized(.todaysTokens))

            if let summary, summary.totalTokens > 0 {
                HStack(alignment: .center, spacing: DesignTokens.Metrics.modulePadding) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(TokenFormatter.formatCompact(summary.totalTokens))
                                .font(DesignTokens.TypeScale.popoverTotal)
                                .foregroundColor(DesignTokens.Ink.strong)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)
                                .contentTransition(.numericText())
                                .help(TokenFormatter.formatWithTooltip(summary.totalTokens).tooltip)
                            Text(localization.localized(.tokenUnit))
                                .font(DesignTokens.TypeScale.label)
                                .foregroundColor(DesignTokens.Ink.muted)
                        }
                        Text(model.freshnessDeltaText)
                            .font(DesignTokens.TypeScale.caption)
                            .foregroundColor(DesignTokens.Ink.muted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    // The one ratio that earns a shape. At 62pt it fits the
                    // 360pt width beside the total without pushing either
                    // reading into truncation.
                    CacheHitReadout(rate: model.cacheHitRate, diameter: 62)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(localization.localized(.popoverAccessibilityDescription))

                if let points = model.trendPoints,
                   points.contains(where: { $0.tokens > 0 }),
                   points.count > 1 {
                    glanceTrend(points: points)
                }
            } else {
                HStack(spacing: 9) {
                    Image(systemName: summary == nil ? "questionmark.circle" : "chart.bar")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(DesignTokens.Ink.muted)
                        .accessibilityHidden(true)
                    Text(summary == nil ? localization.localized(.noDataToDisplay) : localization.localized(.emptyUsage))
                        .font(DesignTokens.TypeScale.heading)
                        .foregroundColor(DesignTokens.Ink.strong)
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, DesignTokens.Metrics.windowPadding)
        .padding(.vertical, DesignTokens.Metrics.modulePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ② Two facts and one state. Each is a figure the reader would otherwise
    /// have to open the Dashboard for, and each says what period it covers.
    private func glanceFacts(active: [ActiveTool]) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Metrics.modulePadding) {
            // `Readout` expands by default, which suits a row of equal-weight
            // columns. Here it stole the state capsule's width instead, so the
            // pill every popover shows read "数据刚刚…".
            Readout(
                label: localization.localized(.estimatedCost),
                // A missing summary is "not measured yet", which is not the
                // same claim as "spent nothing": the block above already says
                // there is no data, so $0.00 here contradicted it.
                value: summary == nil ? "—" : pricingEngine.spendString(summary?.totalCostUSD ?? 0),
                valueFont: DesignTokens.TypeScale.value
            )
            .fixedSize(horizontal: true, vertical: false)
            InlineDivider(axis: .vertical).frame(height: 30)
            Readout(
                label: localization.localized(.popoverSourceCount),
                value: summary == nil ? "—" : String(active.count),
                valueFont: DesignTokens.TypeScale.value
            )
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            // The capsule states the state. It used to show the success
            // timestamp even while sources were failing, so a partial failure
            // read as "data updated just now".
            StateCapsule(model.freshnessLevel, text: freshnessText)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, DesignTokens.Metrics.windowPadding)
        .padding(.vertical, DesignTokens.Metrics.modulePaddingTight)
    }

    /// The popover hangs off a menu bar item that already names the app, so the
    /// header states the window's subject — today's usage — rather than
    /// repeating the product name, and carries the sync state inline. Freshness
    /// used to get its own tinted panel between the total and the breakdown,
    /// which cost a whole band to say one short thing.
    /// The popover hangs off a menu bar item that already names the app, so the
    /// header states the window's subject — today's usage — rather than
    /// repeating the product name, and carries the sync state inline. Freshness
    /// used to get its own tinted panel between the total and the breakdown,
    /// which cost a whole band to say one short thing.
    private var popoverHeader: some View {
        let detail = dataFreshnessText
        return HStack(spacing: 8) {
            RegionLabel(localization.localized(.todaysTokens))
            Spacer(minLength: 6)
            StateCapsule(model.freshnessLevel, text: detail)
            if let onOpenSettings = onOpenSettings {
                ToolbarIconButton(
                    systemImage: "gearshape",
                    help: localization.localized(.openSettingsAction),
                    action: onOpenSettings
                )
            }
        }
        .padding(.horizontal, DesignTokens.Metrics.windowPadding)
        .padding(.top, 13)
        .padding(.bottom, 9)
        .help(detail)
    }

    /// One primary action, three secondary icon rows.
    ///
    /// The previous bar had a prominent button, two bordered buttons beside it
    /// and a text button below — four controls, three of them for the same
    /// "leave this panel" intent, which is how a menu bar popover ends up
    /// looking like a toolbar. The icon row keeps all three actions reachable
    /// at 44pt while making the hierarchy honest: one thing is primary.
    private var actionBar: some View {
        VStack(spacing: DesignTokens.Metrics.moduleGap) {
            PrimaryAction(
                localization.localized(.openDashboardAction),
                systemImage: "macwindow",
                action: onOpenDashboard
            )
            .keyboardShortcut(.defaultAction)

            InlineDivider()

            HStack(spacing: 0) {
                secondaryAction(
                    systemImage: "arrow.triangle.2.circlepath",
                    label: localization.localized(.syncNow),
                    action: onSyncNow
                )
                InlineDivider(axis: .vertical).frame(height: 20)
                if let onOpenSettings = onOpenSettings {
                    secondaryAction(
                        systemImage: "gearshape",
                        label: localization.localized(.settings),
                        action: onOpenSettings
                    )
                }
                InlineDivider(axis: .vertical).frame(height: 20)
                secondaryAction(
                    systemImage: "power",
                    label: localization.localized(.quit),
                    action: onQuit
                )
            }
        }
        .padding(.horizontal, DesignTokens.Metrics.windowPadding)
        .padding(.vertical, DesignTokens.Metrics.modulePaddingTight)
    }

    /// A secondary action: an icon over a word, at the full 44pt row height so
    /// it clears the target floor without looking heavy.
    private func secondaryAction(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        SecondaryIconAction(systemImage: systemImage, label: label, action: action)
    }

    /// What the capsule says: the failure if there was one, otherwise how old
    /// the last successful sync is.
    ///
    /// The failure branch used only to color the dot red while the text kept
    /// promising "just updated" — the copy has to carry the state, because the
    /// color is never the only signal.
    private var freshnessText: String {
        if model.dataReadFailed {
            return localization.localized(.staleData)
        }
        if model.freshness.partialFailure != nil {
            return localization.localized(.syncFailed)
        }
        return dataFreshnessText
    }

    private var dataFreshnessText: String {
        guard let lastSuccessfulAt = model.freshness.lastSuccessful?.completedAt else {
            return localization.localized(.notSyncedYet)
        }
        let minutes = max(0, Int(Date().timeIntervalSince(lastSuccessfulAt) / 60))
        if minutes == 0 {
            return localization.localized(.dataUpdatedJustNow)
        }
        if minutes < 60 {
            return localization.localized(.dataUpdatedMinutesAgo, arguments: minutes)
        }
        let hours = minutes / 60
        if hours < 48 {
            return localization.localized(.syncedHoursAgo, arguments: hours)
        }
        // "Synced 43200 minutes ago" was the alternative, and it is not a
        // duration anyone reads.
        return localization.localized(.syncedDaysAgo, arguments: hours / 24)
    }

    /// A sparkline with a baseline and a named peak. Without them the mark
    /// floated in its own whitespace and gave no scale, so "is this a spike or
    /// a plateau" was unanswerable from the glance it was meant to support.
    private func glanceTrend(points: [TrendPoint]) -> some View {
        let total = points.reduce(0) { $0 + $1.tokens }
        let peak = points.max { $0.tokens < $1.tokens }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(localization.localized(.hourlyTrendToday))
                    .font(DesignTokens.TypeScale.caption)
                    .foregroundColor(DesignTokens.Ink.muted)
                Spacer(minLength: 6)
                if let peak, peak.tokens > 0 {
                    Text(localization.localized(.popoverPeakAt, arguments: peak.label))
                        .font(DesignTokens.TypeScale.caption)
                        .foregroundColor(DesignTokens.Ink.muted)
                        .lineLimit(1)
                }
                Text(TokenFormatter.formatCompact(peak?.tokens ?? 0))
                    .font(DesignTokens.TypeScale.numeric)
                    .foregroundColor(DesignTokens.Ink.muted)
            }

            SparkLine(points: points)
                .fill(DesignTokens.Ink.faint)
                .frame(height: 26)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(DesignTokens.Ink.track)
                        .frame(height: DesignTokens.Metrics.hairline)
                }
                .accessibilityLabel(localization.localized(.hourlyTrendToday))
                .accessibilityValue(
                    String(format: localization.localized(.tokenValue), TokenFormatter.formatFull(total))
                )
        }
    }

    /// ③ The two heaviest sources, as a definition list.
    ///
    /// A full ranking does not fit a glance without pushing the primary action
    /// down, and the third source is not what anyone opened a menu bar popover
    /// to find. The remaining sources are still counted in layer ②, so the
    /// reader knows the two rows are a top-two and not the whole picture.
    private func topSources(active: [ActiveTool], toolColors: [String: Color]) -> some View {
        let visibleTools = Array(active.prefix(2))
        let totalActive = active.reduce(0) { $0 + $1.tokens }

        return VStack(alignment: .leading, spacing: 8) {
            RegionLabel(localization.localized(.toolBreakdownToday))

            if visibleTools.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DesignTokens.Ink.muted)
                        .accessibilityHidden(true)
                    Text(localization.localized(.popoverNoUsage))
                        .font(DesignTokens.TypeScale.body)
                        .foregroundColor(DesignTokens.Ink.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else {
                // The same mark and the same neutral track as the Dashboard, so
                // the two surfaces read as one product rather than two bar
                // styles.
                ShareBar(
                    segments: active.map { tool in
                        ShareBar.Segment(
                            id: tool.id,
                            share: totalActive > 0 ? Double(tool.tokens) / Double(totalActive) : 0,
                            color: toolColors[tool.id]
                                ?? AppTheme.Agent.knownColor(for: tool.id)
                                ?? AppTheme.Harmonic.color(for: tool.id)
                        )
                    },
                    height: 6,
                    label: localization.localized(.toolBreakdownToday)
                )
                .accessibilityValue(
                    Self.distributionAccessibilityValue(for: active, localization: localization)
                )

                VStack(spacing: 0) {
                    ForEach(Array(visibleTools.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 {
                            InlineDivider(inset: 15)
                        }
                        HStack(spacing: 8) {
                            Circle()
                                .fill(
                                    toolColors[tool.id]
                                        ?? AppTheme.Agent.knownColor(for: tool.id)
                                        ?? AppTheme.Harmonic.color(for: tool.id)
                                )
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)

                            Text(AgentFilterBarView.displayName(for: tool.id))
                                .font(DesignTokens.TypeScale.label)
                                .foregroundColor(DesignTokens.Ink.strong)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            Text(TokenFormatter.formatCompact(tool.tokens))
                                .font(DesignTokens.TypeScale.numeric)
                                .foregroundColor(DesignTokens.Ink.muted)
                                .lineLimit(1)

                            Text(String(format: "%.1f%%", topShare(for: tool, in: active)))
                                .font(DesignTokens.TypeScale.numeric)
                                .foregroundColor(DesignTokens.Ink.muted)
                                // 13pt monospaced digits need ~7.8pt each, so
                                // "100.0%" wants 47pt. At 40 the fullest row in
                                // the list — the one every screenshot shows —
                                // rendered as "100…".
                                .frame(width: 50, alignment: .trailing)
                        }
                        .frame(height: 24)
                        .accessibilityElement(children: .combine)
                        .help(TokenFormatter.formatFull(tool.tokens))
                    }
                }

                if active.count > visibleTools.count {
                    Text(String(
                        format: localization.localized(.moreToolsCount),
                        active.count - visibleTools.count
                    ))
                    .font(DesignTokens.TypeScale.caption)
                    .foregroundColor(DesignTokens.Ink.ghost)
                    .padding(.top, 2)
                    .accessibilityLabel(
                        String(
                            format: localization.localized(.moreToolsCount),
                            active.count - visibleTools.count
                        )
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func topShare(for tool: ActiveTool, in active: [ActiveTool]) -> Double {
        let total = active.reduce(0) { $0 + $1.tokens }
        guard total > 0 else { return 0 }
        return Double(tool.tokens) / Double(total) * 100
    }

    // MARK: - Mini Distribution Bar

    private func miniDistributionBar(active: [ActiveTool], toolColors: [String: Color]) -> some View {
        let totalActive = active.reduce(0) { $0 + $1.tokens }
        let accessibilityValue = Self.distributionAccessibilityValue(
            for: active,
            localization: localization
        )
        return GeometryReader { proxy in
            let totalWidth = proxy.size.width
            if active.isEmpty || totalActive <= 0 {
                Capsule()
                    .fill(DesignTokens.Surfaces.inset)
                    .frame(height: 4)
            } else {
                let spacing: CGFloat = 1.5
                let totalSpacing = CGFloat(max(0, active.count - 1)) * spacing
                let availableWidth = max(0, totalWidth - totalSpacing)

                HStack(spacing: spacing) {
                    ForEach(active, id: \.id) { tool in
                        let fraction = CGFloat(tool.tokens) / CGFloat(totalActive)
                        let segWidth = max(2, availableWidth * fraction)
                        (toolColors[tool.id] ?? AppTheme.Agent.knownColor(for: tool.id) ?? AppTheme.Harmonic.color(for: tool.id))
                            .frame(width: segWidth, height: 4)
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localization.localized(.toolBreakdownToday))
        .accessibilityValue(accessibilityValue)
    }

    static func distributionAccessibilityValue(
        for active: [ActiveTool],
        localization: LocalizationManager
    ) -> String {
        let totalTokens = active.reduce(0) { $0 + $1.tokens }
        guard totalTokens > 0 else { return localization.localized(.noToolsActiveToday) }

        let tokenUnit = localization.localized(.tokenUnit)
        return active.map { tool in
            let name = AgentFilterBarView.displayName(for: tool.id)
            let share = Double(tool.tokens) / Double(totalTokens) * 100
            let shareText = localization.localized(.distributionShare, arguments: share)
            return "\(name), \(TokenFormatter.formatFull(tool.tokens)) \(tokenUnit), \(shareText)"
        }.joined(separator: ", ")
    }

    // MARK: - Update Banner

    @ViewBuilder
    private var updateStatusNotice: some View {
        switch updateChecker.status {
        case .checking:
            compactUpdateNotice(
                systemName: "arrow.triangle.2.circlepath",
                title: localization.localized(.checkingForUpdates),
                color: DesignTokens.Accent.base
            )
        case .failed:
            compactUpdateNotice(
                systemName: "exclamationmark.triangle.fill",
                title: localization.localized(.updateCheckFailed),
                color: DesignTokens.State.danger
            )
        default:
            EmptyView()
        }
    }

    private func compactUpdateNotice(systemName: String, title: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundColor(DesignTokens.Ink.strong)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color.opacity(0.10))
        )
        .accessibilityElement(children: .combine)
    }

    private func updateBanner(_ release: UpdateRelease) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(DesignTokens.Accent.base)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: localization.localized(.updateAvailableTitle), release.version.description))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(DesignTokens.Ink.strong)
                Text(release.title)
                    .font(.caption2)
                    .foregroundColor(DesignTokens.Ink.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(release.title)
            }
            Spacer()
            Button(localization.localized(.downloadUpdate)) {
                NSWorkspace.shared.open(release.preferredAsset()?.downloadURL ?? release.pageURL)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(localization.localized(.downloadUpdate))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DesignTokens.Accent.base.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DesignTokens.Accent.base.opacity(0.22), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }

    // MARK: - Active Tools

    /// Tools with activity today, sorted by tokens descending. Zero-token and
    /// unknown tools are omitted so the popover never shows unused rows.
    public struct ActiveTool: Sendable, Equatable {
        public let id: String
        public let tokens: Int
    }

    public static func activeTools(for summary: TodaySummary?) -> [ActiveTool] {
        guard let summary else { return [] }
        return summary.toolTokens
            .filter { $0.value > 0 }
            .map { ActiveTool(id: $0.key, tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens || ($0.tokens == $1.tokens && $0.id < $1.id) }
    }
}

private struct SparkLine: Shape {
    let points: [TrendPoint]

    func path(in rect: CGRect) -> Path {
        let values = points.map { CGFloat(max(0, $0.tokens)) }
        guard values.count > 1 else { return Path() }
        let maxValue = max(values.max() ?? 0, 1)
        let denominator = CGFloat(max(values.count - 1, 1))
        var path = Path()
        for (index, value) in values.enumerated() {
            let x = rect.minX + CGFloat(index) / denominator * rect.width
            let normalized = value / maxValue
            let y = rect.maxY - normalized * rect.height
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

// MARK: - Quiet Hover Controls

private struct QuietIconButton: View {
    let systemName: String
    let tooltip: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isHovered ? DesignTokens.Ink.strong : DesignTokens.Ink.muted)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? DesignTokens.Surfaces.hover : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}

private struct QuietTextButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(isHovered ? DesignTokens.Ink.strong : DesignTokens.Ink.muted)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered ? DesignTokens.Surfaces.hover : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

#Preview {
    MenuBarPopoverView(
        model: StatusSummaryModel(summary: TodaySummary(
            totalTokens: 1_254_300,
            totalCostUSD: 3.42,
            toolTokens: ["claude": 800_000, "gemini": 454_300],
            toolCosts: ["claude": 2.10, "gemini": 1.32]
        )),
        onOpenDashboard: {},
        onSyncNow: {},
        onQuit: {}
    )
}
