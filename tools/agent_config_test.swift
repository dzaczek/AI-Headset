// Standalone smoke test for AgentConfigClient: confirms the GET/PATCH
// requests are well-formed against the real ElevenLabs endpoint (fake
// credentials, so real auth failure is the expected/correct outcome).
// Restores whatever settings existed before. Not part of the daemon.
import Foundation

guard ProcessInfo.processInfo.environment["AIHEADSET_TEST_KEYCHAIN_SUFFIX"] != nil else {
    print("FAIL: uruchom z AIHEADSET_TEST_KEYCHAIN_SUFFIX, inaczej test nadpisze produkcyjny klucz")
    exit(1)
}

let savedAgentID = AgentSettings.agentID
let savedAPIKey = AgentSettings.apiKey

AgentSettings.agentID = "test-agent-id-does-not-exist"
AgentSettings.apiKey = "test-fake-api-key"

let semaphore = DispatchSemaphore(value: 0)
var ok = true

Task {
    do {
        let prompt = try await AgentConfigClient.fetchSystemPrompt()
        print("Unexpected success with fake credentials: \(prompt)")
        ok = false
    } catch {
        print("fetchSystemPrompt() failed as expected with fake credentials: \(error)")
    }

    do {
        try await AgentConfigClient.updateSystemPrompt("test prompt")
        print("Unexpected success updating with fake credentials")
        ok = false
    } catch {
        print("updateSystemPrompt() failed as expected with fake credentials: \(error)")
    }

    semaphore.signal()
}
_ = semaphore.wait(timeout: .now() + 15)

AgentSettings.agentID = savedAgentID
AgentSettings.apiKey = savedAPIKey
print("Restored previous settings.")

print(ok ? "PASS" : "SOME FAILED")
exit(ok ? 0 : 1)
