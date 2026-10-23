import Foundation
import DenProtocol
#if os(macOS)
import CoreGraphics
#endif

extension HostPermissions {
    /// This process's grants, checked without showing any prompt.
    static func probe() -> HostPermissions {
        #if os(macOS)
        HostPermissions(fullDiskAccess: fullDiskAccess(), screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .missing)
        #else
        HostPermissions(fullDiskAccess: .notApplicable, screenRecording: .notApplicable)
        #endif
    }

    static func requestScreenRecording() {
        #if os(macOS)
        _ = CGRequestScreenCaptureAccess()
        #endif
    }

    #if os(macOS)
    /// The privacy database opens only with Full Disk Access, and trying
    /// never prompts. access(2) can't tell: privacy checks happen at open.
    private static func fullDiskAccess() -> Access {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.TCC/TCC.db").path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return .missing }
        close(fd)
        return .granted
    }
    #endif
}
