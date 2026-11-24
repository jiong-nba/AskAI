import AppKit
import Foundation
import Testing
@testable import AskAI

@Suite(.serialized)
struct HistoryMenuTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(minutesAgo minutes: Double, mode: String = "explain", source: String,
                       question: String? = nil) -> HistoryEntry {
        HistoryEntry(time: now.addingTimeInterval(-minutes * 60), mode: mode, source: source, answer: "a",
                     question: question)
    }

    // Twenty entries that differ only after their first 24 characters are told apart by mode and age.
    @Test @MainActor func labelCarriesModeAndAge() {
        let label = AppDelegate.historyLabel(entry(minutesAgo: 5, source: "throttling"), now: now)
        #expect(label.hasPrefix("throttling"))
        #expect(label.contains(historyMode("explain").title))
        #expect(label.contains(L("5 分钟前", "5 min ago")))
        // A follow-up is named after its question, not after the selection it continues.
        let followUp = AppDelegate.historyLabel(entry(minutesAgo: 30 * 60, mode: "translate", source: "same selection",
                                                      question: "and why?"), now: now)
        #expect(followUp.hasPrefix("↳ and why?"))
        #expect(followUp.contains(historyMode("translate").title) && followUp.contains(L("昨天", "yesterday")))
    }

    @Test @MainActor func longTextIsCutAfterTwentyFourCharacters() {
        let long = String(repeating: "字", count: 40)
        let opener = appIsChinese ? "（" : "  ("
        #expect(AppDelegate.historyLabel(entry(minutesAgo: 0.5, source: long), now: now)
            == String(long.prefix(24)) + "…" + opener + historyMode("explain").title + " · " + L("刚刚", "just now")
            + (appIsChinese ? "）" : ")"))
        // A multi-line selection (including CRLF and surrounding whitespace) does not break the menu title.
        let flat = AppDelegate.historyLabel(entry(minutesAgo: 0.5, source: "  line one\r\nline two  "), now: now)
        #expect(!flat.contains("\n") && !flat.contains("\r") && flat.hasPrefix("line one line two"))
    }

    @Test func relativeTimeSteps() {
        #expect(relativeTime(from: now.addingTimeInterval(-30), now: now) == L("刚刚", "just now"))
        #expect(relativeTime(from: now.addingTimeInterval(-30 * 60), now: now) == L("30 分钟前", "30 min ago"))
        #expect(relativeTime(from: now.addingTimeInterval(-5 * 3_600), now: now) == L("5 小时前", "5 h ago"))
        #expect(relativeTime(from: now.addingTimeInterval(-40 * 3_600), now: now) == L("昨天", "yesterday"))
        // A clock that runs ahead must not produce "-3 分钟前".
        #expect(relativeTime(from: now.addingTimeInterval(180), now: now) == L("刚刚", "just now"))
        let older = relativeTime(from: now.addingTimeInterval(-40 * 86_400), now: now)
        #expect(!older.isEmpty && !older.contains("前") && !older.contains("ago"))
    }
}
