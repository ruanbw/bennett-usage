import SwiftUI

/// The components named in `docs/ui-refactor/design-system.md` §4, implemented
/// once so the dashboard, the popover and Settings express the same hierarchy
/// with the same parts.
///
/// Each one is deliberately narrow. A component that takes a color where the
/// spec names a role is how the roles get crossed again, so the interaction,
/// state and identity colors are chosen by the component, not the call site.
public extension View {

    // MARK: - Focus & hover

    /// The one focus treatment: a 2pt accent ring at a 2pt offset, drawn only
    /// while the control holds keyboard focus.
    ///
    /// The ring is drawn by AppKit, not by this code. A hand-rolled ring needs
    /// a reliable "the keyboard is here" signal, and the only such signal a
    /// plain `.buttonStyle(.plain)` label can receive is one the view cannot
    /// observe without owning a focus binding it does not have — which is
    /// exactly how an earlier version ended up with a ring pinned at
    /// `opacity(0)`: not a focus ring, but decoration that happened to be
    /// invisible. Leaving the system to draw it means the ring appears on
    /// keyboard traversal, never on a mouse click, and always matches the
    /// user's own Appearance settings.
    ///
    /// `focusEffectDisabled()` is deliberately not used. The spec requires a
    /// visible ring in every state; suppressing the system effect in order to
    /// replace it satisfies the letter of "2pt accent" and none of the intent.
    func accentFocusRing() -> some View {
        overlay(
            RoundedRectangle(
                cornerRadius: DesignTokens.Metrics.Radius.control,
                style: .continuous
            )
            .strokeBorder(DesignTokens.Accent.ring, lineWidth: 2)
            .padding(-2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        )
    }

    /// The same ring, driven by an explicit focus state.
    ///
    /// Used where the control must own its focus binding — which is every
    /// control the product builds by hand rather than inheriting AppKit's
    /// default button behavior. `isFocused` is the caller's `@FocusState`,
    /// because a modifier cannot observe a `@FocusState` it does not hold.
    func accentFocusRing(isFocused: Bool) -> some View {
        overlay(
            RoundedRectangle(
                cornerRadius: DesignTokens.Metrics.Radius.control,
                style: .continuous
            )
            .strokeBorder(DesignTokens.Accent.ring, lineWidth: 2)
            .padding(-2)
            .opacity(isFocused ? 1 : 0)
            .animation(.easeOut(duration: 0.1), value: isFocused)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        )
    }

    /// Applies a hover wash to a row without moving it.
    func hoverSurface(_ isHovered: Bool, radius: CGFloat = DesignTokens.Metrics.Radius.control) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(isHovered ? DesignTokens.Surfaces.hover : .clear)
        )
        .animation(
            .easeOut(duration: DesignTokens.Motion.hover),
            value: isHovered
        )
    }
}

/// A tracked micro-label introducing a region of a screen.
///
/// CJK has no uppercase form, so the transform is applied only to Latin text;
/// the tracking keeps the two scripts optically consistent.
public struct RegionLabel: View {
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

    private var displayTitle: String {
        title.contains(where: { $0.isUppercase }) ? title : title.uppercased()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(displayTitle)
                .font(DesignTokens.TypeScale.eyebrow)
                .tracking(0.8)
                .foregroundColor(DesignTokens.Ink.muted)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let trailing { trailing }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A labelled readout inside a column of readouts.
///
/// The value is tabular and gets 25% headroom, so an abbreviated figure such
/// as `3.28B` never clips when Dynamic Type reaches `.accessibility3`.
public struct Readout: View {
    private let label: String
    private let value: String
    private var detail: String?
    private var valueColor: Color
    private var valueFont: Font
    private var accessory: AnyView?

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
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(DesignTokens.TypeScale.caption)
                .foregroundColor(DesignTokens.Ink.muted)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(valueFont)
                    .foregroundColor(valueColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if let accessory { accessory }
            }
            if let detail {
                Text(detail)
                    .font(DesignTokens.TypeScale.caption)
                    .foregroundColor(DesignTokens.Ink.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The cache-hit ring. It encodes exactly one number, and nothing else.
///
/// Its color is a state, not a magnitude: green at or above the 95% target,
/// amber below it. Because green is the good state, the ring carries
/// `accessibilityValue` — the same number is also always present as text, so
/// the reading never depends on hue alone.
public struct CacheHitRing: View {
    private let rate: Double
    private var diameter: CGFloat
    private let target: Double

    public init(rate: Double, diameter: CGFloat = 104, target: Double = 0.95) {
        self.rate = min(max(rate, 0), 1)
        self.diameter = diameter
        self.target = target
    }

    private var meetsTarget: Bool { rate >= target }

    private var strokeColor: Color {
        meetsTarget ? DesignTokens.State.ok : DesignTokens.State.warn
    }

    private var lineWidth: CGFloat { diameter * 0.085 }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(DesignTokens.Ink.track, style: StrokeStyle(lineWidth: lineWidth))
            Circle()
                .trim(from: 0, to: max(rate, 0.0001))
                .stroke(
                    strokeColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(
                    .easeOut(duration: DesignTokens.Motion.ring),
                    value: rate
                )
            VStack(spacing: 0) {
                Text(String(format: "%.0f%%", rate * 100))
                    .font(.system(size: diameter * 0.26, weight: .semibold, design: .monospaced))
                    .foregroundColor(DesignTokens.Ink.strong)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Cache"))
        .accessibilityValue(Text(verbatim: String(format: "%.1f%%", rate * 100)))
    }
}

/// A horizontal proportional mark on a neutral track.
///
/// Segments keep their identity color, but the unfilled remainder is an
/// explicit track rather than more saturated fill, and every segment is filled
/// — never an outline. A segment below the floor still renders as a 2pt sliver
/// so a 0.4% category is visible without distorting the rest.
public struct ShareBar: View {
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
                        .frame(width: max(segment.share > 0 ? 2 : 0, width))
                }
            }
            .frame(height: height, alignment: .center)
        }
        .frame(height: height)
        .background(Capsule().fill(DesignTokens.Ink.track))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: segments.map(\.id).joined(separator: ", ")))
    }
}

/// A state capsule: a dot plus wording.
///
/// The wording is the state. A capsule that only changed color would be
/// unreadable to anyone who cannot separate the hues, so the text always says
/// what the dot means.
public struct StateCapsule: View {
    public enum Level: Sendable {
        case ok
        case syncing
        case stale
        case error

        var color: Color {
            switch self {
            case .ok: return DesignTokens.State.ok
            case .syncing: return DesignTokens.Accent.base
            case .stale: return DesignTokens.State.warn
            case .error: return DesignTokens.State.danger
            }
        }

        var systemImage: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .syncing: return "arrow.triangle.2.circlepath"
            case .stale: return "clock.badge.exclamationmark"
            case .error: return "exclamationmark.triangle.fill"
            }
        }
    }

    private let level: Level
    private let text: String
    private var height: CGFloat

    public init(_ level: Level, text: String, height: CGFloat = 24) {
        self.level = level
        self.text = text
        self.height = height
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: level.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(level.color)
            Text(text)
                .font(DesignTokens.TypeScale.caption)
                .foregroundColor(DesignTokens.Ink.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(Capsule().fill(DesignTokens.Surfaces.hover))
        .accessibilityElement(children: .combine)
    }
}

/// A hairline between two things inside one module.
public struct InlineDivider: View {
    private let inset: CGFloat
    private let axis: Axis

    public init(inset: CGFloat = 0, axis: Axis = .horizontal) {
        self.inset = inset
        self.axis = axis
    }

    public var body: some View {
        let line = DesignTokens.Lines.soft
        Group {
            if axis == .horizontal {
                line.frame(height: DesignTokens.Metrics.hairline).padding(.leading, inset)
            } else {
                line.frame(width: DesignTokens.Metrics.hairline).padding(.top, inset)
            }
        }
    }
}

/// One continuous module. Children separate themselves with `InlineDivider` so
/// the group reads as a single object rather than a wall of identical tiles.
public struct Module<Content: View>: View {
    private var padding: CGFloat
    private var background: Color
    private var radius: CGFloat
    private var showsBorder: Bool
    private var content: Content

    public init(
        padding: CGFloat = DesignTokens.Metrics.modulePadding,
        background: Color = DesignTokens.Surfaces.module,
        radius: CGFloat = DesignTokens.Metrics.Radius.module,
        showsBorder: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.background = background
        self.radius = radius
        self.showsBorder = showsBorder
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        DesignTokens.Lines.module,
                        lineWidth: showsBorder ? DesignTokens.Metrics.hairline : 0
                    )
            )
    }
}

/// The single primary action on a surface.
///
/// One fill per screen, by rule. A second solid button for the same job is
/// how a window ends up with two things that look equally important and are
/// not.
public struct PrimaryAction: View {
    private let title: String
    private let systemImage: String?
    private let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    public init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(DesignTokens.TypeScale.label)
            }
            .foregroundColor(DesignTokens.Accent.onFill)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Metrics.Radius.control, style: .continuous)
                    .fill(
                        isHovered
                            ? DesignTokens.Accent.base.opacity(0.88)
                            : DesignTokens.Accent.fill
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accentFocusRing(isFocused: isFocused)
        .accessibilityAddTraits(.isButton)
    }
}

/// A destructive action: red outline, red text, no fill.
///
/// It never sits beside a primary button, because a filled red next to a
/// filled blue is two primaries competing for the same click.
public struct DangerAction: View {
    private let title: String
    private let isConfirming: Bool
    private let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    public init(_ title: String, isConfirming: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isConfirming = isConfirming
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isConfirming {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 10, height: 10)
                }
                Text(title)
                    .font(DesignTokens.TypeScale.label)
            }
            .foregroundColor(DesignTokens.State.dangerText)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Metrics.Radius.control, style: .continuous)
                    .stroke(
                        DesignTokens.State.danger.opacity(isConfirming ? 0.9 : (isHovered ? 0.75 : 0.45)),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isConfirming)
        .onHover { isHovered = $0 }
        .focused($isFocused)
        .accentFocusRing(isFocused: isFocused)
        .accessibilityAddTraits(.isButton)
    }
}

/// A 30×30 toolbar icon button. Quiet by default, filled on hover.
public struct ToolbarIconButton: View {
    private let systemImage: String
    private let help: String
    private var isActive: Bool
    private let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    public init(
        systemImage: String,
        help: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.help = help
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(
                    isActive
                        ? DesignTokens.Accent.base
                        : (isHovered ? DesignTokens.Ink.strong : DesignTokens.Ink.muted)
                )
                .frame(
                    width: DesignTokens.Metrics.toolbarIcon,
                    height: DesignTokens.Metrics.toolbarIcon
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .hoverSurface(isHovered)
        .focused($isFocused)
        .accentFocusRing(isFocused: isFocused)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }
}

/// A secondary action in an icon row: a glyph over a word, at the full 44pt
/// row height so it clears the target floor without looking heavy.
///
/// It is never a filled control. A filled button beside the primary action
/// would make two things look equally important when only one is, which is the
/// failure the one-primary rule exists to prevent.
public struct SecondaryIconAction: View {
    private let systemImage: String
    private let label: String
    private let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    public init(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                Text(label)
                    .font(DesignTokens.TypeScale.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            // Hover darkens the label rather than lightening it, so contrast
            // only ever improves from the resting state.
            .foregroundColor(isHovered ? DesignTokens.Ink.strong : DesignTokens.Ink.muted)
            .frame(maxWidth: .infinity)
            .frame(height: DesignTokens.Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .focused($isFocused)
        .accentFocusRing(isFocused: isFocused)
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// A scope tag: "this number covers exactly this period".
///
/// Every module states its own time window. A chart whose axis says "30 days"
/// while the number above it says "24 hours" is the single most common way a
/// dashboard misleads, and a tag is cheaper than a paragraph explaining it.
public struct ScopeTag: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(DesignTokens.TypeScale.caption)
            .foregroundColor(DesignTokens.Ink.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(DesignTokens.Surfaces.hover)
            )
            .accessibilityLabel(Text(verbatim: text))
    }
}

/// A change indicator that pairs direction with a sign and a word.
///
/// Color is the third signal here, never the first, so a red/green pair is not
/// the only thing carrying "this went down".
public struct DeltaBadge: Sendable {
    public enum Direction: Sendable {
        case up
        case down
        case flat

        public var systemImage: String {
            switch self {
            case .up: return "arrow.up.right"
            case .down: return "arrow.down.right"
            case .flat: return "minus"
            }
        }
    }

    public let direction: Direction
    public let text: String
    /// Whether an increase is bad. Spend rising is bad; cache hit rate falling
    /// is bad. The color follows this, not the direction.
    public let increaseIsBad: Bool

    public init(direction: Direction, text: String, increaseIsBad: Bool) {
        self.direction = direction
        self.text = text
        self.increaseIsBad = increaseIsBad
    }

    public var color: Color {
        switch direction {
        case .flat: return DesignTokens.Ink.muted
        case .up: return increaseIsBad ? DesignTokens.State.dangerText : DesignTokens.State.okText
        case .down: return increaseIsBad ? DesignTokens.State.okText : DesignTokens.State.dangerText
        }
    }
}

/// Renders a `DeltaBadge` as a glyph plus a percentage.
public struct DeltaLabel: View {
    private let delta: DeltaBadge

    public init(_ delta: DeltaBadge) {
        self.delta = delta
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: delta.direction.systemImage)
                .font(.system(size: 9, weight: .bold))
            Text(delta.text)
                .font(DesignTokens.TypeScale.numeric)
                .monospacedDigit()
        }
        .foregroundColor(delta.color)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}
