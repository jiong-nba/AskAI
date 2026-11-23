import Foundation

// MARK: - 提示词模式

struct PromptMode {
    let key: String
    let title: String
    let system: String

    static let all: [PromptMode] = [
        PromptMode(key: "explain",
                   title: L("解释名词", "Explain"),
                   system: L(
                     "你是名词/术语解释助手，读者有计算机/数据库/软件工程背景。用户给出的通常是一个名词、术语或一小段文字。"
                   + "请用简体中文解释：如果原文是英文单词或术语，开头先给出它的中文翻译或对应说法；"
                   + "然后用一句话说清它是什么，再补充关键背景、机制或一个例子。"
                   + "技术术语优先按其领域含义解释（有歧义时点明），但不要预设具体技术栈、产品名或内部语境。"
                   + "不要翻译腔。控制在 150 字以内。",
                     "You explain terms for an engineer with a computer science / database / software engineering background. "
                   + "The user usually gives a single term or a short phrase. Start with a one-line plain definition, "
                   + "then add the key mechanism or a concrete example. Prefer the technical meaning of the term and call out "
                   + "ambiguity when it exists, but do not assume a specific stack, product or private context. "
                   + "Keep it under 120 words. Answer in English.")),
        PromptMode(key: "translate",
                   title: L("翻译", "Translate"),
                   system: L(
                     "你是翻译助手。把用户给出的文本翻译成简体中文；若原文本身是中文，则翻译成英文。"
                   + "只输出译文，不要解释、不要加引号或前缀。专业术语按通行译法。",
                     "You are a translator. Translate the user's text into English; if it is already English, translate it "
                   + "into Simplified Chinese. Output the translation only — no explanations, quotes or prefixes. "
                   + "Use conventional terminology.")),
        PromptMode(key: "summarize",
                   title: L("总结要点", "Summarize"),
                   system: L(
                     "你是摘要助手。用简体中文概括用户文本的核心要点，最多 3 条，每条一行，以「• 」开头。"
                   + "保留关键数字与结论，删除铺垫和重复。不要输出原文。",
                     "You summarize. Give at most 3 bullet points, one per line, each starting with \"• \". "
                   + "Keep key numbers and conclusions, drop filler and repetition. Do not restate the source. "
                   + "Answer in English.")),
        PromptMode(key: "code",
                   title: L("解释代码", "Explain Code"),
                   system: L(
                     "你是代码讲解助手。用简体中文解释用户给出的代码：先说它整体做什么，"
                   + "再按执行顺序说明关键语句的作用，最后指出可能的坑或副作用。控制在 200 字以内。",
                     "You explain code. Start with what it does overall, then walk through the key statements in "
                   + "execution order, and finish with pitfalls or side effects. Keep it under 160 words. Answer in English.")),
    ]
}



func currentMode() -> PromptMode {
    let key = defaults.string(forKey: "mode") ?? "explain"
    return PromptMode.all.first { $0.key == key } ?? PromptMode.all[0]
}

/// Older history entries stored the Chinese display title instead of the mode key.
func historyMode(_ key: String) -> PromptMode {
    let legacy = ["解释名词": "explain", "翻译": "translate", "总结要点": "summarize", "解释代码": "code"]
    return PromptMode.all.first { $0.key == (legacy[key] ?? key) || $0.title == key } ?? PromptMode.all[0]
}
