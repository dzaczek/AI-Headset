// Standalone smoke test for Faza 2.1 (plan): creates the private
// aggregate device (physical default output + hidden Bridge),
// verifies it resolves and lists both sub-devices, then destroys it.
// Not part of the daemon; a throwaway dev diagnostic.
import CoreAudio
import Foundation

guard let physicalUID = AudioDeviceUtil.defaultOutputDeviceUID() else {
    print("FAIL: could not determine default output device UID")
    exit(1)
}
let physicalName = AudioDeviceUtil.translateUIDToDevice(physicalUID)
    .flatMap { AudioDeviceUtil.deviceName(for: $0) } ?? "?"
print("Physical device: \(physicalName) (UID \(physicalUID))")
let physicalInputUID = AudioDeviceUtil.defaultInputDeviceUID()
print("Physical input UID: \(physicalInputUID ?? "none")")

guard AudioDeviceUtil.translateUIDToDevice(AIHeadsetConfig.bridgeUID) != nil else {
    print("FAIL: AI Headset Bridge not found -- is the driver installed?")
    exit(1)
}
print("Bridge device found.")

let aggregate = AggregateDevice()
do {
    let aggID = try aggregate.create(outputDeviceUID: physicalUID, inputDeviceUID: physicalInputUID)
    print("Created aggregate device, AudioObjectID = \(aggID)")

    guard let lookedUp = AudioDeviceUtil.translateUIDToDevice(AIHeadsetConfig.aggregateUID), lookedUp == aggID else {
        print("FAIL: aggregate UID does not resolve back to the created device")
        exit(1)
    }
    print("Aggregate UID resolves correctly.")

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    // Despite being a "list" property, this comes back as a single
    // CFArrayRef (one pointer), not a packed C-array of CFStringRefs.
    var arrayRef: CFArray?
    var size = UInt32(MemoryLayout<CFArray?>.size)
    let status = withUnsafeMutablePointer(to: &arrayRef) { ptr -> OSStatus in
        AudioObjectGetPropertyData(aggID, &address, 0, nil, &size, ptr)
    }
    guard status == noErr, let cfArray = arrayRef, let uids = cfArray as? [String] else {
        print("FAIL: could not read sub-device list, status \(status)")
        exit(1)
    }
    print("Sub-device UIDs: \(uids)")
    let hasPhysical = uids.contains(physicalUID)
    let hasBridge = uids.contains(AIHeadsetConfig.bridgeUID)
    let hasInput = physicalInputUID == nil || physicalInputUID == physicalUID || uids.contains(physicalInputUID!)
    if !hasPhysical || !hasBridge || !hasInput {
        print("FAIL: sub-device list missing physical (\(hasPhysical)), bridge (\(hasBridge)), or input (\(hasInput))")
        exit(1)
    }

    try aggregate.destroy()
    print("Destroyed aggregate device (destruction is documented as asynchronous -- polling for it to clear)...")

    var goneWithin: TimeInterval?
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
        if AudioDeviceUtil.translateUIDToDevice(AIHeadsetConfig.aggregateUID) == nil {
            goneWithin = Date().timeIntervalSince(deadline.addingTimeInterval(-2.0))
            break
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard let elapsed = goneWithin else {
        print("FAIL: aggregate still resolvable 2s after destroy")
        exit(1)
    }
    print("Aggregate UID stopped resolving \(String(format: "%.2f", elapsed))s after destroy() returned.")
    print("PASS: aggregate device lifecycle OK")
} catch {
    print("FAIL: \(error)")
    exit(1)
}
