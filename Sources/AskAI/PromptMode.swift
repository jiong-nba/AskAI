import Foundation

// MARK: - 回答语言

/// 回答用什么语言。默认跟着界面语言走，也可以在设置里单独指定。
enum AnswerLanguage: String {
    case chinese = "zh"
    case english = "en"

    /// defaults 里显式设置的值；没设或设了别的值就是 nil（跟随界面语言）。
    static func stored(defaults: UserDefaults = .standard) -> AnswerLanguage? {
        switch defaults.string(forKey: "answerLanguage")?.lowercased() {
        case "zh": return .chinese
        case "en": return .english
        default: return nil
        }
    }

    static func current(defaults: UserDefaults = .standard) -> AnswerLanguage {
        stored(defaults: defaults) ?? (appIsChinese ? .chinese : .english)
    }
}

// MARK: - 提示词模式

struct PromptMode {
    let key: String
    let title: String
    private let chinese: String
    private let english: String

    /// 只有一套提示词的模式（测试连接、自定义模式）。
    init(key: String, title: String, system: String) {
        self.init(key: key, title: title, chinese: system, english: system)
    }

    private init(key: String, title: String, chinese: String, english: String) {
        self.key = key
        self.title = title
        self.chinese = chinese
        self.english = english
    }

    /// 当前回答语言下的系统提示词。回答语言与界面语言可以不同，所以不能在建表时就用 L() 定死。
    var system: String { systemPrompt(language: AnswerLanguage.current()) }

    func systemPrompt(language: AnswerLanguage) -> String {
        language == .chinese ? chinese : english
    }

    static let builtin: [PromptMode] = [
        PromptMode(key: "explain",
                   title: L("解释名词", "Explain"),
                   chinese:
                     "你是名词/术语解释助手，读者有计算机/数据库/软件工程背景。用户给出的通常是一个名词、术语或一小段文字。"
                   + "请用简体中文解释：如果原文是英文单词或术语，开头先给出它的中文翻译或对应说法；"
                   + "然后用一句话说清它是什么，再补充关键背景、机制或一个例子。"
                   + "技术术语优先按其领域含义解释（有歧义时点明），但不要预设具体技术栈、产品名或内部语境。"
                   + "不要翻译腔。控制在 150 字以内。",
                   english:
                     "You explain terms for an engineer with a computer science / database / software engineering background. "
                   + "The user usually gives a single term or a short phrase. Start with a one-line plain definition, "
                   + "then add the key mechanism or a concrete example. Prefer the technical meaning of the term and call out "
                   + "ambiguity when it exists, but do not assume a specific stack, product or private context. "
                   + "Keep it under 120 words. Answer in English."),
        PromptMode(key: "translate",
                   title: L("翻译", "Translate"),
                   chinese:
                     "你是翻译助手。把用户给出的文本翻译成简体中文；若原文本身是中文，则翻译成英文。"
                   + "只输出译文，不要解释、不要加引号或前缀。专业术语按通行译法。",
                   english:
                     "You are a translator. Translate the user's text into English; if it is already English, translate it "
                   + "into Simplified Chinese. Output the translation only — no explanations, quotes or prefixes. "
                   + "Use conventional terminology."),
        PromptMode(key: "summarize",
                   title: L("总结要点", "Summarize"),
                   chinese:
                     "你是摘要助手。用简体中文概括用户文本的核心要点，最多 3 条，每条一行，以「• 」开头。"
                   + "保留关键数字与结论，删除铺垫和重复。不要输出原文。",
                   english:
                     "You summarize. Give at most 3 bullet points, one per line, each starting with \"• \". "
                   + "Keep key numbers and conclusions, drop filler and repetition. Do not restate the source. "
                   + "Answer in English."),
        PromptMode(key: "code",
                   title: L("解释代码", "Explain Code"),
                   chinese:
                     "你是代码讲解助手。用简体中文解释用户给出的代码：先说它整体做什么，"
                   + "再按执行顺序说明关键语句的作用，最后指出可能的坑或副作用。控制在 200 字以内。",
                   english:
                     "You explain code. Start with what it does overall, then walk through the key statements in "
                   + "execution order, and finish with pitfalls or side effects. Keep it under 160 words. Answer in English."),
    ]

    static var all: [PromptMode] { builtin }
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
