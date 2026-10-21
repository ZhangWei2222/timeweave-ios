# TimeWeave V2：本地 AI 时间分析闭环

## 1. 目标

V2 打通一条可运行、可测试、可解释的本地分析链路：用户在 TimeWeave 统计页输入一个问题，iOS 将当前统计范围压缩成不含原始记录的只读快照，通过 HTTP 发给 Mac 上的 `selfweave-agent`；Go 服务复用现有 Agent Runner、OpenAI-compatible Model 和 Tool 机制调用阿里云百炼，再把有数据依据的回答返回 iOS 展示。

本期服务于单个用户在 Mac + iOS Simulator 上验证完整产品与 Agent 链路。它不是最终的跨设备后台架构；云部署、账号与主动运行需要在后续版本单独设计，不能以扩大 V2 信任边界的方式提前混入。

## 2. 成功标准

一次端到端验收必须满足：

1. 用户在统计页选择近 7 天或近 30 天，进入 AI 分析页并提交问题；
2. iOS 根据提交时的本地 ledger 生成聚合快照，不读取或发送备注、记录明细、分类 UUID；
3. 请求到达仅监听 Mac 回环地址的 Go Server；
4. Go 为该请求创建独立的 Snapshot Tool 和 Runner，模型必须成功读取快照后才能返回最终答案；
5. 百炼收到的业务数据只有用户问题、时间范围、时区、总分钟、分类分钟和每日分钟；
6. iOS 展示最终回答；连接失败、超时、协议错误和服务端错误均显示可操作的中文错误，并允许用户手动重试；
7. API Key 只存在于 Go Server 进程环境中，不进入 iOS 工程、请求或日志；
8. `swift test`、iOS 两套 SDK 构建、`go test ./...` 和 `go vet ./...` 均通过，现有 CLI 行为不回归。

## 3. 已确认范围

### 3.1 包含

- 统计页的单次、只读 AI 分析入口；
- 近 7 天和近 30 天两种现有统计范围；
- 用户问题输入、提交中状态、回答展示、错误展示和手动重试；
- iOS 聚合快照构建与 HTTP Client；
- 本机 Go HTTP Server；
- 请求级只读 Snapshot Tool；
- 复用现有 Runner、模型适配器、类型化错误和 JSONL 运行日志；
- 百炼 OpenAI-compatible Chat Completions 调用；
- 离线、确定性的两端测试，以及显式执行的真实链路验收。

### 3.2 不包含

- 云部署、公网访问、局域网真机访问；
- 账号、认证、授权、多用户隔离；
- 多设备或换机同步；
- App 未打开时主动运行、定时任务、后台任务、APNs；
- 多轮聊天、会话恢复、长期记忆、RAG；
- Agent 对记录、分类或任何本地状态的写操作；
- 原始记录、备注、分类 UUID 或整个 ledger 的上传；
- 流式响应、SSE、WebSocket、自动重试、模型路由或供应商降级；
- 在 iOS 中配置、保存或展示模型 API Key；
- 在 V2 中为未来云架构预建通用插件系统。

## 4. 方案选择

### 4.1 采用：iOS 生成聚合快照，Go 通过请求级 Tool 暴露给 Runner

iOS 是本地账本和统计语义的事实源，负责把指定自然日范围转换为最小聚合数据。Go 不接触 App 沙盒，也不重新解释原始记录；它只校验快照、把快照作为只读工具结果交给模型并执行 Agent Loop。

该方案一次性划清了三个边界：iOS 负责事实计算，Go 负责 Agent 编排和密钥，模型只负责解释事实。未来迁移到云端时，HTTP 契约仍可保留，认证和同步可在边界外演进。

### 4.2 未采用：iOS 直接调用百炼

这会迫使 API Key 进入客户端，无法形成可靠的秘密边界；模型配置、错误映射与供应商协议也会污染 iOS。即使当前只有个人使用，该路径仍会把未来迁移成本固化到客户端，因此拒绝。

### 4.3 未采用：上传原始 ledger，或由 Go 读取 App 数据文件

上传 ledger 会暴露备注、精确起止时间和稳定标识，超出回答当前问题所需的最小信息。让 Go 读取 App 沙盒则依赖模拟器路径和 Apple 容器实现，真机、换机和云端都不可复用。两者都增加耦合而不提高本期答案质量，因此拒绝。

## 5. 总体架构

```text
TimeWeave iOS
  StatisticsView
    -> AIAnalysisView / AIAnalysisViewModel
      -> AnalysisSnapshotBuilder
      -> AgentClient
           | POST /v1/analysis (loopback HTTP)
           v
selfweave-agent
  cmd/selfweave-server
    -> internal/api Handler
      -> internal/analysis Service
        -> request-scoped Snapshot Tool
        -> agent.Runner
          -> model.OpenAICompatible -> 阿里云百炼
          -> runlog.JSONL

现有 CLI
  cmd/selfweave -> internal/app
    -> 同一个 internal/analysis Service / agent.Runner / Model / runlog
    -> fixture-backed Weekly Summary Tool
```

核心约束：HTTP Handler 只处理协议，Snapshot Tool 只返回本次请求的不可变事实，Runner 只编排模型和工具，模型适配器只处理供应商协议。不得在 Handler 中直接拼模型消息，也不得为 Server 复制第二套 Agent Loop。

## 6. iOS 设计

### 6.1 `AnalysisSnapshot`

在 `TimeWeave/Core` 中定义可编码、可比较、可发送的值类型：

- `range.startDate`：本地自然日，`YYYY-MM-DD`；
- `range.endDateExclusive`：右开区间结束日，`YYYY-MM-DD`；
- `range.timezone`：设备当前 IANA 时区标识；
- `totalMinutes`：范围内已记录总分钟；
- `categories[]`：分类名称与分钟数，按分钟降序、同分钟按名称稳定排序；
- `days[]`：范围内每个自然日及分钟数，按日期升序，包含 0 分钟日期。

快照不包含记录数组、备注、分类 UUID、颜色、设备标识、用户标识或文件路径。分类占比是 `minutes / totalMinutes` 的派生值，不在网络请求中重复发送，由 Go Tool 统一计算，避免两个来源产生不一致。

### 6.2 `AnalysisSnapshotBuilder`

Builder 是无网络、无副作用的纯逻辑。输入为 `TimeLedger`、统计天数、提交时刻和显式 `Calendar`；输出为快照。它复用 `TimeStatistics.days` 和区间求交规则，保持与统计页一致：

- 范围为以提交时刻所在自然日结尾的 7 或 30 个完整自然日窗口；
- 使用左闭右开区间；
- 跨午夜记录按自然日切分；
- 夏令时日按真实 23/25 小时时长处理；
- 只输出有分钟数的分类；每日数组始终完整；
- 当前输入控件以分钟为粒度。Builder 先按“分类 × 自然日”切成最小统计单元，每个单元只计算完整分钟，再由同一组单元分别汇总出分类、每日和总分钟。这样即使旧数据意外含秒级边界，也只是舍弃不足一分钟的碎片，不会让三类合计彼此漂移；未来若要保留秒级精度，必须升级契约版本。

Builder 只接收 ledger 的值副本，不读取 `LedgerFile`，从而可由 Swift Package 单元测试直接验证。

### 6.3 `AgentClient`

`AgentClient` 使用 `URLSession` 发送 `Codable` 请求，默认 Base URL 为 `http://127.0.0.1:8787`，请求超时 35 秒。它只负责：

- 构造 `POST /v1/analysis`；
- 设置 `Content-Type: application/json`；
- 编解码成功与错误响应；
- 把传输失败、超时、非 2xx 和非法响应映射为稳定的客户端错误。

Client 不读取 ledger、不持有 UI 状态、不自动重试。自动重试会在用户不知情时重复产生付费模型调用；V2 只提供显式的“重试”按钮。

### 6.4 `AIAnalysisView`

统计页在现有总览中增加一个“AI 分析”入口，将当前 `period` 传入分析页。页面维持单次请求状态：`idle -> loading -> success/error`。

- 用户输入一个问题；空白问题不能提交；
- 提交时从最新 ledger 重新构建快照，避免打开页面后数据变化导致旧快照；
- 加载期间禁用重复提交，并允许离开页面取消客户端任务；
- 成功后展示只读回答，不提供修改本地数据的动作；
- 失败时展示面向用户的中文信息和重试按钮；重试沿用问题，但重新构建快照；
- 每次提交都是独立请求，新的结果替换旧结果，不保留多轮上下文。

UI 状态放在 `@MainActor` 的 `AIAnalysisViewModel`，网络依赖通过协议注入，避免 SwiftUI View 同时承担请求编排与状态机逻辑。

### 6.5 iOS 网络权限

V2 只访问回环地址。工程在生成的 Info.plist 的 `NSAppTransportSecurity` 字典中设置 `NSAllowsLocalNetworking = YES`，不设置 `NSAllowsArbitraryLoads`。这是 Apple 为 IP 地址和本地资源提供的定向 ATS 开关，不应扩大成全局明文 HTTP 许可。模拟器验收固定使用 `127.0.0.1`；局域网 IP 和真机访问不属于本期。参考 [Apple `NSAllowsLocalNetworking` 文档](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)。

## 7. HTTP API 契约

### 7.1 请求

```http
POST /v1/analysis HTTP/1.1
Content-Type: application/json
```

```json
{
  "schema_version": 1,
  "question": "过去 7 天最值得调整的时间投入是什么？",
  "snapshot": {
    "range": {
      "start_date": "2026-10-15",
      "end_date_exclusive": "2026-10-22",
      "timezone": "Asia/Shanghai"
    },
    "total_minutes": 720,
    "categories": [
      { "name": "工作", "minutes": 300 },
      { "name": "其他", "minutes": 240 },
      { "name": "阅读", "minutes": 180 }
    ],
    "days": [
      { "date": "2026-10-15", "minutes": 120 },
      { "date": "2026-10-16", "minutes": 0 },
      { "date": "2026-10-17", "minutes": 180 },
      { "date": "2026-10-18", "minutes": 90 },
      { "date": "2026-10-19", "minutes": 150 },
      { "date": "2026-10-20", "minutes": 60 },
      { "date": "2026-10-21", "minutes": 120 }
    ]
  }
}
```

契约规则：

- 请求体上限 64 KiB，只接受一个 JSON 值并拒绝未知字段；
- `schema_version` 必须为 `1`；
- `question` 去除首尾空白后长度为 1～500 个 Unicode 字符；
- 日期必须使用 `YYYY-MM-DD`，时区必须是可加载的 IANA 标识；
- 范围长度为 1～31 个本地自然日，V2 UI 只产生 7 或 30 天；
- 数值必须是非负整数；分类名非空且不能重复。iOS 沿用账本的 24 个用户可见字符（扩展字素簇）限制；Go 不另设更窄的码点限制，名称传输大小受整体 64 KiB 上限约束；
- `days` 必须完整覆盖范围、按日期升序且无重复；
- 分类分钟合计、每日分钟合计都必须等于 `total_minutes`；
- 任何校验失败都在调用模型前返回。

### 7.2 成功响应

```http
HTTP/1.1 200 OK
Content-Type: application/json
```

```json
{
  "schema_version": 1,
  "run_id": "run-example",
  "answer": "过去 7 天共记录 720 分钟，其中工作 300 分钟，占 41.7%……"
}
```

`run_id` 用于关联本机运行日志，不是会话 ID。服务端不会通过它恢复上下文。

### 7.3 错误响应

所有能正常写回的 HTTP 错误使用同一结构：

```json
{
  "schema_version": 1,
  "run_id": "run-example",
  "error": {
    "code": "model_unavailable",
    "message": "模型服务暂时不可用，请稍后重试。",
    "retryable": true
  }
}
```

`run_id` 只在已经分配后出现。V2 的公开错误码和状态码为：

| HTTP | code | retryable | 含义 |
| --- | --- | --- | --- |
| 400 | `invalid_request` | false | JSON、字段或聚合不满足契约 |
| 404 | `not_found` | false | 路径不存在 |
| 405 | `method_not_allowed` | false | 路径正确但方法不支持，同时返回 `Allow: POST` |
| 413 | `payload_too_large` | false | 请求体超过 64 KiB |
| 415 | `unsupported_media_type` | false | 不是 JSON 请求 |
| 502 | `model_unavailable` | true | 模型请求失败、响应非法或未按要求使用工具 |
| 504 | `analysis_timeout` | true | 30 秒分析超时 |
| 500 | `internal_error` | true | 工具、事件日志或服务内部失败 |

公开 `message` 使用稳定、无敏感信息的中文文案，不回传百炼错误正文、文件路径、堆栈或 API Key。详细因果只保留在本机日志中。

## 8. Go Server 设计

### 8.1 `cmd/selfweave-server`

Server 是薄 composition root：读取现有三个模型环境变量，构造 OpenAI-compatible Model、分析 Service 和 HTTP Server，处理 `SIGINT` / `SIGTERM` 优雅退出。默认监听 `127.0.0.1:8787`；即使提供地址参数，V2 也只接受 IPv4/IPv6 回环地址，拒绝 `0.0.0.0`、局域网地址和公网地址。

配置继续使用：

- `SELFWEAVE_MODEL_BASE_URL`
- `SELFWEAVE_MODEL_API_KEY`
- `SELFWEAVE_MODEL_NAME`

Server 启动前一次性校验配置，失败即退出，不在首个用户请求时才暴露配置问题。

### 8.2 `internal/api`

Handler 的职责限制为：路由、方法和 Content-Type 检查、限长解码、DTO 校验、调用分析 Service、错误映射和 JSON 响应。它不依赖百炼具体类型，不生成提示词，不实现 Agent Loop。

Handler 接收一个最小 `Analyzer` 接口，因此测试可注入 Fake；真实网络、模型密钥和文件系统不参与 HTTP 单元测试。

### 8.3 `internal/analysis`

新增传输无关的分析用例层，供现有 CLI 与 HTTP Server 共用。Service 持有只读、可并发复用的 Model 和固定运行策略；每次 `Analyze` 调用都在局部创建：

- 随机 `run_id`；
- 独立 JSONL EventSink；
- 独立 Tool Registry；
- 独立 Runner 与 30 秒 Context。

Service 返回 `answer`、`run_id` 和本机日志路径。CLI 继续用日志路径自动生成 HTML 并保持现有 stdout/stderr 契约；HTTP Server 不自动生成 HTML，避免把派生展示失败变成用户请求的新故障点。需要排障时仍可用现有 `selfweave trace render` 手动生成。

Service 不保存上一次请求的消息或 Snapshot。共享的 OpenAI-compatible Model 只含不可变配置和并发安全的 `http.Client`，因此并发请求不会串数据。

### 8.4 请求级 Snapshot Tool

新增工具名 `get_time_analysis_snapshot`。构造工具时传入已经校验且不可变的快照；工具参数必须是空对象，执行只返回本次请求的：

- 时间范围和时区；
- 总分钟；
- 分类分钟及由 Go 计算的一位小数占比；
- 每日分钟。

Registry 每请求只注册这个工具，禁止模型访问文件、网络或写操作。工具不持有全局“当前快照”，否则并发请求可能交叉读取其他请求的数据。

API 模式的 Runner 开启“最终回答前至少成功调用一次工具”的策略。该策略作为 Runner 的可选配置加入，默认关闭，以保留现有 CLI 的直接回答能力和测试语义。系统提示同时要求：只依据工具事实、引用具体分钟或占比、数据不足时明确说明、不得声称看到了记录明细。

### 8.5 CLI 兼容性

现有 `cmd/selfweave` 的参数、fixture Weekly Summary Tool、Fake 模式、真实模型模式、退出码、JSONL 和 HTML 输出保持不变。重构只提取模型配置和一次运行的公共生命周期，不改变 V1 API 与默认行为。HTTP Server 不复用 CLI 参数解析器，而是复用其下方的分析核心。

## 9. 数据流

1. 用户在统计页选择 7/30 天并打开 AI 分析页；
2. 用户输入问题并点击分析；
3. ViewModel 从当前 `TimeStore.ledger` 取值，Builder 按当前日历和时区生成快照；
4. AgentClient 编码请求并发往 `127.0.0.1:8787`；
5. Handler 限长解码并完成全部确定性校验；
6. Service 创建本次 run、JSONL、Snapshot Tool、Registry 和 Runner；
7. Runner 将系统约束、用户问题和 Tool 定义发给百炼；
8. 百炼调用 `get_time_analysis_snapshot`；
9. Tool 返回聚合事实，Runner 将其作为 tool message 回填百炼；
10. 百炼生成引用具体数据的最终回答；
11. Runner 写入终态事件，Service 关闭日志，Handler 返回 answer 与 run_id；
12. ViewModel 切换到 success，SwiftUI 展示回答。

任何失败都沿原调用栈返回；V2 不在后台继续任务，也不在客户端或服务端自动重试。

## 10. 错误与取消

- iOS 无法连接：提示“未连接到本机分析服务，请确认 selfweave-server 已启动”，可重试；
- iOS 请求超时：取消 URLSession Task，提示超时；服务端通过请求 Context 感知断开并尽快取消模型调用；
- 请求校验失败：不创建 Runner、不调用百炼；
- 模型、工具、步数上限、事件写入和超时：沿用 Agent 类型化错误，在 API 边界映射为第 7.3 节的稳定错误；
- Runner 失败后仍尽力写入终态事件并关闭 JSONL；日志关闭失败不得被静默忽略；
- View 消失时取消当前客户端任务，但不承诺已经到达百炼的请求不产生费用；
- 重试是一次新的 run，获得新的 `run_id`，不复用旧模型上下文。

## 11. 安全与隐私边界

### 11.1 网络边界

- Server 只监听回环地址；V2 没有认证，因此不得通过参数绕过该限制；
- iOS 只连接固定回环 Base URL，不接受用户输入任意地址；
- 限制请求体、严格 Content-Type、拒绝未知字段和多余 JSON，减少协议漂移和资源滥用；
- 不启用 CORS；原生 iOS Client 不需要浏览器跨域能力。

### 11.2 数据最小化

允许离开 iOS 的业务数据只有：问题、范围、时区、总分钟、分类名称/分钟、日期/分钟。禁止发送备注、起止时间、记录 ID、分类 UUID、颜色、完整 ledger 和设备信息。

分类名称与问题仍可能包含个人信息。它们会发送给用户配置的百炼模型，并写入本机 JSONL 轨迹；AI 分析页在提交按钮附近固定展示这一事实，不引入额外的首次提示状态。运行目录继续使用 `0700`，日志文件使用 `0600`，`.selfweave/` 保持 Git 忽略。V2 不自动上传日志，也不实现自动清理；保留策略在云化前单独设计。

### 11.3 密钥

API Key 仅由 Go 进程通过环境变量读取，只用于到百炼的 `Authorization` Header。它不得出现在 iOS 源码、UserDefaults、请求/响应、事件日志、错误正文或 README 示例值中。

## 12. 测试策略

### 12.1 iOS 单元测试

`AnalysisSnapshot`、Builder、AgentClient 和 ViewModel 都属于无 SwiftUI View 的应用逻辑，放入现有 `TimeWeaveCore` target，通过 `swift test` 覆盖：

1. 7/30 天范围和右开边界；
2. 跨午夜分类/每日拆分；
3. 23/25 小时夏令时日；
4. 空数据、零分钟日和稳定排序；
5. 快照中不存在 note、UUID 和原始记录字段；
6. 分类、每日与总分钟合计一致；
7. AgentClient 的请求方法、路径、Header、JSON 和成功解码；
8. 连接错误、超时、各类错误响应和非法响应映射。

ViewModel 使用 Fake Client 覆盖 idle/loading/success/error、重复提交抑制、重试重建快照和取消。UI 只做少量结构验收，不把业务规则放进 View 测试。

### 12.2 Go 单元与集成测试

覆盖：

1. API 路由、方法、Content-Type、64 KiB 上限、严格 JSON 解码；
2. schema、日期、时区、范围、名称、非负数、完整 days 和两个合计不变量；
3. 成功/失败响应结构、状态码、`retryable` 与敏感信息不泄漏；
4. Snapshot Tool 定义、空参数校验、稳定排序与占比；
5. Runner 的可选“必须先成功使用工具”策略，且默认行为不变；
6. 两个并发请求使用不同快照、run_id 和日志，不发生交叉污染；
7. Service 的超时、取消、日志关闭和错误保留；
8. 现有 CLI 测试全部保留并通过。

HTTP 集成测试使用 `httptest`、Fake Model 和临时日志目录，不访问百炼。默认 `go test ./...` 必须完全离线。

### 12.3 构建与真实链路验收

自动验证：

```bash
# timeweave-ios
swift test
xcodebuild -project TimeWeave.xcodeproj -scheme TimeWeave \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project TimeWeave.xcodeproj -scheme TimeWeave \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build

# selfweave-agent
go test ./...
go vet ./...
```

真实链路使用显式配置的百炼环境变量启动 Server，在 iOS Simulator 中至少验证：有数据回答、空数据回答、Server 未启动、模型配置/调用失败、超时与手动重试。真实调用不是默认测试的一部分，避免 CI 依赖网络和密钥。

## 13. 预期文件边界

具体文件拆分由后续实施计划确定，但职责边界预期如下：

```text
timeweave-ios/
├── TimeWeave/Core/
│   ├── AnalysisSnapshot.swift
│   ├── AnalysisSnapshotBuilder.swift
│   ├── AgentClient.swift
│   └── AIAnalysisViewModel.swift
├── TimeWeave/
│   ├── AIAnalysisView.swift
│   └── StatisticsView.swift             # 仅增加入口
├── Tests/TimeWeaveCoreTests/
└── TimeWeave.xcodeproj/project.pbxproj  # 新文件与最小网络配置

selfweave-agent/
├── cmd/selfweave-server/main.go
├── internal/analysis/
├── internal/api/
├── internal/tool/snapshot.go
├── internal/agent/                      # 可选 required-tool 策略
├── internal/app/                        # CLI 兼容与公共装配
└── README.md
```

不为目录整齐而搬迁现有包；只有 CLI/Server 真正共享的生命周期和配置才提取。

## 14. 验收清单

- [ ] iOS 请求体经测试证明不含原始记录、备注、分类 UUID 或 ledger；
- [ ] Go Server 只监听回环地址，非回环配置启动失败；
- [ ] 非法请求在模型调用前失败；
- [ ] 每个请求拥有独立 Snapshot Tool、Runner、run_id 和 JSONL；
- [ ] 模型未成功调用 Snapshot Tool 时不能返回 200；
- [ ] 成功回答引用工具中的具体分钟数或占比；
- [ ] API Key 未进入 iOS、协议或日志；
- [ ] iOS 能展示回答、错误和重试；
- [ ] 模拟器到 Mac Server 再到百炼的真实链路通过；
- [ ] 两端自动测试和构建通过；
- [ ] 现有 `selfweave` CLI 的命令、输出和轨迹能力不回归。

## 15. 后续演进边界

V2 的 HTTP 契约和聚合快照可以继续作为未来云服务的输入，但“本机无认证回环服务”不能直接升级为公网服务。进入云部署前必须重新设计身份、传输加密、租户隔离、数据保留、密钥托管和滥用控制；进入主动运行前必须重新设计数据同步、调度语义和通知授权。V2 不通过占位接口假装这些问题已经解决。
