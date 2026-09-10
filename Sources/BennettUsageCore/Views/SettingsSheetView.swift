import SwiftUI

public struct SettingsSheetView: View {
    @ObservedObject public var localization: LocalizationManager
    public let onDismiss: () -> Void

    public init(
        localization: LocalizationManager = .shared,
        onDismiss: @escaping () -> Void
    ) {
        self.localization = localization
        self.onDismiss = onDismiss
    }

    private var selectedLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { localization.selectedLanguage },
            set: { newLang in localization.setLanguage(newLang) }
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label(localization.localized(.settings), systemImage: "gearshape.fill")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help(localization.localized(.done))
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            // Content
            VStack(alignment: .leading, spacing: 20) {
                // Section: General
                VStack(alignment: .leading, spacing: 10) {
                    Text(localization.localized(.general))
                        .font(.subheadline).bold()
                        .foregroundColor(.secondary)

                    HStack {
                        Text(localization.localized(.language))
                            .font(.body)
                        Spacer()
                        Picker("", selection: selectedLanguageBinding) {
                            ForEach(localization.availableLanguages) { lang in
                                Text(displayName(for: lang)).tag(lang)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }

                // Section: About
                VStack(alignment: .leading, spacing: 10) {
                    Text(localization.localized(.about))
                        .font(.subheadline).bold()
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(localization.localized(.appName))
                                .font(.headline)
                            Spacer()
                            Text("v1.0.0")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Text(localization.localized(.aboutDescription))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }
            }
            .padding(20)

            Spacer()

            Divider()

            // Footer
            HStack {
                Spacer()
                Button(localization.localized(.done)) {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 440, height: 340)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func displayName(for lang: AppLanguage) -> String {
        if lang.code == AppLanguage.system.code {
            return "\(localization.localized(.systemDefault)) (\(lang.displayName))"
        }
        return lang.displayName
    }
}
