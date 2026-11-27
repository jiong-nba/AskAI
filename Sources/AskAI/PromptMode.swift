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
    var system: String { systemPrompt(defaults: .standard) }

    func systemPrompt(defaults: UserDefaults) -> String {
        systemPrompt(language: AnswerLanguage.current(defaults: defaults),
                     background: defaults.string(forKey: "explainBackground") ?? "")
    }

    func systemPrompt(language: AnswerLanguage, background: String = "") -> String {
        let prompt = language == .chinese ? chinese : english
        guard key == "explain" else { return prompt }
        let reader = background.trimmingCharacters(in: .whitespacesAndNewlines)
        let guidance: String
        if reader.isEmpty {
            guidance = language == .chinese ? ExplainCatalog.generalZh : ExplainCatalog.generalEn
        } else if let profile = ExplainCatalog.profiles.first(where: { $0.en == reader || $0.zh == reader }) {
            guidance = language == .chinese ? profile.hintZh : profile.hintEn
        } else {
            guidance = (language == .chinese ? ExplainCatalog.customZh : ExplainCatalog.customEn) + " · " + reader
        }
        return guidance + "\n" + prompt
    }

    static let builtin: [PromptMode] = [
        PromptMode(key: "explain",
                   title: L("解释名词", "Explain"),
                   chinese: ExplainCatalog.baseZh, english: ExplainCatalog.baseEn),
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

    /// 内置模式加上用户在 defaults 里定义的模式。每次都重新读：设置窗里改完立即生效。
    static func all(defaults: UserDefaults = .standard) -> [PromptMode] {
        builtin + CustomModes.load(defaults: defaults).map {
            PromptMode(key: $0.key, title: $0.title, system: $0.system)
        }
    }
}

func currentMode(in defaults: UserDefaults = .standard) -> PromptMode {
    let key = defaults.string(forKey: "mode") ?? "explain"
    return PromptMode.all(defaults: defaults).first { $0.key == key } ?? PromptMode.builtin[0]
}

/// Older history entries stored the Chinese display title instead of the mode key.
func historyMode(_ key: String, defaults: UserDefaults = .standard) -> PromptMode {
    let legacy = ["解释名词": "explain", "翻译": "translate", "总结要点": "summarize", "解释代码": "code"]
    return PromptMode.all(defaults: defaults).first { $0.key == (legacy[key] ?? key) || $0.title == key }
        ?? PromptMode.builtin[0]
}
