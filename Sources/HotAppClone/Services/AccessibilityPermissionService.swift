import ApplicationServices

struct AccessibilityPermissionService {
    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestIfNeeded(prompt: Bool = true) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
