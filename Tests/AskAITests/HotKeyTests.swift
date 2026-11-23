import AppKit
import Carbon
import HotKey
import Testing
@testable import AskAI

// These tests register ⌃⌥⇧F18 and ⌃⌥⇧F19 as real global hotkeys while they run, so they are
// serialized: each one needs both combinations to be free, or owned only by itself.
@Suite(.serialized)
struct HotKeyTests {
    private let mods: NSEvent.ModifierFlags = [.control, .option, .shift]
    private let f18 = UInt32(kVK_F18)
    private let f19 = UInt32(kVK_F19)

    @Test @MainActor func rebindingTheSameCombinationKeepsItRegistered() {
        let slot = HotKeySlot()
        #expect(slot.bind(keyCode: f18, mods: mods) {})
        #expect(hotKeyIsTaken(keyCode: f18, mods: mods))
        // Regression: registering the new HotKey before releasing the old one left nothing bound.
        #expect(slot.bind(keyCode: f18, mods: mods) {})
        #expect(hotKeyIsTaken(keyCode: f18, mods: mods))
    }

    @Test @MainActor func switchingToAnotherCombinationReleasesTheOldOne() {
        let slot = HotKeySlot()
        #expect(slot.bind(keyCode: f18, mods: mods) {})
        #expect(slot.bind(keyCode: f19, mods: mods) {})
        #expect(!hotKeyIsTaken(keyCode: f18, mods: mods))
        #expect(hotKeyIsTaken(keyCode: f19, mods: mods))
    }

    @Test @MainActor func aTakenCombinationKeepsThePreviousBinding() throws {
        let owner = try registerAsAnotherApp(f19)
        defer { UnregisterEventHotKey(owner) }

        let slot = HotKeySlot()
        #expect(slot.bind(keyCode: f18, mods: mods) {})
        #expect(slot.bind(keyCode: f19, mods: mods, handler: {}) == false)
        #expect(hotKeyIsTaken(keyCode: f18, mods: mods))
    }

    @Test @MainActor func recorderOutcomeForSameFreeUnsupportedAndTakenKeys() throws {
        let current = (code: f18, mods: mods)
        #expect(HotKeyRecording.outcome(keyCode: f18, mods: mods, current: current) == .unchanged)
        #expect(HotKeyRecording.outcome(keyCode: f19, mods: mods, current: current) == .accepted)
        #expect(HotKeyRecording.outcome(keyCode: 999, mods: mods, current: current) == .unsupported)

        let owner = try registerAsAnotherApp(f19)
        defer { UnregisterEventHotKey(owner) }
        #expect(HotKeyRecording.outcome(keyCode: f19, mods: mods, current: current) == .taken)
    }

    @Test @MainActor func configuredHotKeyFallsBackToTheDefault() throws {
        let name = "AskAI.hotkey.tests"
        let suite = try #require(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)
        defer { suite.removePersistentDomain(forName: name) }
        #expect(configuredHotKey(defaults: suite) == (defaultHotKeyCode, NSEvent.ModifierFlags(rawValue: UInt(defaultHotKeyMods))))
        suite.set(Int(kVK_ANSI_J), forKey: "hotkeyKey")
        suite.set(Int(NSEvent.ModifierFlags.option.rawValue), forKey: "hotkeyMods")
        #expect(configuredHotKey(defaults: suite) == (UInt32(kVK_ANSI_J), .option))
    }

    /// Stands in for another app that already owns a combination.
    private func registerAsAnotherApp(_ keyCode: UInt32) throws -> EventHotKeyRef {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x41736B54, id: 77)
        let status = RegisterEventHotKey(keyCode, mods.carbonFlags, id, GetEventDispatcherTarget(), 0, &ref)
        try #require(status == noErr)
        return try #require(ref)
    }
}
