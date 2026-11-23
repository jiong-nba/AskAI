import AppKit
import ApplicationServices
import Carbon

/// 剪贴板快照：逐 item 保存全部类型的数据。
/// 只备份 .string 会丢内容：图片会被清掉，富文本被降级成纯文本，多文件只剩一个。
private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
}

private func snapshotPasteboard(_ pb: NSPasteboard) -> PasteboardSnapshot? {
    let items = (pb.pasteboardItems ?? []).compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
        var data: [NSPasteboard.PasteboardType: Data] = [:]
        for type in item.types {
            // 主动取数据会促使 lazy provider 立即产出；取不到的类型直接略过
            if let d = item.data(forType: type) { data[type] = d }
        }
        return data.isEmpty ? nil : data
    }
    return items.isEmpty ? nil : PasteboardSnapshot(items: items)
}

private func restorePasteboard(_ pb: NSPasteboard, _ snapshot: PasteboardSnapshot?) {
    pb.clearContents() // 清掉本次 ⌘C 复制进来的内容
    guard let snapshot else { return }
    pb.writeObjects(snapshot.items.map { data in
        let item = NSPasteboardItem()
        for (type, d) in data { item.setData(d, forType: type) }
        return item
    })
}

private func trimmedSelection(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text
}

func accessibleSelection(in pid: pid_t) -> String? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.12)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    let element = focused as! AXUIElement // Type checked above.
    AXUIElementSetMessagingTimeout(element, 0.12)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
    return trimmedSelection(value as? String)
}

// A target with no selection can ignore Copy. Leave its original pasteboard untouched in that case.
@MainActor
func copiedSelection(from board: NSPasteboard, timeout: Duration = .milliseconds(350),
                     stillFocused: () -> Bool = { true }, postCopy: () -> Void) async throws -> String? {
    let original = board.changeCount
    let backup = snapshotPasteboard(board)
    guard stillFocused(), board.changeCount == original else { throw CancellationError() }
    postCopy()
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var copyGeneration: Int?
    defer {
        if let copyGeneration, stillFocused(), board.changeCount == copyGeneration {
            restorePasteboard(board, backup)
        }
    }
    repeat {
        guard stillFocused() else { throw CancellationError() }
        let current = board.changeCount
        if current != original {
            if let copyGeneration, current != copyGeneration { throw CancellationError() }
            copyGeneration = current
            if let text = trimmedSelection(board.string(forType: .string)), board.changeCount == current {
                return text
            }
        }
        try await Task.sleep(for: .milliseconds(10))
    } while clock.now < deadline
    return nil
}

@MainActor
private func focusedAccessibleApp() -> pid_t? {
    guard AXIsProcessTrusted() else { return nil }
    return NSWorkspace.shared.frontmostApplication?.processIdentifier
}

@MainActor
func selectedText(focusedPID: @MainActor () -> pid_t? = focusedAccessibleApp,
                  readAX: @escaping @Sendable (pid_t) -> String? = { accessibleSelection(in: $0) },
                  copy: @MainActor (pid_t) async throws -> String? = copyFromApp) async throws -> String? {
    guard let pid = focusedPID() else { return nil }
    let text = await Task.detached { readAX(pid) }.value
    guard focusedPID() == pid else { throw CancellationError() }
    if let text { return text }
    return try await copy(pid)
}

@MainActor
private func copyFromApp(_ pid: pid_t) async throws -> String? {
    return try await copiedSelection(from: .general, stillFocused: {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
