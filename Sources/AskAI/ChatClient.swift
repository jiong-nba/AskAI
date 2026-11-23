import Foundation

// MARK: - 2. 调用 LLM（OpenAI Chat Completions 格式）

func askLLM(_ input: QueryInput, mode: PromptMode, connection: ConnectionSettings,
            session: URLSession = .shared, onDelta: ((String) async -> Void)? = nil,
            onReasoning: ((String) async -> Void)? = nil) async throws -> String {
    guard !connection.apiKey.isEmpty else {
        throw AskError(L("未配置 API Key。请打开菜单栏设置或指定 ASKAI_KEY。",
                         "No API key configured. Open Settings in the menu bar or set ASKAI_KEY."))
    }
    var req = URLRequest(url: connection.url)
    req.httpMethod = "POST"
    req.timeoutInterval = 60
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(connection.apiKey)", forHTTPHeaderField: "Authorization")

    let streaming = onDelta != nil
    var body: [String: Any] = [
        "model": connection.model,
        "temperature": 0.3,
        "messages": [
            ["role": "system", "content": mode.system],
            ["role": "user", "content": input.message],
        ],
    ]
    if streaming { body["stream"] = true }
    req.httpBody = try JSONSerialization.data(withJSONObject: body)

    guard let onDelta else {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AskAI", code: code,
                          userInfo: [NSLocalizedDescriptionKey: L("API 出错 (\(code)): \(errBody.prefix(200))", "API error (\(code)): \(errBody.prefix(200))")])
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = root?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        guard let content = message?["content"] as? String, !content.isEmpty else {
            throw NSError(domain: "AskAI", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: L("响应里没有 content", "Response contained no content")])
        }
        return content
    }

    // 流式：逐行解析 SSE，边到边刷新
    let (bytes, resp) = try await session.bytes(for: req)
    return try await withTaskCancellationHandler {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            // 读取有限量错误信息后立即跳出：不让序列继续挂起等待
            var raw = ""
            var lines = 0
            for try await line in bytes.lines {
                raw += line
                lines += 1
                if raw.count > 300 || lines > 20 { break }
            }
            throw NSError(domain: "AskAI", code: code,
                          userInfo: [NSLocalizedDescriptionKey: L("API 出错 (\(code)): \(raw.prefix(200))", "API error (\(code)): \(raw.prefix(200))")])
        }

        return try await readChatStream(bytes.lines, onDelta: onDelta, onReasoning: onReasoning)
    } onCancel: {
        bytes.task.cancel()
    }
}

func readChatStream<Lines: AsyncSequence>(_ lines: Lines,
                                          onDelta: (String) async -> Void,
                                          onReasoning: ((String) async -> Void)? = nil) async throws -> String
where Lines.Element == String {
    var full = ""
    var reasoning = ""
    var finished = false
    for try await line in lines {
        try Task.checkCancellation()
        guard line.hasPrefix("data:") else { continue }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            finished = true
            break
        }
        guard !payload.isEmpty else { continue }
        let obj = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        if let error = obj?["error"], !(error is NSNull) {
            let message = (error as? [String: Any])?["message"] as? String
            throw NSError(domain: "AskAI", code: 3, userInfo: [NSLocalizedDescriptionKey:
                message ?? L("服务端报告流式请求失败", "The server reported a streaming error")])
        }
        guard let choices = obj?["choices"] as? [[String: Any]], let choice = choices.first else { continue }
        if let delta = choice["delta"] as? [String: Any] {
            // 推理模型（deepseek-reasoner 等）先流式输出思考过程，正文随后；分开累计，
            // onReasoning 只用于浮窗实时展示，返回值与历史仍只含正文
            if let thought = delta["reasoning_content"] as? String, !thought.isEmpty {
                reasoning += thought
                await onReasoning?(reasoning)
            }
            if let piece = delta["content"] as? String, !piece.isEmpty {
                full += piece
                await onDelta(full)
            }
        }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
            guard reason == "stop" else {
                throw NSError(domain: "AskAI", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    L("生成提前结束（\(reason)）", "Generation ended early (\(reason))")])
            }
            finished = true
        }
    }
    guard finished else {
        throw NSError(domain: "AskAI", code: 3, userInfo: [NSLocalizedDescriptionKey:
            L("连接在服务端确认完成前关闭", "Connection closed before the server confirmed completion")])
    }
    guard !full.isEmpty else {
        throw NSError(domain: "AskAI", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: L("流式响应没有内容", "Empty streaming response")])
    }
    return full
}
