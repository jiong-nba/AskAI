import AppKit
import Testing
@testable import AskAI

@Suite(.serialized)
struct CustomModesTests {
    @Test @MainActor func modesRoundTripThroughDefaults() {
        let defaults = InMemoryDefaults()
        #expect(CustomModes.load(defaults: defaults).isEmpty)
        let modes = [CustomMode.make(title: "改写", system: "把用户给的文字改写得更简洁。"),
                     CustomMode.make(title: "Commit message", system: "Write a commit message.")]
        CustomModes.save(modes, defaults: defaults)
        #expect(CustomModes.load(defaults: defaults) == modes)
        CustomModes.save([], defaults: defaults)
        #expect(defaults.data(forKey: CustomModes.defaultsKey) == nil)
        // Garbage is ignored rather than fatal.
        defaults.set(Data("not json".utf8), forKey: CustomModes.defaultsKey)
        #expect(CustomModes.load(defaults: defaults).isEmpty)
        // Keys never collide with the built-in modes, and are distinct from each other.
        #expect(modes.allSatisfy { $0.key.hasPrefix("user.") } && Set(modes.map(\.key)).count == modes.count)
        #expect(!PromptMode.builtin.contains { $0.key.hasPrefix("user.") })
    }

    // Custom modes join the built-in ones everywhere modes are resolved.
    @Test @MainActor func customModesJoinTheBuiltinOnes() {
        let defaults = InMemoryDefaults()
        CustomModes.save([CustomMode(key: "user.abcd1234", title: "改写", system: "Rewrite.")], defaults: defaults)
        let all = PromptMode.all(defaults: defaults)
        #expect(all.count == PromptMode.builtin.count + 1 && all.last?.key == "user.abcd1234")
        #expect(all.last?.system == "Rewrite.")
        #expect(historyMode("user.abcd1234", defaults: defaults).title == "改写")
        #expect(historyMode("user.gone", defaults: defaults).key == "explain")   // deleted meanwhile
        #expect(currentMode(in: defaults).key == "explain")
        defaults.set("user.abcd1234", forKey: "mode")
        #expect(currentMode(in: defaults).key == "user.abcd1234")
        // A mode that was deleted after being chosen as the default falls back to Explain.
        CustomModes.save([], defaults: defaults)
        #expect(currentMode(in: defaults).key == "explain")
    }

    @Test @MainActor func thePanelOffersCustomModes() throws {
        _ = NSApplication.shared
        let defaults = InMemoryDefaults()
        CustomModes.save([CustomMode(key: "user.abcd1234", title: "改写", system: "Rewrite.")], defaults: defaults)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let panel = ResultPanel(source: "idempotency", pasteboard: board, defaults: defaults) { _, _, _, _, _, _ in "x" }
        defer { panel.close() }
        func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views(in:)) }
        let content = try #require(panel.contentView)
        let picker = try #require(views(in: content).compactMap { $0 as? NSPopUpButton }.first)
        #expect(picker.itemTitles.contains("改写") && picker.itemTitles.count == PromptMode.builtin.count + 1)
    }

    // The editor validates before writing, keeps a mode's key when it is edited, and falls back to
    // Explain when the default mode is deleted.
    @Test @MainActor func editorValidatesAndWrites() {
        var changes = 0
        let defaults = InMemoryDefaults()
        let editor = ModesEditor(defaults: defaults) { changes += 1 }
        editor.beginNew()
        #expect(!editor.save() && editor.status == L("请填写名称。", "Enter a name."))
        editor.title = "  改写  "
        #expect(!editor.save() && editor.status == L("请填写系统提示词。", "Enter the system prompt."))
        editor.prompt = " Rewrite. "
        #expect(editor.save() && editor.status.isEmpty)
        #expect(CustomModes.load(defaults: defaults).map(\.title) == ["改写"])
        #expect(CustomModes.load(defaults: defaults).first?.system == "Rewrite.")

        // A name that is already taken, by a built-in mode or by another custom one, is rejected.
        editor.beginNew()
        editor.title = PromptMode.builtin[0].title
        editor.prompt = "x"
        #expect(!editor.save() && CustomModes.load(defaults: defaults).count == 1)
        editor.title = "改写"
        #expect(!editor.save() && CustomModes.load(defaults: defaults).count == 1)

        // Editing keeps the key, so history entries still resolve.
        editor.select(editor.modes[0].key)
        editor.title = "改写正式"
        #expect(editor.save())
        #expect(CustomModes.load(defaults: defaults).map(\.title) == ["改写正式"])
        #expect(editor.modes[0].key.hasPrefix("user.") && editor.selection == editor.modes[0].key)

        // Deleting the mode that is the default falls back to Explain.
        let key = editor.modes[0].key
        defaults.set(key, forKey: "mode")
        editor.delete(key)
        #expect(CustomModes.load(defaults: defaults).isEmpty && defaults.string(forKey: "mode") == "explain")
        #expect(editor.selection == nil && editor.title.isEmpty)
        #expect(changes == 3)   // two saves and one delete; rejected saves change nothing
    }

    @Test @MainActor func modesWindowOpensAtFormSize() throws {
        _ = NSApplication.shared
        let window = makeModesWindow(defaults: InMemoryDefaults()) {}
        defer { window.close() }
        let view = try #require(window.contentView)
        #expect(view.bounds.height > 0 && view.bounds.height >= view.fittingSize.height)
        #expect(view.bounds.width >= view.fittingSize.width)
    }
}
