# Conversational Chat UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-result analysis experience with a persistent chat UI that uses the Agent Conversation API locally and remotely, while preserving legacy `/v1/analysis` fallback.

**Architecture:** `AgentClient` gains resource DTOs and a small polling client. A new chat state machine, kept in the existing core file to avoid touching the user-modified Xcode project, owns capability selection, Conversation restoration, stable message IDs, retries, and Memory actions. SwiftUI renders that state without managing recovery logic.

**Tech Stack:** Swift 6, Swift Concurrency, Foundation/URLSession, SwiftUI, XCTest/Swift Package Manager.

**Spec:** `docs/superpowers/specs/2026-11-04-conversational-context-memory-design.md`

## Global Constraints

- Reuse the current service environment and Keychain Bearer Token.
- Build a fresh 7/30-day snapshot for every submitted Turn.
- A retry reuses the pending `message_id`; App/UI cancellation stops polling but not server work.
- Capability absence falls back to existing stateless `/v1/analysis`.
- Do not modify or stage the pre-existing `TimeWeave.xcodeproj/project.pbxproj` change.
- No new third-party dependency and no Go-language tutorial.

## Review Focus

- A stale request from a previous service environment must never replace the current Conversation (Task 2 test).
- Retrying after transport failure must reuse `message_id` and avoid a duplicate user bubble (Task 2 test).
- Polling must stop on terminal statuses and reject malformed/oversized responses (Task 1 test).
- Capability failure from an old server must select legacy analysis without erasing the user’s draft (Task 2 test).
- Deleting or confirming memory must update the visible list only after server success (Task 2 test).

---

### Task 1: Conversation HTTP client

**Files:**
- Modify: `TimeWeave/Core/AgentClient.swift`
- Modify: `Tests/TimeWeaveCoreTests/AgentClientTests.swift`

**Interfaces:**
- Produces: Codable/Sendable `AgentCapabilities`, `Conversation`, `ConversationSummary`, `ChatMessage`, `ConversationTurn`, `UserMemory`.
- Produces: `AgentConversing` methods for capabilities, conversation CRUD, Turn submission/polling/cancel, and Memory list/confirm/reject/delete.

- [ ] **Step 1: Write failing request/response contract tests**

Add `testConversationClientDiscoversCapabilitiesAndCreatesConversation`, `testConversationClientSubmitsStableMessageAndPollsToCompletion`, and `testConversationClientRejectsMalformedTerminalTurn` with literal URLs, methods, headers, and bodies.

- [ ] **Step 2: Run tests to verify RED**

Run: `swift test --filter AgentClientTests`
Expected: FAIL because chat DTOs/protocol methods do not exist.

- [ ] **Step 3: Implement resource methods and bounded polling**

Reuse redirect rejection, Bearer headers, 4 MiB response limit, and typed server errors. `sendMessage` accepts a caller-supplied message ID, POSTs once, then polls GET with capped backoff until a terminal Turn.

- [ ] **Step 4: Run focused tests and commit**

Run: `swift test --filter AgentClientTests`
Expected: PASS.

Commit: `feat: add conversation api client`

---

### Task 2: Chat state machine and persistence

**Files:**
- Modify: `TimeWeave/Core/AIAnalysisViewModel.swift`
- Create: `Tests/TimeWeaveCoreTests/AIChatViewModelTests.swift`

**Interfaces:**
- Consumes: Task 1 `AgentConversing`.
- Produces: `AIChatViewModel` with mode, conversations, current timeline, memories, draft, loading/error, `load`, `submit`, `retry`, `newConversation`, `deleteCurrentConversation`, and Memory actions.

- [ ] **Step 1: Write failing state-machine tests**

Add `testChatLoadsLatestConversationAndPersistsSelection`, `testSubmitRebuildsSnapshotAndRetryReusesMessageID`, `testEnvironmentChangeRejectsStaleResult`, `testOldServerFallsBackToLegacyAnalysis`, and `testMemoryActionsUpdateAfterServerSuccess`.

- [ ] **Step 2: Run tests to verify RED**

Run: `swift test --filter AIChatViewModelTests`
Expected: FAIL because `AIChatViewModel` does not exist.

- [ ] **Step 3: Implement the MainActor state machine**

Keep server-owned messages authoritative. Persist only the latest Conversation ID per service origin in `UserDefaults`; never persist snapshots or tokens there. Keep a failed message’s UUID for retry and generate a new UUID only after terminal success or explicit draft replacement.

- [ ] **Step 4: Run all core tests and commit**

Run: `swift test`
Expected: PASS.

Commit: `feat: manage persistent analysis conversations`

---

### Task 3: SwiftUI chat and controlled-memory experience

**Files:**
- Modify: `TimeWeave/AIAnalysisView.swift`
- Modify: `UITests/LocalAnalysisUITests.swift`

**Interfaces:**
- Consumes: Task 2 `AIChatViewModel`.
- Produces: timeline UI, draft composer, new/delete Conversation controls, capability/legacy notice, and “AI 对我的了解” Memory sheet.

- [ ] **Step 1: Update UI test expectations before production UI**

Change the UI test flow to assert stable identifiers for the timeline, composer, send button, new Conversation action, and Memory sheet. Keep the existing legacy result assertion for old servers.

- [ ] **Step 2: Implement the chat presentation**

Render visible user/assistant messages, a non-blocking pending indicator, retry/error cards, and memory confirm/reject/delete buttons. The View calls ViewModel actions only; it does not poll or build requests.

- [ ] **Step 3: Run build and core tests**

Run: `swift test`
Expected: PASS.

Run: `xcodebuild -project TimeWeave.xcodeproj -scheme TimeWeave -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: BUILD SUCCEEDED.

Commit: `feat: present analysis as persistent chat`

---

### Task 4: Project-specific learning guide and end-to-end verification

**Files:**
- Create: `docs/conversational-context-learning-guide.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: final Agent and iOS behavior.
- Produces: a Chinese learning path that teaches the architecture without requiring Go syntax.

- [ ] **Step 1: Write the learning guide**

Explain Conversation/Turn/Run, server-authoritative state, idempotency, context projection, controlled memory, async polling, remote identity, and crash recovery through TimeWeave’s request path. Include file-reading order, diagrams, and hands-on experiments/tests; do not teach Go language syntax.

- [ ] **Step 2: Update README entry points**

Link the design, implementation plans, and learning guide; document local and authenticated remote startup at a product level.

- [ ] **Step 3: Run full verification and commit**

Run: `swift test`
Expected: PASS.

Run: `xcodebuild -project TimeWeave.xcodeproj -scheme TimeWeave -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: BUILD SUCCEEDED.

Commit: `docs: add conversational context learning guide`

