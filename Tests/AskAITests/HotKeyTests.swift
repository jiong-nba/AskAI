import AppKit
import Carbon
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

    @Test @MainActor func unbindingSlotReleasesTheRegisteredHotKey() {
        let slot = HotKeySlot()
        #expect(slot.bind(keyCode: f18, mods: mods) {})
        #expect(hotKeyIsTaken(keyCode: f18, mods: mods))
        slot.unbind()
        #expect(!hotKeyIsTaken(keyCode: f18, mods: mods))
    }

    @Test @MainActor func multipleSlotsCanBindAndUnbindIndependently() {
        let primary = HotKeySlot()
        let secondary = HotKeySlot()
        #expect(primary.bind(keyCode: f18, mods: mods) {})
        #expect(secondary.bind(keyCode: f19, mods: mods) {})
        #expect(hotKeyIsTaken(keyCode: f18, mods: mods))
        #expect(hotKeyIsTaken(keyCode: f19, mods: mods))
        secondary.unbind()
        #expect(hotKeyIsTaken(keyCode: f18, mods: mods))
        #expect(!hotKeyIsTaken(keyCode: f19, mods: mods))
    }

    @Test @MainActor func recorderOutcomeForSameFreeUnsupportedTakenAndOtherActionKeys() throws {
        let current = HotKeyCombo(code: f18, mods: mods)
        let others: [(HotKeyAction, HotKeyCombo)] = [(.askDirectly, HotKeyCombo(code: f19, mods: mods))]
        #expect(HotKeyRecording.outcome(keyCode: f18, mods: mods, current: current, others: others) == .unchanged)
        #expect(HotKeyRecording.outcome(keyCode: f19, mods: mods, current: current, others: others) == .usedByOtherAction(.askDirectly))
        #expect(HotKeyRecording.outcome(keyCode: f19, mods: mods, current: current) == .accepted)
        #expect(HotKeyRecording.outcome(keyCode: 999, mods: mods, current: current, others: others) == .unsupported)

        // Same combo wins as .unchanged even if listed in another slot.
        let duplicated: [(HotKeyAction, HotKeyCombo)] = [(.askDirectly, current)]
        #expect(HotKeyRecording.outcome(keyCode: f18, mods: mods, current: current, others: duplicated) == .unchanged)

        let owner = try registerAsAnotherApp(f19)
        defer { UnregisterEventHotKey(owner) }
        #expect(HotKeyRecording.outcome(keyCode: f19, mods: mods, current: current) == .taken)
    }

    @Test @MainActor func configuredHotKeyFallsBackToTheDefault() throws {
        let suite = InMemoryDefaults()
        let defaultCombo = HotKeyCombo(code: defaultHotKeyCode, mods: NSEvent.ModifierFlags(rawValue: defaultHotKeyMods))
        #expect(configuredHotKey(defaults: suite) == (defaultCombo.code, defaultCombo.mods))
        #expect(configuredHotKey(for: .askSelection, defaults: suite) == defaultCombo)
        #expect(hotKeyDescription(for: .askSelection, defaults: suite) == defaultHotKeyDesc)

        suite.set(Int(kVK_ANSI_J), forKey: "hotkeyKey")
        suite.set(Int(NSEvent.ModifierFlags.option.rawValue), forKey: "hotkeyMods")
        suite.set("⌥J", forKey: "hotkeyDesc")
        #expect(configuredHotKey(defaults: suite) == (UInt32(kVK_ANSI_J), .option))
        #expect(hotKeyDescription(for: .askSelection, defaults: suite) == "⌥J")
    }

    @Test @MainActor func optionalHotKeysDefaultToUnsetAndRoundTripThroughDefaults() {
        let suite = InMemoryDefaults()
        for action in [HotKeyAction.askDirectly, .askFromScreen] {
            #expect(configuredHotKey(for: action, defaults: suite) == nil)
            #expect(hotKeyDescription(for: action, defaults: suite) == nil)
        }

        let direct = HotKeyCombo(code: UInt32(kVK_ANSI_D), mods: [.command, .shift])
        saveHotKey(direct, desc: "⇧⌘D", for: .askDirectly, defaults: suite)
        #expect(configuredHotKey(for: .askDirectly, defaults: suite) == direct)
        #expect(hotKeyDescription(for: .askDirectly, defaults: suite) == "⇧⌘D")
        #expect(configuredHotKey(for: .askFromScreen, defaults: suite) == nil)

        let othersForScreen = otherConfiguredHotKeys(excluding: .askFromScreen, defaults: suite)
        #expect(othersForScreen.count == 2)
        #expect(othersForScreen.contains { $0.0 == .askDirectly && $0.1 == direct })
        #expect(othersForScreen.contains { $0.0 == .askSelection })

        clearHotKey(for: .askDirectly, defaults: suite)
        #expect(configuredHotKey(for: .askDirectly, defaults: suite) == nil)
        #expect(hotKeyDescription(for: .askDirectly, defaults: suite) == nil)

        // Clearing the primary selection hotkey is a no-op.
        let customPrimary = HotKeyCombo(code: UInt32(kVK_ANSI_J), mods: .option)
        saveHotKey(customPrimary, desc: "⌥J", for: .askSelection, defaults: suite)
        clearHotKey(for: .askSelection, defaults: suite)
        #expect(configuredHotKey(for: .askSelection, defaults: suite) == customPrimary)
        #expect(hotKeyDescription(for: .askSelection, defaults: suite) == "⌥J")
    }

    @Test @MainActor func invalidOrPartialOptionalHotKeyDefaultsAreIgnored() {
        let suite = InMemoryDefaults()
        suite.set(Int(kVK_ANSI_K), forKey: HotKeyAction.askDirectly.keyCodeKey)
        #expect(configuredHotKey(for: .askDirectly, defaults: suite) == nil)

        suite.set(0, forKey: HotKeyAction.askDirectly.modsKey)
        #expect(configuredHotKey(for: .askDirectly, defaults: suite) == nil)

        suite.set(55, forKey: HotKeyAction.askDirectly.keyCodeKey)
        suite.set(Int(NSEvent.ModifierFlags.command.rawValue), forKey: HotKeyAction.askDirectly.modsKey)
        #expect(configuredHotKey(for: .askDirectly, defaults: suite) == nil)

        suite.set(Int(kVK_ANSI_S), forKey: HotKeyAction.askFromScreen.keyCodeKey)
        suite.set(Int(NSEvent.ModifierFlags.control.union(.shift).rawValue), forKey: HotKeyAction.askFromScreen.modsKey)
        #expect(configuredHotKey(for: .askFromScreen, defaults: suite)
            == HotKeyCombo(code: UInt32(kVK_ANSI_S), mods: [.control, .shift]))
        let fallbackDesc = hotKeyDescription(for: .askFromScreen, defaults: suite)
        #expect(fallbackDesc != nil && fallbackDesc?.hasPrefix("⌃⇧") == true)
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
