# ASC.14 wrapper implementation plan

## Round 2 — native single-session correction

### Spec and plan phase

> **QUALITY CONTRACT — operate to all three bars (full standard: ~/.claude/QUALITY_STANDARD.md). Each item is a checkable gate.**
> GOALS: serve the project's stated north-star goals + a real user problem vs a competent baseline (problem-first, not metric-supremacy). [append the project's specific goals here.]
> STAFF-ENG: production-only (no stubs/mocks/TODO); tested with shown passing output; reuse>reinvent; minimal reversible; verify-before-claim; rank a recommendation.
> PhD (any empirical claim): hypothesis-first; controlled apparatus (competent baseline + confounds-held + no starvation + best-config); powered pre-registered N; cross-family verified before any result is trusted; debug-apparatus-before-reframe; honest negatives valid; NEVER manufacture a win.
> APPLE PRINCIPLES (craft, all code): zero-config (clone+run core path in 60s); ≤5 public methods common path; raw exceptions → contextual domain errors; no just-in-case/unused code; zero-arg init = production-safe; one predictable pattern; sanitize at boundary + mask sensitive data; no blocking-I/O / N+1 / runaway memory. + POLISH GATE (UI only): one runtime, Dynamic Type/VoiceOver/Reduce Motion/60Hz, nothing half-wired ships.
> META-GATES: value/problem-first; definition-of-done + round-cap (don't loop forever); reproducible env; verify-the-verifier (non-vacuity); real human/peer/device is the last word.
> If a task can't meet the relevant bar at the stated budget, STOP and say so — never fake a green.

Project GOALS appended: represent LiteRT-LM v0.11.0 `db33d2c`'s native one-session-per-engine limit honestly; reject a second resident managed conversation with a stable typed Swift error; release the slot only after native deletion; preserve gates 2–7 and the single engine construction.

#### Acceptance criteria

- [x] One resident `LiteRTLMConversation` is permitted per engine.
- [x] A concurrent/sequential second `makeConversation` while the first is resident throws `LiteRTLMError.conversationSlotOccupied` before any native create attempt.
- [x] `close()` deletes the native conversation before releasing the managed slot; awaited close→reopen succeeds without constructing another engine.
- [x] Public Swift docs and all three packaged `engine.h` copies record the `db33d2c`, `engine.cc:923` native limit verbatim; iOS headers remain byte-identical.
- [x] The real-model XCTest covers A marker send, typed occupied rejection, A close, B isolation by content, exact stable tokenization, double close, idle cancel followed by send, positive native usage deltas, and engine construction count 1.
- [x] Gates 2–7 remain unchanged; device, simulator, macOS, and XCTest direct typechecks pass.
- [x] The report contains the exact `TEST_RUNNER_B4_LITERT_MODEL_PATH` chairman command and the required requested-range diff stat.

#### Files and sequence

1. `LiteRTLMEngine.swift`: add the typed error, public native-limit docs, and queue-confined occupied-slot guard.
2. `LiteRTLMConversation.swift`: correct the handle docs from multi-handle residency to one resident slot.
3. Three packaged `engine.h` files: add the identical native-limit note without changing declarations.
4. `LiteRTLMConversationIntegrationTests.swift`: rewrite the real-model contract in the required order and make destructive replacement an explicit `XCTFail` arm.
5. Verify red-first/clean controls, all requested typechecks, header identity, no-estimates rule, diff hygiene, and report evidence.

#### Review, risks, and rollback

- Race risk: checking outside `inferenceQueue` could admit two opens. Mitigation: guard on the same serial queue immediately before native config allocation.
- Early-release risk: removing the slot before native deletion could race reopen. Mitigation: preserve deletion-before-registry-removal ordering in `deleteManagedConversation`.
- Compatibility risk: changing legacy conversation/session APIs would expand scope. Mitigation: confine behavior to the round-1 managed handle factory and its docs/test.
- Raw-native-error risk: allowing a second native create would leak the `FAILED_PRECONDITION` failure. Mitigation: typed preflight before allocation/native create.
- Runtime-proof boundary: CoreSimulator is unavailable in this lane. Mitigation: typecheck all four surfaces and leave the one real-model XCTest to the chairman command; do not claim runtime green here.

Rollback is the surgical removal of only the round-2 hunks from these uncommitted files. No binary, package topology, branch history, tag, main branch, or external worktree changes are involved.

Plan review gate: **PASS (94/100)** — complete file/verification sequence, exact rollback boundary, five concrete risks, source/API alignment, and an explicit real-device authority. No architectural fork remains because the native one-session constraint fixes the design.

### Implement and verification phase

> **QUALITY CONTRACT — operate to all three bars (full standard: ~/.claude/QUALITY_STANDARD.md). Each item is a checkable gate.**
> GOALS: serve the project's stated north-star goals + a real user problem vs a competent baseline (problem-first, not metric-supremacy). [append the project's specific goals here.]
> STAFF-ENG: production-only (no stubs/mocks/TODO); tested with shown passing output; reuse>reinvent; minimal reversible; verify-before-claim; rank a recommendation.
> PhD (any empirical claim): hypothesis-first; controlled apparatus (competent baseline + confounds-held + no starvation + best-config); powered pre-registered N; cross-family verified before any result is trusted; debug-apparatus-before-reframe; honest negatives valid; NEVER manufacture a win.
> APPLE PRINCIPLES (craft, all code): zero-config (clone+run core path in 60s); ≤5 public methods common path; raw exceptions → contextual domain errors; no just-in-case/unused code; zero-arg init = production-safe; one predictable pattern; sanitize at boundary + mask sensitive data; no blocking-I/O / N+1 / runaway memory. + POLISH GATE (UI only): one runtime, Dynamic Type/VoiceOver/Reduce Motion/60Hz, nothing half-wired ships.
> META-GATES: value/problem-first; definition-of-done + round-cap (don't loop forever); reproducible env; verify-the-verifier (non-vacuity); real human/peer/device is the last word.
> If a task can't meet the relevant bar at the stated budget, STOP and say so — never fake a green.

Project GOALS appended: implement and verify the reviewed one-resident-slot contract without weakening exact token/usage, awaitable lifecycle, header identity, or no-estimate gates.

## Objective

Cut the source-compatible LiteRTLM-Swift wrapper needed by C242: one loaded engine with independently owned conversation handles, exact loaded-model tokenization, typed native usage, and awaitable idempotent cancellation/close.

## Research phase

> **QUALITY CONTRACT — operate to all three bars (full standard: ~/.claude/QUALITY_STANDARD.md). Each item is a checkable gate.**
> GOALS: serve the project's stated north-star goals + a real user problem vs a competent baseline (problem-first, not metric-supremacy). [append the project's specific goals here.]
> STAFF-ENG: production-only (no stubs/mocks/TODO); tested with shown passing output; reuse>reinvent; minimal reversible; verify-before-claim; rank a recommendation.
> PhD (any empirical claim): hypothesis-first; controlled apparatus (competent baseline + confounds-held + no starvation + best-config); powered pre-registered N; cross-family verified before any result is trusted; debug-apparatus-before-reframe; honest negatives valid; NEVER manufacture a win.
> APPLE PRINCIPLES (craft, all code): zero-config (clone+run core path in 60s); ≤5 public methods common path; raw exceptions → contextual domain errors; no just-in-case/unused code; zero-arg init = production-safe; one predictable pattern; sanitize at boundary + mask sensitive data; no blocking-I/O / N+1 / runaway memory. + POLISH GATE (UI only): one runtime, Dynamic Type/VoiceOver/Reduce Motion/60Hz, nothing half-wired ships.
> META-GATES: value/problem-first; definition-of-done + round-cap (don't loop forever); reproducible env; verify-the-verifier (non-vacuity); real human/peer/device is the last word.
> If a task can't meet the relevant bar at the stated budget, STOP and say so — never fake a green.

Project GOALS appended: prove the exact ABI from the shipped binary's own LiteRT-LM revision and stop rather than guess; preserve the established loader and bundle topology.

- [x] Verify branch `b4-asc.14` starts at tag `1.0.0-b4-asc.13` / `78b6a42`.
- [x] Read the C242 ResearchPack and inspect the complete relevant Swift/C surface.
- [x] Tie both shipped iOS tokenizer implementations to LiteRT-LM `db33d2c` using repository provenance and source-line-bearing disassembly.
- [x] Verify tokenizer result ownership and exact declarations against upstream C and Python FFI sources.
- [x] Verify all packaged slices export tokenize, result-delete, and result-count symbols.

Research gate: PASS. The declaration is established; implementation may proceed. The current rebuild script's unpinned `HEAD` clone is a reproducibility defect to record, not an ABI blocker for the already-shipped binaries.

## Plan phase

> **QUALITY CONTRACT — operate to all three bars (full standard: ~/.claude/QUALITY_STANDARD.md). Each item is a checkable gate.**
> GOALS: serve the project's stated north-star goals + a real user problem vs a competent baseline (problem-first, not metric-supremacy). [append the project's specific goals here.]
> STAFF-ENG: production-only (no stubs/mocks/TODO); tested with shown passing output; reuse>reinvent; minimal reversible; verify-before-claim; rank a recommendation.
> PhD (any empirical claim): hypothesis-first; controlled apparatus (competent baseline + confounds-held + no starvation + best-config); powered pre-registered N; cross-family verified before any result is trusted; debug-apparatus-before-reframe; honest negatives valid; NEVER manufacture a win.
> APPLE PRINCIPLES (craft, all code): zero-config (clone+run core path in 60s); ≤5 public methods common path; raw exceptions → contextual domain errors; no just-in-case/unused code; zero-arg init = production-safe; one predictable pattern; sanitize at boundary + mask sensitive data; no blocking-I/O / N+1 / runaway memory. + POLISH GATE (UI only): one runtime, Dynamic Type/VoiceOver/Reduce Motion/60Hz, nothing half-wired ships.
> META-GATES: value/problem-first; definition-of-done + round-cap (don't loop forever); reproducible env; verify-the-verifier (non-vacuity); real human/peer/device is the last word.
> If a task can't meet the relevant bar at the stated budget, STOP and say so — never fake a green.

Project GOALS appended: add the smallest coherent handle API that preserves every asc.13 entry point while making cancellation, terminal accounting, and native destruction race-free.

### Success criteria

- [x] `makeConversation` creates N independent native conversations without another `litert_lm_engine_create`.
- [x] A response returns text and the exact typed metrics captured for that same terminal generation.
- [x] Running usage is cumulative native prefill plus decode counts; no estimates or log parsing exist.
- [x] Idle cancel is reusable; in-flight cancel and generation errors invalidate the uncertain conversation epoch.
- [x] `close()` joins concurrent callers, waits terminal and native cancel return, and deletes each pointer exactly once.
- [x] `unload()` closes every managed conversation before deleting the engine.
- [x] Legacy session, conversation, generation, media, load, and unload public signatures stay unchanged.

### Files

1. `Sources/LiteRTLMSwift/LiteRTLMEngine.swift` — narrow engine factory/tokenizer/registry integration and unchanged legacy surface.
2. `Sources/LiteRTLMSwift/LiteRTLMConversation.swift` — public handle/response/metrics plus internal lifecycle state.
3. Three packaged `engine.h` files — exact tokenizer result/tokenize/delete/count declarations; iOS gate hashes remain byte-identical.
4. `Package.swift` and `Tests/LiteRTLMSwiftTests/LiteRTLMConversationIntegrationTests.swift` — real-model XCTest target.
5. `.gitignore` — mandated repo-local build caches only.
6. `ASC14_WRAPPER_REPORT_20260820.md` — evidence and acceptance disposition.

### Risks and mitigations

- Cancel queued behind inference would deadlock: use a dedicated control queue and a terminal/cancel-return barrier.
- Callback/delete races could use freed pointers: resource deletion requires terminal metrics capture and cancel-call return.
- Engine unload could dangle handles: queue-confined registry closes exact-once storage first.
- Benchmark counters could reset or overflow: reject decreasing/overflowing snapshots and invalidate the handle.
- Simulator execution is unavailable: compile both generic destinations and provide a non-vacuous real-model test for chairman execution.

### Rollback

Revert the source/header/test/report changes as one uncommitted working-tree set; no binary rebuild, package topology, tag, push, merge, or external worktree is involved.

Plan review gate: PASS. The design preserves legacy behavior and confines new lifecycle semantics to the new handle surface.

## Implement phase

> **QUALITY CONTRACT — operate to all three bars (full standard: ~/.claude/QUALITY_STANDARD.md). Each item is a checkable gate.**
> GOALS: serve the project's stated north-star goals + a real user problem vs a competent baseline (problem-first, not metric-supremacy). [append the project's specific goals here.]
> STAFF-ENG: production-only (no stubs/mocks/TODO); tested with shown passing output; reuse>reinvent; minimal reversible; verify-before-claim; rank a recommendation.
> PhD (any empirical claim): hypothesis-first; controlled apparatus (competent baseline + confounds-held + no starvation + best-config); powered pre-registered N; cross-family verified before any result is trusted; debug-apparatus-before-reframe; honest negatives valid; NEVER manufacture a win.
> APPLE PRINCIPLES (craft, all code): zero-config (clone+run core path in 60s); ≤5 public methods common path; raw exceptions → contextual domain errors; no just-in-case/unused code; zero-arg init = production-safe; one predictable pattern; sanitize at boundary + mask sensitive data; no blocking-I/O / N+1 / runaway memory. + POLISH GATE (UI only): one runtime, Dynamic Type/VoiceOver/Reduce Motion/60Hz, nothing half-wired ships.
> META-GATES: value/problem-first; definition-of-done + round-cap (don't loop forever); reproducible env; verify-the-verifier (non-vacuity); real human/peer/device is the last word.
> If a task can't meet the relevant bar at the stated budget, STOP and say so — never fake a green.

Project GOALS appended: satisfy release gates 1–7 with shown compile/static evidence and an honest chairman-owned simulator runtime gate.

- [x] Patch production source and headers.
- [x] Add the XCTest target and real-model contract test.
- [x] Prove guard non-vacuity with planted static/header violations and clean controls.
- [x] Generic Xcode destinations are HELD by package sandbox/CoreSimulator refusal; direct device, simulator, macOS, and XCTest typechecks pass.
- [x] Critically review the diff for source compatibility, pointer lifetime, privacy, and bundle changes.
- [x] Write the final report and acceptance table; leave all work uncommitted.
