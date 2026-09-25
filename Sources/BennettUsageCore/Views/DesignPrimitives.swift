import SwiftUI

// Compatibility shims.
//
// The design system now lives in `DesignTokens.swift` (the values) and
// `DesignComponents.swift` (the parts). These types are the names the dashboard
// and Settings were already written against, so they are kept as thin
// forwarders rather than a second implementation: two definitions of "a
// module" is how a codebase ends up with two module treatments that differ by
// a few points of radius and nobody can say which is canonical.
//
// Each one documents the mapping it now performs. New code should use the
// `DesignComponents` name directly.

// MARK: - Section label

/// Deprecated spelling of `RegionLabel`.
public struct SectionEyebrow: View {
    private let title: String
    private let trailing: AnyView?

    public init(_ title: String) {
        self.title = title
        self.trailing = nil
    }

    public init<T: View>(_ title: String, @ViewBuilder trailing: () -> T) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    public var body: some View {
        if let trailing {
            RegionLabel(title) { trailing }
        } else {
            RegionLabel(title)
        }
    }
}

// MARK: - Module

/// Deprecated spelling of `Module`, with the old default insets preserved so
/// existing call sites keep their current density.
public struct ContinuousPanel<Content: View>: View {
    private let padding: CGFloat
    private let background: Color
    private let content: Content

    public init(
        padding: CGFloat = DesignTokens.Metrics.modulePadding,
        background: Color = DesignTokens.Surfaces.module,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.background = background
        self.content = content()
    }

    public var body: some View {
        Module(padding: padding, background: background, content: { content })
    }
}

// MARK: - Divider

/// Deprecated spelling of `InlineDivider`.
public struct PanelDivider: View {
    private let inset: CGFloat

    public init(inset: CGFloat = 0) {
        self.inset = inset
    }

    public var body: some View {
        InlineDivider(inset: inset)
    }
}

// MARK: - Readout

/// Deprecated spelling of `Readout`.
public struct MetricCell: View {
    private let label: String
    private let value: String
    private let detail: String?
    private let valueColor: Color
    private let valueFont: Font
    private let accessory: AnyView?

    public init(
        label: String,
        value: String,
        detail: String? = nil,
        valueColor: Color = DesignTokens.Ink.strong,
        valueFont: Font = DesignTokens.TypeScale.numericLarge
    ) {
        self.label = label
        self.value = value
        self.detail = detail
        self.valueColor = valueColor
        self.valueFont = valueFont
        self.accessory = nil
    }

    public init<T: View>(
        label: String,
        value: String,
        detail: String? = nil,
        valueColor: Color = DesignTokens.Ink.strong,
        valueFont: Font = DesignTokens.TypeScale.numericLarge,
        @ViewBuilder accessory: () -> T
    ) {
        self.label = label
        self.value = value
        self.detail = detail
        self.valueColor = valueColor
        self.valueFont = valueFont
        self.accessory = AnyView(accessory())
    }

    public var body: some View {
        if let accessory {
            Readout(
                label: label,
                value: value,
                detail: detail,
                valueColor: valueColor,
                valueFont: valueFont
            ) { accessory }
        } else {
            Readout(
                label: label,
                value: value,
                detail: detail,
                valueColor: valueColor,
                valueFont: valueFont
            )
        }
    }
}

// MARK: - Proportional mark

/// Deprecated spelling of `ShareBar`.
public struct ProportionBar: View {
    /// Deprecated spelling of `ShareBar.Segment`.
    public struct Segment: Identifiable {
        public let id: String
        public let share: Double
        public let color: Color

        public init(id: String, share: Double, color: Color) {
            self.id = id
            self.share = max(0, share)
            self.color = color
        }
    }

    private let segments: [Segment]
    private let height: CGFloat
    private let spacing: CGFloat

    public init(segments: [Segment], height: CGFloat = 8, spacing: CGFloat = 2) {
        self.segments = segments
        self.height = height
        self.spacing = spacing
    }

    public var body: some View {
        ShareBar(
            segments: segments.map { ShareBar.Segment(id: $0.id, share: $0.share, color: $0.color) },
            height: height,
            spacing: spacing
        )
    }
}

// MARK: - State marker

/// Deprecated spelling of `StateCapsule`, minus the pill background.
public struct StatusMarker: View {
    private let systemImage: String
    private let text: String
    private let color: Color
    private let showsText: Bool

    public init(systemImage: String, text: String, color: Color, showsText: Bool = true) {
        self.systemImage = systemImage
        self.text = text
        self.color = color
        self.showsText = showsText
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
            if showsText {
                Text(text)
                    .font(DesignTokens.TypeScale.caption)
                    .foregroundColor(DesignTokens.Ink.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bounded meter

/// Deprecated spelling of a plain bounded meter. Magnitude only, so it takes
/// ink rather than a caller-supplied hue.
public struct PercentageMeter: View {
    private let value: Double
    private let color: Color
    private let width: CGFloat

    public init(value: Double, color: Color, width: CGFloat = 132) {
        self.value = min(max(value, 0), 1)
        self.color = color
        self.width = width
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(DesignTokens.Ink.track)
                Capsule()
                    .fill(color)
                    .frame(width: max(2, geometry.size.width * CGFloat(value)), height: 4)
            }
        }
        .frame(width: width, height: 4)
        .accessibilityHidden(true)
    }
}
