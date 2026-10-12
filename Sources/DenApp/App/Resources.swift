import Foundation

extension Bundle {
    /// DenApp's SwiftPM resource bundle. In Den.app, scripts/bundle.sh puts it
    /// in Contents/Resources, which SwiftPM's `Bundle.module` never searches:
    /// it checks next to Den.app and then the build machine's .build path, and
    /// traps when neither exists (any app built on another machine, e.g. CI).
    /// `Bundle.module` stays the fallback for `swift run`.
    static let denResources: Bundle = {
        if let url = Bundle.main.resourceURL?.appending(path: "Den_DenApp.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}
