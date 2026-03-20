import ApplicationServices

// MARK: - Deprecated Carbon API re-declaration
// GetProcessForPID was removed from Swift but still exists as a symbol.
@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

// MARK: - SkyLight private API declarations
// Used for reliable app activation from LSUIElement background apps.
// NSRunningApplication.activate() is unreliable on macOS 14+ due to cooperative activation.
// _SLPSSetFrontProcessWithOptions communicates directly with WindowServer, bypassing AppKit.
// Reference: alt-tab-macos, sorrycc/HotApp blog

enum SLPSMode: UInt32 {
    case allWindows = 0x100
    case userGenerated = 0x200
    case noWindows = 0x400
}

@_silgen_name("_SLPSSetFrontProcessWithOptions") @discardableResult
func _SLPSSetFrontProcessWithOptions(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
    _ wid: CGWindowID,
    _ mode: SLPSMode.RawValue
) -> CGError

@_silgen_name("SLPSPostEventRecordTo") @discardableResult
func SLPSPostEventRecordTo(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
    _ bytes: UnsafeMutablePointer<UInt8>
) -> CGError
