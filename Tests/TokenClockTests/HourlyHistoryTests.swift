import Foundation
import XCTest
@testable import TokenClock

final class HourlyHistoryTests: XCTestCase {
    private func day() -> Date { Calendar.current.startOfDay(for: Date()) }
    private func hour(_ tokens: Int, cache: Int = 0, model: String? = "gpt-6-sol") -> HourlyUsage {
        var value = HourlyUsage(tokens: tokens, messages: 1)
        value.recordMetadata(tokens: tokens, cache: cache, model: model, cost: .init(value: 0.25))
        return value
    }
    private func temporary(_ run: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenclock-hourly-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try run(root)
    }
    func testSingleDayIsOptInAndAlwaysHas24OrderedBuckets() throws {
        try temporary { root in
            let daily = HistoryStore(path: root.appendingPathComponent("daily.sqlite"))
            let hourly = HourlyHistoryStore(path: root.appendingPathComponent("hourly.sqlite"))
            let date = day(), key = DateHelper.dateKey(from: date)
            hourly.replace(tool: "Codex", hours: [key+"-00":hour(10), key+"-23":hour(20)], force:true)
            let result = UsageOverviewBuilder.load(startDate: date,endDate: date,grouping:.tool,
                store:daily,hourlyWhenSingleDay:true,hourlyStore:hourly)
            XCTAssertTrue(result.isHourly); XCTAssertEqual(result.days.count,24)
            XCTAssertEqual(result.days.first?.dateKey,key+"-00")
            XCTAssertEqual(result.days.last?.dateKey,key+"-23")
            XCTAssertEqual(result.days[12].metrics.tokens,0)
            XCTAssertEqual(result.summary.tokens,30)
            XCTAssertEqual(UsageOverviewBuilder.load(startDate:date,endDate:date,grouping:.tool,store:daily).days.count,1)
            let tomorrow = Calendar.current.date(byAdding:.day,value:1,to:date)!
            let range = UsageOverviewBuilder.load(startDate:date,endDate:tomorrow,grouping:.tool,store:daily,
                hourlyWhenSingleDay:true,hourlyStore:hourly)
            XCTAssertFalse(range.isHourly); XCTAssertEqual(range.days.count,2)
        }
    }
    func testCacheModelsMessagesAndCostsStayInTheirHour() throws {
        try temporary { root in
            let store = HourlyHistoryStore(path:root.appendingPathComponent("h.sqlite"))
            let key = DateHelper.dateKey(from:day())
            var value = hour(10,cache:90)
            value.tokens += 20; value.messages += 1
            value.recordMetadata(tokens:20,cache:0,model:"claude-sonnet-5",cost:.init(value:0.5))
            store.replace(tool:"Codex",hours:[key+"-03":value],force:true)
            let report = UsageOverviewBuilder.makeHourly(date:day(),hourly:store.query(day:key),daily:[],
                grouping:.model,includingCacheRead:true)
            XCTAssertEqual(report.days[3].metrics.displayedTokens(includingCacheRead:true),120)
            XCTAssertEqual(report.days[3].metrics.messages,2)
            XCTAssertEqual(report.days[3].metrics.cost.value,0.75,accuracy:0.000001)
            XCTAssertEqual(Set(report.days[3].rows.map(\.name)),Set(["gpt-6-sol","claude-sonnet-5"]))
            XCTAssertEqual(report.days[2].rows.count,0)
        }
    }
    func testReplaceDoesNotAccumulateAndPreservesOtherToolsAndDays() throws {
        try temporary { root in
            let store = HourlyHistoryStore(path:root.appendingPathComponent("h.sqlite"))
            let key = DateHelper.dateKey(from:day())
            store.replace(tool:"Codex",hours:[key+"-02":hour(10)],force:true)
            store.replace(tool:"Codex",hours:[key+"-02":hour(10)],force:true)
            XCTAssertEqual(store.query(day:key).first?.totalTokens,10)
            store.replace(tool:"Claude Code",hours:[key+"-02":hour(20)],force:true)
            store.replace(tool:"Codex",hours:[key+"-03":hour(40)],force:true)
            XCTAssertEqual(store.query(day:key).reduce(0){$0+$1.totalTokens},60)
            store.replace(tool:"Codex",hours:[:],force:true)
            XCTAssertEqual(store.query(day:key).reduce(0){$0+$1.totalTokens},60)
            let reopened = HourlyHistoryStore(path:root.appendingPathComponent("h.sqlite"))
            XCTAssertEqual(reopened.query(day:key).reduce(0){$0+$1.totalTokens},60)
        }
    }
    func testLegacyDailyTotalIsNotInventedAsHourlyData() {
        let key = DateHelper.dateKey(from:day())
        let tool = DaySnapshot.Tool(name:"Hermes",tokens:2400,messages:24,cacheRate:0,isActive:false,
            cost:.unavailable,cacheReadTokens:0,sessions:[])
        let legacy = DaySnapshot(date:key,totalTokens:2400,totalMessages:24,tools:[tool])
        let report = UsageOverviewBuilder.makeHourly(date:day(),hourly:[],daily:[legacy],grouping:.tool)
        XCTAssertEqual(report.summary.tokens,2400)
        XCTAssertTrue(report.hasPartialHourlyData)
        XCTAssertTrue(report.days.allSatisfy{$0.metrics.tokens == 0})
    }
    func testUnstampedCountsCannotBecomeEventHours() throws {
        try temporary { root in
            let store = HourlyHistoryStore(path:root.appendingPathComponent("h.sqlite"))
            let key = DateHelper.dateKey(from:day())
            store.replace(tool:"Hermes",hours:[key+"-12":HourlyUsage(tokens:500,messages:1)],force:true)
            XCTAssertTrue(store.query(day:key).isEmpty)
        }
    }
    func testMetadataSubtractionAndUnknownPriceRemainHonest() {
        let first = hour(10,cache:90)
        var combined = first
        combined.tokens += first.tokens; combined.messages += first.messages
        combined.mergeMetadata(first)
        combined.tokens -= first.tokens; combined.messages -= first.messages
        combined.mergeMetadata(first,subtract:true)
        let snapshot = combined.historyTool(name:"Codex")
        XCTAssertEqual(snapshot.tokens,10); XCTAssertEqual(snapshot.cacheReadTokens,90)
        XCTAssertEqual(snapshot.cost.value,0.25,accuracy:0.000001)
        combined.recordMetadata(tokens:5,cache:nil,model:nil)
        let partial = combined.historyTool(name:"Codex")
        XCTAssertNil(partial.cacheReadTokens); XCTAssertFalse(partial.cost.complete)
    }
    func testClaudeIncrementalRewriteDoesNotDuplicateHourMetadata() throws {
        try temporary { root in
            let directory = root.appendingPathComponent("projects/p")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let file = directory.appendingPathComponent("session.jsonl")
            let eventDate = day().addingTimeInterval(3600)
            let stamp = ISO8601DateFormatter().string(from:eventDate)
            func write(_ tokens: Int) throws {
                let line = #"{"type":"assistant","timestamp":"STAMP","message":{"model":"claude-sonnet-5","usage":{"input_tokens":TOKENS,"output_tokens":5,"cache_read_input_tokens":90}}}"#
                    .replacingOccurrences(of:"STAMP",with:stamp).replacingOccurrences(of:"TOKENS",with:String(tokens))
                try (line+"\n").write(to:file,atomically:true,encoding:.utf8)
                try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(Double(tokens))],ofItemAtPath:file.path)
            }
            let service = ClaudeCodeUsageService(claudeHome:root.path)
            try write(10); service.fullScan()
            let key = DateHelper.hourKey(from:eventDate)
            XCTAssertEqual(service.hourlyData[key]?.historyTool(name:"Claude Code").tokens,15)
            try write(30); service.incrementalScan()
            XCTAssertEqual(service.hourlyData[key]?.historyTool(name:"Claude Code").tokens,35)
            XCTAssertEqual(service.hourlyData[key]?.historyTool(name:"Claude Code").cacheReadTokens,90)
            service.incrementalScan()
            XCTAssertEqual(service.hourlyData[key]?.historyTool(name:"Claude Code").messages,1)
        }
    }
    func testCursorAndGrokBotHourlyCallbackIsPartitionedAndIdempotent() throws {
        try temporary { root in
            let store = HourlyHistoryStore(path:root.appendingPathComponent("h.sqlite"))
            let date = day().addingTimeInterval(7200)
            let service = CursorAgentUsageService(onHourlyUpdate: { cursor,grok in
                store.replace(tool:"Cursor Agent",hours:cursor,force:true)
                store.replace(tool:"Grok Bot",hours:grok,force:true)
            })
            let event: (String) -> [String:Any] = { model in [
                "timestamp":Int(date.timeIntervalSince1970*1000), "model":model,
                "tokenUsage":["inputTokens":10,"outputTokens":5,"cacheReadTokens":90,"cacheWriteTokens":0]
            ] }
            service.applyEvents([event("gpt-6-sol"),event("grok-bot-default")],rangeDays:30)
            service.applyEvents([event("gpt-6-sol"),event("grok-bot-default")],rangeDays:30)
            let data = store.query(day:DateHelper.dateKey(from:date))
            XCTAssertEqual(Set(data.flatMap(\.tools).map(\.name)),Set(["Cursor Agent","Grok Bot"]))
            XCTAssertEqual(data.reduce(0){$0+$1.totalTokens},30)
            XCTAssertEqual(data.reduce(0){$0+$1.totalMessages},2)
        }
    }
}
