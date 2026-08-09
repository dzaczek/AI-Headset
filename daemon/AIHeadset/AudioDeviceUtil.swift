import AudioToolbox
import CoreAudio
import Foundation

/// Small CoreAudio client-API helpers shared by AggregateDevice.swift
/// now and by the physical-device picker in Faza 4 later.
enum AudioDeviceUtil {
    /// True for the plug-in's own devices and the daemon's aggregate.
    /// Feeding any of these back in as the "physical" endpoint builds
    /// an aggregate that contains the very device applications play
    /// into -- a loop CoreAudio cannot resolve, after which the device
    /// simply stops working. Easy to hit, because pointing macOS's
    /// default output at "AI Headset" is exactly what you do to test.
    static func isOwnDevice(_ uid: String) -> Bool {
        uid == AIHeadsetConfig.deviceUID
            || uid == AIHeadsetConfig.bridgeUID
            || uid == AIHeadsetConfig.aggregateUID
    }

    /// System default output, but never one of ours -- falls back to
    /// the first real device with output channels.
    static func physicalDefaultOutputUID() -> String? {
        if let uid = defaultOutputDeviceUID(), !isOwnDevice(uid) { return uid }
        return firstPhysicalDeviceUID(scope: kAudioObjectPropertyScopeOutput)
    }

    /// System default input, but never one of ours.
    static func physicalDefaultInputUID() -> String? {
        if let uid = defaultInputDeviceUID(), !isOwnDevice(uid) { return uid }
        return firstPhysicalDeviceUID(scope: kAudioObjectPropertyScopeInput)
    }

    static func firstPhysicalDeviceUID(scope: AudioObjectPropertyScope) -> String? {
        for id in allDeviceIDs() {
            guard let uid = deviceUID(for: id), !isOwnDevice(uid) else { continue }
            guard channelCount(for: id, scope: scope) > 0 else { continue }
            return uid
        }
        return nil
    }

    static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceUID(for: deviceID)
    }

    static func defaultInputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceUID(for: deviceID)
    }

    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }

    static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return name as String?
    }

    /// Hidden devices (the Bridge) don't turn up via
    /// kAudioHardwarePropertyDevices — go through the HAL's UID
    /// resolver instead, which routes to the owning plug-in regardless
    /// of hidden state.
    static func translateUIDToDevice(_ uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID)
        }
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    /// Sums channel counts across all streams in the given scope
    /// (input/output) -- 0 means the device has no capability in that
    /// direction (e.g. this Mac's speakers have 0 input channels).
    static func channelCount(for deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
