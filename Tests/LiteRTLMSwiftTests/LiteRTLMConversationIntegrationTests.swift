import Foundation
import XCTest
@testable import LiteRTLMSwift

final class LiteRTLMConversationIntegrationTests: XCTestCase {
    func testRealModelConversationContract() async throws {
        guard let configuredPath = ProcessInfo.processInfo.environment["B4_LITERT_MODEL_PATH"],
              !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip(
                "Set B4_LITERT_MODEL_PATH to a simulator-visible .litertlm model"
            )
        }

        let engine = LiteRTLMEngine(
            modelPath: URL(fileURLWithPath: configuredPath),
            backend: "cpu"
        )
        var resident: LiteRTLMConversation?

        do {
            try await engine.load()

            #if DEBUG
            XCTAssertEqual(engine.successfulNativeEngineCreationCount, 1)
            #else
            XCTFail("Native engine-construction proof requires the documented Debug test build")
            #endif

            let first = try await engine.makeConversation(temperature: 0, maxTokens: 96)
            resident = first
            let firstSeed = try await first.send(
                "Store the exact marker C242_ALPHA_7291. Reply only ACK."
            )
            assertStrictlyPositiveUsageDelta(firstSeed)

            do {
                let unexpected = try await engine.makeConversation(
                    temperature: 0,
                    maxTokens: 96
                )
                await unexpected.close()
                XCTFail(
                    "A second resident handle replaced the first instead of throwing the typed slot error"
                )
            } catch LiteRTLMError.conversationSlotOccupied {
                // Required typed rejection. In particular, do not expose the
                // native FAILED_PRECONDITION diagnostic as an untyped failure.
            } catch {
                XCTFail("Expected LiteRTLMError.conversationSlotOccupied, got \(error)")
            }

            await first.close()
            await first.close()
            resident = nil

            let second = try await engine.makeConversation(temperature: 0, maxTokens: 96)
            resident = second
            await second.cancel()
            let secondFirstTurn = try await second.send(
                "What exact marker was stored earlier in this conversation? "
                    + "If none was stored, reply only NO_MARKER."
            )
            assertStrictlyPositiveUsageDelta(secondFirstTurn)
            XCTAssertTrue(secondFirstTurn.text.contains("NO_MARKER"))
            XCTAssertFalse(secondFirstTurn.text.contains("C242_ALPHA_7291"))
            XCTAssertEqual(second.latestMetrics, secondFirstTurn.metrics)

            let knownText = "The quick brown fox jumps over the lazy dog."
            let firstCount = try engine.tokenCount(knownText)
            let secondCount = try engine.tokenCount(knownText)
            XCTAssertGreaterThan(firstCount, 0)
            XCTAssertEqual(firstCount, secondCount)

            await second.close()
            await second.close()
            resident = nil

            #if DEBUG
            XCTAssertEqual(engine.successfulNativeEngineCreationCount, 1)
            #endif
        } catch {
            await resident?.close()
            await engine.unload()
            throw error
        }

        await engine.unload()
    }

    private func assertStrictlyPositiveUsageDelta(
        _ response: LiteRTLMConversationResponse,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(response.metrics.prefillTokenCount, 0, file: file, line: line)
        XCTAssertGreaterThan(response.metrics.decodeTokenCount, 0, file: file, line: line)
        XCTAssertGreaterThan(response.metrics.runningTokenCount, 0, file: file, line: line)
    }
}
