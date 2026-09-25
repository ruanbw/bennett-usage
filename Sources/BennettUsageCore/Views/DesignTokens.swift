import SwiftUI

/// The shared visual contract for all three native surfaces.
///
/// The values here are the OKLch tokens from `docs/ui-refactor/design-system.md`
/// resolved to sRGB, because SwiftUI has no `oklch()` initializer and an
/// NSColor-backed dynamic color has to be built from concrete channels. Each
/// token keeps its OKLch origin in a comment so the spec stays the source of
/// truth and the conversion can be re-verified.
///
/// Three roles, and they never overlap:
///
/// 1. **Interaction** — `Accent`. Anything the user can act on, and anything
///    that reports its own selection. Never a data mark.
/// 2. **State** — `Ok` / `Warn` / `Danger`. Whether the data can be trusted.
///    Never an identity.
/// 3. **Identity** — `AppTheme.Agent`. Which tool a row belongs to. Never a
///    selection or a state.
///
/// Magnitude — how much — is always an ink ramp derived from `ink`, never a
/// hue of its own. That rule is what stops one agent's amber from meaning
/// "Pi Agent" in a legend and "caution" in a warning bar at the same time.
///
/// A color that answers "is the data trustworthy?" is a state color. One that
/// answers "who is this?" is an identity color. One that answers "what am I
/// operating?" is the interaction color. Anything else is ink.
public enum DesignTokens {

    // MARK: - Ink

    /// The four-step ink ramp, used for magnitude and for every non-text mark.
    public enum Ink {
        /// Strongest. Headings, the trend line, a full-height bar.
        public static let strong = Color.dynamic(lightHex: "#1B2129", darkHex: "#EEF0F3")
        /// Default body and value text.
        public static let base = strong
        /// Secondary explanation, labels, units.
        public static let muted = Color.dynamic(lightHex: "#525963", darkHex: "#A3AAB2")
        /// A fill that is present but recedes. Unselected bars, empty tracks.
        public static let faint = Color.dynamic(
            lightHex: "#1B2129", darkHex: "#EEF0F3",
            lightAlpha: 0.16, darkAlpha: 0.20
        )
        /// The faintest usable mark. Heatmap level 0, gridlines.
        public static let ghost = Color.dynamic(
            lightHex: "#1B2129", darkHex: "#EEF0F3",
            lightAlpha: 0.07, darkAlpha: 0.09
        )
        /// The track behind a proportional mark.
        public static let track = Color.dynamic(
            lightHex: "#1B2129", darkHex: "#EEF0F3",
            lightAlpha: 0.09, darkAlpha: 0.12
        )
    }

    // MARK: - Surfaces

    public enum Surfaces {
        /// The window canvas. Everything else sits on it.
        public static let canvas = Color.dynamic(lightHex: "#F2F5F7", darkHex: "#0F1318")
        /// A module: card, panel, sheet.
        public static let module = Color.dynamic(lightHex: "#FFFFFF", darkHex: "#22272E")
        /// An inset well inside a module: the conclusion band, a grouped list.
        public static let inset = Color.dynamic(lightHex: "#F7F9FC", darkHex: "#22272E")
        /// Hover wash. Applied to a row or control, never to a text color.
        public static let hover = Color.dynamic(
            lightHex: "#1B2129", darkHex: "#EEF0F3",
            lightAlpha: 0.05, darkAlpha: 0.07
        )
        /// The one selected-row wash. Derived from the accent.
        public static let selected = Color.dynamic(lightHex: "#216CD3", darkHex: "#609EFA", lightAlpha: 0.12, darkAlpha: 0.20)
        /// An elevated transient: menu, popover, tooltip.
        public static let elevated = Color.dynamic(lightHex: "#FFFFFF", darkHex: "#2A2F36")
    }

    // MARK: - Lines

    /// Exactly two levels. A screen with three visible border weights has no
    /// hierarchy left, so shadows are never used to imply elevation.
    public enum Lines {
        /// A module boundary. `--line`. 1.30:1 light, 1.31:1 dark.
        public static let module = Color.dynamic(lightHex: "#DEE2E7", darkHex: "#353A41")
        /// A divider between two things inside one module. `--line-soft`.
        ///
        /// The dark value is `#32373E`, not the spec's `#292D33`: at `#292D33` it
        /// measured 1.09:1 against the `#22272E` module, under the 1.1:1 floor
        /// for a divider that has to be *perceptible* — invisible in practice.
        /// Hue and role are unchanged; only lightness moved enough to clear it.
        public static let soft = Color.dynamic(lightHex: "#E8EBEF", darkHex: "#32373E")
    }

    // MARK: - Interaction

    public enum Accent {
        /// `oklch(0.545 0.175 258)` / `oklch(0.700 0.150 258)`. 5.06:1 on a
        /// light module, 6.15:1 on a dark one.
        public static let base = Color.dynamic(lightHex: "#216CD3", darkHex: "#609EFA")
        /// The fill behind a selected segment or a primary button.
        public static let fill = base
        /// A selected row's background.
        public static let wash = Surfaces.selected
        /// The ring around a focused control. 2pt at 2pt offset, never removed.
        public static let ring = base
        /// Foreground on `Accent.fill`.
        ///
        /// This is not `Color.white` in both appearances. The light accent is
        /// dark enough for white text at 5.06:1; the dark accent is a light
        /// blue where white text drops to 2.69:1. Dark text on the dark accent
        /// measures 7.60:1, so the fill carries near-black ink in dark mode.
        public static let onFill = Color.dynamic(lightHex: "#FFFFFF", darkHex: "#0B0F14")
        /// A hairline accent border, for a selected chip that must not hide its
        /// identity dot.
        public static let edge = Color.dynamic(lightHex: "#216CD3", darkHex: "#609EFA", lightAlpha: 0.55, darkAlpha: 0.70)
    }

    // MARK: - State

    /// Colors that mean "can this data be trusted". A state color never
    /// identifies a tool and never marks a value as merely large or small.
    public enum State {
        /// `oklch(0.575 0.125 162)`. 4.11:1 on a light module — see `okText`.
        public static let ok = Color.dynamic(lightHex: "#058F62", darkHex: "#4EC491")
        /// `oklch(0.665 0.145 68)`. 3.15:1 on a light module — see `warnText`.
        public static let warn = Color.dynamic(lightHex: "#CD8004", darkHex: "#ECA84A")
        /// `oklch(0.565 0.185 25)`. 5.00:1 light, 5.75:1 dark.
        public static let danger = Color.dynamic(lightHex: "#CC3839", darkHex: "#F46F68")

        /// `--ok-text`. The base green converges 8% toward `--fg` to clear
        /// 4.5:1 as body text (4.56:1). Use this for any `ok` that is read as
        /// words; `ok` itself stays for a dot, a ring arc and a bar.
        public static let okText = Color.dynamic(lightHex: "#00875A", darkHex: "#4EC491")
        /// `--warn-text`. Amber needs a 22% convergence to clear 4.5:1
        /// (4.55:1) because its hue is inherently light.
        public static let warnText = Color.dynamic(lightHex: "#AE6400", darkHex: "#ECA84A")
        /// `--danger-text`. The base red already clears 4.5:1, so this is the
        /// same value, named so call sites read consistently.
        public static let dangerText = danger

        /// A stale or degraded surface: a warning tint that stays legible.
        public static let warnSurface = Color.dynamic(lightHex: "#CD8004", darkHex: "#ECA84A", lightAlpha: 0.10, darkAlpha: 0.16)
        /// An error surface, for an alert bar that must not shout.
        public static let dangerSurface = Color.dynamic(lightHex: "#CC3839", darkHex: "#F46F68", lightAlpha: 0.10, darkAlpha: 0.16)
    }

    // MARK: - Type ramp

    /// SF Pro Display for display type, SF Pro Text for prose, SF Mono with
    /// tabular figures for every number.
    ///
    /// A macOS-native tool does not take a serif, and one family for everything
    /// is only acceptable in a data-dense grid — the dashboard mixes prose
    /// labels with large readouts, so it keeps the text/display split.
    ///
    /// Named `TypeScale` rather than `Type`: the latter is reserved by Swift's
    /// `foo.Type` metatype expression.
    public enum TypeScale {
        /// The period total. 50pt, dynamic.
        public static let display = Font.system(size: 50, weight: .bold, design: .default)
        /// A section's leading figure. 34pt.
        public static let title = Font.system(size: 34, weight: .semibold, design: .default)
        /// The popover's total. 34pt in a 360pt surface.
        public static let popoverTotal = Font.system(size: 34, weight: .bold, design: .default)
        /// A module heading. 17pt.
        public static let heading = Font.system(size: 17, weight: .semibold)
        /// A value inside a metric cell. 15pt.
        public static let value = Font.system(size: 15, weight: .semibold)
        /// Body copy. 15pt.
        public static let body = Font.system(size: 15)
        /// A label or a secondary row. 13pt.
        public static let label = Font.system(size: 13, weight: .medium)
        /// A caption, an axis marker, a unit. 11.5pt.
        public static let caption = Font.system(size: 11.5)
        /// A tracked micro-label that introduces a region.
        public static let eyebrow = Font.system(size: 11.5, weight: .semibold)
        /// Any number, unit or code fragment. Tabular so columns do not jitter.
        public static let numeric = Font.system(size: 13, weight: .medium, design: .monospaced)
        public static let numericLarge = Font.system(size: 17, weight: .semibold, design: .monospaced)
        public static let numericDisplay = Font.system(size: 50, weight: .bold, design: .monospaced)
    }

    // MARK: - Metrics

    /// An 8pt baseline. Every gap in the product is a multiple of it.
    public enum Metrics {
        /// Window inset.
        public static let windowPadding: CGFloat = 20
        /// Gap between two modules.
        public static let moduleGap: CGFloat = 14
        /// Module inner padding.
        public static let modulePadding: CGFloat = 16
        public static let modulePaddingTight: CGFloat = 14
        /// Minimum tappable height.
        public static let rowHeight: CGFloat = 44
        /// Toolbar icon target.
        public static let toolbarIcon: CGFloat = 30
        /// A single border weight. Two exist, and only two.
        public static let hairline: CGFloat = 0.5

        public enum Radius {
            /// A control: a segment, a chip, an icon button.
            public static let control: CGFloat = 6
            /// A module.
            public static let module: CGFloat = 10
            /// The conclusion band, a sheet, a popover.
            public static let band: CGFloat = 14
        }
    }

    // MARK: - Motion

    /// Every duration, in one place, so the whole product decelerates together.
    public enum Motion {
        /// Hover. Only background and border transition — never offset, never
        /// shadow, because a moving row is a moving target.
        public static let hover: Double = 0.12
        /// A number changing to another number.
        public static let numeric: Double = 0.18
        /// The cache ring sweeping to a new value.
        public static let ring: Double = 0.52

        /// Animations collapse to zero under Reduce Motion rather than being
        /// swapped for a different effect, so nothing surprising appears.
        public static func duration(_ value: Double, reduceMotion: Bool) -> Double {
            reduceMotion ? 0 : value
        }
    }
}
