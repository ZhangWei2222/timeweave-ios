# TimeWeave iOS Hello World Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 创建一个能由 Xcode 编译、签名并安装到 iPhone，启动后居中显示 `Hello world` 的原生 SwiftUI 应用。

**Architecture:** 单一 iOS App Target 使用 SwiftUI 生命周期。`TimeWeaveApp` 只创建窗口并加载 `ContentView`，`ContentView` 只负责静态首屏；工程使用自动签名配置，但不提交个人 Team ID 或证书。

**Tech Stack:** Xcode 26.3、Swift 6、SwiftUI、iOS 16+

**Spec:** `docs/superpowers/specs/2026-10-16-timeweave-ios-hello-world-design.md`

## Global Constraints

- 最低部署版本固定为 iOS 16.0。
- 工程名、Target 名和 Scheme 名均为 `TimeWeave`。
- 手机桌面显示名为 `时序`。
- Bundle Identifier 为 `com.zhangwei2222.timeweave`。
- 使用 Xcode 自动签名，`DEVELOPMENT_TEAM` 保持为空。
- 首屏中央精确显示 `Hello world`。
- 不添加第三方依赖、网络、存储、账号、通知或时间管理功能。

## Review Focus

- 通用 iOS Simulator 目标必须能在禁用签名时完成 Debug 编译。
- 通用 iOS Device 目标必须能在禁用签名时完成 Debug 编译，确保产物包含真机架构。
- 构建设置必须解析出 iOS 16.0、`com.zhangwei2222.timeweave` 和桌面名称“时序”。
- 工程不能写入任何个人 Team ID、证书路径或密钥。
- App 入口必须加载唯一首屏，且首屏文案精确为 `Hello world`。

---

### Task 1: 创建并验证最小 SwiftUI iOS 工程

**Files:**
- Create: `TimeWeave.xcodeproj/project.pbxproj`
- Create: `TimeWeave.xcodeproj/xcshareddata/xcschemes/TimeWeave.xcscheme`
- Create: `TimeWeave/TimeWeaveApp.swift`
- Create: `TimeWeave/ContentView.swift`
- Create: `TimeWeave/Assets.xcassets/Contents.json`
- Create: `TimeWeave/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `TimeWeave/Assets.xcassets/AccentColor.colorset/Contents.json`
- Modify: `README.md`

**Interfaces:**
- Consumes: SwiftUI 的 `App`、`Scene`、`WindowGroup`、`View` 和 `Text`。
- Produces: `TimeWeaveApp: App` 作为应用入口；`ContentView: View` 作为根视图；共享 Scheme `TimeWeave` 供 Xcode 和 `xcodebuild` 使用。

- [ ] **Step 1: 记录工程尚不存在的基线**

Run: `test ! -e TimeWeave.xcodeproj`
Expected: PASS，证明后续验证针对本次新建工程。

- [ ] **Step 2: 创建 Xcode 工程配置和共享 Scheme**

在 `project.pbxproj` 中定义一个 iOS Application Target、Debug/Release 配置、自动签名、iOS 16.0、Swift 6、Bundle Identifier、显示名称、资源目录和仅 iPhone 设备族。共享 Scheme 构建并运行该 Target。

- [ ] **Step 3: 创建应用入口 `TimeWeaveApp`**

在 `TimeWeave/TimeWeaveApp.swift` 定义 `@main struct TimeWeaveApp: App`，其 `WindowGroup` 加载 `ContentView()`。

- [ ] **Step 4: 创建根视图 `ContentView`**

在 `TimeWeave/ContentView.swift` 定义 `struct ContentView: View`，使用系统布局居中渲染精确文本 `Hello world`，并提供 SwiftUI Preview。

- [ ] **Step 5: 创建最小资源目录**

添加有效的 Asset Catalog 根清单、空的 AppIcon 清单和系统强调色清单，使工程可编译且为后续正式图标保留标准入口。

- [ ] **Step 6: 整理 README**

用单一标题替换重复内容，记录工程用途、Xcode 打开方式、模拟器运行方式，以及真机选择 Personal Team 和自动签名的步骤。

- [ ] **Step 7: 编译通用模拟器目标**

Run: `xcodebuild -project TimeWeave.xcodeproj -scheme TimeWeave -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/timeweave-derived-simulator CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 8: 编译通用真机目标**

Run: `xcodebuild -project TimeWeave.xcodeproj -scheme TimeWeave -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /tmp/timeweave-derived-device CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 9: 核对关键构建设置和源码契约**

Run: `xcodebuild -project TimeWeave.xcodeproj -scheme TimeWeave -showBuildSettings`
Expected: 输出包含 `IPHONEOS_DEPLOYMENT_TARGET = 16.0`、`PRODUCT_BUNDLE_IDENTIFIER = com.zhangwei2222.timeweave`、`INFOPLIST_KEY_CFBundleDisplayName = 时序`、`CODE_SIGN_STYLE = Automatic`，且 `DEVELOPMENT_TEAM` 为空；源码包含唯一的 `Hello world` 文案和 `ContentView()` 根视图加载。

- [ ] **Step 10: 检查差异格式**

Run: `git diff --check`
Expected: 无空白错误。

- [ ] **Step 11: 检查变更范围**

Run: `git status --short`
Expected: 只出现计划内的新建和修改文件。

- [ ] **Step 12: 创建功能提交**

Run: `git add README.md TimeWeave TimeWeave.xcodeproj`，随后运行 `git commit -m "feat: add SwiftUI hello world app"`。
Expected: 提交只包含工程、源码、资源目录和 README。

- [ ] **Step 13: 推送并核对远程提交**

Run: `git push`，随后运行 `git ls-remote origin refs/heads/main`。
Expected: 本地 `main` 与 `origin/main` 指向同一提交。
