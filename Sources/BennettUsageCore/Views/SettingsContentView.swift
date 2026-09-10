import SwiftUI
import AppKit

public struct SettingsContentView: View {
    public let aggregator: MetricsAggregator?
    @ObservedObject public var localization: LocalizationManager
    public let onDismiss: (() -> Void)?

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
        onDismiss: (() -> Void)? = nil
    ) {
        self.aggregator = aggregator
        self.localization = localization
        self.onDismiss = onDismiss
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

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label(localization.localized(.settings), systemImage: "gearshape.fill")
                    .font(.title2.bold())
                Spacer()
                if let onDismiss = onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .help(localization.localized(.done))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    generalSection
                    agentHealthSection
                    pricingSection
                    storageSection
                    aboutSection
                }
                .padding(24)
            }
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

    // MARK: - Section 1: General Settings
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localization.localized(.generalSettings))
                .font(.headline)

            VStack(spacing: 12) {
                HStack {
                    Label(localization.localized(.language), systemImage: "globe")
                    Spacer()
                    Picker("", selection: selectedLanguageBinding) {
                        ForEach(localization.availableLanguages) { lang in
                            Text(displayName(for: lang)).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }

                Divider()

                HStack {
                    Label(localization.localized(.autoRefreshLabel), systemImage: "arrow.clockwise")
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
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
        }
    }

    // MARK: - Section 2: Agent Health & Diagnostics
    private var agentHealthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(localization.localized(.agentHealthSection))
                    .font(.headline)
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
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSyncing)
            }

            VStack(spacing: 10) {
                if agentHealthInfos.isEmpty {
                    HStack {
                        Spacer()
                        Text(localization.localized(.agentsConnected, arguments: 0))
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                } else {
                    ForEach(agentHealthInfos) { info in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(info.isInstalled ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 9, height: 9)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.displayName)
                                    .font(.body.weight(.medium))
                                Text(info.defaultPath)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(formatNumber(info.recordCount)) records")
                                    .font(.caption.monospacedDigit())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12))
                                    .cornerRadius(4)

                                if let lastTimestamp = info.lastRecordTimestamp {
                                    Text(relativeTimestamp(lastTimestamp))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        if info.id != agentHealthInfos.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
        }
    }

    // MARK: - Section 3: Pricing & Currency
    private var pricingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localization.localized(.pricingSection))
                .font(.headline)

            VStack(spacing: 12) {
                HStack {
                    Label(localization.localized(.preferredCurrencyLabel), systemImage: "dollarsign.circle")
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

                Divider()

                HStack {
                    Label(localization.localized(.exchangeRateLabel), systemImage: "chart.line.uptrend.xyaxis")
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
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
        }
    }

    // MARK: - Section 4: Storage & Maintenance
    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localization.localized(.storageSection))
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "cylinder.split.1x2")
                            .foregroundColor(.secondary)
                        Text(resolvedDbPath)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if !storageStatusText.isEmpty {
                        Text(storageStatusText)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.primary)
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    Button(action: revealDatabaseInFinder) {
                        Label(localization.localized(.revealInFinder), systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: {
                        Task {
                            try? await aggregator?.rebuildDailyRollups()
                            await updateStorageStatus()
                        }
                    }) {
                        Label(localization.localized(.rebuildRollups), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Button(role: .destructive, action: {
                        isShowingClearAlert = true
                    }) {
                        Label(localization.localized(.clearAllRecords), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(.red)
                }
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
        }
    }

    // MARK: - Section 5: About
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localization.localized(.about))
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                        .font(.system(size: 32))
                        .foregroundColor(.accentColor)
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(localization.localized(.appName))
                                .font(.headline)
                            Text("v1.0.0")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Text(localization.localized(.aboutDescription))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                HStack {
                    Label("100% Local & Private", systemImage: "lock.shield.fill")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.green)

                    Spacer()

                    if let githubURL = URL(string: "https://github.com/ruanbw/bennett-usage") {
                        Link(destination: githubURL) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right.square")
                                Text("GitHub")
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
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
