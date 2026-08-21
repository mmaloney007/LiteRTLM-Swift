# LiteRTLM-Swift 1.0.0-b4-asc.14 wrapper report — round 2

**Date:** 2026-08-20  
**Lane:** `c242wrapper-r2`  
**Worktree:** `/private/tmp/litertlm-swift-asc14`  
**Branch:** `b4-asc.14`  
**Base / HEAD:** `1.0.0-b4-asc.13` / `78b6a420abe418877f127a56cf08bb0c6a7cecd9`  
**Disposition:** **HELD only for chairman real-model simulator execution.** The redesigned source, public error, packaged headers, lifecycle ordering, red-first static controls, and device/simulator/macOS/XCTest typechecks pass. This lane cannot run CoreSimulator and does not claim the model-backed gate passed.

The binding lane law forbids commits even though the brief's opening sentence requested one. No commit, push, merge, tag, main-branch change, binary rebuild, upload, or external-worktree edit was performed; the chairman lands the working tree.

## Round-2 native finding

The chairman's round-1 run disproved the N-resident-handles premise. The shipped LiteRT-LM v0.11.0 binary from `db33d2c` enforces one native session/conversation per engine. The observed native diagnostic is recorded verbatim in the Swift API docs and all three packaged `engine.h` copies:

```text
E0000 engine.cc:923] Failed to create conversation: FAILED_PRECONDITION: A session already exists. Only one session is supported at a time. Please delete the existing session before creating a new one.
```

A second engine would evade rather than represent that constraint and is explicitly out of scope. Gate 1 is therefore redesigned to one resident managed conversation per loaded engine.

## Redesigned gate 1

```text
loaded engine (native construction count = 1)
        |
        v
slot free --makeConversation--> resident A
   ^                               |
   |                               +--second makeConversation
   |                                      -> LiteRTLMError.conversationSlotOccupied
   |                                          (no native create call)
   |
   +-- await A.close() -- native delete completes -- slot released
        |
        +--makeConversation--> resident B
                                  (same engine; fresh transcript/KV state)
```

The occupied check runs on the same serial `inferenceQueue` as native creation. Concurrent factory calls therefore cannot both pass it. `deleteManagedConversation` calls `litert_lm_conversation_delete` before removing the storage from `managedConversations`; awaited `close()` does not return until deletion, registry removal, and `markClosed()` complete. A close→reopen cannot race early slot release.

`LiteRTLMError.conversationSlotOccupied` is a stable typed case with the localized description:

```text
LiteRT-LM engine already has a resident conversation — close it before creating another
```

The raw `FAILED_PRECONDITION` text is documentation/provenance only. A second managed factory call never reaches `litert_lm_conversation_create`, so it cannot leak that native failure as its API result.

## What changed

| File | Round-2 lines | Change |
|---|---:|---|
| `Sources/LiteRTLMSwift/LiteRTLMEngine.swift` | 306–384 | Replaced the multi-resident claim with the native one-slot contract; documented `db33d2c` / `engine.cc:923`; added the pre-allocation typed slot guard. |
| `Sources/LiteRTLMSwift/LiteRTLMEngine.swift` | 653–662, 684–687 | Preserved native-delete-before-slot-release ordering and added the lock-backed occupied query. |
| `Sources/LiteRTLMSwift/LiteRTLMEngine.swift` | 1814–1833 | Added public `LiteRTLMError.conversationSlotOccupied` and its contextual description. |
| `Sources/LiteRTLMSwift/LiteRTLMConversation.swift` | 34–39 | Corrected handle documentation to one resident conversation per engine. |
| all three packaged `engine.h` files | 443–445 | Recorded the exact native diagnostic and `db33d2c` provenance; declarations remain identical. |
| `Tests/LiteRTLMSwiftTests/LiteRTLMConversationIntegrationTests.swift` | 6–98 | Rewrote the real-model contract for typed occupied rejection and close→fresh-slot content isolation. |
| `tasks/todo.md`, `tasks/lessons.md` | round-2 section / current entries | Added reviewed spec, risks, verification plan, and standalone typecheck apparatus lessons. |

No round-1 tokenizer, benchmark, cancellation, terminal-barrier, or public response/metrics implementation was weakened or replaced.

## Real-model XCTest arms

The one test skips only when the test-process environment has no non-empty `B4_LITERT_MODEL_PATH`. An invalid configured path reaches model loading and fails; it is not converted to a skip.

| Arm | Test lines | Assertion |
|---|---:|---|
| a | 29–34 | Resident A sends and stores `C242_ALPHA_7291`; native prefill, decode, and running usage are strictly positive. |
| b | 36–50 | A second `makeConversation` while A is resident must throw exactly `LiteRTLMError.conversationSlotOccupied`. A successful destructive replacement executes an explicit `XCTFail`; any other error, including an untyped native-create failure, also fails. |
| c | 52–54 | A is closed and a second awaited close is safe. |
| d | 56–66 | B opens on the same engine, sends a transcript question without naming marker-1, must answer `NO_MARKER`, and must not contain `C242_ALPHA_7291`. This is the content proof of fresh transcript/KV state across slot reuse. |
| e | 68–72 | Loaded-model `tokenCount` is greater than zero and stable for identical text. |
| f | 52–53, 74–75 | Double close is safe on both A and B. |
| g | 58–63 | Idle `cancel()` is awaited, then B successfully sends. |
| h | 34, 63, 90–98 | After every send, the native prefill delta, decode delta, and running count are strictly positive. |

Debug assertions at lines 23–27 and 78–80 prove `successfulNativeEngineCreationCount == 1` before A and after A-close→B-open→B-close.

This arm is red against asc.13-style destructive-slot behavior: if the second open silently replaces A, line 42 executes `XCTFail`. It is also red against round 1's untyped native failure because only the new typed enum case is accepted.

## Gates 2–7 retained

- Gate 2: `tokenCount(_:)` still calls `litert_lm_engine_tokenize`, reads `litert_lm_tokenize_result_get_num_tokens`, and deletes the owned result exactly once. No estimate exists.
- Gates 3–4: terminal usage still comes from typed `litert_lm_conversation_get_benchmark_info` getters for the same generation. Event deltas and cumulative counts remain overflow/monotonicity checked; no log parsing exists.
- Gate 5: `cancel()` and `close()` remain async, awaitable, and idempotent. Idle cancel remains a no-op; active cancellation and close still join terminal/cancel-return barriers before native deletion.
- Gate 6: the two iOS headers are byte-identical; the macOS header is identical as well.
- Gate 7: the real-model XCTest remains the runtime release authority and now matches the actual one-slot binary contract.

## Header identity

```text
$ shasum -a 256 <device engine.h> <simulator engine.h> <macOS engine.h>
55a1fead991d9250a2d4896278176105d398788dfc9497cc81fd1aeb93805827  <device engine.h>
55a1fead991d9250a2d4896278176105d398788dfc9497cc81fd1aeb93805827  <simulator engine.h>
55a1fead991d9250a2d4896278176105d398788dfc9497cc81fd1aeb93805827  <macOS engine.h>

HEADER_IDENTITY_CLEAN=PASS
```

No xcframework executable was rebuilt or modified.

## Verifier non-vacuity

Planted violations existed only in process substitution and never entered the worktree. Removing the production typed guard, weakening the test's expected typed case, adding header drift, and adding a text-length estimate each make its corresponding verifier fail; the real sources pass:

```text
SLOT_GUARD_RED=FIRED
SLOT_GUARD_CLEAN=PASS
TYPED_SLOT_ARM_RED=FIRED
TYPED_SLOT_ARM_CLEAN=PASS
HEADER_IDENTITY_RED=FIRED
HEADER_IDENTITY_CLEAN=PASS
NO_ESTIMATES_RED=FIRED
NO_ESTIMATES_CLEAN=PASS
```

The actual model-backed red/green remains chairman-owned: this lane can prove that destructive replacement enters the XCTest failure arm and can compile that arm, but cannot honestly claim it executed without CoreSimulator.

## Typecheck proof

Xcode 26.6 / Swift 6.3.3 direct typechecks used each destination's SDK target and matching packaged CLiteRTLM slice. The XCTest proof first emitted a Debug `-enable-testing` simulator module from the current sources, then typechecked the test against that module and Xcode's simulator XCTest Swift overlay.

```text
SWIFTC_DEVICE_TYPECHECK=PASS
SWIFTC_SIMULATOR_TYPECHECK=PASS
SWIFTC_MACOS_TYPECHECK=PASS
SWIFTC_XCTEST_TYPECHECK=PASS
```

The production typechecks retain pre-existing Swift 6 warnings for capturing legacy optional `OpaquePointer` values in the engine deinit queue. They emit no errors. `git diff --check` exits 0.

## Exact chairman simulator command

The environment variable must use Xcode's `TEST_RUNNER_` forwarding prefix. Plain `B4_LITERT_MODEL_PATH=...` on the `xcodebuild` process does not reach the XCTest process.

```sh
cd /private/tmp/litertlm-swift-asc14
TEST_RUNNER_B4_LITERT_MODEL_PATH='/Users/maloney/Developer/personal/b4/ios/b4-ios-app/Tests/Resources/b4_sim_test_model.litertlm' \
SWIFTPM_CACHE_DIR=/private/tmp/litertlm-swift-asc14/.spm/cache \
XDG_CACHE_HOME=/private/tmp/litertlm-swift-asc14/.cache \
CLANG_MODULE_CACHE_PATH=/private/tmp/litertlm-swift-asc14/.dd/ModuleCache.noindex \
/usr/bin/xcodebuild test \
  -scheme LiteRTLMSwift \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=2441FCE0-063D-466F-BAC0-08C6D1280408' \
  -clonedSourcePackagesDirPath /private/tmp/litertlm-swift-asc14/.spm \
  -derivedDataPath /private/tmp/litertlm-swift-asc14/.dd \
  -only-testing:LiteRTLMSwiftTests/LiteRTLMConversationIntegrationTests/testRealModelConversationContract
```

Model: `/Users/maloney/Developer/personal/b4/ios/b4-ios-app/Tests/Resources/b4_sim_test_model.litertlm` (2.6 GB, simulator-visible host path). Simulator: `platform=iOS Simulator,id=2441FCE0-063D-466F-BAC0-08C6D1280408`.

## Minimum release gate

| # | Gate | Status | Evidence / remaining authority |
|---:|---|---|---|
| 1 | One resident conversation per engine; typed occupied error; close→reopen; one engine construction | **HELD for runtime** | Queue/lock/deletion review, red-first static controls, and all typechecks pass. Chairman must execute the real-model occupied and reopen arms. |
| 2 | Exact loaded-model `tokenCount(_:)` | **HELD for runtime** | Proven `db33d2c` ABI/ownership and typecheck pass; chairman must execute positive/stable assertions. |
| 3 | Exact per-terminal usage deltas and cumulative total | **HELD for runtime** | Typed implementation and strictly-positive assertions compile; native values need the real model. |
| 4 | Typed native metrics; no log parsing or estimates | **PASS** | Getter calls, accounting implementation, and red/clean no-estimate verifier pass. |
| 5 | Awaitable idempotent cancel/close | **HELD for runtime** | Lifecycle/barrier review and XCTest typecheck pass; idle-cancel/send and double-close await runtime. |
| 6 | Header identity | **PASS** | All three hashes are identical; planted drift fires. |
| 7 | Wrapper real-model XCTest | **HELD for chairman** | Correct test and command are present; CoreSimulator execution is outside this lane. |

Recommendation: run the exact chairman command above and do not tag if any typed-slot, content-isolation, positive-usage, tokenization, cancel/send, double-close, or one-engine assertion fails.

## Requested git diff stat

The exact requested committed range is empty because the binding lane law requires the changes to remain uncommitted:

```text
$ git diff --stat 1.0.0-b4-asc.13..HEAD
```

For completeness, the tracked working-tree stat against the tag is:

```text
$ git diff --stat 1.0.0-b4-asc.13
 .gitignore                                         |   3 +
 .../CLiteRTLM.framework/Headers/engine.h           |  49 ++-
 .../ios-arm64/CLiteRTLM.framework/Headers/engine.h |  49 ++-
 .../Versions/A/Headers/engine.h                    |  49 ++-
 Package.swift                                      |   5 +
 Sources/LiteRTLMSwift/LiteRTLMEngine.swift         | 452 ++++++++++++++++++++-
 6 files changed, 569 insertions(+), 38 deletions(-)
```

The standard stat excludes the new untracked source/test/report/task files; `git status --short` lists `Sources/LiteRTLMSwift/LiteRTLMConversation.swift`, `Tests/`, `ASC14_WRAPPER_REPORT_20260820.md`, and `tasks/` in addition to the tracked modifications.

MARKER_END_OF_RUN
