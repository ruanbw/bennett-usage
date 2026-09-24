import SwiftUI
import AppKit

/// Category navigation items in the macOS System Settings-style view.
public enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case general
    case agents
    case pricing
    case storage
    case about

    public var id: String { rawValue }

    public func title(localization: LocalizationManager) -> String {
        switch self {
        case .general:
            return localization.localized(.settingsNavGeneral)
        case .agents:
            return localization.localized(.settingsNavAgents)
        case .pricing:
            return localization.localized(.settingsNavPricing)
        case .storage:
            return localization.localized(.settingsNavStorage)
        case .about:
            return localization.localized(.settingsNavAbout)
        }
    }

    public func fullTitle(localization: LocalizationManager) -> String {
        switch self {
        case .general:
            return localization.localized(.generalSettings)
        case .agents:
            return localization.localized(.agentHealthSection)
        case .pricing:
            return localization.localized(.pricingSection)
        case .storage:
            return localization.localized(.storageSection)
        case .about:
            return localization.localized(.about)
        }
    }

    public func subtitle(localization: LocalizationManager) -> String {
        switch self {
        case .general:
            return localization.localized(.settingsGeneralSubtitle)
        case .agents:
            return localization.localized(.settingsAgentsSubtitle)
        case .pricing:
            return localization.localized(.settingsPricingSubtitle)
        case .storage:
            return localization.localized(.settingsStorageSubtitle)
        case .about:
            return localization.localized(.settingsAboutSubtitle)
        }
    }

    public var systemImage: String {
        switch self {
        case .general:
            return "slider.horizontal.3"
        case .agents:
            return "bolt.shield.fill"
        case .pricing:
            return "dollarsign"
        case .storage:
            return "internaldrive.fill"
        case .about:
            return "info"
        }
    }

    public var iconColor: Color {
        switch self {
        case .general:
            return AppTheme.Status.accent
        case .agents:
            return AppTheme.Status.success
        case .pricing:
            return AppTheme.Status.warning
        case .storage:
            return AppTheme.Agent.copilot
        case .about:
            return AppTheme.Text.secondary
        }
    }
}

public struct SettingsContentView: View {
    private enum MaintenanceFeedback: Equatable {
        case succeeded
        case failed
    }

    public let aggregator: MetricsAggregator?
    @ObservedObject public var localization: LocalizationManager
    @ObservedObject public var updateChecker: UpdateChecker
    public let onDismiss: (() -> Void)?

    /// The packaged app icon, available when running from a real .app bundle.
    /// Nil under `swift run` and in tests, where the hero card falls back to the
    /// drawn gradient tile.
    @MainActor private static let bundledAppIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    @State private var selectedCategory: SettingsCategory
    @State private var agentHealthInfos: [AgentHealthInfo] = []
    @State private var isSyncing: Bool = false
    @State private var exchangeRateText: String = ""
    @State private var exchangeRateError = false
    @State private var selectedCurrency: PreferredCurrency = .usd
    @State private var autoRefreshSeconds: Int
    @AppStorage(AppThemeMode.storageKey)
    private var themeModeRaw: String = AppThemeMode.dark.rawValue
    @State private var isShowingClearAlert: Bool = false
    @State private var isRebuilding = false
    @State private var isClearingRecords = false
    @State private var maintenanceFeedback: MaintenanceFeedback?
    @State private var storageStatusText: String = ""
    @State private var storageIsLoading = true
    @State private var storageIsUnavailable = false
    @State private var preferenceFeedbackVisible = false
    @State private var agentHealthLoadFailed = false

    public init(
        aggregator: MetricsAggregator? = nil,
        localization: LocalizationManager = .shared,
        updateChecker: UpdateChecker = .shared,
        initialCategory: SettingsCategory = .general,
        onDismiss: (() -> Void)? = nil
    ) {
        self.aggregator = aggregator
        self.localization = localization
        self.updateChecker = updateChecker
        self.onDismiss = onDismiss
        self._autoRefreshSeconds = State(
            initialValue: UserDefaults.standard.integer(forKey: "bennett_auto_refresh_seconds")
        )
        self._selectedCategory = State(initialValue: initialCategory)
    }

    private var resolvedDbPath: String {
        if let dbPath = aggregator?.databasePath, !dbPath.isEmpty {
            return dbPath
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return appSupport?.appendingPathComponent("BennettUsage/usage.db").path ?? "~/Library/Application Support/BennettUsage/usage.db"
    }

    private var connectedAgentCount: Int {
        agentHealthInfos.filter(\.isInstalled).count
    }

    private var isAnyAgentConnected: Bool {
        connectedAgentCount > 0
    }

    private var autoRefreshSubtitle: String {
        if autoRefreshSeconds == 0 {
            return localization.localized(.autoRefreshOff)
        } else {
            return String(format: localization.localized(.autoRefreshSeconds), autoRefreshSeconds)
        }
    }

    private var themeModeBinding: Binding<AppThemeMode> {
        Binding(
            get: { Self.resolvedThemeMode(rawValue: themeModeRaw) },
            set: { themeModeRaw = $0.rawValue }
        )
    }

    static func resolvedThemeMode(rawValue: String?) -> AppThemeMode {
        guard let rawValue else { return .dark }
        return AppThemeMode(rawValue: rawValue) ?? .dark
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebarView
                .frame(width: 176)

            AppTheme.Border.divider
                .frame(width: AppTheme.Layout.hairline)

            detailColumn
        }
        .frame(minWidth: 750, idealWidth: 750, minHeight: 510, idealHeight: 510)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Canvas.background)
        .alert(localization.localized(.clearRecordsConfirmTitle), isPresented: $isShowingClearAlert) {
            Button(localization.localized(.clearAllRecords), role: .destructive) {
                clearLocalUsageCache()
            }
            Button(localization.localized(.cancel), role: .cancel) {}
        } message: {
            Text(localization.localized(.clearRecordsConfirmMessage))
        }
        .onAppear {
            selectedCurrency = PricingEngine.shared.preferredCurrency
            exchangeRateText = String(format: "%.2f", PricingEngine.shared.usdToCnyRate)
            preferenceFeedbackVisible = false
            Task {
                await rescanAgents()
                await updateStorageStatus()
            }
        }
        .onChange(of: autoRefreshSeconds) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "bennett_auto_refresh_seconds")
            showPreferenceFeedback()
        }
        .onChange(of: themeModeRaw) { _, newValue in
            AppThemeMode(rawValue: newValue)?.apply(to: .shared)
            showPreferenceFeedback()
        }
        .onChange(of: selectedCategory) { _, _ in
            preferenceFeedbackVisible = false
        }
        .task(id: preferenceFeedbackVisible) {
            guard preferenceFeedbackVisible else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            preferenceFeedbackVisible = false
        }
        .onExitCommand {
            // Keep the original callback/API for callers, while leaving window
            // chrome to the native title bar (there is no duplicate close button).
            onDismiss?()
        }
    }

    // MARK: - Sidebar View
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AppTheme.Status.accent.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.Status.accent)
                }
                Text(localization.localized(.settings))
                    .font(.headline.weight(.semibold))
                    .foregroundColor(AppTheme.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 12)
            .padding(.top, 15)
            .padding(.bottom, 9)

            VStack(spacing: 2) {
                ForEach(SettingsCategory.allCases) { category in
                    categoryRow(category)
                }
            }
            .padding(.horizontal, 7)

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Circle()
                    .fill(isAnyAgentConnected ? AppTheme.Status.success : AppTheme.Text.quaternary)
                    .frame(width: 7, height: 7)
                Text(String(format: localization.localized(.agentsConnected), connectedAgentCount))
                    .font(.caption2)
                    .foregroundColor(AppTheme.Text.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(AppTheme.Surface.primary.opacity(0.5))
            .overlay(alignment: .top) {
                AppTheme.Border.divider.frame(height: AppTheme.Layout.hairline)
            }
        }
        .background(AppTheme.Surface.subtle.opacity(0.56))
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            detailHeaderView

            AppTheme.Border.divider
                .frame(height: AppTheme.Layout.hairline)

            ScrollView(.vertical, showsIndicators: true) {
                detailContentView
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
            }

            AppTheme.Border.divider
                .frame(height: AppTheme.Layout.hairline)

            privacyFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Canvas.background)
    }

    private var privacyFooter: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppTheme.Status.success)
            Text(localization.localized(.privacyFooter))
                .font(.caption2)
                .foregroundColor(AppTheme.Text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
            Spacer(minLength: 8)
            Text(localization.localized(.privacyLocalOnly))
                .font(.caption2)
                .foregroundColor(AppTheme.Text.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .padding(.horizontal, 20)
        .frame(height: 30)
        .background(AppTheme.Surface.subtle.opacity(0.5))
        .accessibilityElement(children: .combine)
    }

    private func categoryRow(_ category: SettingsCategory) -> some View {
        let isSelected = selectedCategory == category
        return CategoryRowButton(
            category: category,
            isSelected: isSelected,
            localization: localization
        ) {
            selectedCategory = category
        }
    }

    // MARK: - Detail Header View
    private var detailHeaderView: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedCategory.iconColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: selectedCategory.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(selectedCategory.iconColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedCategory.fullTitle(localization: localization))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppTheme.Text.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(selectedCategory.subtitle(localization: localization))
                    .font(.caption)
                    .foregroundColor(AppTheme.Text.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            detailStatusView
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 64)
        .background(AppTheme.Canvas.background)
    }

    private var detailStatusView: some View {
        let status = detailStatus
        return Label(status.text, systemImage: status.systemImage)
            .font(.caption.weight(.medium))
            .foregroundColor(status.color)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(status.color.opacity(0.10), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(status.text)
    }

    private var detailStatus: (text: String, systemImage: String, color: Color) {
        switch selectedCategory {
        case .general:
            return (autoRefreshSubtitle, "arrow.clockwise", AppTheme.Status.accent)
        case .agents:
            return (
                String(format: localization.localized(.agentsConnected), connectedAgentCount),
                isAnyAgentConnected ? "checkmark.circle.fill" : "circle.dashed",
                isAnyAgentConnected ? AppTheme.Status.success : AppTheme.Text.secondary
            )
        case .pricing:
            return (
                selectedCurrency == .usd ? localization.localized(.usdOption) : localization.localized(.cnyOption),
                "coloncurrencysign.circle.fill",
                AppTheme.Status.warning
            )
        case .storage:
            return (storageStatusDisplayText, storageStatusIcon, storageStatusColor)
        case .about:
            return (
                String(format: localization.localized(.versionLabel), updateChecker.currentVersion.description),
                "checkmark.seal.fill",
                AppTheme.Status.accent
            )
        }
    }

    // MARK: - Detail Content Switcher
    @ViewBuilder
    private var detailContentView: some View {
        switch selectedCategory {
        case .general:
            generalPane
        case .agents:
            agentsPane
        case .pricing:
            pricingPane
        case .storage:
            storagePane
        case .about:
            aboutPane
        }
    }

    // MARK: - Section 1: General Settings Pane
    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsSection(
                title: localization.localized(.generalSettings),
                subtitle: localization.localized(.settingsGeneralSubtitle),
                systemImage: "slider.horizontal.3"
            ) {
                settingsCard {
                    generalLanguageRow
                    rowDivider
                    generalAppearanceRow
                    rowDivider
                    generalAutoRefreshRow
                }
            }

            if preferenceFeedbackVisible {
                preferenceFeedbackView
            }

            settingsSection(
                title: localization.localized(.checkForUpdates),
                subtitle: localization.localized(.autoCheckUpdatesSubtitle),
                systemImage: "arrow.down.circle"
            ) {
                settingsCard {
                    generalUpdateRow
                    rowDivider
                    generalUpdateStatusRow
                }
            }

            settingsSection(
                title: localization.localized(.privacy),
                subtitle: localization.localized(.privacyNoUpload),
                systemImage: "lock.shield.fill"
            ) {
                settingsCard {
                    generalDatabaseRow
                    rowDivider
                    generalPrivacyRow
                }
            }
        }
    }

    private var generalLanguageRow: some View {
        HStack(spacing: 12) {
            cardRowIcon("globe", color: AppTheme.Status.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.localized(.language))
                    .font(.body.weight(.medium))
                    .foregroundColor(AppTheme.Text.primary)
                Text(displayName(for: localization.selectedLanguage))
                    .font(.caption)
                    .foregroundColor(AppTheme.Text.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            trailingMenuPicker(
                displayName(for: localization.selectedLanguage),
                accessibilityLabel: localization.localized(.language),
                options: localization.availableLanguages.map(displayName(for:))
            ) { index in
                let languages = localization.availableLanguages
                guard languages.indices.contains(index) else { return }
                localization.setLanguage(languages[index])
                showPreferenceFeedback()
            }
        }
        .frame(minHeight: 48)
    }

    private var generalAppearanceRow: some View {
        HStack(spacing: 12) {
            cardRowIcon("circle.lefthalf.filled", color: AppTheme.Agent.claude)
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.localized(.appearance))
                    .font(.body.weight(.medium))
                    .foregroundColor(AppTheme.Text.primary)
                Text(Self.resolvedThemeMode(rawValue: themeModeRaw).localizedTitle(localization: localization))
                    .font(.caption)
                    .foregroundColor(AppTheme.Text.secondary)
            }
            Spacer(minLength: 12)
            Picker(localization.localized(.appearance), selection: themeModeBinding) {
                ForEach(AppThemeMode.allCases) { mode in
                    Text(mode.localizedTitle(localization: localization)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .controlSize(.small)
            .accessibilityIdentifier(Self.themePickerID)
        }
        .frame(minHeight: 48)
    }

    private var generalAutoRefreshRow: some View {
        HStack(spacing: 12) {
            cardRowIcon("arrow.clockwise", color: AppTheme.Agent.trae)
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.localized(.autoRefreshLabel))
                    .font(.body.weight(.medium))
                    .foregroundColor(AppTheme.Text.primary)
                Text(autoRefreshSubtitle)
                    .font(.caption)
                    .foregroundColor(AppTheme.Text.secondary)
            }
            Spacer(minLength: 12)
            trailingMenuPicker(
                autoRefreshSubtitle,
                accessibilityLabel: localization.localized(.autoRefreshLabel),
                options: [
                    localization.localized(.autoRefreshOff),
                    String(format: localization.localized(.autoRefreshSeconds), 10),
                    String(format: localization.localized(.autoRefreshSeconds), 30),
                    String(format: localization.localized(.autoRefreshSeconds), 60)
                ]
            ) { index in
                autoRefreshSeconds = [0, 10, 30, 60][index]
                showPreferenceFeedback()
            }
        }
        .frame(minHeight: 48)
    }

    private var generalUpdateRow: some View {
        HStack(spacing: 12) {
            cardRowIcon("arrow.down.circle", color: AppTheme.Status.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.localized(.autoCheckUpdatesLabel))
                    .font(.body.weight(.medium))
                    .foregroundColor(AppTheme.Text.primary)
                Text(localization.localized(.autoCheckUpdatesSubtitle))
                    .font(.caption)
                    .foregroundColor(AppTheme.Text.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $updateChecker.automaticallyChecksForUpdates)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier(Self.autoCheckToggleID)
                .onChange(of: updateChecker.automaticallyChecksForUpdates) { _, _ in
                    showPreferenceFeedback()
                }
        }
        .frame(minHeight: 52)
    }

    private var generalUpdateStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: updateChecker.isChecking ? "arrow.triangle.2.circlepath" : updateStatusIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(updateStatusColor)
            Text(updateStatusDetail)
                .font(.caption)
                .foregroundColor(AppTheme.Text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Spacer(minLength: 8)
            Button(action: checkForUpdatesNow) {
                if updateChecker.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Text(localization.localized(.checkForUpdates))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(updateChecker.isChecking)
            .accessibilityIdentifier(Self.checkNowButtonID)
        }
        .frame(minHeight: 34)
    }

    private var generalDatabaseRow: some View {
        HStack(spacing: 12) {
            cardRowIcon("cylinder.split.1x2", color: AppTheme.Agent.copilot)
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.localized(.sqliteDatabase))
                    .font(.body.weight(.medium))
                    .foregroundColor(AppTheme.Text.primary)
                Text(storageStatusDisplayText)
                    .font(.caption)
                    .foregroundColor(storageStatusColor)
                    .lineLimit(1)
                Text(resolvedDbPath)
                    .font(.caption2.monospaced())
                    .foregroundColor(AppTheme.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: revealDatabaseInFinder) {
                Image(systemName: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(localization.localized(.revealInFinder))
            .accessibilityLabel(localization.localized(.revealInFinder))
        }
        .frame(minHeight: 52)
    }

    private var generalPrivacyRow: some View {
        HStack(alignment: .top, spacing: 12) {
            cardRowIcon("lock.shield.fill", color: AppTheme.Status.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.localized(.localFirstPrivate))
                    .font(.body.weight(.medium))
                    .foregroundColor(AppTheme.Text.primary)
                Text(localization.localized(.privacyDescription))
                    .font(.caption)
                    .foregroundColor(AppTheme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Section 2: Agent Health & Diagnostics Pane
    private var agentsPane: some View {
        settingsSection(
            title: localization.localized(.agentHealthSection),
            subtitle: localization.localized(.settingsAgentsSubtitle),
            systemImage: "bolt.shield.fill"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(
                        String(format: localization.localized(.agentsConnected), connectedAgentCount),
                        systemImage: isAnyAgentConnected ? "checkmark.circle.fill" : "circle.dashed"
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(isAnyAgentConnected ? AppTheme.Status.success : AppTheme.Text.secondary)
                    Spacer()
                    Button(action: {
                        Task { await rescanAgents() }
                    }) {
                        HStack(spacing: 6) {
                            if isSyncing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(localization.localized(.rescanNow))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSyncing)
                }

                if agentHealthLoadFailed {
                    Label(localization.localized(.dataUnavailable), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundColor(AppTheme.Status.warning)
                }

                settingsCard {
                    if agentHealthInfos.isEmpty {
                        HStack(spacing: 8) {
                            Spacer()
                            if isSyncing {
                                ProgressView().controlSize(.small)
                                Text(localization.localized(.loadingUsage))
                            } else {
                                Image(systemName: agentHealthLoadFailed ? "exclamationmark.triangle.fill" : "circle.dashed")
                                    .foregroundColor(agentHealthLoadFailed ? AppTheme.Status.warning : AppTheme.Text.secondary)
                                if agentHealthLoadFailed {
                                    Text(localization.localized(.dataUnavailable))
                                } else {
                                    Text(String(format: localization.localized(.agentsConnected), 0))
                                }
                            }
                            Spacer()
                        }
                        .font(.subheadline)
                        .foregroundColor(AppTheme.Text.secondary)
                        .padding(.vertical, 18)
                    } else {
                        ForEach(agentHealthInfos) { info in
                            agentHealthRow(info)
                            if info.id != agentHealthInfos.last?.id {
                                rowDivider
                            }
                        }
                    }
                }
            }
        }
    }

    static func agentRecordsText(for info: AgentHealthInfo, localization: LocalizationManager) -> String {
        String(format: localization.localized(.agentRecords), info.recordCount)
    }

    private func agentHealthRow(_ info: AgentHealthInfo) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(info.isInstalled ? AppTheme.Status.success.opacity(0.14) : AppTheme.Text.secondary.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: info.isInstalled ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(info.isInstalled ? AppTheme.Status.success : AppTheme.Text.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(info.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundColor(AppTheme.Text.primary)
                    if info.isInstalled {
                        Text(localization.localized(.agentActive))
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(AppTheme.Status.success.opacity(0.15))
                            .foregroundColor(AppTheme.Status.success)
                            .cornerRadius(4)
                    } else {
                        Text(localization.localized(.agentNotFound))
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(AppTheme.Surface.subtle)
                            .foregroundColor(AppTheme.Text.secondary)
                            .cornerRadius(4)
                    }
                }

                Text(info.defaultPath)
                    .font(.caption.monospaced())
                    .foregroundColor(AppTheme.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(info.defaultPath)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(Self.agentRecordsText(for: info, localization: localization))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundColor(AppTheme.Text.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppTheme.Surface.subtle)
                    .cornerRadius(6)

                if let lastTimestamp = info.lastRecordTimestamp {
                    Text(relativeTimestamp(lastTimestamp))
                        .font(.caption2)
                        .foregroundColor(AppTheme.Text.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Section 3: Pricing & Currency Pane
    private var pricingPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Preferred Currency Card
            settingsCard {
                HStack(spacing: 12) {
                    cardRowIcon("coloncurrencysign.circle.fill", color: AppTheme.Status.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localization.localized(.preferredCurrencyLabel))
                            .font(.body.weight(.medium))
                            .foregroundColor(AppTheme.Text.primary)
                        Text(localization.localized(.currencySummary))
                            .font(.caption)
                            .foregroundColor(AppTheme.Text.secondary)
                    }
                    Spacer()
                    Picker("", selection: $selectedCurrency) {
                        Text(localization.localized(.usdOption)).tag(PreferredCurrency.usd)
                        Text(localization.localized(.cnyOption)).tag(PreferredCurrency.cny)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                    .onChange(of: selectedCurrency) { _, newCurrency in
                        PricingEngine.shared.setPreferredCurrency(newCurrency)
                        showPreferenceFeedback()
                    }
                }
                .padding(.vertical, 4)
            }

            // Exchange Rate Card
            settingsCard {
                HStack(spacing: 12) {
                    cardRowIcon("chart.line.uptrend.xyaxis", color: AppTheme.Status.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localization.localized(.exchangeRateLabel))
                            .font(.body.weight(.medium))
                            .foregroundColor(AppTheme.Text.primary)
                        Text(String(format: localization.localized(.exchangeRateSummary), exchangeRateText))
                            .font(.caption)
                            .foregroundColor(AppTheme.Text.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Text(localization.localized(.exchangeRatePrefix))
                            .font(.callout)
                            .foregroundColor(AppTheme.Text.secondary)
                        TextField(localization.localized(.exchangeRatePlaceholder), text: $exchangeRateText)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(width: 62)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: exchangeRateText) { _, _ in
                                exchangeRateError = false
                            }
                            .onSubmit {
                                saveExchangeRate()
                            }
                        Text(localization.localized(.currencyCNY))
                            .font(.callout)
                            .foregroundColor(AppTheme.Text.secondary)
                        Button(localization.localized(.done)) {
                            saveExchangeRate()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }

            if exchangeRateError {
                Label(localization.localized(.invalidExchangeRate), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundColor(AppTheme.Status.warning)
            }

            if preferenceFeedbackVisible {
                preferenceFeedbackView
            }
        }
    }

    // MARK: - Section 4: Storage & Maintenance Pane
    private var storagePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Database Info Card
            settingsCard {
                HStack(alignment: .top, spacing: 12) {
                    cardRowIcon("cylinder.split.1x2", color: AppTheme.Agent.copilot)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localization.localized(.sqliteDatabase))
                            .font(.body.weight(.semibold))
                            .foregroundColor(AppTheme.Text.primary)
                        Text(resolvedDbPath)
                            .font(.caption.monospaced())
                            .foregroundColor(AppTheme.Text.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(resolvedDbPath)

                        Text(storageStatusDisplayText)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(storageStatusColor)
                            .padding(.top, 2)
                    }
                    Spacer()
                    Button(action: revealDatabaseInFinder) {
                        Label(localization.localized(.revealInFinder), systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                }
                .padding(.vertical, 4)
            }

            // Maintenance Actions Card
            settingsCard {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localization.localized(.rebuildRollups))
                                .font(.body.weight(.medium))
                                .foregroundColor(AppTheme.Text.primary)
                            Text(localization.localized(.rebuildRollupsDescription))
                                .font(.caption)
                                .foregroundColor(AppTheme.Text.secondary)
                        }
                        Spacer()
                        Button(action: rebuildAggregates) {
                            Label(
                                localization.localized(.rebuildRollups),
                                systemImage: isRebuilding ? "hourglass" : "arrow.triangle.2.circlepath"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isPerformingMaintenance)
                        .accessibilityIdentifier(Self.rebuildButtonID)
                    }

                    rowDivider

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localization.localized(.clearAllRecords))
                                .font(.body.weight(.medium))
                                .foregroundColor(AppTheme.Status.error)
                            Text(localization.localized(.clearRecordsDescription))
                                .font(.caption)
                                .foregroundColor(AppTheme.Text.secondary)
                        }
                        Spacer()
                        Button(role: .destructive, action: {
                            isShowingClearAlert = true
                        }) {
                            Label(
                                localization.localized(.clearAllRecords),
                                systemImage: isClearingRecords ? "hourglass" : "trash"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundColor(AppTheme.Status.error)
                        .disabled(isPerformingMaintenance)
                        .accessibilityIdentifier(Self.clearCacheButtonID)
                    }

                    if let maintenanceFeedback {
                        maintenanceFeedbackView(maintenanceFeedback)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Section 5: About Pane

    /// The packaged app icon, or the gradient tile it replaced when the bundle
    /// carries no icon (a `swift run` build, or the test host).
    @ViewBuilder
    private var appIconTile: some View {
        if let icon = Self.bundledAppIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.Status.accent, AppTheme.Status.accent.opacity(0.68)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
    }

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            updateCard

            // Hero Card
            settingsCard {
                HStack(spacing: 16) {
                    appIconTile

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(localization.localized(.appName))
                                .font(.title3.bold())
                                .foregroundColor(AppTheme.Text.primary)
                            Text(String(format: localization.localized(.versionLabel), updateChecker.currentVersion.description))
                                .font(.subheadline)
                                .foregroundColor(AppTheme.Text.secondary)
                        }
                        Text(localization.localized(.aboutDescription))
                            .font(.caption)
                            .foregroundColor(AppTheme.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            // Privacy Card
            settingsCard {
                HStack(alignment: .top, spacing: 14) {
                    cardRowIcon("lock.shield.fill", color: AppTheme.Status.success)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localization.localized(.localFirstPrivate))
                            .font(.body.weight(.semibold))
                            .foregroundColor(AppTheme.Text.primary)
                        Text(localization.localized(.privacyDescription))
                            .font(.caption)
                            .foregroundColor(AppTheme.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            // Repository Link Card
            settingsCard {
                HStack {
                    cardRowIcon("chevron.left.forwardslash.chevron.right", color: AppTheme.Text.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localization.localized(.openSource))
                            .font(.body.weight(.medium))
                            .foregroundColor(AppTheme.Text.primary)
                        Text("github.com/ruanbw/bennett-usage")
                            .font(.caption)
                            .foregroundColor(AppTheme.Text.secondary)
                    }
                    Spacer()
                    if let githubURL = URL(string: "https://github.com/ruanbw/bennett-usage") {
                        Link(destination: githubURL) {
                            HStack(spacing: 4) {
                                Text(localization.localized(.github))
                                Image(systemName: "arrow.up.right.square")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Update Check Card

    /// Stable identifiers so the settings tests can reach the new controls.
    static let themePickerID = "settings.general.themePicker"
    static let autoCheckToggleID = "settings.update.autoCheck"
    static let checkNowButtonID = "settings.update.checkNow"
    static let downloadUpdateButtonID = "settings.update.download"
    static let rebuildButtonID = "settings.maintenance.rebuild"
    static let clearCacheButtonID = "settings.maintenance.clearCache"

    private var updateCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    cardRowIcon("arrow.down.circle", color: AppTheme.Status.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localization.localized(.checkForUpdates))
                            .font(.body.weight(.medium))
                            .foregroundColor(AppTheme.Text.primary)
                        Text(updateStatusDetail)
                            .font(.caption)
                            .foregroundColor(AppTheme.Text.secondary)
                    }
                    Spacer()
                    Button(action: checkForUpdatesNow) {
                        HStack(spacing: 6) {
                            if updateChecker.isChecking {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(localization.localized(updateChecker.isChecking ? .checkingForUpdates : .checkForUpdates))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(updateChecker.isChecking)
                    .accessibilityIdentifier(Self.checkNowButtonID)
                }
                .padding(.vertical, 4)

                if let release = updateChecker.availableUpdate {
                    rowDivider
                    availableUpdateRow(release)
                } else if let skipped = skippedPendingVersion {
                    rowDivider
                    skippedUpdateRow(skipped)
                } else if case .upToDate = updateChecker.status {
                    rowDivider
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.Status.success)
                        Text(localization.localized(.updateUpToDate))
                            .font(.caption)
                            .foregroundColor(AppTheme.Text.secondary)
                        Spacer()
                    }
                }

                if case .failed(let failure) = updateChecker.status {
                    rowDivider
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.Status.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localization.localized(.updateCheckFailed))
                                .font(.caption.weight(.medium))
                                .foregroundColor(AppTheme.Text.primary)
                            Text(failureDescription(failure))
                                .font(.caption)
                                .foregroundColor(AppTheme.Text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    /// “Version v1.2.0 · Last checked 3 minutes ago”.
    private var updateStatusDetail: String {
        let checkedText: String
        if let lastCheckAt = updateChecker.lastCheckAt {
            checkedText = String(format: localization.localized(.updateLastChecked), relativeTimestamp(lastCheckAt))
        } else {
            checkedText = localization.localized(.updateNeverChecked)
        }
        let versionText = String(
            format: localization.localized(.updateCurrentVersion),
            updateChecker.currentVersion.description
        )
        return "\(versionText) · \(checkedText)"
    }

    /// The version the user skipped — only while it is still the release on
    /// offer, so the row disappears once a newer version shows up.
    private var skippedPendingVersion: AppVersion? {
        guard case .updateAvailable = updateChecker.status, updateChecker.availableUpdate == nil else { return nil }
        return updateChecker.skippedVersion
    }

    private func availableUpdateRow(_ release: UpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: localization.localized(.updateAvailableTitle), release.version.description))
                .font(.subheadline.weight(.semibold))
            Text(String(format: localization.localized(.updateAvailableMessage), updateChecker.currentVersion.description))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: { download(release) }) {
                    Label(localization.localized(.downloadUpdate), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(Self.downloadUpdateButtonID)

                Button(localization.localized(.viewReleaseNotes)) {
                    NSWorkspace.shared.open(release.pageURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(localization.localized(.skipThisVersion)) {
                    updateChecker.skip(release)
                }
                .buttonStyle(.link)
                .controlSize(.small)

                Spacer()
            }
        }
    }

    private func skippedUpdateRow(_ version: AppVersion) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.slash")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(String(format: localization.localized(.updateSkippedNote), version.description))
                .font(.caption)
                .foregroundColor(.secondary)
            Button(localization.localized(.updateRestoreSkipped)) {
                updateChecker.clearSkippedVersion()
            }
            .buttonStyle(.link)
            .controlSize(.small)
            Spacer()
        }
    }

    /// Opens the DMG built for this Mac; a release without a recognizable
    /// asset name still gets the user to the release page.
    private func download(_ release: UpdateRelease) {
        NSWorkspace.shared.open(release.preferredAsset()?.downloadURL ?? release.pageURL)
    }

    private func checkForUpdatesNow() {
        Task { await updateChecker.check(force: true) }
    }

    private func failureDescription(_ failure: UpdateCheckFailure) -> String {
        switch failure {
        case .network:
            return localization.localized(.updateErrorNetwork)
        case .server(let statusCode):
            return String(format: localization.localized(.updateErrorServer), statusCode)
        case .decoding:
            return localization.localized(.updateErrorDecoding)
        case .noReleases:
            return localization.localized(.updateErrorNoReleases)
        }
    }

    // MARK: - Reusable UI Helpers
    private func settingsSection<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(AppTheme.Status.accent)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.Text.primary)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundColor(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private var storageStatusDisplayText: String {
        if storageIsLoading || storageStatusText.isEmpty {
            return localization.localized(.loadingUsage)
        }
        return storageStatusText
    }

    private var storageStatusIcon: String {
        if storageIsLoading { return "arrow.triangle.2.circlepath" }
        if storageIsUnavailable { return "exclamationmark.triangle.fill" }
        return "externaldrive.fill"
    }

    private var storageStatusColor: Color {
        if storageIsLoading { return AppTheme.Status.accent }
        if storageIsUnavailable { return AppTheme.Status.warning }
        return AppTheme.Status.success
    }

    private func showPreferenceFeedback() {
        preferenceFeedbackVisible = true
    }

    private var preferenceFeedbackView: some View {
        Label(localization.localized(.done), systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundColor(AppTheme.Status.success)
            .accessibilityIdentifier("settings.preferences.feedback")
    }

    private var updateStatusIcon: String {
        if updateChecker.isChecking { return "arrow.triangle.2.circlepath" }
        if case .failed = updateChecker.status { return "exclamationmark.triangle.fill" }
        if updateChecker.availableUpdate != nil { return "arrow.down.circle.fill" }
        if case .upToDate = updateChecker.status { return "checkmark.circle.fill" }
        return "circle.dashed"
    }

    private var updateStatusColor: Color {
        if updateChecker.isChecking { return AppTheme.Status.accent }
        if case .failed = updateChecker.status { return AppTheme.Status.warning }
        if updateChecker.availableUpdate != nil { return AppTheme.Status.accent }
        if case .upToDate = updateChecker.status { return AppTheme.Status.success }
        return AppTheme.Text.secondary
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) {
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.Surface.primary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.Border.subtle, lineWidth: AppTheme.Layout.hairline)
        )
    }

    private var rowDivider: some View {
        AppTheme.Border.divider
            .frame(height: 0.5)
    }

    private func cardRowIcon(_ name: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color.opacity(0.12))
                .frame(width: 30, height: 30)
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
        }
        .accessibilityHidden(true)
    }

    /// A right-aligned selection control matching the settings card styling.
    /// SwiftUI's own `Menu`/`.pickerStyle(.menu)` bridges to a native popup that
    /// centers its value and ignores custom label layout; this control keeps the
    /// value flush with the card's trailing edge and draws its own chrome.
    private func trailingMenuPicker(
        _ title: String,
        accessibilityLabel: String,
        options: [String],
        onSelect: @escaping (Int) -> Void
    ) -> some View {
        SettingsMenuControlView(
            title: title,
            accessibilityLabel: accessibilityLabel,
            options: options,
            onSelect: onSelect
        )
    }

    private var isPerformingMaintenance: Bool {
        isRebuilding || isClearingRecords
    }

    private func maintenanceFeedbackView(_ feedback: MaintenanceFeedback) -> some View {
        let isSuccess = feedback == .succeeded
        return Label(
            localization.localized(isSuccess ? .maintenanceSucceeded : .maintenanceFailed),
            systemImage: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption.weight(.medium))
        .foregroundColor(isSuccess ? AppTheme.Status.success : AppTheme.Status.error)
        .accessibilityIdentifier("settings.maintenance.feedback")
    }

    private func rebuildAggregates() {
        guard !isPerformingMaintenance else { return }
        isRebuilding = true
        maintenanceFeedback = nil
        guard let aggregator else {
            isRebuilding = false
            maintenanceFeedback = .failed
            return
        }

        Task {
            do {
                try await aggregator.rebuildDailyRollups()
                await updateStorageStatus()
                maintenanceFeedback = .succeeded
            } catch {
                maintenanceFeedback = .failed
            }
            isRebuilding = false
        }
    }

    private func clearLocalUsageCache() {
        guard !isPerformingMaintenance else { return }
        isClearingRecords = true
        maintenanceFeedback = nil
        guard let aggregator else {
            isClearingRecords = false
            maintenanceFeedback = .failed
            return
        }

        Task {
            do {
                try await aggregator.clearAllRecords()
                await rescanAgents()
                await updateStorageStatus()
                maintenanceFeedback = .succeeded
            } catch {
                maintenanceFeedback = .failed
            }
            isClearingRecords = false
        }
    }

    // MARK: - Helpers
    private func displayName(for lang: AppLanguage) -> String {
        if lang.code == AppLanguage.system.code {
            return "\(localization.localized(.systemDefault)) (\(lang.displayName))"
        }
        return lang.displayName
    }

    private func saveExchangeRate() {
        guard let rate = Double(exchangeRateText), rate > 0 else {
            exchangeRateError = true
            return
        }
        exchangeRateError = false
        PricingEngine.shared.setExchangeRate(rate)
        showPreferenceFeedback()
    }

    private func revealDatabaseInFinder() {
        let path = (resolvedDbPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    private func updateStorageStatus() async {
        let path = (resolvedDbPath as NSString).expandingTildeInPath
        storageIsLoading = true
        storageIsUnavailable = false
        guard let aggregator,
              FileManager.default.fileExists(atPath: path),
              let count = try? await aggregator.fetchTotalRecordCount() else {
            storageStatusText = localization.localized(.dataUnavailable)
            storageIsUnavailable = true
            storageIsLoading = false
            return
        }
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let sizeFormatted = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        storageStatusText = String(format: localization.localized(.storageStatus), count, sizeFormatted)
        storageIsUnavailable = false
        storageIsLoading = false
    }

    @MainActor
    private func rescanAgents() async {
        guard !isSyncing else { return }
        isSyncing = true
        agentHealthInfos = []
        agentHealthLoadFailed = false
        defer { isSyncing = false }
        if let infos = try? await aggregator?.fetchAgentHealthInfos() {
            agentHealthInfos = infos
            agentHealthLoadFailed = false
        } else {
            agentHealthInfos = []
            agentHealthLoadFailed = true
        }
        await updateStorageStatus()
    }

    // `RelativeDateTimeFormatter` is comparatively expensive to construct, so a
    // single shared instance is reused instead of building one on every row
    // render. Its short format is identical to the previous per-call instance.
    private static let shortRelativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private func relativeTimestamp(_ date: Date) -> String {
        return Self.shortRelativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    SettingsContentView(aggregator: nil)
        .frame(width: 750, height: 510)
}

// MARK: - Right-aligned settings dropdown

/// AppKit-backed selection control used for the settings dropdowns.
///
/// SwiftUI's `Menu` and `.pickerStyle(.menu)` both bridge to a native popup
/// button that centers the selected value and discards custom label layout,
/// which left the value detached from the card's trailing edge. This control
/// draws its own rounded chrome, keeps the value flush-left inside itself (so it
/// ends flush with the card), and pops a native `NSMenu` that carries a checkmark
/// on the current selection.
@MainActor
final class SettingsMenuControl: NSView {
    /// Stable identifier used by tests to locate the control in the view tree.
    static let accessibilityID = "settings.menu.control"
    static let valueLabelID = "settings.menu.value"

    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private var currentTitle: String
    private var accessibilityLabelText: String
    private var options: [String]
    private var onSelect: (Int) -> Void
    private var isHovered = false
    private var isMenuExpanded = false

    private let minWidth: CGFloat = 140
    private let maxWidth: CGFloat = 260

    init(
        title: String,
        accessibilityLabel: String? = nil,
        options: [String],
        onSelect: @escaping (Int) -> Void
    ) {
        self.currentTitle = title
        self.accessibilityLabelText = accessibilityLabel ?? title
        self.options = options
        self.onSelect = onSelect
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityIdentifier(Self.accessibilityID)
        updateAccessibilityState()

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.usesSingleLineMode = true
        titleLabel.identifier = NSUserInterfaceItemIdentifier(Self.valueLabelID)
        addSubview(titleLabel)

        chevronView.image = NSImage(
            systemSymbolName: "chevron.up.chevron.down",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        chevronView.contentTintColor = .secondaryLabelColor
        addSubview(chevronView)

        titleLabel.stringValue = title
        toolTip = title

        for subview in [titleLabel, chevronView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -8),
            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 11),
            chevronView.heightAnchor.constraint(equalToConstant: 11)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { preferredSize() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        let fill: NSColor = isHovered ? .selectedContentBackgroundColor.withAlphaComponent(0.14) : .controlBackgroundColor
        fill.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func preferredSize() -> NSSize {
        let textWidth = ceil(titleLabel.intrinsicContentSize.width)
        let width = min(maxWidth, max(minWidth, textWidth + 46))
        return NSSize(width: width, height: 26)
    }

    override func mouseDown(with event: NSEvent) { presentMenu() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var canBecomeKeyView: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}": presentMenu()
        default: super.keyDown(with: event)
        }
    }

    func update(
        title: String,
        accessibilityLabel: String? = nil,
        options: [String],
        onSelect: @escaping (Int) -> Void
    ) {
        self.options = options
        self.onSelect = onSelect
        let updatedAccessibilityLabel = accessibilityLabel ?? title
        let didChangeValue = title != currentTitle
        let didChangeAccessibilityLabel = updatedAccessibilityLabel != accessibilityLabelText
        guard didChangeValue || didChangeAccessibilityLabel else { return }
        currentTitle = title
        accessibilityLabelText = updatedAccessibilityLabel
        titleLabel.stringValue = title
        toolTip = title
        updateAccessibilityState()
        if didChangeValue {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    private func presentMenu() {
        isMenuExpanded = true
        updateAccessibilityState()
        defer {
            isMenuExpanded = false
            updateAccessibilityState()
        }

        let menu = NSMenu()
        menu.font = .systemFont(ofSize: NSFont.systemFontSize)
        let selected = options.firstIndex(of: currentTitle)
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option, action: #selector(selectItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selected ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(
            positioning: menu.items.first,
            at: NSPoint(x: 0, y: bounds.height + 4),
            in: self
        )
    }

    @objc private func selectItem(_ sender: NSMenuItem) {
        guard options.indices.contains(sender.tag) else { return }
        currentTitle = options[sender.tag]
        titleLabel.stringValue = currentTitle
        toolTip = currentTitle
        updateAccessibilityState()
        invalidateIntrinsicContentSize()
        needsLayout = true
        onSelect(sender.tag)
    }

    /// Test hook: applies a selection as if the corresponding menu item was
    /// chosen, without presenting the menu.
    func performSelectionForTesting(at index: Int) {
        guard options.indices.contains(index) else { return }
        let item = NSMenuItem(title: options[index], action: nil, keyEquivalent: "")
        item.tag = index
        selectItem(item)
    }

    /// Test hook: mirrors the expanded state while the native menu is open.
    func setMenuExpandedForTesting(_ expanded: Bool) {
        isMenuExpanded = expanded
        updateAccessibilityState()
    }

    private func updateAccessibilityState() {
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(accessibilityLabelText)
        setAccessibilityValue(currentTitle)
        setAccessibilityValueDescription(currentTitle)
        setAccessibilityExpanded(isMenuExpanded)
    }
}

struct SettingsMenuControlView: NSViewRepresentable {
    let title: String
    let accessibilityLabel: String
    let options: [String]
    let onSelect: (Int) -> Void

    func makeNSView(context: Context) -> SettingsMenuControl {
        SettingsMenuControl(
            title: title,
            accessibilityLabel: accessibilityLabel,
            options: options,
            onSelect: onSelect
        )
    }

    func updateNSView(_ control: SettingsMenuControl, context: Context) {
        control.update(
            title: title,
            accessibilityLabel: accessibilityLabel,
            options: options,
            onSelect: onSelect
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SettingsMenuControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

private struct CategoryRowButton: View {
    let category: SettingsCategory
    let isSelected: Bool
    let localization: LocalizationManager
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? category.iconColor : category.iconColor.opacity(0.12))
                        .frame(width: 24, height: 24)
                    Image(systemName: category.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isSelected ? .white : category.iconColor)
                }

                Text(category.title(localization: localization))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? AppTheme.Text.primary : AppTheme.Text.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AppTheme.Surface.selected : (isHovered ? AppTheme.Surface.hover : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(category.title(localization: localization))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
