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
            return .blue
        case .agents:
            return .green
        case .pricing:
            return .orange
        case .storage:
            return .purple
        case .about:
            return .gray
        }
    }
}

public struct SettingsContentView: View {
    public let aggregator: MetricsAggregator?
    @ObservedObject public var localization: LocalizationManager
    public let onDismiss: (() -> Void)?

    @State private var selectedCategory: SettingsCategory
    @State private var agentHealthInfos: [AgentHealthInfo] = []
    @State private var isSyncing: Bool = false
    @State private var exchangeRateText: String = ""
    @State private var selectedCurrency: PreferredCurrency = .usd
    @State private var autoRefreshSeconds: Int = 0
    @State private var isShowingClearAlert: Bool = false
    @State private var storageStatusText: String = ""

    public init(
        aggregator: MetricsAggregator? = nil,
        localization: LocalizationManager = .shared,
        initialCategory: SettingsCategory = .general,
        onDismiss: (() -> Void)? = nil
    ) {
        self.aggregator = aggregator
        self.localization = localization
        self.onDismiss = onDismiss
        self._selectedCategory = State(initialValue: initialCategory)
    }

    private var selectedLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { localization.selectedLanguage },
            set: { newLang in localization.setLanguage(newLang) }
        )
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

    public var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar
            sidebarView
                .frame(width: 200)

            Divider()

            // Right Detail Content Area
            VStack(spacing: 0) {
                detailHeaderView

                Divider()

                ScrollView(.vertical, showsIndicators: true) {
                    detailContentView
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .background(Color(NSColor.windowBackgroundColor))
        .alert(localization.localized(.clearRecordsConfirmTitle), isPresented: $isShowingClearAlert) {
            Button(localization.localized(.clearAllRecords), role: .destructive) {
                Task {
                    try? await aggregator?.clearAllRecords()
                    await rescanAgents()
                    await updateStorageStatus()
                }
            }
            Button(localization.localized(.cancel), role: .cancel) {}
        } message: {
            Text(localization.localized(.clearRecordsConfirmMessage))
        }
        .onAppear {
            selectedCurrency = PricingEngine.shared.preferredCurrency
            exchangeRateText = String(format: "%.2f", PricingEngine.shared.usdToCnyRate)
            autoRefreshSeconds = UserDefaults.standard.integer(forKey: "bennett_auto_refresh_seconds")
            Task {
                await rescanAgents()
                await updateStorageStatus()
            }
        }
        .onChange(of: autoRefreshSeconds) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "bennett_auto_refresh_seconds")
        }
    }

    // MARK: - Sidebar View
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sidebar Header
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(localization.localized(.settings))
                    .font(.headline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 14)

            // Category Items
            VStack(spacing: 4) {
                ForEach(SettingsCategory.allCases) { category in
                    categoryRow(category)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            // Sidebar Footer: Active agents summary
            HStack(spacing: 6) {
                Circle()
                    .fill(isAnyAgentConnected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(String(format: localization.localized(.agentsConnected), connectedAgentCount))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.55))
    }

    private func categoryRow(_ category: SettingsCategory) -> some View {
        let isSelected = selectedCategory == category
        return Button(action: {
            selectedCategory = category
        }) {
            HStack(spacing: 10) {
                // Colored squircle icon
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(category.iconColor)
                        .frame(width: 22, height: 22)
                    Image(systemName: category.systemImage)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }

                Text(category.title(localization: localization))
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail Header View
    private var detailHeaderView: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedCategory.fullTitle(localization: localization))
                    .font(.title2.bold())
                Text(selectedCategory.subtitle(localization: localization))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let onDismiss = onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(localization.localized(.done))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(NSColor.windowBackgroundColor))
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
        VStack(alignment: .leading, spacing: 18) {
            settingsCard {
                // Language selection row
                HStack(spacing: 12) {
                    cardRowIcon("globe", color: .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localization.localized(.language))
                            .font(.body.weight(.medium))
                        Text(localization.localized(.systemDefault))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: selectedLanguageBinding) {
                        ForEach(localization.availableLanguages) { lang in
                            Text(displayName(for: lang)).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }
                .padding(.vertical, 4)

                Divider()

                // Auto Refresh row
                HStack(spacing: 12) {
                    cardRowIcon("arrow.clockwise", color: .cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localization.localized(.autoRefreshLabel))
                            .font(.body.weight(.medium))
                        Text(autoRefreshSubtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $autoRefreshSeconds) {
                        Text(localization.localized(.autoRefreshOff)).tag(0)
                        Text(String(format: localization.localized(.autoRefreshSeconds), 10)).tag(10)
                        Text(String(format: localization.localized(.autoRefreshSeconds), 30)).tag(30)
                        Text(String(format: localization.localized(.autoRefreshSeconds), 60)).tag(60)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Section 2: Agent Health & Diagnostics Pane
    private var agentsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Summary and Rescan action bar
            HStack {
                Text(String(format: localization.localized(.agentsConnected), connectedAgentCount))
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    Task { await rescanAgents() }
                }) {
                    HStack(spacing: 6) {
                        if isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(localization.localized(.rescanNow))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isSyncing)
            }

            // Agents list card
            settingsCard {
                if agentHealthInfos.isEmpty {
                    HStack {
                        Spacer()
                        Text(String(format: localization.localized(.agentsConnected), 0))
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(.vertical, 18)
                } else {
                    ForEach(agentHealthInfos) { info in
                        agentHealthRow(info)
                        if info.id != agentHealthInfos.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func agentHealthRow(_ info: AgentHealthInfo) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(info.isInstalled ? Color.green.opacity(0.14) : Color.secondary.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: info.isInstalled ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(info.isInstalled ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(info.displayName)
                        .font(.body.weight(.semibold))
                    if info.isInstalled {
                        Text("Active")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    } else {
                        Text("Not Found")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundColor(.secondary)
                            .cornerRadius(4)
                    }
                }

                Text(info.defaultPath)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(info.defaultPath)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(formatNumber(info.recordCount)) records")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.10))
                    .cornerRadius(6)

                if let lastTimestamp = info.lastRecordTimestamp {
                    Text(relativeTimestamp(lastTimestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
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
                    cardRowIcon("coloncurrencysign.circle.fill", color: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localization.localized(.preferredCurrencyLabel))
                            .font(.body.weight(.medium))
                        Text("USD ($) / CNY (¥)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $selectedCurrency) {
                        Text(localization.localized(.usdOption)).tag(PreferredCurrency.usd)
                        Text(localization.localized(.cnyOption)).tag(PreferredCurrency.cny)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .onChange(of: selectedCurrency) { _, newCurrency in
                        PricingEngine.shared.setPreferredCurrency(newCurrency)
                    }
                }
                .padding(.vertical, 4)
            }

            // Exchange Rate Card
            settingsCard {
                HStack(spacing: 12) {
                    cardRowIcon("chart.line.uptrend.xyaxis", color: .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localization.localized(.exchangeRateLabel))
                            .font(.body.weight(.medium))
                        Text("1 USD = \(exchangeRateText) CNY")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Text("1 USD =")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        TextField("7.30", text: $exchangeRateText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .onSubmit {
                                saveExchangeRate()
                            }
                        Text("CNY")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Button(localization.localized(.done)) {
                            saveExchangeRate()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Section 4: Storage & Maintenance Pane
    private var storagePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Database Info Card
            settingsCard {
                HStack(alignment: .top, spacing: 12) {
                    cardRowIcon("cylinder.split.1x2", color: .purple)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SQLite Database")
                            .font(.body.weight(.semibold))
                        Text(resolvedDbPath)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(resolvedDbPath)

                        if !storageStatusText.isEmpty {
                            Text(storageStatusText)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                                .padding(.top, 2)
                        }
                    }
                    Spacer()
                    Button(action: revealDatabaseInFinder) {
                        Label(localization.localized(.revealInFinder), systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
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
                            Text("Re-aggregate token usage and daily summaries from raw records")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: {
                            Task {
                                try? await aggregator?.rebuildDailyRollups()
                                await updateStorageStatus()
                            }
                        }) {
                            Label(localization.localized(.rebuildRollups), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localization.localized(.clearAllRecords))
                                .font(.body.weight(.medium))
                                .foregroundColor(.red)
                            Text("Permanently delete all stored token usage history")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive, action: {
                            isShowingClearAlert = true
                        }) {
                            Label(localization.localized(.clearAllRecords), systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Section 5: About Pane
    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Hero Card
            settingsCard {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor, Color.purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 52, height: 52)
                        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(localization.localized(.appName))
                                .font(.title3.bold())
                            Text("v1.0.0")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Text(localization.localized(.aboutDescription))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            // Privacy Card
            settingsCard {
                HStack(alignment: .top, spacing: 14) {
                    cardRowIcon("lock.shield.fill", color: .green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("100% Local-First & Private")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.primary)
                        Text("All analytics and token logs are stored exclusively in your local SQLite database. Bennett Usage never collects, transmits, or inspects your source code, prompts, or API keys.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            // Repository Link Card
            settingsCard {
                HStack {
                    cardRowIcon("chevron.left.forwardslash.chevron.right", color: .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Source")
                            .font(.body.weight(.medium))
                        Text("github.com/ruanbw/bennett-usage")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if let githubURL = URL(string: "https://github.com/ruanbw/bennett-usage") {
                        Link(destination: githubURL) {
                            HStack(spacing: 4) {
                                Text("GitHub")
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

    // MARK: - Reusable UI Helpers
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) {
            content()
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func cardRowIcon(_ name: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.15))
                .frame(width: 28, height: 28)
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
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
        if let rate = Double(exchangeRateText), rate > 0 {
            PricingEngine.shared.setExchangeRate(rate)
        }
    }

    private func revealDatabaseInFinder() {
        let path = (resolvedDbPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    private func updateStorageStatus() async {
        let count = (try? await aggregator?.fetchTotalRecordCount()) ?? 0
        let path = (resolvedDbPath as NSString).expandingTildeInPath
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let sizeFormatted = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        storageStatusText = String(format: localization.localized(.storageStatus), count, sizeFormatted)
    }

    @MainActor
    private func rescanAgents() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        if let infos = try? await aggregator?.fetchAgentHealthInfos() {
            agentHealthInfos = infos
        }
        await updateStorageStatus()
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private func relativeTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    SettingsContentView(aggregator: nil)
        .frame(width: 750, height: 510)
}
