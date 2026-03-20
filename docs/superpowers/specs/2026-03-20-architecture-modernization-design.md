# Architecture Modernization: @Observable + ViewModel 拆分 + 协议抽象

**Date:** 2026-03-20
**Status:** Draft
**Inspired by:** CodexBar (steipete/CodexBar) 的 UsageStore/SettingsStore 分离、@Observable 模式

## Background

Quickey 是一个 feature-complete 的 macOS menu bar 工具（~35 源文件，单 SPM target，零外部依赖）。核心代码质量高——EventTapManager 的后台线程设计、三层激活、O(1) trigger index 都经过实战验证。

但 UI 层存在可改进的结构性问题，且部分 API 选择落后于项目已支持的 macOS 14+ 最低版本。

本次重构借鉴 CodexBar 中合理的部分（ViewModel 职责分离、@Observable 模式），跳过不适用的部分（多 target 拆分、SwiftUI @main 入口、外部依赖引入）。

## Goals

1. 迁移到 `@Observable` 宏，利用细粒度追踪提升 SwiftUI 性能并简化代码
2. 拆分 SettingsViewModel，消除职责过重问题
3. 为热路径服务提取协议，提升可测试性
4. 不改变运行时行为，不引入外部依赖

## Non-Goals

- 不迁移到 SwiftUI `@main` 入口（LSUIElement 需要 `setActivationPolicy(.accessory)` 在 `app.run()` 之前）
- 不做多 target 拆分（35 文件的项目不需要）
- 不引入 Sparkle、KeyboardShortcuts 等外部依赖
- 不重构 EventTapManager、AppSwitcher、SkyLight 相关代码（已稳定）

---

## Part 1: @Observable 迁移

### 涉及文件

| 文件 | 变更 |
|------|------|
| `SettingsViewModel.swift` | `ObservableObject` → `@Observable`，去掉所有 `@Published` |
| `InsightsViewModel.swift` | 同上 |
| `SettingsView.swift` | `@ObservedObject var viewModel` → `var viewModel` |
| `ShortcutsTabView.swift` | 同上 |
| `GeneralTabView.swift` | 同上 |
| `InsightsTabView.swift` | 同上 |

### 关键变更细节

**ViewModel 类标注：**
```swift
// Before
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var shortcuts: [AppShortcut] = []
    @Published var accessibilityGranted: Bool = false
    // ...
}

// After
@MainActor
@Observable
final class SettingsViewModel {
    var shortcuts: [AppShortcut] = []
    var accessibilityGranted: Bool = false
    // ...
}
```

**View 层引用：**
```swift
// Before
struct ShortcutsTabView: View {
    @ObservedObject var viewModel: SettingsViewModel
}

// After
struct ShortcutsTabView: View {
    var viewModel: SettingsViewModel
}
```

**Binding 处理：**
- `$viewModel.property` 语法在 `@Observable` 中需要用 `@Bindable` 包装
- 在需要 `$` 绑定的 View 中，声明改为 `@Bindable var viewModel`
- 涉及：SettingsView（`$selectedTab` 不受影响，它是 `@State`）、ShortcutsTabView（`$viewModel.recordedShortcut`、`$viewModel.isRecordingShortcut`）、InsightsTabView（`$viewModel.period`）
- GeneralTabView 的手动 `Binding(get:set:)` 保持不变（setter 有副作用）

**SettingsWindowController 不变：** 它只是创建 ViewModel 实例并传给 NSHostingController，`@Observable` 对象不需要特殊处理。

---

## Part 2: SettingsViewModel 拆分

### 问题分析

当前 `SettingsViewModel`（152 行）混合了 5 个职责：
1. 快捷键 CRUD（add/remove/save）
2. 快捷键编辑草稿状态（selectedAppName、recordedShortcut、isRecording）
3. 权限状态轮询
4. Launch at Login 开关
5. Hyper Key 开关

### 拆分方案

拆成两个 `@Observable` 类：

**`ShortcutEditorState`** — 快捷键编辑的 UI 草稿状态 + CRUD 操作：
- `shortcuts: [AppShortcut]`
- `selectedAppName`, `selectedBundleIdentifier`
- `recordedShortcut`, `isRecordingShortcut`
- `conflictMessage`
- `usageCounts`
- `addShortcut()`, `removeShortcut()`, `chooseApplication()`, `revealApplication()`, `clearRecordedShortcut()`

**`AppPreferences`** — 全局偏好设置（借鉴 CodexBar 的 SettingsStore 思路）：
- `accessibilityGranted: Bool`（只读，从 ShortcutManager 获取）
- `launchAtLoginEnabled: Bool`
- `hyperKeyEnabled: Bool`
- `setLaunchAtLogin()`, `setHyperKeyEnabled()`
- `refreshPermissions()`

### 权限轮询去重

当前 SettingsViewModel 和 ShortcutManager 各有一个 3 秒 Timer 轮询权限。重构后：

- ShortcutManager 的权限轮询保留（它负责 EventTap 的启停）
- AppPreferences 不自建 Timer，改为从 ShortcutManager 读取当前状态
- SettingsViewModel 的 `permissionTimer` 删除
- AppPreferences.refreshPermissions() 直接调 `shortcutManager.hasAccessibilityAccess()`
- View 层的 Refresh 按钮仍然可用
- **UX 变化：** Settings UI 的权限指示灯不再每 3 秒自动更新，改为在 View 出现时 + 用户点击 Refresh 时更新。这是可接受的：用户不会长时间盯着权限灯等待变化，且 ShortcutManager 的后台轮询仍会在权限变化时自动启停 EventTap。

### View 层适配

```swift
// SettingsWindowController.show()
let editor = ShortcutEditorState(shortcutStore: shortcutStore, shortcutManager: shortcutManager, usageTracker: usageTracker)
let preferences = AppPreferences(shortcutManager: shortcutManager, hyperKeyService: hyperKeyService)
let insightsVM = InsightsViewModel(usageTracker: usageTracker, shortcutStore: shortcutStore)
let contentView = SettingsView(editor: editor, preferences: preferences, insightsViewModel: insightsVM)
```

```swift
// SettingsView
struct SettingsView: View {
    var editor: ShortcutEditorState
    var preferences: AppPreferences
    var insightsViewModel: InsightsViewModel
    @State private var selectedTab: SettingsTab = .shortcuts
    // ...
}

// ShortcutsTabView — 同时需要 editor（CRUD）和 preferences（权限状态）
struct ShortcutsTabView: View {
    @Bindable var editor: ShortcutEditorState
    var preferences: AppPreferences
}

// GeneralTabView — 只需要 preferences
struct GeneralTabView: View {
    var preferences: AppPreferences
}

// InsightsTabView — 不变
struct InsightsTabView: View {
    @Bindable var insightsViewModel: InsightsViewModel
}
```

### 文件变更

| 操作 | 文件 |
|------|------|
| 新建 | `Services/ShortcutEditorState.swift` |
| 新建 | `Services/AppPreferences.swift` |
| 删除 | `UI/SettingsViewModel.swift` |
| 修改 | `UI/SettingsView.swift` |
| 修改 | `UI/ShortcutsTabView.swift` |
| 修改 | `UI/GeneralTabView.swift` |
| 修改 | `UI/SettingsWindowController.swift` |

---

## Part 3: 协议抽象热路径

### 目标

为 AppSwitcher 和 EventTapManager 提取协议，让 ShortcutManager 的测试不依赖真实的 CGEvent tap 和窗口操作。

### KeyPress 提升为独立类型

当前 `KeyPress` 是 `EventTapManager` 的嵌套类型。提取协议后，如果协议方法仍引用 `EventTapManager.KeyPress`，则协议与具体类型耦合，mock 实现也被迫依赖 `EventTapManager`。

解决：将 `KeyPress` 提升为独立顶层 struct，放在 `Models/KeyPress.swift`：

```swift
// Models/KeyPress.swift
struct KeyPress: Equatable, Hashable, Sendable {
    let keyCode: CGKeyCode
    let modifiers: NSEvent.ModifierFlags
}
```

`EventTapManager` 中删除嵌套 `KeyPress` 定义，改为使用顶层 `KeyPress`。所有引用 `EventTapManager.KeyPress` 的地方改为 `KeyPress`（涉及 `EventTapManager`、`ShortcutManager`、`KeyMatcher`）。

### 协议定义

```swift
// Protocols/AppSwitching.swift
@MainActor
protocol AppSwitching {
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool
}

// Protocols/EventTapManaging.swift
@MainActor
protocol EventTapManaging {
    var isRunning: Bool { get }
    func start(onKeyPress: @escaping (KeyPress) -> Bool)
    func stop()
    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>)
    func setHyperKeyEnabled(_ enabled: Bool)
}
```

### 适配

- `AppSwitcher` 添加 `: AppSwitching` 遵循
- `EventTapManager` 添加 `: EventTapManaging` 遵循
- `ShortcutManager` 内部用 `any` 存储协议类型：

```swift
@MainActor
final class ShortcutManager {
    private let appSwitcher: any AppSwitching
    private let eventTapManager: any EventTapManaging
    // ...

    init(
        shortcutStore: ShortcutStore,
        persistenceService: PersistenceService,
        appSwitcher: any AppSwitching,
        eventTapManager: any EventTapManaging = EventTapManager(),
        permissionService: AccessibilityPermissionService = AccessibilityPermissionService(),
        usageTracker: UsageTracker? = nil
    )
}
```

用 `any` 而非 `some`：`some` 会让 ShortcutManager 变成泛型类，导致所有存储 ShortcutManager 的地方（AppController、SettingsWindowController、AppPreferences）都必须携带类型参数。`any` 的运行时开销仅在方法调用时有一次间接寻址，对 init 注入场景完全可忽略。

### AccessibilityPermissionService

已经是 struct 且方法简单，当前不需要协议抽象。如果未来测试需要 mock 权限状态，可以再提取。

### 文件变更

| 操作 | 文件 |
|------|------|
| 新建 | `Models/KeyPress.swift`（从 EventTapManager 提升） |
| 新建 | `Protocols/AppSwitching.swift` |
| 新建 | `Protocols/EventTapManaging.swift` |
| 修改 | `Services/AppSwitcher.swift`（添加协议遵循） |
| 修改 | `Services/EventTapManager.swift`（删除嵌套 KeyPress，添加协议遵循） |
| 修改 | `Services/ShortcutManager.swift`（参数类型改为 `any` 协议，`EventTapManager.KeyPress` → `KeyPress`） |
| 修改 | `Services/KeyMatcher.swift`（`EventTapManager.KeyPress` → `KeyPress`） |

---

## Part 4: 不改动的部分（决策记录）

| 组件 | 决策 | 理由 |
|------|------|------|
| `main.swift` 入口 | 保留 | LSUIElement 需要在 `app.run()` 前设 activation policy，SwiftUI @main 无法控制 |
| `MenuBarController` | 保留纯 AppKit | NSMenu 定制化需求，MenuBarExtra 灵活度不足 |
| `EventTapManager` 内部实现 | 保留 | 后台线程 + os_unfair_lock 设计已验证，不需要改 |
| `AppSwitcher` 内部实现 | 保留 | 三层 SkyLight 激活已稳定 |
| `DiagnosticLog` | 保留 | 文件日志 + os.log 双轨设计是对的，不需要引入 swift-log |
| `ShortcutStore` | 保留 | 简单的内存缓存，不需要改成 @Observable（它不直接被 View 引用） |
| SPM 单 target | 保留 | 35 文件不需要多 target |
| 零外部依赖 | 保留 | 当前没有引入外部依赖的必要性 |

---

## Risk Assessment

| 风险 | 影响 | 缓解 |
|------|------|------|
| @Observable 迁移后 View 不更新 | 中 | @Observable 的追踪是自动的，但需确认 @Bindable 用法正确；运行时验证 |
| ViewModel 拆分后 ShortcutsTabView 同时依赖两个对象 | 低 | 职责边界清晰：editor 管编辑状态，preferences 管权限/偏好 |
| ShortcutManager 协议注入后编译问题 | 低 | 用 `any` 避免泛型蔓延，运行时开销可忽略 |
| KeyPress 提升为独立类型后遗漏引用 | 低 | 编译器会报错所有 `EventTapManager.KeyPress` 引用 |
| 权限轮询去重后 UI 不及时更新 | 低 | AppPreferences.refreshPermissions() 是同步调用，View 的 Refresh 按钮仍可用 |

## Testing Plan

1. `swift build` 编译通过
2. `swift test` 现有测试通过
3. macOS 真机验证：
   - Settings 窗口打开、Tab 切换正常
   - 快捷键添加/删除/冲突检测正常
   - 权限状态指示灯正确
   - Launch at Login 开关正常
   - Hyper Key 开关正常
   - Insights Tab 数据加载正常
   - 全局快捷键触发正常
