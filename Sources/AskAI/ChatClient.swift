import Foundation

// MARK: - 2. 调用 LLM（OpenAI Chat Completions 格式）

/// 一轮已经完成的问答，追问时作为上下文原样发回。
struct ChatTurn: Equatable {
    let question: String     // 显示用的问题
    let answer: String       // 回答的 Markdown 原文（不含思考过程）
    var message: String      // 实际发给模型的用户消息；对原文提问时是整段原文（或其预览）
    var isFollowUp: Bool     // 是否追问：显示时先列出问题
}

func askLLM(_ input: QueryInput, mode: PromptMode, connection: ConnectionSettings, context: [ChatTurn] = [],
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
    var messages: [[String: String]] = [["role": "system", "content": mode.system]]
    // 追问：之前的轮次原样发回，模型才知道“它”指的是什么
    for turn in context {
        messages.append(["role": "user", "content": turn.message])
        messages.append(["role": "assistant", "content": turn.answer])
    }
    messages.append(["role": "user", "content": input.message])
    var body: [String: Any] = ["model": connection.model, "messages": messages]
    // 有的模型不接受非默认的 temperature（OpenAI 的推理模型直接返回 400），配置为不发送时就不带这个字段
    if let temperature = connection.temperature { body["temperature"] = temperature }
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

        // 服务端确认完成后 readChatStream 会提前返回；读完或出错后都把底层请求收掉，不让连接挂着
        defer { bytes.task.cancel() }
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
        // 不是 JSON 的 data 行（心跳、代理注入的内容）跳过，不让整段回答失败；
        // 真被截断的流仍会在循环结束后因为 finished 为假而报错
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
        if let error = obj["error"], !(error is NSNull) {
            let message = (error as? [String: Any])?["message"] as? String
            throw NSError(domain: "AskAI", code: 3, userInfo: [NSLocalizedDescriptionKey:
                message ?? L("服务端报告流式请求失败", "The server reported a streaming error")])
        }
        guard let choices = obj["choices"] as? [[String: Any]], let choice = choices.first else { continue }
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
            // 服务端已经确认完成：到此为止。继续读到连接结束的话，对方关闭得不干净
            // （或不发 [DONE]）就会把一段完整的回答判成失败
            finished = true
            break
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
