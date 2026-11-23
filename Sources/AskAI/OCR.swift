import AppKit
import Vision

// MARK: - 2.5 OCR：截图选区 → 识别文字（用于图片里不可复制的词）

func captureRegion() -> URL? {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("askai-shot-\(UUID().uuidString).png")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-i", "-x", "-t", "png", url.path]   // -i 交互选区，-x 静音
    do { try task.run() } catch { return nil }
    task.waitUntilExit()
    // 用户按 Esc 取消时不会产生文件
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

func ocrText(from url: URL) -> String? {
    defer { try? FileManager.default.removeItem(at: url) }
    guard let img = NSImage(contentsOf: url),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])

    let text = (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}
