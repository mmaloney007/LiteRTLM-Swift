import Foundation

/// Native benchmark data captured for one terminal conversation generation.
///
/// `runningTokenCount` is the exact cumulative prefill plus decode count
/// reported by LiteRT-LM. The first prefill includes the conversation preface;
/// later prefills represent appended turns. No text-length estimate is used.
public struct LiteRTLMConversationMetrics: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case completed
        case cancelled
        case failed
    }

    public let generation: UInt64
    public let outcome: Outcome
    public let prefillTokenCount: Int
    public let decodeTokenCount: Int
    public let cumulativePrefillTokenCount: Int
    public let cumulativeDecodeTokenCount: Int
    public let runningTokenCount: Int
    public let prefillTokensPerSecond: [Double]
    public let decodeTokensPerSecond: [Double]
    public let timeToFirstToken: TimeInterval
    public let totalInitializationTime: TimeInterval
}

/// Text and native usage captured from the same completed generation.
public struct LiteRTLMConversationResponse: Sendable, Equatable {
    public let text: String
    public let metrics: LiteRTLMConversationMetrics
}

/// The resident LiteRT-LM conversation and its persistent KV cache.
///
/// The handle owns its native Conversation/config objects and retains its engine.
/// LiteRT-LM v0.11.0 permits one resident conversation per engine; await
/// `close()` before asking that engine to create another handle. One generation
/// may be active on the handle at a time.
public final class LiteRTLMConversation: @unchecked Sendable {
    private let owner: LiteRTLMEngine
    private let storage: LiteRTLMConversationStorage

    init(owner: LiteRTLMEngine, storage: LiteRTLMConversationStorage) {
        self.owner = owner
        self.storage = storage
    }

    /// Metrics from the most recent native terminal event, if one has occurred.
    public var latestMetrics: LiteRTLMConversationMetrics? {
        storage.metricsSnapshot()
    }

    /// Append a text turn and return its response with exact native usage.
    public func send(_ text: String) async throws -> LiteRTLMConversationResponse {
        try await owner.send(text, on: storage)
    }

    /// Cancel the active generation and wait until native processing has drained.
    /// Calling this on an idle or already-cancelled handle is a no-op.
    public func cancel() async {
        await owner.cancel(storage)
    }

    /// Cancel any active generation, wait for confirmation, and free native state.
    /// This operation is idempotent and safe to await concurrently.
    public func close() async {
        await owner.close(storage)
    }

    deinit {
        owner.release(storage)
    }
}

struct LiteRTLMConversationNativeResources: @unchecked Sendable {
    let conversation: OpaquePointer
    let conversationConfig: OpaquePointer
    let sessionConfig: OpaquePointer
}

final class LiteRTLMNativeCancellation: @unchecked Sendable {
    let conversation: OpaquePointer
    let generation: UInt64
    let storage: LiteRTLMConversationStorage

    init(
        conversation: OpaquePointer,
        generation: UInt64,
        storage: LiteRTLMConversationStorage
    ) {
        self.conversation = conversation
        self.generation = generation
        self.storage = storage
    }
}

struct LiteRTLMConversationBenchmarkSnapshot: Sendable {
    let prefillTokenCounts: [Int]
    let decodeTokenCounts: [Int]
    let prefillTokensPerSecond: [Double]
    let decodeTokensPerSecond: [Double]
    let timeToFirstToken: TimeInterval
    let totalInitializationTime: TimeInterval
}

final class LiteRTLMConversationStorage: @unchecked Sendable {
    enum NativeStartAction {
        case start(OpaquePointer)
        case cancelledBeforeStart
        case unavailable
    }

    struct CancellationRequest {
        let barrier: DispatchGroup?
        let generation: UInt64?
        let conversationToCancel: OpaquePointer?
    }

    enum CloseDisposition {
        case perform
        case wait(DispatchGroup)
        case closed
    }

    private enum Phase {
        case idle
        case queued
        case generating
        case invalidated
        case closed
    }

    let id = UUID()

    private let lock = NSLock()
    private var resources: LiteRTLMConversationNativeResources?
    private var phase: Phase = .idle
    private var isClosing = false
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?
    private var generationBarrier: DispatchGroup?
    private var cancelRequested = false
    private var nativeStartReturned = false
    private var nativeStartSucceeded = false
    private var nativeTerminalObserved = false
    private var nativeCancelStarted = false
    private var nativeCancelInProgress = false
    private var nativeCancelBarrier: DispatchGroup?
    private var terminalRecorded = false
    private var closeBarrier: DispatchGroup?
    private var observedPrefillTurns = 0
    private var observedDecodeTurns = 0
    private var cumulativePrefillTokens = 0
    private var cumulativeDecodeTokens = 0
    private var latestMetrics: LiteRTLMConversationMetrics?

    init(resources: LiteRTLMConversationNativeResources) {
        self.resources = resources
    }

    func metricsSnapshot() -> LiteRTLMConversationMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return latestMetrics
    }

    func queueGeneration() throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        guard resources != nil, phase != .closed, !isClosing else {
            throw LiteRTLMError.inferenceFailure("Conversation is closed")
        }
        guard phase == .idle else {
            throw LiteRTLMError.inferenceFailure(
                phase == .invalidated
                    ? "Conversation cannot be reused after cancellation or failure"
                    : "Conversation already has an active generation"
            )
        }
        guard nextGeneration < UInt64.max else {
            throw LiteRTLMError.inferenceFailure("Conversation generation counter overflow")
        }

        nextGeneration += 1
        activeGeneration = nextGeneration
        phase = .queued
        cancelRequested = false
        nativeStartReturned = false
        nativeStartSucceeded = false
        nativeTerminalObserved = false
        nativeCancelStarted = false
        nativeCancelInProgress = false
        nativeCancelBarrier = nil
        terminalRecorded = false
        let barrier = DispatchGroup()
        barrier.enter()
        generationBarrier = barrier
        return nextGeneration
    }

    func prepareNativeStart(generation: UInt64) -> NativeStartAction {
        lock.lock()
        defer { lock.unlock() }

        guard activeGeneration == generation,
              phase == .queued,
              let conversation = resources?.conversation else {
            return .unavailable
        }
        if cancelRequested || isClosing {
            nativeStartReturned = true
            return .cancelledBeforeStart
        }
        phase = .generating
        return .start(conversation)
    }

    func nativeStartDidReturn(
        generation: UInt64,
        succeeded: Bool
    ) -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }

        guard activeGeneration == generation, !terminalRecorded else { return nil }
        nativeStartReturned = true
        nativeStartSucceeded = succeeded
        guard succeeded,
              cancelRequested,
              !nativeTerminalObserved,
              !nativeCancelStarted,
              let conversation = resources?.conversation else { return nil }
        nativeCancelStarted = true
        nativeCancelInProgress = true
        let barrier = DispatchGroup()
        barrier.enter()
        nativeCancelBarrier = barrier
        return conversation
    }

    func requestCancellation() -> CancellationRequest {
        lock.lock()
        defer { lock.unlock() }

        guard let barrier = generationBarrier,
              let generation = activeGeneration,
              !terminalRecorded else {
            return CancellationRequest(
                barrier: generationBarrier,
                generation: activeGeneration,
                conversationToCancel: nil
            )
        }

        guard !nativeTerminalObserved else {
            return CancellationRequest(
                barrier: barrier,
                generation: generation,
                conversationToCancel: nil
            )
        }

        cancelRequested = true
        var conversationToCancel: OpaquePointer?
        if phase == .generating,
           nativeStartReturned,
           nativeStartSucceeded,
           !nativeCancelStarted,
            let conversation = resources?.conversation {
            nativeCancelStarted = true
            nativeCancelInProgress = true
            let cancelBarrier = DispatchGroup()
            cancelBarrier.enter()
            nativeCancelBarrier = cancelBarrier
            conversationToCancel = conversation
        }
        return CancellationRequest(
            barrier: barrier,
            generation: generation,
            conversationToCancel: conversationToCancel
        )
    }

    func nativeTerminalDidArrive(generation: UInt64) {
        lock.lock()
        if activeGeneration == generation {
            nativeTerminalObserved = true
        }
        lock.unlock()
    }

    func nativeCancelDidReturn(generation: UInt64) {
        let cancelBarrierToLeave: DispatchGroup?
        let barrierToLeave: DispatchGroup?
        lock.lock()
        if activeGeneration == generation, nativeCancelInProgress {
            nativeCancelInProgress = false
            cancelBarrierToLeave = nativeCancelBarrier
        } else {
            cancelBarrierToLeave = nil
        }
        barrierToLeave = finishGenerationBarrierIfReadyLocked()
        lock.unlock()
        cancelBarrierToLeave?.leave()
        barrierToLeave?.leave()
    }

    func waitForNativeCancellationBlocking(generation: UInt64) {
        let barrier: DispatchGroup?
        lock.lock()
        barrier = activeGeneration == generation ? nativeCancelBarrier : nil
        lock.unlock()
        barrier?.wait()
    }

    func isCancellationRequested(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation && cancelRequested
    }

    func completeGeneration(
        generation: UInt64,
        proposedOutcome: LiteRTLMConversationMetrics.Outcome,
        benchmark: LiteRTLMConversationBenchmarkSnapshot
    ) throws -> LiteRTLMConversationMetrics {
        let barrierToLeave: DispatchGroup?
        let metrics: LiteRTLMConversationMetrics

        lock.lock()
        do {
            guard activeGeneration == generation, !terminalRecorded else {
                throw LiteRTLMError.inferenceFailure("Duplicate conversation terminal event")
            }
            let outcome: LiteRTLMConversationMetrics.Outcome = cancelRequested
                ? .cancelled
                : proposedOutcome
            guard benchmark.prefillTokenCounts.count == benchmark.prefillTokensPerSecond.count,
                  benchmark.decodeTokenCounts.count == benchmark.decodeTokensPerSecond.count,
                  benchmark.prefillTokenCounts.count >= observedPrefillTurns,
                  benchmark.decodeTokenCounts.count >= observedDecodeTurns else {
                throw LiteRTLMError.inferenceFailure("Native benchmark turn counters regressed")
            }

            let totalPrefill = try Self.checkedSum(benchmark.prefillTokenCounts)
            let totalDecode = try Self.checkedSum(benchmark.decodeTokenCounts)
            guard totalPrefill >= cumulativePrefillTokens,
                  totalDecode >= cumulativeDecodeTokens else {
                throw LiteRTLMError.inferenceFailure("Native benchmark token counters regressed")
            }

            let eventPrefill = totalPrefill - cumulativePrefillTokens
            let eventDecode = totalDecode - cumulativeDecodeTokens
            let (runningTotal, overflow) = totalPrefill.addingReportingOverflow(totalDecode)
            guard !overflow else {
                throw LiteRTLMError.inferenceFailure("Native benchmark token total overflow")
            }

            metrics = LiteRTLMConversationMetrics(
                generation: generation,
                outcome: outcome,
                prefillTokenCount: eventPrefill,
                decodeTokenCount: eventDecode,
                cumulativePrefillTokenCount: totalPrefill,
                cumulativeDecodeTokenCount: totalDecode,
                runningTokenCount: runningTotal,
                prefillTokensPerSecond: Array(
                    benchmark.prefillTokensPerSecond.dropFirst(observedPrefillTurns)
                ),
                decodeTokensPerSecond: Array(
                    benchmark.decodeTokensPerSecond.dropFirst(observedDecodeTurns)
                ),
                timeToFirstToken: benchmark.timeToFirstToken,
                totalInitializationTime: benchmark.totalInitializationTime
            )

            observedPrefillTurns = benchmark.prefillTokenCounts.count
            observedDecodeTurns = benchmark.decodeTokenCounts.count
            cumulativePrefillTokens = totalPrefill
            cumulativeDecodeTokens = totalDecode
            latestMetrics = metrics
            terminalRecorded = true
            phase = outcome == .completed ? .idle : .invalidated
            barrierToLeave = finishGenerationBarrierIfReadyLocked()
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }

        barrierToLeave?.leave()
        return metrics
    }

    func failGenerationWithoutMetrics(generation: UInt64) {
        let barrierToLeave: DispatchGroup?
        lock.lock()
        if activeGeneration == generation, !terminalRecorded {
            terminalRecorded = true
            phase = .invalidated
        }
        barrierToLeave = finishGenerationBarrierIfReadyLocked()
        lock.unlock()
        barrierToLeave?.leave()
    }

    func beginClose() -> CloseDisposition {
        lock.lock()
        defer { lock.unlock() }

        if phase == .closed { return .closed }
        if isClosing, let closeBarrier { return .wait(closeBarrier) }
        if resources == nil { return .closed }
        isClosing = true
        let barrier = DispatchGroup()
        barrier.enter()
        closeBarrier = barrier
        return .perform
    }

    func waitForActiveGenerationBlocking() {
        let barrier: DispatchGroup?
        lock.lock()
        barrier = generationBarrier
        lock.unlock()
        barrier?.wait()
    }

    func takeResourcesForDeletion() -> LiteRTLMConversationNativeResources? {
        lock.lock()
        defer { lock.unlock() }
        guard generationBarrier == nil else { return nil }
        let ownedResources = resources
        resources = nil
        return ownedResources
    }

    func conversationForBenchmark(generation: UInt64) -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == generation else { return nil }
        return resources?.conversation
    }

    func markClosed() {
        let barrierToLeave: DispatchGroup?
        lock.lock()
        resources = nil
        phase = .closed
        isClosing = true
        barrierToLeave = closeBarrier
        closeBarrier = nil
        lock.unlock()
        barrierToLeave?.leave()
    }

    private func finishGenerationBarrierIfReadyLocked() -> DispatchGroup? {
        guard terminalRecorded, !nativeCancelInProgress else { return nil }
        let barrier = generationBarrier
        generationBarrier = nil
        activeGeneration = nil
        nativeCancelBarrier = nil
        return barrier
    }

    private static func checkedSum(_ counts: [Int]) throws -> Int {
        var total = 0
        for count in counts {
            guard count >= 0 else {
                throw LiteRTLMError.inferenceFailure("Native benchmark returned a negative token count")
            }
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else {
                throw LiteRTLMError.inferenceFailure("Native benchmark token count overflow")
            }
            total = next
        }
        return total
    }
}

struct LiteRTLMConversationTerminal: Sendable {
    let chunks: [String]
    let errorMessage: String?
}

final class LiteRTLMConversationCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private let terminalSemaphore = DispatchSemaphore(value: 0)
    private let terminalObserver: @Sendable () -> Void
    private var chunks: [String] = []
    private var terminalClaimed = false
    private var terminal: LiteRTLMConversationTerminal?

    init(terminalObserver: @escaping @Sendable () -> Void) {
        self.terminalObserver = terminalObserver
    }

    func receive(
        chunk: UnsafePointer<CChar>?,
        isFinal: Bool,
        errorMessage: UnsafePointer<CChar>?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminalClaimed else { return false }

        let nativeError: String? = {
            guard let errorMessage else { return nil }
            let message = String(cString: errorMessage)
            return message.isEmpty ? nil : message
        }()
        if nativeError == nil, let chunk {
            chunks.append(String(cString: chunk))
        }
        guard isFinal || nativeError != nil else { return false }
        terminalClaimed = true
        terminal = LiteRTLMConversationTerminal(chunks: chunks, errorMessage: nativeError)
        terminalObserver()
        return true
    }

    func failedToStart(code: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminalClaimed else { return false }
        terminalClaimed = true
        terminal = LiteRTLMConversationTerminal(
            chunks: chunks,
            errorMessage: "Failed to start conversation stream (code \(code))"
        )
        terminalObserver()
        return true
    }

    func cancelledBeforeStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminalClaimed else { return false }
        terminalClaimed = true
        terminal = LiteRTLMConversationTerminal(chunks: chunks, errorMessage: nil)
        terminalObserver()
        return true
    }

    func signalTerminal() {
        terminalSemaphore.signal()
    }

    func waitForTerminal() -> LiteRTLMConversationTerminal {
        terminalSemaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return terminal ?? LiteRTLMConversationTerminal(
            chunks: [],
            errorMessage: "Conversation ended without a terminal result"
        )
    }
}

func liteRTLMManagedConversationCallback(
    callbackData: UnsafeMutableRawPointer?,
    chunk: UnsafePointer<CChar>?,
    isFinal: Bool,
    errorMessage: UnsafePointer<CChar>?
) {
    guard let callbackData else { return }
    let unmanaged = Unmanaged<LiteRTLMConversationCallbackContext>.fromOpaque(callbackData)
    let context = unmanaged.takeUnretainedValue()
    guard context.receive(
        chunk: chunk,
        isFinal: isFinal,
        errorMessage: errorMessage
    ) else { return }
    context.signalTerminal()
    unmanaged.release()
}
