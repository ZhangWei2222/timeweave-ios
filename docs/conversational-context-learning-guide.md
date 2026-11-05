# TimeWeave 对话上下文学习指南

这份指南不教 Go 语法。目标是让你沿着 TimeWeave 的真实请求链，掌握这次实现里最值得复用的 8 个系统概念，并能自己判断一个 Agent 是否真的“记得上一问”。

## 先建立一张总图

```text
用户输入
  │
  ▼
iOS AIChatViewModel
  ├─ 生成稳定 message_id
  ├─ 生成这一刻的统计快照
  └─ POST /conversations/{id}/turns
           │ 202 Accepted
           ▼
Agent Conversation Service ──持久化──> Conversation / Turn / Memory
           │
           ├─ 取最近对话 + 较早摘要 + 已确认记忆
           ├─ 为本轮创建独立 V3 Thread
           └─ 后台运行模型与只读工具
                    │
                    ├─ get_time_analysis_snapshot
                    ├─ propose_user_memory（可选）
                    └─ V3 checkpoint / receipt / run log
           │
           ▼
Turn completed + assistant message
           ▲
           └── iOS GET 轮询，最后刷新服务端完整 Conversation
```

这里最重要的判断是：**iOS 负责交互，Agent 服务负责事实状态，模型只负责基于被允许的上下文做推理。**

## 1. Conversation、Turn、Thread、Run 分别是什么

不要把它们都叫“会话”。它们解决的是四个不同问题：

| 名称 | 人话解释 | 生命周期 |
|---|---|---|
| Conversation | 用户在界面看到的一段长期对话 | 直到用户删除 |
| Turn | 一次提问及其最终回答 | 一问一答 |
| Thread | V3 为这一轮维护的可恢复任务状态 | 与 Turn 一一对应 |
| Run | Thread 的一次实际执行尝试 | 中断恢复时可有多次 |

关系如下：

```text
Conversation
  ├─ Turn 1 ─ Thread 1 ─ Run 1
  ├─ Turn 2 ─ Thread 2 ─ Run 2a ──中断
  │                      └─ Run 2b ──恢复完成
  └─ Turn 3 ─ Thread 3 ─ Run 3
```

为什么每个 Turn 都用独立 Thread？因为“记得历史”和“恢复当前任务”是两件事：

- Conversation 提供跨请求的聊天历史；
- V3 Thread 只负责当前这一问的预算、工具回执和崩溃恢复。

这样某一轮坏掉时，不会污染整段对话的运行状态。

先读：

1. `selfweave-agent/internal/conversation/types.go`：看四类数据的边界；
2. `selfweave-agent/internal/conversation/store.go`：看 Turn 如何进入 accepted、running、completed；
3. `selfweave-agent/internal/conversation/service.go`：看 Turn 如何组装成 V3 Thread。

## 2. 为什么服务端才是对话的事实源

iOS 不把自己刚显示过的气泡当成永久事实。一次 Turn 完成后，它重新获取整个 Conversation，再用服务端返回的 messages 更新界面。

```text
错误思路：iOS 本地 append 一条消息 → 假设服务端也成功了

当前实现：提交 Turn → 等待终态 → GET Conversation → 用服务端状态刷新界面
```

这解决三个现实问题：

- App 被杀掉后，重新打开仍能恢复对话；
- 手机请求超时但服务端已经完成时，不会丢回答；
- 同一服务上的后续请求读到同一份历史，而不是依赖某台设备的临时内存。

对应代码：

- `TimeWeave/Core/AgentClient.swift`：资源式 API 与轮询；
- `TimeWeave/Core/AIAnalysisViewModel.swift`：`AIChatViewModel` 的加载、提交和刷新；
- `TimeWeave/AIAnalysisView.swift`：只消费 ViewModel 状态，不自己维护协议状态。

## 3. message_id 为什么比“重试按钮”更重要

网络超时只说明客户端没收到结果，不说明服务端没执行。如果重试时生成新 ID，同一问题可能被模型执行两次。

当前规则是：

```text
同一 message_id + 同一内容  → 返回原 Turn，不重复启动模型
同一 message_id + 不同内容  → 拒绝，报告幂等冲突
新 message_id                → 新 Turn
```

iOS 首次提交时生成 `message_id`；可重试错误发生后，重试沿用它。Agent 在持久化层检查它，所以即使 App 或服务重启，规则仍然有效。

这叫幂等：**重复表达同一个意图，不重复产生副作用。**

重点测试：

- `Tests/TimeWeaveCoreTests/AIChatViewModelTests.swift` 中的 `testSubmitRebuildsSnapshotAndRetryReusesMessageID`
- `selfweave-agent/internal/conversation/store_test.go` 中的重复提交测试
- `selfweave-agent/internal/api/handler_test.go` 中连续提交同一 `message_id` 的测试

## 4. 模型每次真正收到什么

每轮不会把数据库和全部历史原样塞给模型。它收到的是受控投影：

```text
系统规则
+ 已确认的长期记忆（标记为不可信背景）
+ 较早历史的有界摘要
+ 最近 8 条已完成消息
+ 当前问题
+ 当前统计范围
+ 本轮可调用工具的定义
```

真正的分钟数和占比不来自旧消息，而来自本轮冻结的统计快照。模型必须成功调用 `get_time_analysis_snapshot`，完成审核才允许通过。

这条边界非常关键：

- 聊天历史用于理解“那工作呢？”里的“那”；
- 当前快照用于回答“现在到底多少分钟”；
- 旧回答里的数字不能冒充当前事实。

`selfweave-agent/internal/conversation/context.go` 负责历史投影；`service.go` 的系统规则和完成审核负责事实边界。

当前较早历史使用有长度上限的提取式摘要，而不是向量检索。它简单、可审计，适合现阶段数据量；以后只有在对话规模证明需要时，才值得引入更复杂的检索。

## 5. 长期记忆为什么独立于聊天记录

聊天记录回答“以前说过什么”，长期记忆回答“以后每次都值得带上什么”。二者不能混在一起。

TimeWeave 只允许三类记忆：

- 目标：例如“我希望每周运动 4 次”；
- 偏好：例如“建议要简短、可执行”；
- 约束：例如“工作日晚上不能安排深度工作”。

保存规则：

```text
用户明确说“记住……” + 普通内容   → 可直接激活
用户明确表达但内容敏感             → 先 proposed，等用户确认
AI 自己观察到的稳定信息            → 只能 proposed，等用户确认
密钥、密码、令牌等秘密             → 拒绝保存
统计数字、一次性事件、AI 猜测       → 不应保存
```

记忆内容进入模型时会被标成“不可信用户背景”。也就是说，记忆不能通过写入“忽略系统规则”来提升权限。

删除对话默认保留已经确认的长期记忆，因为用户删除聊天不一定等于撤销长期目标；候选记忆会随来源对话失效。界面同时提供单条记忆删除。

## 6. 为什么提交后返回 202，再由 iOS 轮询

模型调用可能持续数秒甚至更久。让一个 HTTP 请求一直挂着，会把移动网络波动误当成任务失败。

当前协议把“接受任务”和“完成任务”拆开：

```text
POST Turn
  └─ 202 + turn_id + accepted/running

GET Turn
  ├─ accepted/running：继续等
  └─ completed/paused/needs_attention/cancelled：停止轮询
```

iOS 采用逐步放慢、最长约两分钟的轮询。用户退出页面时只停止客户端轮询，不会假装撤回服务端已收到的请求；协议另有明确 cancel 接口。

这是一条可复用原则：**长任务的状态必须可查询，不能只依赖最初那条连接。**

## 7. 本地和远端为什么能共用一套实现

本地与远端使用完全相同的 `/v1/*` 资源协议。差别只有连接和身份：

- 本地未配置 Token 时，只允许服务监听回环地址，数据属于 `local`；
- 远端必须配置至少 32 个可见 ASCII 字符的 Bearer Token，且公网入口应由 HTTPS 反向代理保护；
- Agent 用稳定的远端 principal 数据空间隔离对话和记忆；Token 轮换不应让历史突然“换了一个人”；
- iOS 把 Token 放在 Keychain，不放 UserDefaults，不跟随重定向转发。

这不是账号系统。当前目标是安全地支持一个受控远端部署，而不是提前建设用户注册、跨服务同步或向量数据库。

## 8. 服务崩溃后为什么还能继续

Turn 被接受时先持久化，再启动后台 worker。V3 每个关键步骤写 checkpoint、receipt 和运行日志。

服务重启时：

```text
扫描 accepted / running Turn
  └─ 找到对应 Thread
       ├─ 没有 checkpoint：从冻结输入启动
       └─ 已有 checkpoint：创建新 Run，从 checkpoint 恢复
```

它不会凭感觉重做未知副作用。遇到不能安全判断的状态，会进入 `needs_attention`，把风险显式交给人处理。

读代码时把两层恢复分开：

- `conversation.Service.ResumePending`：找到需要继续的业务 Turn；
- V3 `Coordinator.Resume`：恢复该 Turn 内部的 Agent 执行状态。

## 建议阅读顺序：只走一条纵向链路

不要按目录扫代码。按下面顺序，每个文件只回答“输入、职责、输出”三个问题：

1. `TimeWeave/AIAnalysisView.swift`：用户能做什么；
2. `TimeWeave/Core/AIAnalysisViewModel.swift`：页面状态如何转换；
3. `TimeWeave/Core/AgentClient.swift`：网络协议是什么；
4. `selfweave-agent/internal/api/handler.go`：HTTP 如何映射到领域动作；
5. `selfweave-agent/internal/conversation/store.go`：事实状态如何持久化；
6. `selfweave-agent/internal/conversation/context.go`：历史如何变成有界上下文；
7. `selfweave-agent/internal/conversation/service.go`：如何调用 V3；
8. `selfweave-agent/internal/longtask/`：checkpoint、receipt、完成审核如何工作。

## 三组动手实验

### 实验一：证明重试不会重复执行

运行客户端测试：

```sh
swift test --filter AIChatViewModelTests/testSubmitRebuildsSnapshotAndRetryReusesMessageID
```

观察点：第二次请求的统计快照可以更新，但 `message_id` 不变。前者保证分析使用新鲜事实，后者保证同一意图不重复执行。

再运行服务端测试：

```sh
cd ../selfweave-agent
go test -run 'Test.*(Idempot|Conversation)' -v ./internal/conversation ./internal/api
```

观察点：相同 ID 返回同一个 Turn；相同 ID 搭配不同内容会失败。

### 实验二：证明历史、事实、记忆是三条不同通道

运行：

```sh
cd ../selfweave-agent
go test -run 'Test.*(ProjectContext|Memory)' -v ./internal/conversation
```

然后对照 `context.go` 和 `memory.go` 回答：

1. 超过最近 8 条的消息去了哪里？
2. proposed 记忆会不会进入下一轮模型上下文？
3. 当前分钟数为什么不能从 HistorySummary 读取？

### 实验三：观察一个完整远端友好的资源流程

先在 Agent 仓库配置模型环境变量，然后本地启动：

```sh
go run ./cmd/selfweave-server --state-dir .selfweave
```

在 App 中依次操作：新建对话、发送第一问、追问“那工作时间呢？”，再退出并重开分析页。观察：

- 重开后对话仍存在；
- 第二问能利用上一轮语义；
- 每轮统计仍来自各自提交时的新快照；
- `.selfweave/principals/` 保存产品级对话与记忆；
- `.selfweave/conversation-v3/` 保存每轮 V3 Thread 的可恢复状态；
- `.selfweave/conversation-runs/` 保存执行证据。

验证远端安全门槛时，不需要真的暴露公网，可以只验证服务拒绝无 Token 的非回环监听，以及配置 Token 后要求每个 `/v1/*` 请求携带 Bearer 身份。对应测试在 `internal/server/server_test.go` 和 `internal/api/handler_test.go`。

## 学完后的判断标准

你能不看代码回答下面 6 个问题，就已经掌握了本次核心：

1. 为什么“把上一问拼进 prompt”还不等于完整的上下文管理？
2. 为什么一次 Turn 要有自己的 Thread，而 Conversation 不直接复用一个 V3 Thread？
3. 网络超时后，系统靠什么避免同一问题执行两次？
4. 为什么旧回答能帮助理解追问，却不能提供本轮统计事实？
5. AI 主动发现的长期偏好为什么必须让用户确认？
6. 服务重启后，Conversation 恢复和 V3 checkpoint 恢复各负责哪一层？

一句话总结：**跨请求记忆不是让模型“自己记住”，而是应用把历史、当前事实、长期记忆和可恢复运行状态分别保存，再在每轮按规则重新组装。**
