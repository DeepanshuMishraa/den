import Foundation

/// How the cursor blinks: solid for a pause after typing or output, then
/// half a cycle on and half off, easing between the two. Each part is a
/// preset picked in the palette's Cursor Blinking page.
struct CursorBlink: Equatable {
    /// One on-and-off cycle.
    enum Speed: String, CaseIterable {
        case slow, normal, fast, veryFast

        var seconds: TimeInterval {
            switch self {
            case .slow: 1.6
            // As macOS text fields blink.
            case .normal: 1.06
            case .fast: 0.7
            case .veryFast: 0.5
            }
        }

        var title: String {
            switch self {
            case .slow: "Slow"
            case .normal: "Normal"
            case .fast: "Fast"
            case .veryFast: "Very Fast"
            }
        }
    }

    /// Each fade, out and back in.
    enum Transition: String, CaseIterable {
        case instant, quick, smooth, gentle

        var seconds: TimeInterval {
            switch self {
            case .instant: 0
            case .quick: 0.08
            case .smooth: 0.15
            case .gentle: 0.3
            }
        }

        var title: String {
            switch self {
            case .instant: "Instant"
            case .quick: "Quick"
            case .smooth: "Smooth"
            case .gentle: "Gentle"
            }
        }
    }

    /// How long the cursor stays solid after activity, so it's easy to find.
    enum Pause: String, CaseIterable {
        case none, short, normal, long

        var seconds: TimeInterval {
            switch self {
            case .none: 0
            case .short: 0.3
            case .normal: 0.6
            case .long: 1.2
            }
        }

        var title: String {
            switch self {
            case .none: "None"
            case .short: "Short"
            case .normal: "Normal"
            case .long: "Long"
            }
        }
    }

    var speed = Speed.normal
    var transition = Transition.smooth
    var pause = Pause.normal

    /// "Normal · Smooth", for the palette.
    var summary: String { "\(speed.title) · \(transition.title)" }

    /// 1 solid, 0 hidden. Without `fades` (Reduce Motion) it switches.
    func opacity(sinceActivity t: TimeInterval, fades: Bool) -> Float {
        guard t >= pause.seconds else { return 1 }
        let period = speed.seconds
        let half = period / 2
        let phase = (t - pause.seconds).truncatingRemainder(dividingBy: period)
        // A fade never outlasts the half cycle it eases into.
        let fade = fades ? min(transition.seconds, half) : 0
        guard fade > 0 else { return phase < half ? 1 : 0 }
        func ease(_ x: Double) -> Float { Float(x * x * (3 - 2 * x)) }
        switch phase {
        case ..<(half - fade): return 1
        case ..<half: return ease((half - phase) / fade)
        case ..<(period - fade): return 0
        default: return ease((phase - (period - fade)) / fade)
        }
    }
}
