# TimeWeave V4：跨请求对话上下文与长期记忆技术方案

日期：2026-11-04（Asia/Shanghai）

状态：技术方案，待用户确认；本文不授权开始实现。

分支：`codex/conversational-context-integration`（`timeweave-ios` 与 `selfweave-agent` 同名集成分支）

基线：`selfweave-agent/main` 已包含 V3 合并提交 `555f564 merge: add generic long-task runtime`。本文以 V3 的 Checkpoint、ContextPolicy、Tool receipt、Artifact、预算、锁和恢复语义为基础，不复制第二套 Agent Loop。

## 1. 决策摘要

TimeWeave 增加可跨请求、跨 App 重启继续的 AI 对话，并把“会话历史”“长期记忆”“当前时间事实”严格分开：

- `Conversation`：用户看到的一段持续对话，可包含多个已完成的 Turn；关闭 App 不结束对话。
- `Turn`：一次用户消息到一次最终回答；每个 Turn 使用一个独立的 V3 Thread 执行，因此 V3 的“完成后不可重新打开”不变。
- `Run`：一个 Turn 的一次连续执行尝试；超时或进程中断后可由同一 Turn 恢复。
- `UserMemory`：跨 Conversation 生效的少量稳定信息，如用户明确表达的目标、偏好和约束；不是聊天记录副本。
- `AnalysisSnapshot`：每个 Turn 提交时重新生成的当前事实；不写入长期记忆，不由历史摘要替代。

采用“外层 Conversation + 内层 V3 Thread/Turn”的组合，而不是把 V3 Thread 改造成可以在 `completed` 后继续追加消息。这样复用 V3 的可靠性能力，同时保持其终态不可变和恢复不变量。

本地和远端使用同一套 Conversation/Turn/Memory 协议与存储模型，不维护两套实现。回环服务映射到固定 local principal；远端和局域网服务直接复用现有 Bearer Token，把一个部署配置的 Token 映射到一个稳定 principal。首期不引入账号系统、设备配对或跨服务同步。

长期记忆采用可审计的混合策略：

1. 用户明确说“记住……”时直接保存，并提供撤销。
2. AI 可从用户直接表达中提出稳定、低敏感的目标/偏好/约束，但只有用户明确说“记住”时才自动生效；其他情况先展示候选，由用户确认。
3. 健康、情绪、关系、身份、第三方信息等敏感内容即使用户明确要求记住，也只能形成待确认候选，用户确认规范化后的准确文本后才生效。
4. 每条记忆都可查看、修改、删除，并保留来源消息、创建时间和最近确认时间。

## 2. 目标、非目标与失败条件

### 2.1 目标

1. 用户可以在同一 Conversation 中连续追问，Agent 能引用上一轮问题与回答。
2. App 重启、网络失败或服务进程重启后，对话和已提交 Turn 不丢失、不重复。
3. Agent 能在新 Conversation 中使用用户确认过或可审计的长期记忆。
4. 每轮分析始终以本轮最新 Snapshot 为事实源，不能把旧快照或模型摘要冒充当前数据。
5. 上下文超过模型窗口前可压缩；原始对话归档可追溯，工具调用组不被拆断。
6. 复用 V3 的持久状态、模型调用预留、工具回执、预算和恢复协议。
7. 用户能清楚知道哪些信息被记住、存在哪里，并能删除。
8. 同一套跨请求对话和长期记忆能力可部署在本机、局域网或远端服务，不把远端支持留给另一套后续实现。

### 2.2 非目标

- 不做“记住所有聊天”的无限原文上下文。
- 不做向量数据库、语义搜索平台或跨用户推荐系统。
- 不从时间记录自动推断健康、人格、情绪或人际关系。
- 不把 JSONL 运行日志当作会话记忆或长期记忆。
- 不做新的账号体系、设备配对或跨服务数据同步；远端直接复用现有 Bearer Token 作为服务端 principal 的认证来源。
- 不承诺多台独立服务之间自动迁移 Conversation 和 Memory；数据跟随当前分析服务保存。
- 不修改现有账本，不允许长期记忆绕过 Snapshot Tool 成为数字事实源。
- 不在本文阶段编写代码、实现计划或部署方案。

### 2.3 失败条件

出现以下任一情况即不算完成：

- 追问依赖客户端重发全部历史，服务端无法独立恢复对话；
- 重试同一消息产生两条 Turn 或两次付费执行；
- Conversation 完成一轮后被误标为 V3 `completed`，无法继续追问；
- 模型生成的摘要覆盖或改写了精确时间事实；
- Agent 暗中保存长期记忆，用户无法发现或删除；
- 敏感推断未经确认进入长期记忆；
- 为了聊天语义破坏 V3 已有 Thread 终态和恢复不变量。

## 3. 现状与为什么 V2/V3 不能直接满足

### 3.1 V2 分析接口

当前 `POST /v1/analysis` 只有 `question + snapshot`。每次请求创建新的 Runner、Run ID 和 Snapshot Tool；回答结束后单次 Run 的 `messages` 被释放。`run_id` 只关联日志，不是 Conversation ID。

iOS 的 `AIAnalysisViewModel` 只保存当前问题、当前响应和当前请求任务；新结果覆盖旧结果。因此客户端和服务端都没有跨请求聊天身份。

### 3.2 V3 长任务运行时

V3 已具备：

- 稳定 `thread_id` 与多次 `run_id`；
- 递增 Checkpoint 和父链校验；
- 消息、摘要、上下文归档和 Artifact manifest；
- 工具操作、回执、幂等/恢复策略；
- 模型调用预算预留和未知结果处理；
- 上下文压缩、暂停恢复和完成审核。

但 V3 Thread 表示“一项要完成的任务”。候选答案通过审核后，Thread 进入 `completed`，`Resume` 只恢复未完成任务，不接受一个新的用户目标。聊天则要求同一个 Conversation 连续产生多个已完成 Turn。两者生命周期不同，不能把 `resume` 当成追问。

## 4. 方案选择

### 4.1 采用：Conversation 包含多个独立 V3 Turn Thread

```text
Conversation conv-1（持续存在）
├── Turn turn-1 -> V3 Thread thread-turn-1 -> Run A -> completed
├── Turn turn-2 -> V3 Thread thread-turn-2 -> Run B/Run C -> completed
└── Turn turn-3 -> V3 Thread thread-turn-3 -> ...

跨 Turn：对话摘要、近期问答、长期记忆、当前 Snapshot
Turn 内：V3 消息、工具调用/结果、Checkpoint、预算、回执、恢复
```

优点：

- V3 Thread 的完成终态保持不可变；
- 一个 Turn 出错不破坏整个 Conversation；
- 可单独审计、重试或恢复某一轮；
- Conversation 上下文只保留用户可见问答，不被前几轮的底层工具噪音污染。

代价：需要新增 ConversationStore 和面向“用户可见 Turn”的压缩投影，并在 Turn 完成时原子提交回答到 Conversation。

### 4.2 不采用：完成后重新打开同一个 V3 Thread

代码表面更少，但会破坏 `completed` 的终态语义、完成审核和冻结 Goal；旧工具操作与新问题混在同一任务中，恢复边界也变得含糊。

### 4.3 不采用：iOS 每次重发全部聊天历史

短期实现简单，但服务端无法独立恢复和审计，客户端丢数据即失忆；请求体、费用和隐私面持续增长，也无法可靠处理并发与幂等。

### 4.4 延后：向量检索式长期记忆

目前长期记忆规模很小，按类型和状态直接加载即可。引入 Embedding/向量库会增加召回错误、删除一致性和隐私成本，却没有现实数据规模收益。

## 5. 总体架构

```text
iOS AI 对话页
  -> Conversation API
      -> Auth Principal / Local Owner
      -> ConversationService
          -> ConversationStore（对话、Turn、可见消息、摘要）
          -> MemoryStore（跨对话用户记忆）
          -> ConversationContextProjector
          -> TurnWorker（持久队列、后台执行、启动恢复、显式取消）
          -> TurnAssembler
              -> V3 Coordinator（每个 Turn 一个 Thread）
                  -> ContextPolicy / Model / ToolExecutor
                  -> Snapshot Tool / Memory proposal Tool
                  -> V3 Checkpoint / Receipt / Artifact / RunLog
```

边界原则：

- ConversationService 负责多轮产品语义，不执行模型—工具循环。
- V3 Coordinator 负责单个 Turn 的可靠执行，不理解 Conversation 列表或 UI。
- Snapshot Tool 只返回本 Turn 的不可变快照。
- MemoryStore 只保存经过策略判定的结构化记忆，不保存模型自由文本日志。
- TurnWorker 只消费已经持久化的 accepted Turn；客户端是否继续轮询不影响执行。服务启动时扫描 accepted/running/paused Turn，并按 V3 Checkpoint 安全恢复。
- JSONL 只用于审计；ConversationStore 和 V3 Checkpoint 才是恢复事实源。

## 6. 身份与生命周期

### 6.1 标识

| 标识 | 作用域 | 语义 |
| --- | --- | --- |
| `principal_id` | 用户/本地拥有者 | Conversation 与 Memory 的所有权边界 |
| `conversation_id` | Conversation | 一段可持续追问的对话 |
| `message_id` | 客户端生成、Conversation 内唯一 | 幂等键；相同消息重试不得新建 Turn |
| `turn_id` | Conversation | 一次用户消息到最终回答 |
| `thread_id` | V3 | Turn 对应的持久执行任务，建议由 `turn_id` 稳定派生 |
| `run_id` | V3 Thread | 一次连续执行或恢复尝试 |
| `checkpoint_id` | V3 Thread | 已提交执行状态版本 |
| `snapshot_revision` | Turn | 本轮统计快照的内容摘要/版本 |
| `memory_id` | Principal | 一条长期记忆 |

Conversation ID 和 Turn ID 不是认证凭证。所有读取和写入都必须验证其属于当前 `principal_id`。

### 6.2 生命周期

```text
Conversation: active -> deleted

Turn: accepted -> running -> completed
                       \-> paused -> running
                       \-> needs_attention
                       \-> cancelled
```

Conversation 不因一个 Turn 完成而完成。默认进入最近使用的 Conversation；用户可新建、切换或删除对话。新建对话不会改变旧对话的状态，旧对话继续出现在历史列表。首期不增加 `archived` 状态，避免形成没有产品价值的生命周期分支。

同一 Conversation 只允许一个写入中的 Turn。第二个并发追问返回稳定的 `conversation_busy`，而不是并行修改上下文。

## 7. 持久数据模型

以下字段表达语义，不冻结具体 Swift/Go 类型：

```text
Conversation
  schema_version
  principal_id, conversation_id
  title, lifecycle
  latest_revision
  visible_messages[]             # 用户问题与最终回答，不含底层工具噪音
  summary_ref
  archived_context_refs[]
  recent_turn_ids[]
  active_turn_id?
  created_at, updated_at

Turn
  turn_id, conversation_id, message_id
  user_message
  snapshot_revision, snapshot_ref
  context_revision               # 启动时冻结的 Conversation revision
  v3_thread_id
  lifecycle
  answer?
  memory_change_refs[]
  created_at, updated_at

UserMemory
  memory_id, principal_id
  kind                           # goal | preference | constraint
  text
  status                         # proposed | active | rejected | deleted
  sensitivity                    # normal | sensitive
  origin                         # explicit_user | agent_observed | user_edited
  source_conversation_id
  source_message_id
  created_at, updated_at, last_confirmed_at?
```

Snapshot 作为不可变对象先落盘，再由 Turn 引用。Conversation 可见消息、Turn 终态和 Memory change 必须通过带父版本/CAS 的提交写入，防止旧 Turn 覆盖新状态。

## 8. 一次追问的执行协议

1. iOS 生成稳定 `message_id`，用 `conversation_id + message_id + question + 当前分析周期 + 最新 snapshot` 提交 Turn。
2. 服务端校验认证主体、请求大小、Snapshot 一致性和 Conversation 状态。
3. 若 `message_id` 已存在：
   - 已完成：直接返回原结果；
   - 运行/暂停：恢复或返回当前状态；
   - 不得创建第二个 Turn。
4. ConversationService 在锁内冻结当前 Conversation revision、近期可见消息、摘要引用和 active memories，创建 Turn 与对应 V3 Thread。
5. TurnAssembler 构造本轮初始上下文；Snapshot 通过本轮只读 Tool 暴露，不复制进长期记忆。
6. V3 Coordinator 执行模型—工具循环；每次模型调用和工具调用沿用 V3 的预算预留、Checkpoint 和回执协议。
7. 模型给出候选回答后，CompletionEvaluator 至少检查：已成功读取 Snapshot、回答非空、记忆工具调用符合策略。
8. Turn 完成后，在 Conversation 锁内校验起始 `context_revision` 仍有效，原子追加用户消息和最终回答，提交 memory changes，清除 active Turn。
9. 创建 Turn 的 API 在持久化 accepted 状态后返回 `202 + turn_id`；iOS 通过 GET Turn 查询，直到获得 `run_id + answer + memory_changes`。首期使用有退避的短轮询，后续可增加 SSE，但不改变领域协议。
10. HTTP 取消只终止当前等待/查询，不取消已经 accepted 的 Turn；显式“停止”才请求取消 Turn。客户端重新提交相同 `message_id` 时只返回原 Turn，不重复付费执行已经提交的步骤。

Conversation 不绑定 7 天或 30 天周期。每个 Turn 单独记录本轮周期和 Snapshot revision，允许用户在同一对话中切换周期。当前 Snapshot 不足以回答比较问题时，Agent 必须说明缺少哪段事实并引导用户切换到能覆盖该范围的周期；首期不得静默扩大上传范围，也不改造 Snapshot 数据维度。跨周分类比较等现有聚合契约无法支持的问题应明确拒绝推断，留给后续查询型 Tool 设计。

## 9. 每次模型调用的上下文

### 9.1 Turn 内普通决策调用

模型收到：

1. TimeWeave 不可覆盖的系统安全与事实规则；
2. 本场景冻结的 Skill；
3. active UserMemory 的结构化投影，并明确标记为“用户记忆，不是统计事实”；
4. Conversation 摘要（若存在）；
5. 最近若干完整用户/助手可见 Turn；
6. 当前用户问题；
7. 当前 Turn 已产生的 assistant 工具调用和 tool 结果；
8. 当前可用工具定义，包括 Snapshot 读取、上下文归档读取和受控记忆提议工具；
9. 本次最大输出 Token。

模型默认不收到：全部历史日志、旧 Turn 的底层工具轨迹、Checkpoint 字段、预算明细、其他用户记忆、已删除/拒绝记忆、原始账本记录。

### 9.2 Conversation 压缩调用

压缩调用只收到：压缩规则、既有摘要、待归档的旧可见 Turn、来源范围和需要保持的长期目标/未解问题；不提供业务写工具。输出必须是结构化摘要并校验来源范围。

Conversation 压缩复用 V3 ContextPolicy 的核心原则：

- Token 计算包含系统消息、工具 schema 和输出预留；
- 在模型实际窗口的安全阈值前触发，而不是固定假设所有模型都是 100 万 Token；
- assistant tool call 与对应 tool result 不拆分；
- 原始历史写入不可变 archive，摘要只负责投影；
- 重复压缩必须带上上一版摘要，避免早期决策悄悄丢失；
- 失败达到上限时暂停，不带损坏摘要继续。

默认阈值沿用 V3 的 `70%` 触发、`40%` 目标作为初值，但 `ContextWindowTokens` 必须来自模型配置，不再使用与供应商无关的硬编码 100 万窗口。

## 10. 长期记忆策略

### 10.1 可以记住什么

- 用户直接表达的长期目标：例如“希望每周保持三次阅读”。
- 稳定偏好：例如“分析时先指出最值得调整的一点”。
- 稳定约束：例如“工作日晚上不安排高强度任务”。

### 10.2 不能自动记住什么

- 由时间分布推断的健康、情绪、人格或关系结论；
- 第三方姓名、身份和隐私；
- 密钥、Token、服务地址等安全信息；
- 某一周的分钟数、分类占比等 Snapshot 事实；
- 模型自己提出但用户没有表达的目标；
- 一次性计划、临时情绪或上下文不足的歧义表达。

### 10.3 写入机制

模型不能直接写 MemoryStore，只能调用 `propose_user_memory`，提交：`kind`、规范化文本、来源 `message_id`、是否由用户明确要求记住。

运行时根据确定性策略处理：

| 情况 | 结果 |
| --- | --- |
| 用户明确要求记住、内容低敏感且不在禁止项 | `active`，回答中展示并支持撤销 |
| 用户直接表达但未明确要求记住的 goal/preference/constraint | `proposed`，用户确认后生效 |
| 敏感内容，即使用户明确要求记住 | `proposed`，用户确认规范化文本后生效 |
| AI 推断、歧义或分类不确定 | 不自动保存；若确有长期价值，仅可 `proposed` |
| Snapshot 数字、安全信息、第三方隐私等禁止项 | 拒绝写入并记录安全事件 |

运行时只用确定性规则执行类型 allowlist、禁止项、长度、来源和状态转换；模型负责提出候选，但模型自报的“低敏感/稳定”不构成授权。无法由确定性规则确认安全的候选一律进入 `proposed`，不增加第二个模型分类器。首期中文规则为主，但任何未识别语言都走保守的 `proposed`，不能自动 active。

去重按规范化后的 `kind + text` 执行。语义冲突不尝试由运行时自动判断和覆盖：模型可以提出“更新某条记忆”，但必须由用户确认替换。删除后该内容立即停止进入模型上下文，并在本地同步删除主体和索引；若文件删除失败则整体操作失败，不声称已经删除。

### 10.4 用户控制

iOS 增加“AI 对我的了解”页面：

- 查看 active 和 proposed 记忆；
- 确认、编辑、拒绝、删除；
- 查看来源对话和时间；
- 关闭自动记忆；
- 一键清空长期记忆。

界面不展示内部 prompt 或工具轨迹，只展示用户能理解的记忆文本和来源。

“自动记忆”更准确地表示“AI 主动提出记忆候选”，默认开启，作用域是当前分析服务下的 principal，而不是单个 Conversation。关闭后 AI 不再主动提出候选，但用户明确说“记住……”仍会进入上述保存/敏感确认流程。该设置持久化在 PrincipalPreferences 中，并在本地、远端服务环境之间隔离。

## 11. HTTP API 草案

保留 `POST /v1/analysis` 作为无状态兼容入口。新能力使用资源式接口，所有 DTO 继续带 `schema_version: 1`、拒绝未知字段并限制请求体。

```text
POST   /v1/conversations
GET    /v1/capabilities
GET    /v1/conversations
GET    /v1/conversations/{conversation_id}
DELETE /v1/conversations/{conversation_id}

POST   /v1/conversations/{conversation_id}/turns
GET    /v1/conversations/{conversation_id}/turns/{turn_id}
POST   /v1/conversations/{conversation_id}/turns/{turn_id}/cancel

GET    /v1/memories
PATCH  /v1/memories/{memory_id}
DELETE /v1/memories/{memory_id}
POST   /v1/memories/{memory_id}/confirm
POST   /v1/memories/{memory_id}/reject
```

Turn 请求示意：

```json
{
  "schema_version": 1,
  "message_id": "msg-client-generated",
  "question": "那和上周相比呢？",
  "period_days": 30,
  "snapshot": {
    "range": {},
    "total_minutes": 0,
    "categories": [],
    "days": []
  }
}
```

创建 Turn 的 accepted 响应示意：

```json
{
  "schema_version": 1,
  "conversation_id": "conv-...",
  "turn_id": "turn-...",
  "status": "accepted"
}
```

`GET Turn` 完成响应示意：

```json
{
  "schema_version": 1,
  "conversation_id": "conv-...",
  "turn_id": "turn-...",
  "status": "completed",
  "run_id": "run-...",
  "answer": "...",
  "memory_changes": [
    {
      "memory_id": "memory-...",
      "status": "active",
      "text": "希望优先改善晚间工作过多的问题"
    }
  ]
}
```

稳定错误至少包括：`conversation_not_found`、`conversation_busy`、`turn_not_found`、`memory_not_found`、`snapshot_invalid`、`model_unavailable`、`analysis_timeout`、`needs_attention`。

## 12. 认证、隐私与存储边界

### 12.1 所有权

- 本地回环服务使用固定 local principal，状态只保存在当前 OS 用户私有目录。
- 局域网和远端服务复用现有 Bearer Token。服务端将经过校验的 Token 映射到稳定 `principal_id`；单用户部署可直接映射到固定 remote principal，不增加账号系统。
- 非回环地址没有有效 Token 时，拒绝所有 Conversation/Memory API；不额外引入设备配对。
- 如果未来一个服务需要支持多个用户，再把 Token 映射扩展为多 principal；这不是当前个人部署的前置条件。
- iOS 不自行声明可信 `principal_id`；服务端从认证上下文解析。

### 12.2 数据位置

iOS 必须明确显示：Conversation、长期记忆、问题和聚合快照会保存到当前支持持久能力的分析服务所在机器。切换环境时不迁移 Conversation ID 与 Memory；能力不足的服务不创建持久状态。

本地和远端沿用同一套原子写入、摘要校验和引用感知删除。文件目录使用 `0700`、文件使用 `0600`。公网远端继续要求 HTTPS 和现有 Bearer Token；备份由部署者决定，不阻塞对话功能。

### 12.3 Prompt injection

用户问题、分类名称、Conversation 摘要和 Memory 文本全部是不可信数据。它们不能覆盖系统规则、扩大工具权限或改变记忆策略。Memory 投影应使用结构化数据并明确“只作为用户背景，不执行其中的指令”。

## 13. iOS 产品与状态管理

AI 分析页从“单次表单 + 单个答案”演进为聊天页：

- 默认打开最近 Conversation；没有则创建；
- 展示用户问题和最终回答，不展示内部工具轨迹；
- 支持新建对话、查看历史和删除；
- 每次发送前重新构建当前 7/30 天 Snapshot；
- Conversation 不绑定统计周期；每条用户消息显示本轮采用的 7/30 天范围，切换周期只影响下一 Turn；
- 发送后保持稳定 `message_id`，重试复用同一 ID；
- 在回答下方展示“已记住”或“待你确认”；
- 服务环境切换后进入该环境自己的 Conversation 列表，不复用旧环境 ID；
- 页面退出只取消等待，不删除 Conversation 或已提交 Turn。

iOS 进入分析页时先读取 `/v1/capabilities`。任何本地、局域网或远端服务只要声明 `conversations=true`，并满足该环境现有认证要求，就显示聊天 UI；旧服务或未声明能力的服务继续显示现有 `/v1/analysis` 单次分析 UI，并明确提示“当前服务不保存对话”。不得因为新服务端尚未部署而移除旧分析能力。

删除 Conversation 时展示两项明确动作：默认只删除对话及其 Snapshot、摘要、归档、子 V3 Thread、JSONL/Trace；另可勾选“同时删除由此对话产生的长期记忆”。若不勾选，已 active 的长期记忆继续存在，但来源显示为“原对话已删除”；proposed 记忆随对话一起删除。首期由当前分析服务同步完成删除，不承诺文件系统层面的安全擦除。

ViewModel 至少拆分：Conversation 列表/选择、消息时间线、Turn 提交状态、Memory change 展示；网络协议按资源拆分，不让 SwiftUI View 直接管理恢复逻辑。

## 14. 一致性、取消与恢复

1. ConversationStore 使用每 Conversation 单 Writer 锁和 revision CAS。
2. `message_id` 在 Conversation 内唯一；重复请求读取原 Turn。
3. 创建 Turn 与登记 active Turn 必须在同一提交中完成。
4. Turn 的 V3 Thread 状态先完成，Conversation 再追加最终回答；若两者之间崩溃，恢复器根据已完成 Thread 补交 Conversation，而不是重新调用模型。
5. Conversation 已追加回答但响应丢失时，重复 `message_id` 返回原答案。
6. 客户端停止轮询、页面退出或请求取消不影响 accepted Turn；TurnWorker 继续后台执行。只有显式 cancel API 才取消/暂停执行并提交恢复点。
7. 记忆变化与 Turn 回答一起提交；若 MemoryStore 提交失败，Turn 不得声称“已经记住”。
8. 删除 Conversation 时若有 active Turn，先取消并提交终态，再执行引用感知删除。

## 15. 测试与验收

### 15.1 `selfweave-agent`

- ConversationStore 的创建、revision、锁、删除和损坏检测；
- 同一 `message_id` 重试只产生一个 Turn；
- Turn 完成后 Conversation 保持 active，可继续下一轮；
- V3 Thread 完成后、Conversation 提交前崩溃的恢复；
- 客户端停止轮询后 Turn 继续执行，服务重启后自动恢复 accepted/running Turn，显式 cancel 才停止；
- Conversation 压缩保留目标、近期问答、archive refs，重复压缩不丢旧摘要；
- 当前 Snapshot 每 Turn 隔离，并发 Conversation 不串数据；
- Memory allowlist、敏感候选、禁止项、冲突、撤销和删除；
- 被删除/拒绝 Memory 不再进入 ModelRequest；
- Prompt injection 不能改变记忆策略或调用未授权工具；
- 局域网/远端缺失或使用错误 Bearer Token 时拒绝持久接口；正确 Token 可完整创建、恢复和删除 Conversation/Memory；
- 现有 `/v1/analysis` 和 V3 CLI 全量回归。

### 15.2 `timeweave-ios`

- Conversation 与环境隔离、跨重启恢复；
- capabilities 探测：声明 conversations 能力的本地/局域网/远端服务进入聊天 UI，旧服务回退单次分析 UI；
- 每次发送重新构建 Snapshot；
- 重试复用 `message_id`；
- 旧请求不能覆盖新 Conversation；
- 记忆新增、待确认、撤销、编辑和删除 UI；
- 服务切换、取消、超时、busy、needs_attention 的稳定状态机；
- 无状态 `/v1/analysis` 兼容路径不回归。

### 15.3 端到端验收

1. 第一问：“过去 7 天最值得关注什么？”
2. 关闭并重启 App。
3. 追问：“那和刚才说的工作时间有什么关系？”Agent 能引用上一答。
4. 用户说：“记住，我希望优先减少晚间工作。”UI 显示已记住。
5. 新建 Conversation，询问建议；Agent 能使用该目标，但仍用本轮最新 Snapshot 引用分钟数。
6. 删除该记忆后再次新建 Conversation；ModelRequest 中不再出现该目标。
7. 在工具执行后强制终止服务，使用同一 `message_id` 重试；不重复工具副作用或模型已提交步骤。
8. 将 iOS 切换到带有效 Token 的远端服务，重复步骤 1～7；行为与本地一致，App 重启后仍能继续对话。

## 16. 分阶段交付建议

阶段只用于控制风险，不改变最终架构：

1. **Conversation 基础**：多 Turn、跨重启、幂等、当前 Snapshot、无自动长期记忆。
2. **可控记忆**：显式“记住”、记忆管理页、删除/撤销、跨 Conversation 注入。
3. **主动记忆建议**：AI 提出低敏感候选、用户确认；敏感候选二次确认；冲突更新。
4. **上下文压缩**：在合成小窗口下先验证，再按真实模型 profile 开启。

以上每个阶段都同时走通本地与远端路径。远端不是第五阶段，也不另立一套方案；它只是同一服务通过现有 Token 对外提供相同 API。

不得为了阶段 1 快速上线而选择客户端重发历史；阶段 1 仍应建立最终 Conversation/Turn 身份与服务端存储。

## 17. 预计改动边界

### `selfweave-agent`

- 新增 Conversation/Memory 领域类型、Store、Service 和 ContextProjector；
- 抽取/复用 V3 ContextPolicy 的消息分组与压缩原语；
- 为每个 Turn 装配 V3 Coordinator、Snapshot Tool 和 Memory proposal Tool；
- 增加资源式 API、认证 principal 适配及错误映射；
- 扩展 Trace 关联 `conversation_id/turn_id/thread_id/run_id`，但不把 Trace 作为恢复源。

### `timeweave-ios`

- 新增 Conversation、Message、Turn、Memory DTO 与客户端；
- 将单结果页面改为消息时间线与输入区；
- 持久化每个服务环境最近 Conversation ID 和未完成 `message_id`；
- 增加 Conversation 管理和“AI 对我的了解”页面；
- 保留现有 SnapshotBuilder、服务设置、安全重定向和 Keychain 边界。

## 18. 待确认决策

本文建议并默认以下产品决策，需用户批准后才能进入实现计划：

1. Conversation 跨 App 重启保留，直到用户删除；新建 Conversation 不归档旧对话。
2. 当前阶段不做跨服务同步；本地、局域网真机和远端均支持持久对话，非回环服务复用现有 Bearer Token。只有旧服务回退无状态 `/v1/analysis`。
3. 采用“Conversation 包含多个独立 V3 Turn Thread”，不重新打开 completed Thread。
4. 用户明确要求记住的低敏感信息可直接生效；其余内容只能提出候选，敏感内容必须二次确认。
5. 现有 `/v1/analysis` 保留为无状态兼容入口。
6. Turn 使用 `202 accepted + GET Turn` 的异步协议；底层身份和存储从第一阶段即采用最终模型。
7. 当前集成分支的后续实现计划覆盖阶段 1～4，并在每个阶段同时验证本地与远端；不另立远端上下文方案。
