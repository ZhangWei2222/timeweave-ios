# Analysis Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 不重新编译即可切换 AI 分析本地/远端，防止凭证或旧结果串环境。

**Architecture:** Foundation 配置模型验证 origin，UserDefaults 保存非秘密偏好，Keychain 按 origin 存令牌。SwiftUI 设置表单保存后更新请求配置，ViewModel 用请求级 client 快照和 generation 取消防竞态。

**Tech Stack:** Swift 6 / iOS 16+ / SwiftUI / URLSession / Security / XCTest

**Spec:** `docs/superpowers/specs/2026-10-25-analysis-environment.md`

## Global Constraints

- iOS 16+、Swift 6，无新第三方依赖、不全局放宽 ATS、不在手机中嵌入云账号 AK。
- 默认本地 `http://127.0.0.1:8787`；远端预填 `https://api.super-vivian.top`，预填不代表已经可达。
- 远端令牌 32–256 个可见 ASCII 字符，只存 Keychain，按规范化远端 origin 隔离，不写入偏好、源码或日志。
- 保留现有未提交 Xcode 签名设置；只提交本功能文件/工程引用。按仓库规则验证后本地合回 main，不 push。

## Review Focus

- 编辑远端 host/port 后不得复用旧 origin 的令牌。
- Keychain 写入失败不得保存新环境或声称成功。
- 切换时已完成但尚未交付的旧请求不得覆盖新结果。
- HTTP 重定向不得携带分析数据/令牌到其他主机。
- 真机与模拟器 localhost 语义、远端未开通状态须明确提示。

### Task 1: 配置、鉴权与运行时环境开关

**Files:**
- Create: `TimeWeave/Core/AnalysisServiceSettings.swift`
- Create: `Tests/TimeWeaveCoreTests/AnalysisServiceSettingsTests.swift`
- Modify: `TimeWeave/Core/AgentClient.swift`, `TimeWeave/Core/AIAnalysisViewModel.swift`
- Modify: `TimeWeave/AIAnalysisView.swift`, `TimeWeave/Info.plist`, `TimeWeave.xcodeproj/project.pbxproj`
- Modify: `Tests/TimeWeaveCoreTests/AgentClientTests.swift`, `Tests/TimeWeaveCoreTests/AIAnalysisViewModelTests.swift`, `UITests/LocalAnalysisUITests.swift`, `README.md`

**Interfaces:**
- Produces: `AnalysisServiceSettings` (MainActor ObservableObject), `save(environment:localAddress:remoteAddress:token:) throws`, `makeClient(session:) throws -> AgentClient`、`revision`；`AnalysisEnvironment.local/.remote`；`AnalysisEndpoint` 规范化 origin。
- Consumes: 现有 `AgentAnalyzing.analyze(question:snapshot:)`、`AIAnalysisViewModel` generation 保护、已有快照结构。

- [x] 写配置、偏好重载、origin 令牌隔离、写失败、URL/令牌边界测试；为现有请求测试增加远端 Bearer 和拒绝重定向；为 VM 增加切换 client 后清空/晚返回测试。
- [x] 运行 `swift test`，确认新行为因实现缺失而失败。
- [x] 实现验证/Keychain、请求级 client provider、设置表单和即时取消，补本地网络用途说明；保存原签名 diff，不混入提交。
- [x] 运行 `swift test`，预期全套无失败。
- [x] 写 UI 测试：设置保存远端、返回切本地、重启保留本地地址；先观察控件缺失失败，再实现 UI，运行测试通过。
- [x] 双 SDK `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` 成功；文档说明真机地址、令牌、未开公网边界。
- [ ] 提交功能及验证记录，独立只读 review；Critical/Important 做一次 RED→GREEN 修复。
- [ ] 按仓库规则合回 main，再运行全套测试并确认用户签名差异保留，不 push。
