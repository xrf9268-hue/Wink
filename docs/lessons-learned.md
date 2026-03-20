# 真机验证经验教训

在 macOS 15.3.1 (Sequoia) 上完成 Quickey 真机验证过程中积累的关键经验。

---

## 1. CGEvent Tap 需要双权限

**现象：** `AXIsProcessTrusted()` 返回 true，但 `CGEvent.tapCreate()` 仍然失败（`.defaultTap` 和 `.listenOnly` 都失败）。

**根因：** macOS 15 上，CGEvent tap 同时需要 **Accessibility（辅助功能）** 和 **Input Monitoring（输入监控）** 两种权限。单独只有 Accessibility 不够。

**解决方案：**
```swift
// 检查时两者都要检查
func isTrusted() -> Bool {
    AXIsProcessTrusted() && CGPreflightListenEventAccess()
}

// 请求时两者都要请求
func requestIfNeeded(prompt: Bool = true) -> Bool {
    let axGranted = AXIsProcessTrustedWithOptions(
        ["AXTrustedCheckOptionPrompt" as CFString: prompt] as CFDictionary
    )
    let imGranted = CGPreflightListenEventAccess() || (prompt && CGRequestListenEventAccess())
    return axGranted && imGranted
}
```

**教训：** 不要盲目相信第三方项目（alt-tab-macos）的实验结论，必须在目标 macOS 版本上实测验证。

---

## 2. Ad-hoc 签名导致权限每次重建后失效

**现象：** 系统设置里 Quickey 开关是蓝色（已开启），但 `AXIsProcessTrusted()` 返回 false。

**根因：** macOS TCC 数据库将权限绑定到 code signature。每次 `swift build` 生成的 ad-hoc 签名不同，旧的权限记录不再匹配新的二进制。

**解决方案：**
```bash
# 开发阶段：重建后重置权限，再重新授权
tccutil reset Accessibility com.quickey.app
tccutil reset ListenEvent com.quickey.app
```

**生产环境：** 使用 Developer ID 证书签名，签名稳定，权限不会因更新而失效。

---

## 3. App 启动方式影响 TCC 权限匹配

**现象：** 通过命令行直接运行 `./Quickey.app/Contents/MacOS/Quickey` 时权限检查返回 true，但 Refresh 按钮点击后仍显示未授权。通过 `open Quickey.app` 启动后一切正常。

**解决方案：** 测试权限相关功能时，始终用 `open xxx.app` 方式启动。

---

## 4. NSLog/os_log 在 macOS 统一日志系统中被过滤

**现象：** `log show` 和 `log stream` 命令完全看不到 NSLog 和 Logger 的输出，无法调试。

**解决方案：** 调试阶段使用文件日志：
```swift
static let debugLogPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/Quickey/debug.log").path

static func debugLog(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: debugLogPath)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    if let handle = FileHandle(forWritingAtPath: debugLogPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: debugLogPath, contents: data)
    }
}
```

**注意：** `FileManager.createFile` 不会自动创建中间目录，必须先调用 `createDirectory(withIntermediateDirectories: true)`。

---

## 5. @Sendable 闭包与 @MainActor 隔离

**现象：** `NSWorkspace.shared.openApplication` 的 completion handler 在后台队列 `com.apple.launchservices.open-queue` 上回调，导致 `_dispatch_assert_queue_fail` 崩溃。

**根因：** `@MainActor` 类中的闭包默认继承 actor 隔离。completion handler 在非主线程回调时触发断言。

**解决方案：**
```swift
// ❌ 错误 — shortcut 从 @MainActor 上下文捕获
NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
    logger.error("Failed: \(shortcut.bundleIdentifier)")
}

// ✅ 正确 — 提前提取值，标记 @Sendable
let bundleId = shortcut.bundleIdentifier
NSWorkspace.shared.openApplication(at: url, configuration: config) { @Sendable app, error in
    logger.error("Failed: \(bundleId)")
}
```

---

## 6. SkyLight 私有 API 解决 App 激活问题

**现象：** `NSRunningApplication.activate()` 从 LSUIElement 后台应用调用时，macOS 14+ 的协作激活模型导致其不可靠（返回 true 但 app 不到前台）。

**解决方案：** 使用 SkyLight 私有 API 直接与 WindowServer 通信：
```swift
var psn = ProcessSerialNumber()
GetProcessForPID(pid, &psn)
_SLPSSetFrontProcessWithOptions(&psn, 0, SLPSMode.userGenerated.rawValue)
```

需要在 Package.swift 中链接 SkyLight：
```swift
linkerSettings: [
    .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])
]
```

---

## 总结

| 问题 | 浪费时间 | 根因 |
|------|---------|------|
| 权限弹窗不出来 | 高 | 用错了 API（Input Monitoring vs Accessibility） |
| Event tap 创建失败 | 高 | 只授予一种权限，实际需要两种 |
| 权限授了但不生效 | 中 | ad-hoc 签名变化导致 TCC 记录失配 |
| 完全看不到日志 | 中 | 依赖 NSLog，系统日志过滤 |
| App 激活不了 | 中 | NSRunningApplication.activate 不可靠 |
| 启动崩溃 | 低 | @Sendable 闭包隔离 |
