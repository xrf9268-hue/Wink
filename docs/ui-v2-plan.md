# Plan: Wink UI v2 Implementation

## Context

设计稿来源：Claude Design 导出的 handoff bundle (`/tmp/wink-design/wink/project/Wink UI v2.html` + `wink/project/v2/*.jsx`)，与之配套的对话见 `wink/chats/chat1.md`–`chat3.md`。设计师在 v1 基础上完成了一次系统性 audit：

- **Logo**：v1 Crescent 在小尺寸读起来像皱眉脸；v2 重画了 6 个方向（Twin/Lash/Keycap/W/Dot-i/Pair）让闭眼弧线读为 smile。本次决定采用 **Twin** 作为 logo 锚点。
- **设计语言**：从原本零散的系统色 + opacity，统一到 Sequoia 风格的 light/dark 双 token；新增 SectionLabel、Card、Banner、Switch、Segmented、Keycap、HyperBadge、StatusDot 等共享 primitives。
- **Settings 主窗口**：从 segmented Picker 改为**侧边栏导航**（Shortcuts/Insights/General），所有内容居于 macOS System Settings 风格的 grouped Cards 内。
- **菜单栏弹窗**：从 NSMenu+NSView 升级为**带 Wordmark/状态 pill/搜索/Today 直方图/Hyper badge/Pause toggle 的 popover**。
- **Insights**：新增 KPI 三卡（Activations/Time saved/Streak）、24×7 hourly heatmap、per-app sparkline。
- **General**：所有项分到 grouped Cards 内，新增 "When target is frontmost" segmented 控件。

User 决策（2026-04-22）：
1. **分四个 PR 渐进**；
2. **Logo 用 Twin 锚点**；
3. **菜单栏改 NSPopover + SwiftUI**；
4. **不保留任何向后兼容 / deprecation shim**（Wink 仍在开发期）；
5. **先建 issue 再逐个实现**；
6. **plan 文件保存到项目内**。

## Apple 官方最佳实践对齐（macOS 14+, Wink `LSMinimumSystemVersion=14.0`）

经查 `developer.apple.com/documentation/swiftui` 后，v2 落地路径全部走 Apple 推荐的现代 SwiftUI Scene 协议，而不是手写 `NSStatusItem` / `NSPopover` / `NSWindow` + `NSHostingController`：

- **菜单栏弹窗**：用 [`MenuBarExtra` + `.menuBarExtraStyle(.window)`](https://developer.apple.com/documentation/swiftui/menubarextra)（macOS 13+）替代当前 `NSStatusBar.system.statusItem(...)` + `NSMenu` 的手工组合。Apple 文档明确：`.window` style 是为"data-rich"菜单栏 utility 设计的 popover-like 容器，是当前推荐路径。`AGENTS.md` 已经记载了这个方向："for new app-shell work, evaluate `MenuBarExtra`/`Settings`/`openSettings` first"。
- **Settings 主窗口**：用 [`Settings { SettingsView() }`](https://developer.apple.com/documentation/swiftui/building-and-customizing-the-menu-bar-with-swiftui) Scene + [`openSettings()`](https://developer.apple.com/documentation/swiftui/opensettingsaction)（macOS 14+）替代当前手写的 `SettingsWindowController`/`NSWindow`/`NSHostingController`。Apple 文档明确：`openSettings()` 是 macOS 14+ 打开 Settings 窗口的唯一推荐方式。
- **侧边栏导航**：用 [`NavigationSplitView(sidebar:detail:)`](https://developer.apple.com/documentation/swiftui/navigationsplitview)（macOS 13+）实现 Sidebar + Detail 两栏；`List(items, selection: $selection)` 承载 Sidebar items；`detail` 闭包按 `selection` 切换 Shortcuts/Insights/General。比手写 `HStack { CustomSidebar; Content }` 更原生，自动支持 sidebar collapse / 键盘焦点 / VoiceOver。
- **设置项排版**：General tab 的 Toggle/Picker 行优先用 [`Form { Section { LabeledContent { Toggle/Picker } } }`](https://developer.apple.com/documentation/swiftui/form)；macOS 上 Form 自动渲染为 Sequoia System Settings 风格的 grouped 视觉，与 v2 设计稿契合，**不需要**自己再画 Card 边框。仅在 Form 不能满足的复杂版块（Insights KPI、heatmap、Permissions 双状态行）才回到自绘 `WinkCard`。
- **App 启动协议**：从当前的 `main.swift` (`NSApplication.shared` + `AppDelegate` + 手工 `app.run()`) 切换到 [`@main struct WinkApp: App`](https://developer.apple.com/documentation/swiftui/app) + `@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate`，让 `Settings` / `MenuBarExtra` 两个 Scene 落地。`LSUIElement=true` 保留以满足 utility app 配置。
- **状态栏图标**：使用 SF Symbol 模板图（`Image(systemName: "bolt.square.fill")` Phase 1–3），Phase 4 用 `Logo_WinkTwin` 渲染的模板 `NSImage` 替换。Apple 强调菜单栏图标 `isTemplate = true` 是亮/暗模式同步的官方做法。

## Phase 0 — Issue 拆分 + Plan 入库（先于任何代码改动）

**目标**：把这份 plan 入版控、把每个 Phase 拆成 GitHub issue，让 Wink 仓库里看得到、能按 issue 单独评审。

**步骤**
1. 把这份 plan 复制为 `docs/ui-v2-plan.md`，作为 source of truth；`~/.claude/plans/` 副本仅用于本次 plan-mode session。
2. 用 `gh issue create` 建 4 个 issues，每个对应一个 Phase；body 直接引用 plan 中对应 Phase 段落 + 列出涉及文件 + 验收 gate。Issue 之间的依赖关系在 body 里写清楚（Phase 2/3/4 都依赖 Phase 1 的 design tokens；Phase 4 依赖 Phase 3 的 popover）。
3. 不创建 PR、不写代码；user 确认 issue 内容无误后再开始 Phase 1 实现。

**产出**
- `docs/ui-v2-plan.md`（与本文件内容一致）
- 4 个新 issues（建议标题 `UI v2 — Phase 1: Design tokens + Logo`、`UI v2 — Phase 2: Settings window`、`UI v2 — Phase 3: Menu bar popover`、`UI v2 — Phase 4: Logo polish + Insights advanced`）

---

## Phase 1 — Design system + WinkApp scene 重构 + Logo (Twin)

**目标**：建立设计系统底座，并完成"App 启动协议"切换 —— 从 `NSApplication.shared` 手动 run 切到 SwiftUI `App` + `@NSApplicationDelegateAdaptor`。Phase 2/3/4 都构建在新的 Scene 之上。

**新增文件**
- `Sources/Wink/UI/DesignSystem/DesignTokens.swift`
  - `enum WinkPalette`：`light` / `dark` 两个静态命名空间，覆盖 `tokens.jsx` 的 `windowBg/cardBg/sidebarBg/hairline/controlBg/fieldBg/accent*/violet*/green*/amber*/red*/heatmapBase/focusRing` 全部字段；用 `Color(.sRGB, red:, green:, blue:, opacity:)` 显式声明，**不**经过 Asset Catalog。
  - 通过 `@Environment(\.colorScheme)` 派生 `WinkPalette.current`，避免每个 view 自己判断主题。
  - `enum WinkType`：与设计稿对齐的 `Font` 工厂（`sectionLabel`、`tabTitle`、`cardTitle`、`bodyValue` 等）。
- `Sources/Wink/UI/DesignSystem/WinkLogo.swift`
  - `Logo_WinkTwin`、`WinkAppIcon`（violet→blue gradient tile + Twin）、`Wordmark`（W + 自定义 `i` + nk）三个 SwiftUI View，1:1 对照 `logos.jsx`/`primitives.jsx`。`Logo_WinkTwin` 用 `Path` + `addArc` 重画闭眼凹向上、点眼对齐。
- `Sources/Wink/UI/DesignSystem/WinkPrimitives.swift`
  - `WinkCard<Title, Accessory, Content>`、`WinkBanner(kind:title:body:trailing:)`、`WinkSectionLabel`、`WinkKeycap`、`WinkHyperBadge`、`WinkStatusDot`、`WinkSwitch`、`WinkSegmented`、`WinkButton(.primary/.secondary/.ghost/.danger)`、`WinkTextField(leftIcon:trailing:)`。
  - `WinkIcons`：把 `primitives.jsx` 的 16 个 SVG 用 SwiftUI `Path` 重画或选最贴近的 SF Symbol（`magnifyingglass`/`gearshape`/`chart.bar`/`bolt`/`info.circle`/`exclamationmark.triangle`/`checkmark.circle` 等）。
- `Sources/Wink/UI/DesignSystem/WinkSparkline.swift`：纯 `Path` 折线 + 区域填充；Phase 4 实际用，Phase 1 先建 + 测试。
- `Sources/Wink/WinkApp.swift`（新的 `@main`，**取代** `main.swift`）
  ```swift
  @main
  struct WinkApp: App {
      @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
      var body: some Scene {
          // Phase 1 仅占位，Phase 2 接 SettingsView、Phase 3 接 MenuBarExtra
          Settings { Text("Settings placeholder") }
      }
  }
  ```
  - `Package.swift` 的 `executableTarget(name: "Wink")` 自动识别 `@main`。
  - `LSUIElement=true` 保留。

**删除文件**
- `Sources/Wink/main.swift`（被 `WinkApp.swift` 取代；不留 shim）
- `Sources/Wink/UI/SharedComponents.swift` 中的 `CardView`（被 `WinkCard` 取代；不留 type alias）
- `Sources/Wink/UI/InsightsTabView.swift::InsightsVisualStyle`（被 `WinkPalette` 取代）

**修改文件**
- `Sources/Wink/AppDelegate.swift`：保留为 `NSApplicationDelegate`，被 `@NSApplicationDelegateAdaptor` 接管；现有 `applicationDidFinishLaunching` 中实例化 `AppController` 的逻辑不变。
- `Sources/Wink/UI/SharedComponents.swift`：`AppIconCache` / `AppIconView` / `ShortcutLabel` / `PermissionStatusBanner` 留下；后两个在 Phase 2 被 `WinkBanner` / `WinkKeycap` 取代后删除。

**测试**
- `Tests/WinkTests/DesignSystem/DesignTokensTests.swift`：每个 token 在 light/dark 下 sRGB 分量与 `tokens.jsx` 一致（容差 0.005）。
- `Tests/WinkTests/DesignSystem/WinkLogoTests.swift`：`Logo_WinkTwin(size: 16/52/72)` `NSHostingView` 渲染非空、intrinsic size 匹配。
- `Tests/WinkTests/DesignSystem/WinkPrimitivesTests.swift`：`WinkBanner` 四 kind 的字色/底色、`WinkSwitch` on/off knob 偏移、`WinkSegmented` 选中阴影。
- `Tests/WinkTests/AppLaunchTests.swift`（新建）：`WinkApp` `Settings` Scene 存在；`@NSApplicationDelegateAdaptor` 把 `AppDelegate` 装进 application 主循环。

**验收**
- `swift test` 全绿；`swift build -c release` 通过；`bash scripts/package-app.sh` 产出 `build/Wink.app`，Sparkle framework 嵌入完好。
- `bash scripts/e2e-full-test.sh` 在本机 macOS `6/6 PASS`（无 UI 行为变化预期）。
- 标 `macOS runtime validation pending` 直到 macOS 上手动确认 menu bar bolt 图标仍出现、点击仍弹原 NSMenu（Phase 3 才换 MenuBarExtra）、Settings 用 `osascript -e 'tell application "Wink" to activate'` 仍可打开。

---

## Phase 2 — Settings Scene + NavigationSplitView + 三 tab 视觉重构

**目标**：把现在手写的 `SettingsWindowController` / `NSWindow` 路径全部切到 SwiftUI `Settings` Scene + `NavigationSplitView`；三 tab 按 v2 重写视觉与信息层次；保持 `ShortcutEditorState` / `AppPreferences` / `InsightsViewModel` 数据流不变。

**修改 / 新增文件**
- `Sources/Wink/WinkApp.swift`：
  ```swift
  Settings {
      SettingsView(editor: …, preferences: …, insightsViewModel: …, appListProvider: …, shortcutStatusProvider: …)
          .frame(minWidth: 760, minHeight: 560)
  }
  ```
  - 通过 `appDelegate` 暴露的 service container 注入；`AppDelegate` 在 `applicationDidFinishLaunching` 完成 service 装配。
  - `AppController` 是 AppKit 类，无法直接读 `@Environment(\.openSettings)`（环境值仅在 SwiftUI view 树中可用）。改为：在 `Settings` Scene 的根 view（或挂在 scene 上的辅助 `.background` view）里 `@Environment(\.openSettings) private var openSettings`，`onAppear` 时把这个 `OpenSettingsAction` 写入一个共享 `SettingsLauncher` service（`@MainActor`，存在 service container 里）；`AppController.openSettings()` 通过该 service 触发，菜单栏 / 第一次启动 / 任何 AppKit 触发路径都走相同入口。
- `Sources/Wink/UI/SettingsView.swift` 重写为：
  ```swift
  NavigationSplitView {
      List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
          Label(tab.title, systemImage: tab.systemImage)
              .badge(tab.badge)
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
      .listStyle(.sidebar)
  } detail: {
      switch selectedTab {
      case .shortcuts: ShortcutsTabView(...)
      case .insights:  InsightsTabView(...)
      case .general:   GeneralTabView(...)
      }
  }
  .navigationSplitViewStyle(.balanced)
  ```
- 删除 `Sources/Wink/UI/SettingsWindowController.swift`（被 `Settings` Scene + `openSettings()` 取代；不留兼容入口）。
- `Sources/Wink/UI/ShortcutsTabView.swift` 重写视觉，沿用现有 binding：
  - 顶栏 `ShortcutsHeader`（`WinkType.tabTitle` + 副标题 + 右侧 `WinkButton("Refresh")`）。
  - `PermissionStatusBanner` 替换为 `WinkBanner(kind: .success / .warn)`，warn 时 trailing = `WinkButton(.primary, "Open Settings")`。
  - "New Shortcut" `WinkCard`：左 `Target app` 下拉（继续承载 `AppPickerPopover`），右 `Shortcut` 字段 — 默认显示 dashed border + `record` 圆点 + "Press a key combination…"，录制中切到现有 `ShortcutRecorderView`，录完显示 `WinkKeycap` 串。底部 hint + `Clear` / `Add Shortcut`。
  - "Your Shortcuts · N" `WinkCard`：accessory = `WinkTextField(placeholder: "Filter…")` + `WinkButton("Import…")`。
  - 行：`grip` 抓手 → 30pt app icon → 名称 + `WinkStatusDot` → `N× past 7 days · Last used Xm ago` → `WinkHyperBadge` → keys keycap → `WinkSwitch` → `more` overflow（替换 ×）。
  - "Last used" 数据：Phase 2 先显示 "—"，Phase 4 与 hourly schema 一同接入（issue 中标注依赖）。
- `Sources/Wink/UI/GeneralTabView.swift` 重写：
  - 顶部标题区与 Shortcuts 同风格。
  - 主体优先用 `Form { Section("Startup") { LabeledContent { Toggle } } ... }` + `.formStyle(.grouped)`，靠 macOS Form 自渲染原生 grouped 视觉；仅 Permissions 双状态行用 `WinkCard` 自绘（Form 不能表达"Granted/Needed" trailing label）。
  - **Startup**：Launch at Login（保留 `LaunchAtLoginPresentation` 的 enabled/requiresApproval/notFound 三态消息行）。`Show Menu Bar Icon` 延后到 Phase 3，在它能够直接驱动 `MenuBarExtra.isInserted` 时再暴露，避免先上线无效控制。
  - **Keyboard**：Enable All Shortcuts / Hyper Key / "When target is frontmost" `Picker(.segmented)` (`Hide / Toggle / Focus`)。新设置：`AppPreferences.frontmostTargetBehavior`，默认 `.toggle`，接到 `ToggleSessionCoordinator`（默认行为不变）。
  - **Permissions** `WinkCard`：Accessibility / Input Monitoring 两 `PermRow`。
  - **Updates** `WinkCard`：`WinkAppIcon(40)` + `Wordmark` + 版本 + `Check for Updates…` + hairline + Automatic Updates `Toggle`。
  - 底部：`Release Notes · Privacy · Support` 文本链接。
- `Sources/Wink/UI/InsightsTabView.swift` 简化重写（**不**新增 KPI/heatmap/sparkline，留 Phase 4）：
  - 顶栏：标题 + 右上 `Picker(.segmented) D / W / M`，与现有 `InsightsPeriod` 兼容。
  - 替换现有 banner 为 `WinkCard("Most used", accessory: "{total} activations · 7 days")` 列表，每行：app icon → 名称 → 进度条（`WinkPalette.current.accent`）→ 数字。

**测试**
- `Tests/WinkTests/SettingsViewTests.swift`：保留 Settings 生命周期相关 seam，覆盖 `handleAppear` / app reactivation 对权限与 Launch at Login 状态的刷新。
- `Tests/WinkTests/SettingsLauncherTests.swift`：覆盖 tab 持久化、pending open replay、以及 handler 已安装时的直接打开行为。
- `Tests/WinkTests/AppControllerTests.swift`：覆盖 `openPrimarySettingsWindow()` 到 `SettingsLauncher` 的桥接链路，而不是退化成源码字符串断言。
- `Tests/WinkTests/LayoutRegressionTests.swift`：
  - 把 `cardViewExpandsToFillWidthInsideLeadingStack` 替换为 `WinkCard` 等价断言（detail 列宽 ≥ `760 - sidebar(200) - margins`）。
  - 保留 Insights ranking ScrollView 检测。
  - 新增 `shortcutsListRowPresentationHasNewShortcutCardWithDashedRecorder`。
- `Tests/WinkTests/AppPreferencesTests.swift`（新建）：覆盖 `frontmostTargetBehavior` 持久化、`ToggleSessionCoordinator` 接到 `frontmostTargetBehavior` 的三态行为。

**验收**
- `swift test` 全绿。
- `bash scripts/package-app.sh` + `bash scripts/e2e-full-test.sh` 本机 macOS `6/6 PASS`（与 `frontmostTargetBehavior=.toggle` 默认值的旧行为一致）。
- 手动覆盖 Settings 三 tab：侧边栏切换、卡片呈现、按钮行为、permission banner、Hyper key 提示、Launch at Login（含 `requiresApproval`/`notFound` 三态保持）、Updates 板块、Sparkle "Check for Updates…"。
- 标 `macOS runtime validation pending` 直到上述完成。

---

## Phase 3 — MenuBarExtra(.window) + SwiftUI 弹窗

**目标**：把 `MenuBarController` 完全删除，菜单栏改用 SwiftUI `MenuBarExtra` + `.menuBarExtraStyle(.window)`，弹窗内容 1:1 对照 `menubar.jsx`。

**新增文件**
- `Sources/Wink/UI/MenuBar/MenuBarPopoverView.swift`：SwiftUI 版本，对照 `menubar.jsx`：
  - Header：`WinkAppIcon(24) + Wordmark(14) + version("v0.3") + Ready/Paused pill`。
  - Search field（占位，本阶段不实现真实过滤；输入只做样式 + ⌘K keycap，Phase 4 接入过滤）。
  - "Today" 标题 + 24-bar 直方图：本阶段先用 mock 数据（`UsageTracker` 现有 `dailyCounts` 派生当日总值平均分配 24 桶），Phase 4 接入真实 hourly。
  - Shortcuts list：复用 `ShortcutStore` + `ShortcutStatusProvider`；每行 `AppIcon(22) + name + WinkStatusDot(green if running) + WinkHyperBadge + ShortcutGlyph`；底部 "Manage…" 调起 `openSettings()` 并跳到 Shortcuts tab（通过 `selectedTab` 共享状态）。
  - 底部：Pause-all toggle、Settings…(⌘,)、Check for Updates…、Quit Wink (⌘Q) 四行 `MenuRow`。

**修改文件**
- `Sources/Wink/WinkApp.swift`：
  ```swift
  @AppStorage("menuBarIconVisible") var menuBarIconVisible = true
  
  var body: some Scene {
      MenuBarExtra("Wink", systemImage: "bolt.square.fill", isInserted: $menuBarIconVisible) {
          MenuBarPopoverView(services: appDelegate.services)
      }
      .menuBarExtraStyle(.window)
      
      Settings { SettingsView(...) }
  }
  ```
  - `isInserted` 绑定在 Phase 3 同时引入的 `menuBarIconVisible` 偏好；只有当这个 scene 存在时，General 中的 `Show Menu Bar Icon` 才应该重新暴露。
  - `systemImage` 仍用 `"bolt.square.fill"`，Phase 4 切到 Twin 模板。
- `Sources/Wink/UI/GeneralTabView.swift`：在本阶段把 `Show Menu Bar Icon` 加回 Startup 区域，但只允许它直接驱动 `MenuBarExtra.isInserted`，不保留无效占位状态。
- `Sources/Wink/Services/ShortcutManager.swift`：暴露 `setShortcutsPaused(_:)`，flip 时禁用所有 Carbon hotkey 注册 + 关闭 active event tap，但**不**清除 `shortcuts.json`；恢复时 `attemptStart()` 重新注册。Persist 到 `AppPreferences.shortcutsPaused`。
  - 严格遵守 AGENTS 中"persist user-visible state only after underlying op succeeds"：toggle 顺序为 op 成功 → preference update → UI 广播。

**删除文件**
- `Sources/Wink/UI/MenuBarController.swift`
- `Sources/Wink/UI/MenuBarShortcutItemPresentation.swift`
- `Sources/Wink/UI/MenuBarShortcutRowView.swift`
- 对应的 `Tests/WinkTests/MenuBar*Tests.swift`、`MenuBarLaunchAtLoginPresentationTests.swift`（替换为下面 SwiftUI 版本的测试）

**测试**
- `Tests/WinkTests/MenuBar/MenuBarPopoverViewTests.swift`：渲染含搜索框、Today section、shortcuts list 行、Pause toggle；状态 pill 在 paused/ready 切换；Manage 链接触发 `openSettings` 计数 +1。
- `Tests/WinkTests/MenuBar/MenuBarSceneTests.swift`：`WinkApp` body 含 `MenuBarExtra`；`isInserted` false 时 scene 移除。
- `Tests/WinkTests/PauseAllShortcutsTests.swift`：`setShortcutsPaused(true)` 后 `ShortcutManager.attemptStart()` 上报 `ready=false`；`setShortcutsPaused(false)` 后再次 `attemptStart()` 上报 `ready=true`。
- `Tests/WinkTests/LaunchAtLoginPresentationTests.swift` 重写：脱离菜单栏，覆盖 General tab 中 Launch at Login 行的三态展示。

**验收**
- `swift test`、`swift build -c release`、`bash scripts/package-app.sh`。
- macOS 手动：popover 开/关/外点关闭/⌘,/⌘Q/Pause all 切换；
- Pause all 验证：本机 `osascript` 触发 shortcut 在 paused 状态下应**不**触发；resume 后恢复触发；
- Show Menu Bar Icon 关闭后状态栏图标消失，General 仍能开启。
- `macOS runtime validation pending` 直至完成。

---

## Phase 4 — Logo polish + Insights advanced + 真实 hourly + 弹窗搜索

**Logo / Branding**
- `Sources/Wink/Resources/AppIcon.svg` 替换为 `WinkAppIcon` 渲染规格（violet→blue gradient + Twin）；新建 `scripts/build-app-icon.sh` 用 `rsvg-convert`/`sips` 从 SVG 导出 1024/512/256/128/64/32/16 → 重新生成 `AppIcon.icns`，更新 Info.plist 引用（`CFBundleIconFile=AppIcon`）。
- `WinkMenuBarScene` 使用 `MenuBarExtra(isInserted:content:label:)` 的自定义 label；label 从 `MenuBarTemplate` packaged PNG 创建 `NSImage`，显式设置 `isTemplate = true`，再通过 `Image(nsImage:)` + `.renderingMode(.template)` 渲染，避免高亮态出现空占位符。
- About 卡（General → Updates）使用 `WinkAppIcon(40)`。

**Insights 高级图表**
- `Sources/Wink/UI/Insights/InsightsKpiSection.swift`：3 KPI `WinkCard`（Activations/Time saved/Streak）。
  - Activations：`viewModel.totalCount` + 上周对比 delta（新增 `InsightsViewModel.previousPeriodTotal`）+ `WinkSparkline`（24 hourly 数据点）。
  - Time saved：`totalCount × 3s`，格式 "Xm" / "Xs"。
  - Streak：基于 `dailyCounts` 派生连续 ≥1 次激活的天数；持久化历史最长。
- `Sources/Wink/UI/Insights/InsightsHourlyHeatmap.swift`：24×7 heatmap。
- `Sources/Wink/UI/Insights/InsightsAppRow.swift`：sparkline + delta（`+18%` 上箭头）。
- `Sources/Wink/UI/Insights/InsightsUnusedNudge.swift`：`WinkBanner(.info)` 提示 7 天 0 激活的 shortcut。

**Hourly 数据通路**
- `Sources/Wink/Services/UsageTracker.swift`：新增 `hourlyCounts(days:7, relativeTo:) async -> [(date:String, hour:Int, count:Int)]`、`previousPeriodTotal(days:relativeTo:)`、`streakDays(relativeTo:)`。
- `Sources/Wink/Services/PersistenceService.swift`：新增 `usage_hourly(date TEXT, hour INT, count INT, PRIMARY KEY(date,hour))` 表；与现有 `usage_daily` 并行写入。**不**写迁移占位代码（按用户决策不考虑向后兼容，旧 db 删表重建即可），但要确保删除发生在 startup 前的一次性 migration 路径而不是无声重置。
- `Tests/WinkTests/PersistenceServiceTests.swift`：新增 hourly schema 写入/读出/索引覆盖测试。

**Menu bar Today 直方图接入真实数据**
- `MenuBarPopoverView` 替换 Phase 3 的 mock，使用 `hourlyCounts(days:1)`。当前小时高亮 `accent`，过去 `accentBgSoft`，未来 0.04 fill。

**Search in popover (轻量)**
- `MenuBarPopoverView` 搜索文本绑定 list 过滤；`localizedCaseInsensitiveContains`，不做 fuzzy ranking。

**测试**
- `Tests/WinkTests/Insights/InsightsKpiSectionTests.swift`：streak 计算、time-saved 文案、delta 上下行颜色。
- `Tests/WinkTests/Insights/HourlyHeatmapDataTests.swift`：UsageTracker hourly bucket 写入/读出；7 天窗口对齐。
- `Tests/WinkTests/MenuBar/MenuBarPopoverSearchTests.swift`：filter behavior。
- `Tests/WinkTests/AppIconTemplateTests.swift`：菜单栏 image `isTemplate == true` 且 size = 16×16。

**验收**
- `swift test` 全绿；
- `bash scripts/package-app.sh` + `bash scripts/e2e-full-test.sh` 本机 macOS `All 6 tests passed`；
- 手动：跑一周以上数据回溯，对比 General/Insights/MenuBar 截图与 v2 设计稿；Sparkle release 流程产出新版本。

---

## Critical files summary

**只读参照（设计稿，不动）**
- `/tmp/wink-design/wink/project/Wink UI v2.html`
- `/tmp/wink-design/wink/project/v2/{tokens,logos,primitives,chrome,menubar,tab-shortcuts,tab-general,tab-insights,mainwindow}.jsx`

**Phase 1**
- 新：`Sources/Wink/WinkApp.swift`、`Sources/Wink/UI/DesignSystem/{DesignTokens,WinkLogo,WinkPrimitives,WinkSparkline}.swift`
- 删：`Sources/Wink/main.swift`、`SharedComponents.swift::CardView`、`InsightsTabView.swift::InsightsVisualStyle`
- 测试：`Tests/WinkTests/DesignSystem/*`、`Tests/WinkTests/AppLaunchTests.swift`

**Phase 2**
- 改：`Sources/Wink/WinkApp.swift`、`Sources/Wink/UI/{SettingsView,ShortcutsTabView,GeneralTabView,InsightsTabView}.swift`、`Sources/Wink/Services/AppPreferences.swift`、`Sources/Wink/Services/PersistenceService.swift`、`Sources/Wink/AppController.swift`
- 删：`Sources/Wink/UI/SettingsWindowController.swift`
- 测试：`Tests/WinkTests/{SettingsViewTests,LayoutRegressionTests,AppPreferencesTests}.swift`

**Phase 3**
- 新：`Sources/Wink/UI/MenuBar/MenuBarPopoverView.swift`、`Tests/WinkTests/MenuBar/*`、`Tests/WinkTests/PauseAllShortcutsTests.swift`
- 改：`Sources/Wink/WinkApp.swift`、`Sources/Wink/Services/ShortcutManager.swift`、`Sources/Wink/AppController.swift`
- 删：`Sources/Wink/UI/{MenuBarController,MenuBarShortcutItemPresentation,MenuBarShortcutRowView}.swift`、`Tests/WinkTests/{MenuBarShortcutItemPresentation,MenuBarShortcutRowView,MenuBarLaunchAtLoginPresentation}Tests.swift`

**Phase 4**
- 新：`scripts/build-app-icon.sh`、`Sources/Wink/UI/Insights/{InsightsKpiSection,InsightsHourlyHeatmap,InsightsAppRow,InsightsUnusedNudge}.swift`、Resource `MenuBarTemplate.imageset`
- 改：`Sources/Wink/Resources/AppIcon.{svg,icns}`、`Sources/Wink/Services/{UsageTracker,PersistenceService}.swift`、`Sources/Wink/UI/MenuBar/MenuBarPopoverView.swift`
- 测试：`Tests/WinkTests/Insights/*`、`Tests/WinkTests/MenuBar/MenuBarPopoverSearchTests.swift`、`Tests/WinkTests/AppIconTemplateTests.swift`

## Verification (per phase, gates)

```bash
swift build
swift test
swift build -c release
./scripts/package-app.sh
./scripts/e2e-full-test.sh
```

每个 PR 都必须满足：
1. `swift test` 全绿，新增的回归用例覆盖该 phase 的关键 invariant；
2. 在本机 macOS `bash scripts/e2e-full-test.sh` 报 `All 6 tests passed`；
3. 手动覆盖该 phase 涉及的 UI 路径，并在 PR 描述中附验证步骤；
4. 维护 `macOS runtime validation pending` 标签直至 macOS 验证完成；同步更新 `docs/handoff-notes.md`；
5. **不**写任何 backward-compat / deprecation / shim 代码；旧符号 / 旧文件 / 旧 db 表直接删；
6. 任何引入 hourly schema 的改动（仅 Phase 4），`PersistenceServiceTests` 必须覆盖新表的写入/读出。
