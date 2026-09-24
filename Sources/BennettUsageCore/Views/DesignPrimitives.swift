import SwiftUI

// Shared structural vocabulary for the dashboard, the menu-bar popover and
// Settings. These exist so the three surfaces express the same hierarchy with
// the same parts instead of each screen inventing its own card and header
// treatment.
//
// Two rules the primitives enforce:
//
// 1. Grouping is done by one continuous container plus hairlines, never by
//    repeating a bordered card. A screen made of identical tiles has no
//    focal point, which is what made the previous layout read as flat.
// 2. Section titles are set as a tracked micro-label, not as an icon plus a
//    heading. A pictogram next to every heading is decoration, not wayfinding.

/// A tracked, uppercased micro-label that introduces a region of a screen.
///
/// CJK text has no uppercase form, so the label is uppercased only when it
/// actually contains cased Latin characters; the tracking still applies and
/// keeps the CJK line visually consistent with its Latin siblings.
public struct SectionEyebrow: View {
    private let title: String
    private var trailing: AnyView?

    public init(_ title: String) {
        self.title = title
        self.trailing = nil
    }

    public init<T: View>(_ title: String, @ViewBuilder trailing: () -> T) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    private var displayTitle: String {
        title.contains(where: { $0.isUppercase }) ? title : title.uppercased()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(displayTitle)
                .font(AppTheme.Typography.eyebrow)
                .tracking(0.8)
                .foregroundColor(AppTheme.Text.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let trailing {
                trailing
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// One continuous container. Children are expected to separate themselves with
/// `PanelDivider` so the group reads as a single object.
public struct ContinuousPanel<Content: View>: View {
    private var padding: CGFloat
    private var background: Color
    private var content: Content

    public init(
        padding: CGFloat = AppTheme.Layout.cellPadding,
        background: Color = AppTheme.Surface.panel,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.background = background
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                    .stroke(AppTheme.Border.subtle, lineWidth: AppTheme.Layout.hairline)
            )
    }
}

/// A hairline that separates two regions inside a `ContinuousPanel`.
public struct PanelDivider: View {
    private var inset: CGFloat

    public init(inset: CGFloat = 0) {
        self.inset = inset
    }

    public var body: some View {
        AppTheme.Border.divider
            .frame(height: AppTheme.Layout.hairline)
            .padding(.leading, inset)
    }
}

/// A label-above-value readout. The label is deliberately quiet so the number
/// carries the reading, and the value is tabular so columns of metrics align.
public struct MetricCell: View {
    private let label: String
    private let value: String
    private var detail: String?
    private var valueColor: Color
    private var valueFont: Font
    private var trailingAccessory: AnyView?

    public init(
        label: String,
        value: String,
        detail: String? = nil,
        valueColor: Color = AppTheme.Text.primary,
        valueFont: Font = AppTheme.Typography.supportingValue
    ) {
        self.label = label
        self.value = value
        self.detail = detail
        self.valueColor = valueColor
        self.valueFont = valueFont
        self.trailingAccessory = nil
    }

    public init<T: View>(
        label: String,
        value: String,
        detail: String? = nil,
        valueColor: Color = AppTheme.Text.primary,
        valueFont: Font = AppTheme.Typography.supportingValue,
        @ViewBuilder accessory: () -> T
    ) {
        self.label = label
        self.value = value
        self.detail = detail
        self.valueColor = valueColor
        self.valueFont = valueFont
        self.trailingAccessory = AnyView(accessory())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(AppTheme.Typography.label)
                .foregroundColor(AppTheme.Text.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(valueFont)
                    .foregroundColor(valueColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                if let trailingAccessory {
                    trailingAccessory
                }
            }
            if let detail {
                Text(detail)
                    .font(AppTheme.Typography.caption)
                    .foregroundColor(AppTheme.Text.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A proportional bar drawn on a neutral track.
///
/// Segments keep their categorical color for identity, but the unfilled
/// remainder is an explicit track rather than more saturated fill, and the
/// whole mark is short. A single dominant category therefore reads as "almost
/// all of it" instead of flooding the surface with one hue.
public struct ProportionBar: View {
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
    private var height: CGFloat
    private var spacing: CGFloat

    public init(segments: [Segment], height: CGFloat = 8, spacing: CGFloat = 2) {
        self.segments = segments
        self.height = height
        self.spacing = spacing
    }

    public var body: some View {
        GeometryReader { geometry in
            let total = segments.reduce(0) { $0 + $1.share }
            let gaps = CGFloat(max(0, segments.count - 1)) * spacing
            let usable = max(0, geometry.size.width - gaps)

            HStack(spacing: spacing) {
                ForEach(segments) { segment in
                    let width = total > 0 ? usable * CGFloat(segment.share / total) : 0
                    Capsule()
                        .fill(segment.color)
                        // A hairline floor keeps sub-1% categories visible
                        // without letting them distort the proportions.
                        .frame(width: max(segment.share > 0 ? 2 : 0, width))
                }
            }
            .frame(height: height, alignment: .center)
        }
        .frame(height: height)
        .background(
            Capsule().fill(AppTheme.Data.track)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: segments.map { $0.id }.joined(separator: ", ")))
    }
}

/// A compact state marker: a colored dot plus its text. Used instead of a
/// tinted, bordered container so a one-line status does not need a box.
public struct StatusMarker: View {
    private let systemImage: String
    private let text: String
    private let color: Color
    private var showsText: Bool

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
                    .font(AppTheme.Typography.caption)
                    .foregroundColor(AppTheme.Text.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A horizontal meter for a bounded percentage. Constrained to a readable
/// width so a single ratio does not stretch across the whole window.
public struct PercentageMeter: View {
    private let value: Double
    private let color: Color
    private var width: CGFloat

    public init(value: Double, color: Color, width: CGFloat = 132) {
        self.value = min(max(value, 0), 1)
        self.color = color
        self.width = width
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.Data.track)
                Capsule()
                    .fill(color)
                    .frame(width: max(2, geometry.size.width * CGFloat(value)), height: 4)
            }
        }
        .frame(width: width, height: 4)
        .accessibilityHidden(true)
    }
}
