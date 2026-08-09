// Standalone smoke test for KeychainStore/AgentSettings round-trip.
//
// MUST be run with AIHEADSET_TEST_KEYCHAIN_SUFFIX set (see Makefile
// target `test-settings`), so AgentSettings points at a separate
// Keychain account. Writing to the production account from a test
// binary rebinds the item's ACL to that binary and silently locks the
// real app out of its own API key -- that is not hypothetical, it
// happened.
import Foundation

guard ProcessInfo.processInfo.environment["AIHEADSET_TEST_KEYCHAIN_SUFFIX"] != nil else {
    print("FAIL: uruchom z AIHEADSET_TEST_KEYCHAIN_SUFFIX, inaczej test nadpisze produkcyjny klucz")
    exit(1)
}

var ok = true

// Direct KeychainStore round-trip with a scratch account, so we don't
// touch the real "elevenlabs-api-key" entry.
KeychainStore.set("test-value-123", forAccount: "aiheadset-test-account")
let readBack = KeychainStore.get("aiheadset-test-account")
print("Keychain round-trip: wrote 'test-value-123', read '\(readBack ?? "nil")'")
if readBack != "test-value-123" {
    print("FAIL: Keychain round-trip mismatch")
    ok = false
}
KeychainStore.delete("aiheadset-test-account")
if KeychainStore.get("aiheadset-test-account") != nil {
    print("FAIL: Keychain delete did not remove the item")
    ok = false
}

// AgentSettings: exercise the real storage (agentID/apiKey), then
// restore whatever was there before so this test doesn't clobber a
// real configuration.
let savedAgentID = AgentSettings.agentID
let savedAPIKey = AgentSettings.apiKey

AgentSettings.agentID = "test-agent-id"
AgentSettings.apiKey = "test-api-key"
print("isConfigured with fake values = \(AgentSettings.isConfigured) (expected true)")
if !AgentSettings.isConfigured {
    print("FAIL: isConfigured should be true once agentID is set")
    ok = false
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        let url = try await AgentSettings.signedURLProvider()
        print("signedURLProvider() request built OK (network call to ElevenLabs will fail with a fake key, that's expected): \(url)")
    } catch {
        // Expected: a fake API key means ElevenLabs will reject the
        // request (network error or HTTP 401/403/etc). What matters
        // here is that the request got *built and sent* without a
        // crash -- actual auth success needs a real key.
        print("signedURLProvider() failed as expected with a fake key: \(error)")
    }
    semaphore.signal()
}
_ = semaphore.wait(timeout: .now() + 15)

AgentSettings.agentID = savedAgentID
AgentSettings.apiKey = savedAPIKey
print("Restored previous settings (agentID was \(savedAgentID == nil ? "unset" : "set")).")

print(ok ? "PASS" : "SOME FAILED")
exit(ok ? 0 : 1)
