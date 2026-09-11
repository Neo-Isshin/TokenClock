#if os(Windows)
import Foundation
import Testing
import Win32Shim

@Suite(.serialized)
struct WindowsShareRendererTests {
    @Test func rendersA1200By1500PNG() throws {
        gdip_init()
        defer { gdip_shutdown() }
        let previewPath = ProcessInfo.processInfo.environment["TOKENCLOCK_SHARE_PREVIEW_PATH"]
        let path = previewPath.map(URL.init(fileURLWithPath:)) ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenclock-share-renderer-test.png")
        defer { if previewPath == nil { try? FileManager.default.removeItem(at: path) } }

        let values = [
            "September 11, 2026", "3.6M", "TOKENS", "144", "MESSAGES",
            "33.33%", "CACHE", "TOOL BREAKDOWN",
            "⚛️\tCodex\t1.8M\t0.5\n✳️\tClaude Code\t1.2M\t0.333333\n💎\tCursor Agent\t600K\t0.166667",
            "No usage", "Every call moves an idea one step closer to reality.",
            "Made with TokenClock",
        ]
        let result = withCStrings(values) { pointers -> Int32 in
            var card = win_share_card()
            card.date = pointers[0]; card.tokens = pointers[1]; card.token_label = pointers[2]
            card.messages = pointers[3]; card.message_label = pointers[4]
            card.cache = pointers[5]; card.cache_label = pointers[6]
            card.breakdown_label = pointers[7]; card.rows = pointers[8]
            card.empty_label = pointers[9]; card.quote = pointers[10]; card.generated_by = pointers[11]
            return path.path.withCString { output in
                withUnsafePointer(to: &card) { win_share_card_save_png($0, output) }
            }
        }
        #expect(result == 1)
        let png = try Data(contentsOf: path)
        #expect(png.count > 10_000)
        #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        #expect(readUInt32(png, at: 16) == 1_200)
        #expect(readUInt32(png, at: 20) == 1_500)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func withCStrings<T>(
        _ values: [String], _ body: ([UnsafePointer<CChar>]) -> T
    ) -> T {
        func recur(_ index: Int, _ pointers: [UnsafePointer<CChar>]) -> T {
            if index == values.count { return body(pointers) }
            return values[index].withCString { recur(index + 1, pointers + [$0]) }
        }
        return recur(0, [])
    }
}
#endif
