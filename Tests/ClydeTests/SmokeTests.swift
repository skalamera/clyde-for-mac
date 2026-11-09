import Testing
@testable import Clyde

@Suite struct SmokeTests {
    @Test func testTargetLinksTheAppModule() {
        #expect(ConversationRunner.budgetExhaustedInstruction.contains("Tool budget reached"))
    }
}
