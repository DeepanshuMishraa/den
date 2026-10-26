import Testing
@testable import DenApp

@Suite struct InterfaceStyleTests {
    @Test func usesRexStyles() {
        #expect(InterfaceStyle.allCases.map(\.rawValue) == ["glass", "classic"])
        #expect(InterfaceStyle.allCases.map(\.title) == ["Glass", "Classic"])
    }

    @Test func acceptsRetiredStoredValues() {
        #expect(InterfaceStyle(stored: "glass") == .glass)
        #expect(InterfaceStyle(stored: "classic") == .classic)
        #expect(InterfaceStyle(stored: "modern") == .glass)
        #expect(InterfaceStyle(stored: "blendTheme") == .glass)
        #expect(InterfaceStyle(stored: "blended") == .glass)
        #expect(InterfaceStyle(stored: "system") == .classic)
        #expect(InterfaceStyle(stored: "useTheme") == .classic)
        #expect(InterfaceStyle(stored: "themed") == .classic)
        #expect(InterfaceStyle(stored: "unknown") == nil)
    }

    /// Rex's retired styles are the two current styles with a known tint.
    @Test func retiredStylesCarryTheirThemeTint() {
        #expect(InterfaceStyle.storedThemeTint("modern") == false)
        #expect(InterfaceStyle.storedThemeTint("system") == false)
        #expect(InterfaceStyle.storedThemeTint("useTheme") == true)
        #expect(InterfaceStyle.storedThemeTint("blendTheme") == true)
        #expect(InterfaceStyle.storedThemeTint("themed") == true)
        #expect(InterfaceStyle.storedThemeTint("blended") == true)
        #expect(InterfaceStyle.storedThemeTint("glass") == nil)
        #expect(InterfaceStyle.storedThemeTint("classic") == nil)
        #expect(InterfaceStyle.storedThemeTint("unknown") == nil)
    }

    @Test func backdropFollowsStyleAndTint() {
        #expect(InterfaceStyle.glass.backdrop(themeTint: true) == .glass)
        #expect(InterfaceStyle.glass.backdrop(themeTint: false) == .glass)
        #expect(InterfaceStyle.classic.backdrop(themeTint: true) == .none)
        #expect(InterfaceStyle.classic.backdrop(themeTint: false) == .system)
    }
}
