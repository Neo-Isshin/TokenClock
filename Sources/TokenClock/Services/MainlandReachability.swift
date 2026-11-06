#if os(macOS)
import Foundation
import Combine
import Darwin

struct MainlandReachabilityTarget: Equatable, Sendable {
    let ip: String
    let port: Int
    var ipVersion: Int { ip.contains(":") ? 6 : 4 }
    var display: String { ipVersion == 6 ? "[\(ip)]:\(port)" : "\(ip):\(port)" }

    static func parse(ip: String, port: String) -> Self? {
        guard let address = NetworkDiagnosticParser.address(ip.trimmingCharacters(in: .whitespacesAndNewlines)),
              let number = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(number) else { return nil }
        if address.contains(":") {
            var bytes = [UInt8](repeating: 0, count: 16)
            guard address.withCString({ inet_pton(AF_INET6, $0, &bytes) }) == 1,
                  bytes[0] & 0xe0 == 0x20,
                  !address.hasPrefix("2001:db8:") else { return nil }
        } else {
            let b = address.split(separator: ".").compactMap { Int($0) }
            guard b.count == 4, b[0] > 0, b[0] < 224, b[0] != 10, b[0] != 127,
                  !(b[0] == 100 && (64...127).contains(b[1])),
                  !(b[0] == 169 && b[1] == 254), !(b[0] == 172 && (16...31).contains(b[1])),
                  !(b[0] == 192 && b[1] == 168), !(b[0] == 192 && b[1] == 0 && [0, 2].contains(b[2])),
                  !(b[0] == 198 && [18, 19].contains(b[1])),
                  !(b[0] == 198 && b[1] == 51 && b[2] == 100),
                  !(b[0] == 203 && b[1] == 0 && b[2] == 113) else { return nil }
        }
        return .init(ip: address, port: number)
    }
}

enum MainlandProbeOutcome: String, Sendable { case reachable, noResponse, refused, unavailable }

struct MainlandProbeObservation: Identifiable, Sendable {
    let id: String
    let index: Int
    let country: String
    let city: String
    let asn: Int
    let network: String
    let outcome: MainlandProbeOutcome
    let milliseconds: Double?
    var referenceReachable: Bool? = nil
    var carrier: String? {
        guard country == "CN" else { return nil }
        switch asn {
        case 4134: return "China Telecom"
        case 4837: return "China Unicom"
        case 9808: return "China Mobile"
        default: return nil
        }
    }
    var locationKey: String { "\(country)|\(asn)|\(city)|\(network)" }
}

enum MainlandReachabilityVerdict: Equatable, Sendable { case reachable, partial, suspectedRestriction, unavailable, inconclusive }
enum GlobalpingIssue: String, Sendable { case rateLimited, noProbes, serviceUnavailable, invalidResponse, timedOut }

struct MainlandReachabilityReport: Sendable {
    let target: MainlandReachabilityTarget
    var checkedAt = Date()
    var observations: [MainlandProbeObservation] = []
    var measurementIDs: [String] = []
    var issues: [GlobalpingIssue] = []

    var verdict: MainlandReachabilityVerdict {
        let china = observations.filter { $0.carrier != nil }
        let foreign = observations.filter { ["US", "SG"].contains($0.country) }
        let goodChina = china.filter { $0.outcome == .reachable }
        if !goodChina.isEmpty {
            let carriers = Set(china.compactMap(\.carrier))
            return china.count == 6 && carriers.count == 3 && china.allSatisfy { $0.outcome == .reachable } ? .reachable : .partial
        }
        // An ordinary timeout is not a blocking finding. Require repeated failures
        // across carriers, healthy same-probe references, and two foreign controls.
        let evidenced = china.filter { $0.outcome == .noResponse && $0.referenceReachable == true }
        let carriers = Set(evidenced.compactMap(\.carrier))
        let foreignCountries = Set(foreign.filter { $0.outcome == .reachable }.map(\.country))
        if issues.isEmpty, china.count == 6, evidenced.count >= 4, carriers.count >= 2,
           foreignCountries.count == 2, !china.contains(where: { $0.outcome == .refused }) {
            return .suspectedRestriction
        }
        let finished = observations.filter { $0.outcome != .unavailable }
        if foreign.count == 2, foreign.allSatisfy({ $0.outcome == .noResponse || $0.outcome == .refused }),
           !finished.contains(where: { $0.outcome == .reachable }) { return .unavailable }
        return .inconclusive
    }

    var summary: String {
        switch verdict {
        case .reachable: return toolboxText("大陆三网已测节点均可连接目标端口。", "All tested mainland carrier probes connected to the target port.")
        case .partial: return toolboxText("部分大陆节点可达；其余线路需分别核对。", "Some mainland probes connected; review the other routes individually.")
        case .suspectedRestriction: return toolboxText("多条大陆线路疑似受限：境外目标与同探针对照正常。这不是确认封锁。", "Possible mainland route restriction: foreign target checks and same-probe references succeeded. Blocking is not confirmed.")
        case .unavailable: return toolboxText("大陆与境外均未连接成功；请检查端口、服务和防火墙，无法据此判断 GFW。", "Neither mainland nor foreign checks connected. Check the port, service and firewall; this does not identify GFW blocking.")
        case .inconclusive:
            if issues.contains(.rateLimited) { return toolboxText("Globalping 已限流，请稍后手动重试；没有封锁结论。", "Globalping rate limit reached. Retry manually later; no blocking conclusion.") }
            if issues.contains(.noProbes) { return toolboxText("部分地区缺少可用探针，证据不足。", "Some locations have no available probes; evidence is insufficient.") }
            if issues.contains(.serviceUnavailable) || issues.contains(.invalidResponse) { return toolboxText("探测服务或结果暂不可用，无法判断大陆可达性。", "The measurement service or response is unavailable; mainland reachability is unknown.") }
            return toolboxText("仅观测到超时或不完整结果，证据不足，不能判定封锁。", "Timeouts or incomplete results alone are insufficient to identify blocking.")
        }
    }
}

/// Globalping's public API. Schema: https://api.globalping.io/v1/spec.yaml
/// No credentials, proxy configuration or harness/session data are submitted.
enum MainlandReachabilityService {
    static let root = URL(string: "https://api.globalping.io/v1/measurements")!
    private static func integerOption(_ options: [String: Any], _ key: String, default value: Int) -> Int? {
        guard let supplied = options[key] else { return value }
        return supplied as? Int
    }
    static func referenceTarget(for target: MainlandReachabilityTarget) -> MainlandReachabilityTarget {
        let primary = target.ipVersion == 6 ? "2606:4700:4700::1111" : "1.1.1.1"
        let secondary = target.ipVersion == 6 ? "2606:4700:4700::1001" : "1.0.0.1"
        return .init(ip: target.ip == primary ? secondary : primary, port: 443)
    }
    struct Batch: Sendable {
        var id: String? = nil
        var observations: [MainlandProbeObservation] = []
        var issues: [GlobalpingIssue] = []
    }

    static func request(target: MainlandReachabilityTarget, mainland: Bool, reuse: String? = nil) -> URLRequest {
        let locations: Any = reuse.map { $0 as Any } ?? (mainland
            ? [4134, 4837, 9808].map { ["country": "CN", "asn": $0, "limit": 2] as [String: Any] }
            : ["US", "SG"].map { ["country": $0, "limit": 1] as [String: Any] })
        let payload: [String: Any] = ["type": "ping", "target": target.ip, "locations": locations,
            // Literal targets determine the address family; Globalping only
            // permits an explicit ipVersion option for hostname targets.
            "timeout": 10, "measurementOptions": ["protocol": "TCP", "port": target.port, "packets": 3]]
        var request = URLRequest(url: root)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static func run(target: MainlandReachabilityTarget, fetcher: NetworkDiagnosticFetcher) async -> MainlandReachabilityReport {
        await withTaskGroup(of: MainlandReachabilityReport?.self) { group in
            group.addTask { await perform(target: target, fetcher: fetcher) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 40000000000)
                return nil
            }
            let report = await group.next() ?? nil
            fetcher.cancel()
            group.cancelAll()
            return report ?? .init(target: target, issues: [.timedOut])
        }
    }

    private static func perform(target: MainlandReachabilityTarget, fetcher: NetworkDiagnosticFetcher) async -> MainlandReachabilityReport {
        async let foreign = measure(target: target, mainland: false, fetcher: fetcher)
        var china = await measure(target: target, mainland: true, fetcher: fetcher)
        var reference = Batch()
        if !Task.isCancelled, let id = china.id, china.observations.contains(where: { $0.outcome == .noResponse }) {
            reference = await measure(target: referenceTarget(for: target), mainland: true, reuse: id, fetcher: fetcher)
            for index in china.observations.indices {
                let original = china.observations[index]
                if let match = reference.observations.first(where: { $0.index == original.index && $0.locationKey == original.locationKey }) {
                    china.observations[index].referenceReachable = match.outcome == .unavailable ? nil : match.outcome == .reachable
                }
            }
        }
        let controls = await foreign
        return .init(target: target, observations: china.observations + controls.observations,
            measurementIDs: [china.id, controls.id, reference.id].compactMap { $0 }, issues: china.issues + controls.issues + reference.issues)
    }

    static func measure(target: MainlandReachabilityTarget, mainland: Bool, reuse: String? = nil,
                        fetcher: NetworkDiagnosticFetcher) async -> Batch {
        guard !Task.isCancelled else { return .init(issues: [.timedOut]) }
        let created = await fetcher.fetch(request(target: target, mainland: mainland, reuse: reuse))
        guard created.status != 429 else { return .init(issues: [.rateLimited]) }
        guard [200, 201, 202].contains(created.status ?? 0), !created.limited,
              let data = NetworkDiagnosticParser.json(created.data), let id = data["id"] as? String,
              id.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil,
              let count = data["probesCount"] as? Int, (1...8).contains(count) else {
            return .init(issues: [created.status == 422 ? .noProbes : .serviceUnavailable])
        }
        var poll = URLRequest(url: root.appendingPathComponent(id))
        poll.setValue("application/json", forHTTPHeaderField: "Accept")
        while !Task.isCancelled {
            let reply = await fetcher.fetch(poll)
            guard reply.status != 429 else { return .init(id: id, issues: [.rateLimited]) }
            guard reply.status == 200, !reply.limited,
                  let body = NetworkDiagnosticParser.json(reply.data), body["id"] as? String == id,
                  body["type"] as? String == "ping", NetworkDiagnosticParser.address(body["target"] as? String) == target.ip,
                  let options = body["measurementOptions"] as? [String: Any], options["protocol"] as? String == "TCP",
                  // The API omits defaults in GET responses (port 80, 3 packets).
                  integerOption(options, "port", default: 80) == target.port,
                  integerOption(options, "packets", default: 3) == 3,
                  let status = body["status"] as? String, ["in-progress", "finished"].contains(status) else {
                return .init(id: id, issues: [.invalidResponse])
            }
            if status == "finished" {
                guard body["probesCount"] as? Int == count, let results = body["results"] as? [[String: Any]], results.count == count else { return .init(id: id, issues: [.invalidResponse]) }
                let rows = results.enumerated().map { observation($0.element, index: $0.offset, id: id, target: target, mainland: mainland) }
                return .init(id: id, observations: rows)
            }
            do { try await Task.sleep(nanoseconds: 1000000000) } catch { break }
        }
        return .init(id: id, issues: [.timedOut])
    }

    static func observation(_ item: [String: Any], index: Int, id: String,
                            target: MainlandReachabilityTarget, mainland: Bool) -> MainlandProbeObservation {
        let probe = item["probe"] as? [String: Any] ?? [:]
        let result = item["result"] as? [String: Any] ?? [:]
        let country = NetworkDiagnosticParser.country(probe["country"] as? String) ?? ""
        let asn = probe["asn"] as? Int ?? 0
        let city = String((probe["city"] as? String ?? "").prefix(80))
        let network = String((probe["network"] as? String ?? "").prefix(120))
        let belongs = mainland ? country == "CN" && [4134, 4837, 9808].contains(asn) : ["US", "SG"].contains(country)
        var outcome = MainlandProbeOutcome.unavailable
        var average: Double?
        if belongs, NetworkDiagnosticParser.address(result["resolvedAddress"] as? String) == target.ip,
           result["status"] as? String == "finished", let stats = result["stats"] as? [String: Any],
           let total = stats["total"] as? Int, total == 3, let received = stats["rcv"] as? Int,
           (0...total).contains(received), let dropped = stats["drop"] as? Int, received + dropped == total {
            if received > 0, let avg = stats["avg"] as? Double, avg.isFinite, avg >= 0 {
                outcome = .reachable; average = avg
            } else if received == 0 { outcome = .noResponse }
        }
        let output = String((result["rawOutput"] as? String ?? "").prefix(4096)).lowercased()
        if belongs, output.contains("connection refused") || output.contains("econnrefused") { outcome = .refused; average = nil }
        return .init(id: id + "-\(index)", index: index, country: country, city: city, asn: asn,
            network: network, outcome: outcome, milliseconds: average)
    }
}

@MainActor final class MainlandReachabilityModel: ObservableObject {
    @Published var targetIP = ""
    @Published var targetPort = "443"
    @Published private(set) var running = false
    @Published private(set) var report: MainlandReachabilityReport?
    @Published private(set) var inputError = ""
    private var task: Task<Void, Never>?
    private var fetcher: NetworkDiagnosticFetcher?
    private var runID: UUID?

    func start() {
        guard !running else { return }
        guard let target = MainlandReachabilityTarget.parse(ip: targetIP, port: targetPort) else {
            inputError = toolboxText("请输入公网 IPv4 / IPv6，以及 1–65535 的服务端口。", "Enter a public IPv4 / IPv6 address and a service port from 1 to 65535.")
            return
        }
        inputError = ""; report = nil; running = true
        let id = UUID(); runID = id
        let transport = NetworkDiagnosticFetcher(); fetcher = transport
        task = Task { [weak self] in
            let result = await MainlandReachabilityService.run(target: target, fetcher: transport)
            guard !Task.isCancelled, let self, self.runID == id else { return }
            self.report = result; self.running = false; self.fetcher = nil; self.task = nil; self.runID = nil
        }
    }

    func stop() {
        task?.cancel(); task = nil
        fetcher?.cancel(); fetcher = nil
        runID = nil; running = false
    }
}
#endif
