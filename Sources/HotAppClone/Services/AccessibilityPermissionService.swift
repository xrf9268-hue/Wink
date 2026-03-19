import IOKit

struct AccessibilityPermissionService: Sendable {
    func isTrusted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    func requestIfNeeded(prompt: Bool = true) -> Bool {
        let status = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if status == kIOHIDAccessTypeGranted {
            return true
        }
        if prompt && status != kIOHIDAccessTypeDenied {
            return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        return false
    }
}
