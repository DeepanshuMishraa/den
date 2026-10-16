import Testing
@testable import DenApp

@Suite struct CursorBlinkTests {
    private let standard = CursorBlink()

    @Test func solidThroughThePauseAfterActivity() {
        #expect(standard.opacity(sinceActivity: 0, fades: true) == 1)
        #expect(standard.opacity(sinceActivity: standard.pause.seconds - 0.01, fades: true) == 1)
        // No pause: blinks straight away (fades out at the end of the first half).
        let eager = CursorBlink(pause: .none)
        #expect(eager.opacity(sinceActivity: eager.speed.seconds / 2 + 0.05, fades: true) == 0)
    }

    @Test func onThenFadesOutThenOffThenFadesIn() {
        let start = standard.pause.seconds, period = standard.speed.seconds, half = period / 2, fade = standard.transition.seconds
        #expect(standard.opacity(sinceActivity: start + 0.1, fades: true) == 1)
        let fadingOut = standard.opacity(sinceActivity: start + half - fade / 2, fades: true)
        #expect(fadingOut > 0 && fadingOut < 1)
        #expect(standard.opacity(sinceActivity: start + half + 0.1, fades: true) == 0)
        let fadingIn = standard.opacity(sinceActivity: start + period - fade / 2, fades: true)
        #expect(fadingIn > 0 && fadingIn < 1)
        #expect(standard.opacity(sinceActivity: start + period + 0.1, fades: true) == 1)
    }

    /// Each speed's cycle is its own: off exactly in the second half.
    @Test func speedSetsTheCycle() {
        for speed in CursorBlink.Speed.allCases {
            let blink = CursorBlink(speed: speed, transition: .instant, pause: .none)
            #expect(blink.opacity(sinceActivity: speed.seconds * 0.25, fades: true) == 1)
            #expect(blink.opacity(sinceActivity: speed.seconds * 0.75, fades: true) == 0)
        }
    }

    /// Instant and Reduce Motion: on or off, never in between.
    @Test func instantAndReduceMotionNeverFade() {
        let instant = CursorBlink(transition: .instant)
        for step in stride(from: 0.0, to: 4, by: 0.01) {
            for value in [instant.opacity(sinceActivity: step, fades: true), standard.opacity(sinceActivity: step, fades: false)] {
                #expect(value == 0 || value == 1)
            }
        }
    }

    /// A gentle fade on a very fast blink still reaches fully off.
    @Test func fadesNeverOutlastHalfACycle() {
        let blink = CursorBlink(speed: .veryFast, transition: .gentle, pause: .none)
        let values = stride(from: 0.0, to: 2, by: 0.005).map { blink.opacity(sinceActivity: $0, fades: true) }
        #expect(values.contains(0) && values.contains(1))
    }
}
