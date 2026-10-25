# 本地／远端环境开关验收记录

日期：2026-10-25。实现从 `main` 的 `d24ee66` 开始，功能提交 `cbbd6ee`，审查修复另行提交。

## 核心验证

- 基线 Swift XCTest：22/22。
- 环境配置、请求与取消新增用例：先因缺失实现失败，补齐后 30/30。
- 真实 Network.framework 回环 HTTP 307：移除请求的 redirect delegate 时测试捕获 POST 被转发；恢复 delegate 后通过。
- 独立审查发现草稿令牌未随地址修改清空；同轮处理本地保存意外依赖隐藏远端草稿的问题。提取实际表单使用的 `AnalysisServiceDraft`，回归测试先复现令牌复用和隐藏 URL 校验失败，再修复为全套 32/32。
- 偏好重载、地址/端口令牌隔离、Keychain 写失败不提交、错误令牌/地址拒绝、本地无 Bearer、远端带 Bearer、配置错误不请求、切换取消及旧请求晚返回均有行为测试。

## 构建与界面

双 SDK 使用 `TimeWeave` scheme、generic iOS Simulator/iOS destination、`CODE_SIGNING_ALLOWED=NO` 编译。无签名构建仅用于检查编译，不能作为 Keychain 运行验收。

真实 Keychain 界面验证使用独立模拟器 `TimeWeave-Environment-Switch`，iPhone 17 / iOS 26.3。未签名界面测试曾明确报 `-34018`，改用 `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=<本机 Team>` 后通过，不改变生产存储保护。

`TimeWeaveLocalAnalysis` scheme 的回归方法：

- `testServiceEnvironmentSwitchPersistsAndShowsCurrentAddress`：改地址清空令牌草稿、隐藏无效远端不影响本地、远端地址仍保留、远端保存、跨重启保留、空输入读取原 Keychain 令牌、本地切换及重启、确认删除令牌。使用合成测试令牌，不调用真实云分析。
- `testTimerStartStopOpensConfirmationAndSaves`：计时结束确认交互不回归。
- `testManyCategoriesKeepEditorOnOneScreen`：多分类确认面板不回归。

审查后最终界面复验：3/3、0 失败（2026-10-25 12:58:59）；双 SDK 再编译成功。

`6153d17` 已本地快进合入 `main`，同一树再次运行 Swift XCTest：32/32（13:00:17）。没有 push。现有 `project.pbxproj` 未提交差异在集成前后 SHA-256 均为 `cbe10d4e76aeb778589a71216e9d524497811592d4cc9c5b90ba5b33f08eb826`，个人签名及原有格式变更没有被提交、丢弃或改写。本验收记录最后作为同一功能分支的文档提交，再快进同步至 main。

## 审查范围与边界判断

- 独立只读审查一轮；Important 修复采用 RED→GREEN，再运行全套，不重复派审。
- 没有改云端认证、监听、安全组、DNS 或备案；客户端开关不等于入口可达，手机连接 ECS 仍需建立安全入口。
- 没有真机网络 E2E 证据，不能把双 SDK 编译与模拟器测试称为真机联网成功；需后续手机联调。
- 用户已有工程签名／格式改动原样保留、未混入提交；其他机器仍需设置自己的 Team。
- 当前目标是 iPhone 单分析页；未实现跨窗口即时配置同步，多窗口使用需要另加同步。
