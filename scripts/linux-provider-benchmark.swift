#if os(Linux)
import Foundation

struct HourlyForecast: Sendable {
    let time: String
    let tempC: Int
    let emoji: String
    let description: String
}

@main
struct LinuxProviderBenchmark {
    static func main() {
        let codex = CodexUsageService()
        let codexFull = elapsed { codex.fullScan() }
        let codexDetail = elapsed { _ = codex.todaySessions() }
        let codexIncremental = elapsed { codex.incrementalScan() }

        let claude = ClaudeCodeUsageService()
        let claudeFull = elapsed { claude.fullScan() }
        let claudeDetail = elapsed { _ = claude.todaySessions() }
        let claudeIncremental = elapsed { claude.incrementalScan() }

        let openclaw = OpenClawUsageService()
        let openclawFull = elapsed { openclaw.fullScan() }
        let openclawDetail = elapsed { _ = openclaw.todaySessions() }
        let openclawIncremental = elapsed { openclaw.incrementalScan() }

        let gemini = GeminiUsageService()
        let geminiFull = elapsed { gemini.fullScan() }
        let geminiDetail = elapsed { _ = gemini.todaySessions() }
        let geminiIncremental = elapsed { gemini.incrementalScan() }

        let qwen = QwenCodeUsageService()
        let qwenFull = elapsed { qwen.fullScan() }
        let qwenDetail = elapsed { _ = qwen.todaySessions() }
        let qwenIncremental = elapsed { qwen.incrementalScan() }

        let copilot = CopilotUsageService()
        let copilotFull = elapsed { copilot.fullScan() }
        let copilotDetail = elapsed { _ = copilot.todaySessions() }
        let copilotIncremental = elapsed { copilot.incrementalScan() }

        let continueService = ContinueUsageService()
        let continueFull = elapsed { continueService.fullScan() }
        let continueDetail = elapsed { _ = continueService.todaySessions() }
        let continueIncremental = elapsed { continueService.incrementalScan() }

        let grok = GrokUsageService()
        let grokFull = elapsed { grok.fullScan() }
        let grokDetail = elapsed { _ = grok.todaySessions() }
        let grokIncremental = elapsed { grok.incrementalScan() }

        let aider = AiderUsageService()
        let aiderFull = elapsed { aider.fullScan() }
        let aiderDetail = elapsed { _ = aider.todaySessions() }
        let aiderIncremental = elapsed { aider.incrementalScan() }

        print(String(format: "codex_full_ms=%.3f codex_detail_ms=%.3f codex_incremental_ms=%.3f claude_full_ms=%.3f claude_detail_ms=%.3f claude_incremental_ms=%.3f openclaw_full_ms=%.3f openclaw_detail_ms=%.3f openclaw_incremental_ms=%.3f gemini_full_ms=%.3f gemini_detail_ms=%.3f gemini_incremental_ms=%.3f qwen_full_ms=%.3f qwen_detail_ms=%.3f qwen_incremental_ms=%.3f copilot_full_ms=%.3f copilot_detail_ms=%.3f copilot_incremental_ms=%.3f continue_full_ms=%.3f continue_detail_ms=%.3f continue_incremental_ms=%.3f grok_full_ms=%.3f grok_detail_ms=%.3f grok_incremental_ms=%.3f aider_full_ms=%.3f aider_detail_ms=%.3f aider_incremental_ms=%.3f",
            codexFull, codexDetail, codexIncremental,
            claudeFull, claudeDetail, claudeIncremental,
            openclawFull, openclawDetail, openclawIncremental,
            geminiFull, geminiDetail, geminiIncremental,
            qwenFull, qwenDetail, qwenIncremental,
            copilotFull, copilotDetail, copilotIncremental,
            continueFull, continueDetail, continueIncremental,
            grokFull, grokDetail, grokIncremental,
            aiderFull, aiderDetail, aiderIncremental
        ))
    }

    private static func elapsed(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
#endif
