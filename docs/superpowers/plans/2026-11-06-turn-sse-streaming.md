# Turn SSE Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make SSE the primary way iOS waits for a submitted Conversation Turn, while keeping GET polling as recovery and backward-compatible fallback.

**Architecture:** The Agent exposes a state-snapshot SSE endpoint that immediately emits the current Turn and then emits only changed Turn snapshots until a terminal state closes the stream. The iOS client submits with the existing `202 + turn_id` contract, consumes that stream, and falls back to the existing bounded polling path whenever streaming is unavailable or interrupted. Persisted Turn state remains the source of truth, so SSE needs no separate event log.

**Tech Stack:** Go 1.23 `net/http`, Server-Sent Events, Swift 6, Foundation `URLSession`, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-04-conversational-context-memory-design.md`

## Global Constraints

- Keep `POST Turn -> 202 + turn_id`; SSE must not own task durability.
- Keep GET Turn as disconnect, foreground-resume, and old-server fallback.
- Stream full public Turn snapshots, never Snapshot input or private V3 state.
- A client disconnect must not cancel the accepted Turn.
- This change streams Turn state and the final answer; token-by-token model output is out of scope.

## Review Focus

- A terminal Turn present before subscription must be emitted once and close immediately.
- A stream disconnect before terminal state must recover through GET without resubmitting the Turn.
- Unknown or cross-principal IDs must return the existing JSON domain error before SSE headers.
- Authentication and redirect rejection must apply exactly as they do to other Conversation APIs.
- Cancellation of the iOS waiting task must stop waiting without calling the Turn cancel endpoint.

---

### Task 1: Agent Turn event stream

**Files:**
- Modify: `selfweave-agent/internal/api/handler.go`
- Test: `selfweave-agent/internal/api/handler_test.go`
- Modify: `docs/superpowers/specs/2026-11-04-conversational-context-memory-design.md`

**Interfaces:**
- Consumes: existing `conversation.Service.GetTurn` and `publicTurn` DTO.
- Produces: `GET /v1/conversations/{conversation_id}/turns/{turn_id}/events`, with `event: turn` and a full `publicTurn` JSON `data` payload.

- [ ] **Step 1: Write failing HTTP tests**

Add tests proving the endpoint sets `text/event-stream`, flushes the current state, emits the terminal state, closes, and returns JSON `turn_not_found` before opening a stream for an invalid Turn.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `go test ./internal/api -run 'TestConversationTurnEvents' -count=1`

- [ ] **Step 3: Implement the minimal SSE state stream**

Serialize the existing public Turn DTO, compare successive serialized snapshots, write only changes, send periodic comment heartbeats, and close after any terminal status. Use persisted state as the source of truth.

- [ ] **Step 4: Run API tests and verify GREEN**

Run: `go test ./internal/api -count=1`

### Task 2: iOS SSE-first waiting with polling fallback

**Files:**
- Modify: `TimeWeave/Core/AgentClient.swift`
- Test: `Tests/TimeWeaveCoreTests/AgentClientTests.swift`

**Interfaces:**
- Consumes: Task 1 `turn` SSE events.
- Produces: unchanged `AgentConversing.sendMessage` and `resumeTurn` behavior, now SSE-first with GET fallback.

- [ ] **Step 1: Write failing client tests**

Add tests proving a terminal `turn` event completes without GET polling, and an unsupported/interrupted SSE request falls back to GET without issuing another POST.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter AgentClientTests`

- [ ] **Step 3: Implement the SSE parser and fallback**

Open the events URL with `Accept: text/event-stream`, parse SSE frames incrementally, validate every Turn using the existing rules, return on terminal state, and fall back to bounded polling for any non-cancellation stream failure.

- [ ] **Step 4: Run client tests and verify GREEN**

Run: `swift test --filter AgentClientTests`

### Task 3: End-to-end verification and learning documentation

**Files:**
- Modify: `docs/conversational-context-learning-guide.md`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces: documentation matching the shipped SSE-first behavior and its polling recovery boundary.

- [ ] **Step 1: Update the request flow and explain state streaming versus token streaming**

- [ ] **Step 2: Run full verification**

Run: `go test -race ./...` and `go vet ./...` in `selfweave-agent`; run `swift test` plus generic simulator and device builds in `timeweave-ios`.

- [ ] **Step 3: Review both repository diffs and merge only after all checks pass**

