import AppKit

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
final class ModesEditor {
    var modes: [CustomMode]
    var selection: String?        // 列表里选中的 key
    var creating = false          // 正在写一个新的模式
    var title = ""
    var prompt = ""
    var status = ""               // 校验没通过时的说明；通过时为空
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

@MainActor
private final class ModesSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                                 NSTextFieldDelegate, NSTextViewDelegate {
    private let editor: ModesEditor
    private let tableView = NSTableView()
    private let deleteButton = NSButton()
    private let nameField = NSTextField()
    private let promptView = NSTextView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var updatingSelection = false

    init(editor: ModesEditor) {
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self

        let listScroll = NSScrollView()
        listScroll.borderType = .bezelBorder
        listScroll.hasVerticalScroller = true
        listScroll.documentView = tableView

        let addButton = NSButton(title: L("新增", "Add"), target: self, action: #selector(addMode))
        addButton.bezelStyle = .rounded
        deleteButton.title = L("删除", "Delete")
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(confirmDelete)

        let listActions = NSStackView(views: [addButton, deleteButton])
        listActions.orientation = .vertical
        listActions.alignment = .width
        listActions.spacing = 6

        let topRow = NSStackView(views: [listScroll, listActions])
        topRow.alignment = .centerY
        topRow.spacing = 10

        let divider = NSBox()
        divider.boxType = .separator

        let nameLabel = NSTextField(labelWithString: L("名称", "Name"))
        nameLabel.alignment = .right
        nameField.delegate = self

        let promptLabel = NSTextField(labelWithString: L("系统提示词", "System prompt"))
        promptLabel.alignment = .right

        let promptScroll = NSScrollView()
        promptScroll.borderType = .bezelBorder
        promptScroll.hasVerticalScroller = true
        promptView.isEditable = true
        promptView.isRichText = false
        promptView.isVerticallyResizable = true
        promptView.autoresizingMask = [.width]
        promptView.textContainer?.widthTracksTextView = true
        promptView.font = .systemFont(ofSize: 13)
        promptView.textColor = .textColor
        promptView.delegate = self
        promptScroll.documentView = promptView

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        let revertButton = NSButton(title: L("还原", "Revert"), target: self, action: #selector(revertForm))
        revertButton.bezelStyle = .rounded
        revertButton.keyEquivalent = "\u{1b}"

        let saveButton = NSButton(title: L("保存", "Save"), target: self, action: #selector(saveMode))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottomActions = NSStackView(views: [spacer, revertButton, saveButton])
        bottomActions.spacing = 8

        let formGrid = NSGridView(views: [
            [nameLabel, nameField],
            [promptLabel, promptScroll],
        ])
        formGrid.columnSpacing = 12
        formGrid.rowSpacing = 10
        formGrid.column(at: 0).xPlacement = .trailing
        formGrid.column(at: 1).xPlacement = .fill
        formGrid.row(at: 1).yPlacement = .top

        let stack = NSStackView(views: [topRow, divider, formGrid, statusLabel, bottomActions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 540),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listScroll.heightAnchor.constraint(equalToConstant: 160),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            formGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            promptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomActions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        editor.select(editor.modes.first?.key)
        syncUI()
    }

    private func syncUI() {
        updatingSelection = true
        tableView.reloadData()
        if let key = editor.selection, let row = editor.modes.firstIndex(where: { $0.key == key }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        updatingSelection = false

        deleteButton.isEnabled = editor.selection != nil
        nameField.stringValue = editor.title
        promptView.string = editor.prompt
        statusLabel.stringValue = editor.status
    }

    func numberOfRows(in tableView: NSTableView) -> Int { editor.modes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: editor.modes[row].title)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < editor.modes.count else { return }
        editor.select(editor.modes[row].key)
        syncUI()
    }

    func controlTextDidChange(_ obj: Notification) {
        editor.title = nameField.stringValue
    }

    func textDidChange(_ notification: Notification) {
        editor.prompt = promptView.string
    }

    @objc private func addMode() {
        editor.beginNew()
        syncUI()
        view.window?.makeFirstResponder(nameField)
    }

    @objc private func confirmDelete() {
        guard let key = editor.selection else { return }
        let alert = NSAlert()
        alert.messageText = L("删除选中的模式？", "Delete the selected mode?")
        alert.addButton(withTitle: L("删除", "Delete")).hasDestructiveAction = true
        alert.addButton(withTitle: L("取消", "Cancel"))
        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                Task { @MainActor [weak self] in
                    self?.editor.delete(key)
                    self?.syncUI()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            editor.delete(key)
            syncUI()
        }
    }

    @objc private func revertForm() {
        editor.reloadForm()
        syncUI()
    }

    @objc private func saveMode() {
        editor.title = nameField.stringValue
        editor.prompt = promptView.string
        editor.save()
        syncUI()
    }
}

@MainActor
func makeModesWindow(defaults: UserDefaults = .standard, onChange: @escaping () -> Void) -> NSWindow {
    let controller = ModesSettingsViewController(editor: ModesEditor(defaults: defaults, onChange: onChange))
    let window = NSWindow(contentViewController: controller)
    window.title = L("自定义模式", "Custom Modes")
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    controller.view.layoutSubtreeIfNeeded()
    window.setContentSize(controller.view.fittingSize)
    return window
}
