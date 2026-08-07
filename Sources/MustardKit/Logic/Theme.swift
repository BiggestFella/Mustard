import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

extension Color {
    init(hex: String) {
        let s = Scanner(string: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex)
        var rgb: UInt64 = 0
        s.scanHexInt64(&rgb)
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

/// "Things 3 calm" design language, locked 2026-06-12; expanded to the full
/// 2026-redesign token set 2026-07-01 (BAK-98). Source of truth:
/// `docs/design/redesign-2026/README.md` ("Design tokens"). Views must read from
/// here rather than hardcoding handoff hex. Every value below is the exact hex from
/// the handoff so existing surfaces render identically.
public enum Theme {
    public enum Palette {
        // MARK: Surfaces
        public static let bg = Color(hex: "#FBFAF7")            // app / card
        public static let surface = Color(hex: "#EFEBE2")
        public static let titleBar = Color(hex: "#F4F1EA")     // title bar / panels
        public static let sidebar = Color(hex: "#F7F4ED")
        public static let chipActive = Color(hex: "#EAE5DB")
        public static let chipActiveBorder = Color(hex: "#DAD3C6") // active area-chip stroke (Board)
        public static let navActive = Color(hex: "#EDE9E0")
        public static let hairline = Color(hex: "#E7E3DA")     // borders are 0.5px
        public static let divider = Color(hex: "#E1DCD1")      // secondary divider

        // MARK: Text
        public static let textPrimary = Color(hex: "#2B2A26")
        public static let textSecondary = Color(hex: "#9A968B")
        public static let textTertiary = Color(hex: "#B0ACA1")
        public static let textFaint = Color(hex: "#C0BCB1")    // column counts, quick-add chrome — near but distinct from textTertiary
        public static let textMuted = Color(hex: "#A6A296")    // completed title
        public static let strikethrough = Color(hex: "#C8C3B7")
        /// `==highlight==` span background — Craft-style soft mark (Phase 4 /
        /// BAK-253, format toolbar).
        public static let highlightBg = Color(hex: "#FBF1C7")
        public static let onSurface = Color(hex: "#46433B")
        public static let onSurfaceSoft = Color(hex: "#5C584E")

        // MARK: Accent (you) / agent (purple)
        public static let accent = Color(hex: "#2D7FF9")
        public static let agent = Color(hex: "#7F77DD")
        public static let agentText = Color(hex: "#6A61C9")
        public static let agentTextDeep = Color(hex: "#534AB7")  // deeper purple fg — action-label chips/pills (Board/AgentConsole)
        public static let agentMid = Color(hex: "#8079C6")
        public static let agentTintLight = Color(hex: "#EEEBFA")
        public static let agentTintMid = Color(hex: "#CFC9F0")
        public static let agentTintStrong = Color(hex: "#BCB6EC")
        public static let agentTintFaint = Color(hex: "#F3F1FA")
        public static let agentTintBorder = Color(hex: "#E2DCF4") // review-queue toggle capsule stroke
        public static let agentTintOnDark = Color(hex: "#B9B2F0") // agent accent for text on dark chrome (mobile undo toast)
        public static let ownerTabInactive = Color(hex: "#BBB6AA")

        // MARK: Done (green) / review
        public static let done = Color(hex: "#1D9E75")
        public static let reviewText = Color(hex: "#1B7A57")
        public static let reviewBg = Color(hex: "#E3F2EB")
        public static let doneAccent = Color(hex: "#9BD0BD")    // done column accent
        public static let doneHead = Color(hex: "#6A9C84")      // done column header

        // MARK: Warn (amber)
        public static let warning = Color(hex: "#D98A29")       // overdue / needs-attention
        public static let warnText = Color(hex: "#B07A29")
        public static let warnTintSoft = Color(hex: "#FBF1E2")  // amber pill bg (needs-action)
        public static let warnTintBorder = Color(hex: "#EFE2C9") // amber hand-off banner divider
        public static let warningSoft = Color(hex: "#FAEEDA")   // amber pill background (needs-you badge)
        public static let warningDeep = Color(hex: "#633806")   // amber pill text (needs-you badge)

        // MARK: Error / destructive
        public static let error = Color(hex: "#D85A30")          // error text + destructive action

        // "Now" marker for the Today spine. A warm coral that is neither accent-blue nor
        // agent-purple, so "the present moment" never competes with an owner colour.
        // Sanctioned single-accent exception (see ADR-0005), like the notch's dark surface.
        public static let now = Color(hex: "#D85A30")       // now dot + label
        public static let nowLine = Color(hex: "#F0997B")   // lighter now rule

        // MARK: Muted status pill
        public static let statusMutedText = Color(hex: "#8A8579")
        public static let statusMutedBg = Color(hex: "#F1EDE4")

        // MARK: Confidence
        public static let confidenceHigh = done                 // ≥0.7
        public static let confidenceMedium = Color(hex: "#BA7517") // ≥0.5
        public static let confidenceLow = Color(hex: "#D85A30")    // else
        public static let confidenceUnfilled = Color(hex: "#E4DFD5")

        // MARK: Priority
        public static let priorityHighText = Color(hex: "#A8502E")
        public static let priorityHighBg = Color(hex: "#F7E4D8")
        public static let priorityUrgentText = Color.white
        public static let priorityUrgentBg = Color(hex: "#C2603F")

        // MARK: Area dots (handoff per-list intent)
        public static let areaBlue = Color(hex: "#2D7FF9")      // DLA SDK
        public static let areaGreen = Color(hex: "#3E8E7E")     // Admin
        public static let areaPurple = Color(hex: "#7F77DD")    // Errands
        public static let areaGrey = Color(hex: "#B0ACA1")      // Reading
        /// Raw hex twin of `areaGrey` — for call sites that need a `String` fallback
        /// default (e.g. `Area.colorHex` when a list has no area) rather than a `Color`.
        public static let areaGreyHex = "#B0ACA1"

        // MARK: Load / capacity (Week — mobile day-load dots)
        public static let loadEmptyDot = Color(hex: "#D8D3C8") // no scheduled load
    }

    // MARK: Confidence tiers — single source of truth (BAK-98)

    /// Canonical confidence tiers. ≥0.7 high, ≥0.5 medium, else low. Pure + testable;
    /// `confidenceColor(_:)` maps a tier to its palette colour. Unifies the previously
    /// divergent ≥0.4 cutoff in the console/rec-detail with the board card's ≥0.5.
    public enum ConfidenceTier { case high, medium, low }

    public static func confidenceTier(_ c: Double) -> ConfidenceTier {
        if c >= 0.7 { return .high }
        if c >= 0.5 { return .medium }
        return .low
    }

    public static func confidenceColor(_ c: Double) -> Color {
        switch confidenceTier(c) {
        case .high: return Palette.confidenceHigh
        case .medium: return Palette.confidenceMedium
        case .low: return Palette.confidenceLow
        }
    }

    // MARK: Source badges — centralised map (handoff "Source badges")

    public struct SourceBadge {
        public let label: String
        public let icon: String
        public let fg: Color
        public let bg: Color
    }

    /// Badge for a task/recommendation source, or nil for manual (no badge).
    /// `vault` and any unrecognised harvested source map to the KB grey badge.
    public static func sourceBadge(for source: String?) -> SourceBadge? {
        switch source {
        case "gmail":   return SourceBadge(label: "Gmail",  icon: "✉",  fg: Color(hex: "#A8442E"), bg: Color(hex: "#FBEAE4"))
        case "xero":    return SourceBadge(label: "Xero",   icon: "$",  fg: Color(hex: "#1B6FA8"), bg: Color(hex: "#E4F0FA"))
        case "meeting": return SourceBadge(label: "Notes",  icon: "◷",  fg: Palette.agentText,      bg: Palette.agentTintLight)
        case "slack":   return SourceBadge(label: "Slack",  icon: "#",  fg: Color(hex: "#6A4FA0"), bg: Color(hex: "#EFEAF7"))
        case "linear":  return SourceBadge(label: "Linear", icon: "◐",  fg: Color(hex: "#54599A"), bg: Color(hex: "#ECEDF7"))
        case "manual":  return nil
        default:        return SourceBadge(label: "KB",     icon: "📚", fg: Color(hex: "#7B776C"), bg: Color(hex: "#F1EDE4"))
        }
    }

    // MARK: Motion — canonical animation tokens: one feel across the app (desktop + iOS)

    /// Default CSS-style easings are too weak to feel intentional; these curves
    /// (per Emil Kowalski's animation-eng skill) give entrances/exits a punch.
    /// Use `easeOut` for anything entering/exiting, `easeInOut` for on-screen
    /// morphing, `drag` for gesture-driven/interruptible motion (springs preserve
    /// velocity when interrupted; keyframe curves don't), and the `settle`/`expand`/
    /// `pop` state springs for discrete UI state changes.
    public enum Motion {
        public static func easeOut(_ duration: Double = 0.2) -> Animation {
            .timingCurve(0.23, 1, 0.32, 1, duration: duration)
        }

        public static func easeInOut(_ duration: Double = 0.2) -> Animation {
            .timingCurve(0.77, 0, 0.175, 1, duration: duration)
        }

        /// Gesture tracking a finger (drag snap-back, cancel).
        public static let drag = Animation.spring(response: 0.32, dampingFraction: 0.7)

        /// Small state changes settling into place (hover lift, selection, list reflow).
        public static let settle = Animation.snappy(duration: 0.16)
        /// Content expanding or collapsing (drawers, disclosure, trays).
        public static let expand = Animation.snappy(duration: 0.18)
        /// Menus and popovers arriving (slash menu, ⌘K).
        public static let pop = Animation.spring(duration: 0.22)
    }

    public enum Fonts {
        public static let body = Font.system(size: 15)
        public static let title = Font.system(size: 15, weight: .medium)
        public static let meta = Font.system(size: 13)
        public static let gutter = Font.system(size: 13)
        public static let header = Font.system(size: 22, weight: .medium)

        // Chrome micro-text — count badges, capsule labels, inline icons. Weighted
        // variants chain `.weight(_:)` off these (e.g. `Fonts.caption.weight(.medium)`)
        // rather than re-declaring a size, so every call site stays byte-identical
        // to the literal `.system(size:...)` it replaces.
        public static let caption = Font.system(size: 11)
        public static let label = Font.system(size: 11.5)

        // Editorial scale (Craft pass Phase 0, spec 2026-07-06) — long-form
        // note/output content. The chrome tokens above stay for lists and controls.
        public static let docTitle = Font.system(size: 33, weight: .semibold)
        public static let docH1 = Font.system(size: 22, weight: .semibold)
        public static let docH2 = Font.system(size: 18, weight: .semibold)
        public static let reading = Font.system(size: 16)
    }

    // MARK: Elevation — depth recipes (Craft pass Phase 0, spec 2026-07-06)

    /// Three named shadow recipes. Applied via the `.elevation(_:cornerRadius:)`
    /// View extension below so background, clip, border, and shadow always travel
    /// together — no view hand-rolls a shadow, and a surface can swap levels
    /// (e.g. card → float on hover) without re-deriving any part.
    public enum Elevation {
        /// Resting card — board cards, recommendation rows, callouts.
        case card
        /// Lifted — hover state, open-editor feel.
        case float
        /// Highest — menus and popovers.
        case pop

        var shadowOpacity: Double {
            switch self {
            case .card: return 0.05
            case .float: return 0.10
            case .pop: return 0.14
            }
        }

        var shadowRadius: CGFloat {
            switch self {
            case .card: return 14
            case .float: return 24
            case .pop: return 28
            }
        }

        var shadowY: CGFloat {
            switch self {
            case .card: return 4
            case .float: return 10
            case .pop: return 12
            }
        }
    }

    // MARK: Metrics — radius scale (codifies the hand-used 6/7/10/12)

    public enum Metrics {
        public static let rSm: CGFloat = 6    // chips, small fields
        public static let rMd: CGFloat = 7    // list rows, inputs
        public static let rLg: CGFloat = 10   // cards, banners
        public static let rXl: CGFloat = 12   // sheets, popovers
    }
}

#if canImport(AppKit)
extension Theme {
    // MARK: AppKit companions (Craft pass Phase 2a) — for the NSTextView editing
    // surface (MarkdownTextView), which styles via NSTextStorage attributes and so
    // needs NSColor/NSFont. Every value is BRIDGED from the Palette/Fonts tokens
    // above — never fresh hex, never fresh sizes.

    public enum NSPalette {
        public static let bg = NSColor(Palette.bg)
        public static let surface = NSColor(Palette.surface)
        public static let hairline = NSColor(Palette.hairline)
        public static let textPrimary = NSColor(Palette.textPrimary)
        public static let textTertiary = NSColor(Palette.textTertiary)
        public static let accent = NSColor(Palette.accent)
        public static let strikethrough = NSColor(Palette.strikethrough)
        public static let highlightBg = NSColor(Palette.highlightBg)
    }

    /// NSFont equivalents of the editorial scale plus the editor-only variants
    /// (markers, code, emphasis) the SwiftUI token set has no reason to carry.
    public enum NSFonts {
        public static let reading = NSFont.systemFont(ofSize: 16)                       // Fonts.reading
        public static let readingBold = NSFont.boldSystemFont(ofSize: 16)
        public static let readingItalic: NSFont = {
            let base = NSFont.systemFont(ofSize: 16)
            let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
            return NSFont(descriptor: descriptor, size: 16) ?? base
        }()
        public static let docH1 = NSFont.systemFont(ofSize: 22, weight: .semibold)      // Fonts.docH1
        public static let docH2 = NSFont.systemFont(ofSize: 18, weight: .semibold)      // Fonts.docH2
        /// h3+ — matches the preview's 15.5pt sub-heading size.
        public static let docH3 = NSFont.systemFont(ofSize: 15.5, weight: .semibold)
        /// De-emphasized syntax markers ("**", "#", "[["…).
        public static let marker = NSFont.systemFont(ofSize: 12)
        public static let code = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        /// The visible-but-quiet YAML frontmatter block.
        public static let frontmatter = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }
}
#endif

extension View {
    /// Applies an elevation recipe as one unit: `bg` card ground, rounded clip,
    /// faint hairline border, and the level's soft shadow. Every card surface in
    /// this pass sits on `Theme.Palette.bg`; parameterise the ground the day a
    /// non-bg card needs depth.
    public func elevation(
        _ level: Theme.Elevation, cornerRadius: CGFloat = Theme.Metrics.rLg
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        return background(Theme.Palette.bg, in: shape)
            .clipShape(shape)
            .overlay(shape.stroke(Theme.Palette.hairline, lineWidth: 0.5))
            .shadow(
                color: .black.opacity(level.shadowOpacity),
                radius: level.shadowRadius, x: 0, y: level.shadowY
            )
    }
}
