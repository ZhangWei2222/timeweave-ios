# TimeWeave V2 Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` in this session. Steps use checkbox (`- [ ]`) syntax for tracking. 用户已批准正式设计，并明确要求计划完成后直接实现，无需再次评审。

**Goal:** 完成 iOS Simulator → Mac Go Server → 百炼 → iOS 的只读分析闭环。

**Architecture:** iOS 生成最小聚合快照；HTTP Handler 校验协议；请求级 Snapshot Tool 向复用的 Runner 提供事实。CLI 与 HTTP 共享运行生命周期，模型密钥只由 Go 环境变量读取。

**Tech Stack:** Swift 6、SwiftUI / Combine、Foundation URLSession、Go 1.23 标准库、JSON / JSONL。

**Spec:** `docs/superpowers/specs/2026-10-21-v2-local-ai-analysis-design.md`

## Global Constraints

- iOS 16+，无第三方依赖；Go 保持标准库实现。
- POST `/v1/analysis`，schema_version=1，请求上限 64 KiB，问题 1～500 字符。
- 仅监听 `127.0.0.1:8787`（可配置其他回环端口），分析 30 秒，客户端 35 秒。
- 仅发送范围、时区、分类/每日/总分钟和问题；不发送备注、UUID、原始记录。
- 默认测试离线；真实百炼调用显式执行。
- 每请求独立 Runner、Registry、Tool、日志；最多 8 个模型步骤；必须先成功调用工具。
- 不做自动重试、多轮、写入、云部署、同步或认证。

## Review Focus

- null、缺失字段、未知字段与尾随 JSON 不得绕过 API 校验（Task 2）。
- 秒级遗留数据与 DST 不能破坏三个合计（Task 4）。
- 并发请求不得读到另一个快照（Task 2/3，race 检测）。
- 模型未调用工具、上游泄漏密钥的错误正文不得成为成功答案或公开错误（Task 1/3）。
- 页面取消后旧任务不得覆盖新结果，失败重试使用新快照（Task 5）。

### Task 1: 复用运行生命周期并约束工具依据

**Files:** Agent: `internal/agent/runner{,_test}.go`、`internal/analysis/run{,_test}.go`、`internal/model/environment{,_test}.go`、`internal/app/app.go`。

**Interfaces:** `analysis.Run(ctx, RunConfig) (RunResult,error)` 接收 Model、Registry、SystemPrompt、RequireTool、LogDirectory、Timeout，返回 agent.Result 和日志路径；`model.FromEnvironment(getenv)` 共享真实模型配置；RunnerConfig 增加默认 false 的 RequireTool。

- [ ] 写测试：RequireTool 拒绝直接回答、接受成功工具后回答，旧默认语义继续通过；公共 Run 生成日志并处理取消/日志错误；配置缺失启动失败。
- [ ] 运行 `go test ./internal/agent ./internal/analysis ./internal/model`，确认新行为尚未实现而失败。
- [ ] 实现公共运行与环境构造，并让 CLI 复用；保留 CLI 参数、退出码、自动 HTML。
- [ ] 运行 `go test ./...`、`go vet ./...`，期望退出 0；提交 `refactor: share agent run lifecycle with server`。

### Task 2: 聚合快照与只读工具

**Files:** Agent: `internal/timedata/snapshot{,_test}.go`、`internal/tool/snapshot{,_test}.go`。

**Interfaces:** `timedata.AnalysisSnapshot` JSON DTO；`Validate() error`；`tool.NewSnapshot(snapshot) agent.Tool`，名称 `get_time_analysis_snapshot`，参数严格 `{}`。

- [ ] 写测试：有效 7 天/空数据、非法范围/时区/数值、缺失日/重复分类/合计漂移、超日容量；工具参数 null/未知字段/尾随值被拒绝；工具复制数据并计算百分比。
- [ ] 运行 `go test ./internal/timedata ./internal/tool`，期望新类型/工具缺失而失败。
- [ ] 实现验证与深拷贝只读工具；范围允许 1～31 日，每日分钟不超过实际日容量，零总量占比为 0。
- [ ] 运行同一测试，期望全绿；提交 `feat: add validated request snapshots`。

### Task 3: HTTP API 与回环 Server

**Files:** Agent: `internal/api/handler{,_test}.go`、`internal/analysis/service{,_test}.go`、`internal/server/server{,_test}.go`、`cmd/selfweave-server/main.go`、`README.md`。

**Interfaces:** `Service.Analyze(ctx, question, snapshot) (RunResult,error)`；`api.NewHandler(Analyzer) http.Handler`；`server.Run(ctx,args,getenv,stderr) int`。

- [ ] 写 httptest：成功、400/404/405/413/415、502/504/500、未知字段/null/尾随 JSON、run_id 与敏感错误清洗；并发不同快照/日志隔离；非回环监听拒绝。
- [ ] 运行 `go test ./internal/api ./internal/analysis ./internal/server`，期望新入口缺失而失败。
- [ ] 实现严格解码、错误信封、Service 与信号/优雅退出；不自动生成 HTTP 轨迹 HTML。
- [ ] 运行 `go test -race ./...` 和 `go vet ./...`，期望全绿；提交 `feat: serve local snapshot analysis over http`。

### Task 4: Swift 快照构建

**Files:** iOS: `TimeWeave/Core/AnalysisSnapshot.swift`、`AnalysisSnapshotBuilder.swift`、`Tests/TimeWeaveCoreTests/AnalysisSnapshotTests.swift`。

**Interfaces:** `AnalysisSnapshotBuilder.build(ledger:period:now:calendar:) throws -> AnalysisSnapshot`，使用 Gregorian 日期编码、传入时区与自然日边界；按分类×日完整分钟单元汇总。

- [ ] 写 XCTest：7/30 天、跨午夜、DST 23/25 小时、空数据、秒级数据合计一致、编码无 note/UUID/entries。
- [ ] `swift test` 期望新类型缺失失败。
- [ ] 实现纯 Builder、snake_case 编码 DTO 与分钟不变量；保留现有 ledger 持久化格式。
- [ ] `swift test` 期望全绿；提交 `feat: build minimal analysis snapshots`。

### Task 5: Swift Client、状态机与界面

**Files:** iOS: `TimeWeave/Core/AgentClient.swift`、`AIAnalysisViewModel.swift`、`TimeWeave/AIAnalysisView.swift`、`StatisticsView.swift`、Xcode 工程、Client/ViewModel 测试。

**Interfaces:** `AgentAnalyzing.analyze(question:snapshot:) async throws -> AnalysisResponse`；`AgentClient(session:baseURL:)`；`@MainActor AIAnalysisViewModel` 用提交任务 ID 防止旧结果覆盖，注入 Builder closure 以便重试读最新 ledger。

- [ ] 写 URLProtocol 测试请求及成功/错误/超时/非法响应；ViewModel 测试重复提交、错误重试重建、取消与旧结果隔离。
- [ ] `swift test` 期望新入口缺失失败。
- [ ] 实现 Client、状态机和中文分析页，固定告知聚合数据发送与私有日志；加入统计页入口和定向 ATS 配置。
- [ ] `swift test` 和两套 SDK `xcodebuild` 期望退出 0；提交 `feat: analyze statistics through local agent`。

### Task 6: 联调、审查与交付

**Files:** 两端 README、iOS `docs/superpowers/specs/2026-10-21-v2-verification.md`。

- [ ] 检查可用模拟器与环境变量是否已配置（仅报告有/无，不打印密钥）；以离线模型 HTTP fixture 验证模拟器网络链路，再用已配置百炼执行真实分析。
- [ ] 使用测试/临时文件，避免改动真实 ledger；验证响应含具体事实、错误和手动重试。
- [ ] 运行 `swift test`、两套 SDK build、`go test -race ./...`、`go vet ./...`；读取实际输出。
- [ ] 独立上下文整体代码审查（executing-plans 明确要求 reviewer subagent）；修复重要问题并验证。
- [ ] 记录真实验证与未完成的外部前提；提交代码与验证文档，不推送、不合并 main。

## Execution notes

- 用户明确授权计划完成后直接执行，故跳过技能默认的二次计划批准门槛。
- 使用两个仓库各自的 `codex/v2-local-analysis` 分支在现有干净 checkout 实现，避免跨仓库工作树路径导致 Xcode/联调引用不一致；main 引用保持原位。
- 跨仓库任务在同一份进度日志记录；一个整体 reviewer 在最终验证后检查两端契约。
