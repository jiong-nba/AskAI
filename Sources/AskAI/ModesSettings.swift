import SwiftUI

/// 用户自定义的模式：一个名字加一段系统提示词。存在 defaults 的 customModes 里（JSON 数组）。
struct CustomMode: Codable, Equatable, Identifiable {
    var key: String
    var title: String
    var system: String
    var id: String { key }

    /// key 带 user. 前缀，不会和内置模式撞上；历史条目靠它找回模式。
    static func make(title: String, system: String) -> CustomMode {
        CustomMode(key: "user." + UUID().uuidString.prefix(8).lowercased(), title: title, system: system)
    }
}

enum CustomModes {
    static let defaultsKey = "customModes"

    /// 读不出来或格式不对就当没有：一组自定义模式不值得让 App 起不来。
    static func load(defaults: UserDefaults = .standard) -> [CustomMode] {
        guard let data = defaults.data(forKey: defaultsKey),
              let modes = try? JSONDecoder().decode([CustomMode].self, from: data) else { return [] }
        return modes
    }

    static func save(_ modes: [CustomMode], defaults: UserDefaults = .standard) {
        guard !modes.isEmpty else { defaults.removeObject(forKey: defaultsKey); return }
        defaults.set(try? JSONEncoder().encode(modes), forKey: defaultsKey)
    }
}

/// 「自定义模式」窗口的状态和规则，与界面分开，方便测试。
@MainActor
final class ModesEditor: ObservableObject {
    @Published var modes: [CustomMode]
    @Published var selection: String?        // 列表里选中的 key
    @Published var creating = false          // 正在写一个新的模式
    @Published var title = ""
    @Published var prompt = ""
    @Published var status = ""               // 校验没通过时的说明；通过时为空
    private let defaults: UserDefaults
    private let onChange: () -> Void

    init(defaults: UserDefaults = .standard, onChange: @escaping () -> Void) {
        self.defaults = defaults
        self.onChange = onChange
        modes = CustomModes.load(defaults: defaults)
    }

    func select(_ key: String?) {
        creating = false
        selection = key
        reloadForm()
    }

    func beginNew() {
        creating = true
        selection = nil
        title = ""
        prompt = ""
        status = ""
    }

    /// 把选中的那一项（或新建的空白表单）重新填进输入框。
    func reloadForm() {
        let mode = modes.first { $0.key == selection }
        title = mode?.title ?? ""
        prompt = mode?.system ?? ""
        status = ""
    }

    /// 存下表单里的内容：新建一个，或者修改选中的那一个。校验不过时返回 false，说明写在 status 里。
    @discardableResult
    func save() -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { status = L("请填写名称。", "Enter a name."); return false }
        guard !text.isEmpty else { status = L("请填写系统提示词。", "Enter the system prompt."); return false }
        // 名称就是菜单和浮窗下拉里的标识：重名会分不清，下拉也没法按名称选中
        let key = creating ? nil : selection
        let taken = PromptMode.builtin.map(\.title) + modes.filter { $0.key != key }.map(\.title)
        guard !taken.contains(name) else {
            status = L("已经有叫「\(name)」的模式了。", "A mode named \"\(name)\" already exists.")
            return false
        }
        let mode = modes.first { $0.key == key }.map { CustomMode(key: $0.key, title: name, system: text) }
            ?? CustomMode.make(title: name, system: text)
        var updated = modes
        if let index = updated.firstIndex(where: { $0.key == mode.key }) { updated[index] = mode } else { updated.append(mode) }
        commit(updated)
        creating = false
        selection = mode.key
        status = ""
        return true
    }

    func delete(_ key: String) {
        guard modes.contains(where: { $0.key == key }) else { return }
        // 被删的正好是默认模式：退回「解释名词」，免得默认模式指向一个不存在的 key
        if defaults.string(forKey: "mode") == key { defaults.set("explain", forKey: "mode") }
        commit(modes.filter { $0.key != key })
        if selection == key { selection = modes.first?.key }
        reloadForm()
    }

    private func commit(_ updated: [CustomMode]) {
        CustomModes.save(updated, defaults: defaults)
        modes = updated
        onChange()
    }
}

struct ModesSettingsView: View {
    @ObservedObject var editor: ModesEditor
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            // 列表横向撑满，按钮固定在右边；不给宽度的话整行会缩成一条悬在中间
            HStack(spacing: 0) {
                List(editor.modes, selection: $editor.selection) { mode in
                    Text(mode.title).tag(mode.key)
                }
                VStack(spacing: 6) {
                    Button(L("新增", "Add")) { editor.beginNew() }
                    Button(L("删除", "Delete")) { confirmDelete = true }
                        .disabled(editor.selection == nil)
                }
                .padding(10)
            }
            .frame(height: 170)
            Divider()
            Form {
                TextField(L("名称", "Name"), text: $editor.title)
                LabeledContent(L("系统提示词", "System prompt")) {
                    TextEditor(text: $editor.prompt)
                        .font(.system(size: 13))
                        .frame(minHeight: 130)
                }
                Text(editor.status).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Spacer()
                    Button(L("还原", "Revert")) { editor.reloadForm() }.keyboardShortcut(.cancelAction)
                    Button(L("保存", "Save")) { editor.save() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .frame(width: 540)
        .onAppear { editor.select(editor.modes.first?.key) }
        .onChange(of: editor.selection) { _ in
            // 新建时 selection 会被清空，那不是「选中了别的」
            if !editor.creating { editor.reloadForm() }
        }
        .confirmationDialog(L("删除选中的模式？", "Delete the selected mode?"), isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button(L("删除", "Delete"), role: .destructive) {
                if let key = editor.selection { editor.delete(key) }
            }
        }
    }
}

@MainActor
func makeModesWindow(defaults: UserDefaults = .standard, onChange: @escaping () -> Void) -> NSWindow {
    let host = NSHostingController(rootView: ModesSettingsView(editor: ModesEditor(defaults: defaults, onChange: onChange)))
    let window = NSWindow(contentViewController: host)
    window.title = L("自定义模式", "Custom Modes")
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.setContentSize(host.view.fittingSize)
    return window
}
