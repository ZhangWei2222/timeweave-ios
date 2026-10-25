# Timer Entry Interaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace form-first time entry with a persistent start/stop timer and reference-aligned confirmation editor.

**Architecture:** Store the optional running start timestamp in `TimeLedger`, mutate it transactionally through `TimeStore`, and render the resulting idle/running/editor states in `DayView`. Keep final entry validation in the existing ledger path and make `EntryEditor` a reusable page-owned bottom-panel editor rather than a system sheet.

**Tech Stack:** Swift 6, SwiftUI, Foundation, XCTest, iOS 16+

**Spec:** `docs/superpowers/specs/2026-10-25-timer-entry-interaction-design.md`

## Global Constraints

- iOS 16 or later, SwiftUI, Chinese UI, no third-party dependencies.
- Running duration derives from timestamps; no background execution dependency.
- Existing overlap, future-time, cross-day and persistence rules remain authoritative.
- Existing ledger files without timer state must decode unchanged.

## Review Focus

- Legacy ledger JSON without `activeTimerStart` decodes with an idle timer.
- A second start does not overwrite the first start time.
- An invalid stop does not clear the running timer.
- Cancellation clears only timer state and does not remove saved entries.
- A save error leaves the confirmation editor and input intact.

---

### Task 1: Persistent timer domain state

**Files:**
- Modify: `TimeWeave/Core/TimeLedger.swift`
- Modify: `Tests/TimeWeaveCoreTests/LedgerTests.swift`

**Interfaces:**
- Produces: `TimeLedger.activeTimerStart: Date?`, `startTimer(at:now:)`, `stopTimer(at:) -> DateInterval`, and `cancelTimer()`.

- [ ] **Step 1: Write failing tests** for legacy decoding, start/duplicate-start, stop/invalid-stop, and cancellation preserving entries.
- [ ] **Step 2: Run** `swift test --filter LedgerTests` and confirm failures are caused by missing timer APIs/state.
- [ ] **Step 3: Implement** the optional Codable state and minimal state-transition methods.
- [ ] **Step 4: Run** `swift test --filter LedgerTests`, then `swift test`, and confirm both pass.

### Task 2: Transactional store operations

**Files:**
- Modify: `TimeWeave/TimeStore.swift`

**Interfaces:**
- Consumes: Task 1 timer APIs.
- Produces: `startTimer(at:)`, `stopTimer(at:) -> DateInterval`, and `cancelTimer()` for the UI.

- [ ] **Step 1: Add store methods** that route all timer mutations through the existing atomic `update` transaction and return the stopped interval.
- [ ] **Step 2: Run** `swift test` to confirm core behavior remains green; store integration is verified by both simulator/device compilation in Task 4.

### Task 3: Reference-aligned timer and editor UI

**Files:**
- Modify: `TimeWeave/DayView.swift`
- Modify: `TimeWeave/EntryEditor.swift`
- Modify: `TimeWeave/DesignSystem.swift`

**Interfaces:**
- Consumes: Task 2 store methods and existing `save(_:)` validation.
- Produces: idle action bar, running timer card, cancel confirmation, and bottom confirmation editor.

- [ ] **Step 1: Replace** the in-scroll add button with a `safeAreaInset` idle/running control that exposes stable accessibility identifiers.
- [ ] **Step 2: Wire** start, cancel and stop actions; pass the stopped `DateInterval` into the editor without preselecting a category.
- [ ] **Step 3: Restyle** `EntryEditor` as a page-owned custom bottom panel with its own dimming layer, transition, close action, side-by-side wheel times, live duration, category capsules, note field and inline errors; preserve existing edit/delete behavior and cross-day date controls without using system `sheet` or `Form` presentation.
- [ ] **Step 4: Add** accessibility labels and flexible layouts for dynamic type.

### Task 4: Verification and documentation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: Tasks 1–3 completed behavior.

- [ ] **Step 1: Update** the README feature and usage descriptions from form-first entry to persistent timer entry.
- [ ] **Step 2: Run** `swift test` and require zero failures.
- [ ] **Step 3: Run** simulator and device generic `xcodebuild` commands with code signing disabled and require exit code 0.
- [ ] **Step 4: Inspect** `git diff --check` and `git diff` against every design acceptance criterion.

