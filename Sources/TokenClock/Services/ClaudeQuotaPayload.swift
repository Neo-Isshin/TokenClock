import Foundation
enum ClaudeQuotaPayloadError: Error { case malformed }
enum ClaudeQuotaPayload {
    static func decode(_ data: Data) throws -> ClaudeQuotaSnapshot {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeQuotaPayloadError.malformed }
        if let declared = root["limits"], !(declared is NSNull) {
            guard let limits = declared as? [[String: Any]] else { throw ClaudeQuotaPayloadError.malformed }
            var mapped: [String: Any] = [:]
            for limit in limits {
                let unscoped = limit["scope"] == nil || limit["scope"] is NSNull
                    || ((limit["scope"] as? [String: Any]).map { $0.values.allSatisfy { $0 is NSNull } } ?? false)
                guard unscoped, let kind = limit["kind"] as? String,
                      let value = limit["percent"] as? NSNumber, !JSONNumber.isBoolean(value),
                      value.doubleValue.isFinite, (0...100).contains(value.doubleValue) else { continue }
                let key: String
                if kind == "session" { key = "five_hour" }
                else if kind == "weekly_all" { key = "seven_day" }
                else { continue }
                var bucket: [String: Any] = ["utilization":value]
                if let reset = limit["resets_at"] as? String { bucket["resets_at"] = reset }
                if let existing = mapped[key] as? NSDictionary, !existing.isEqual(to: bucket) { throw ClaudeQuotaPayloadError.malformed }
                mapped[key] = bucket
            }
            root = mapped // The declared windows are authoritative; never mix old/new periods.
        }
        for key in ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps", "seven_day_overage_included"] {
            guard let bucket = root[key] as? [String: Any] else { root.removeValue(forKey: key); continue }
            guard let used = bucket["utilization"] as? NSNumber, !JSONNumber.isBoolean(used),
                  used.doubleValue.isFinite, (0...100).contains(used.doubleValue) else {
                root.removeValue(forKey: key); continue
            }
        }
        guard let snapshot = ClaudeQuotaService.decodeUsageResponse(try JSONSerialization.data(withJSONObject: root)) else {
            throw ClaudeQuotaPayloadError.malformed
        }
        return snapshot
    }
}
