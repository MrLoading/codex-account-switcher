import Foundation
import Testing
@testable import SwitcherCore

struct TiboResetForecastTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-23T07:05:25Z")!

    private func payload(updatedAt: String = "2026-10-23T07:05:25.544Z", h24: Int = 32, h48: Int = 53) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "updated_at": updatedAt,
            "probabilities": ["rounded_24h": h24, "rounded_48h": h48],
        ])
    }

    @Test func readsOnlyTheDisplayedProbabilities() throws {
        let result = try TiboResetForecastReader.read(forecast: payload(), now: now)
        #expect(result.next24HourPercent == 32)
        #expect(result.next48HourPercent == 53)
    }

    @Test func unrelatedResetMetadataDoesNotBlockProbabilities() throws {
        var object = try JSONSerialization.jsonObject(with: payload()) as! [String: Any]
        object["last_reset_at"] = "2026-10-22T17:10:01.000Z"
        object["time_window"] = NSNull()
        let result = try TiboResetForecastReader.read(
            forecast: JSONSerialization.data(withJSONObject: object), now: now
        )
        #expect(result.next24HourPercent == 32)
        #expect(result.next48HourPercent == 53)
    }

    @Test(arguments: ["2026-10-23T04:05:25Z", "2026-10-23T07:11:25Z"])
    func rejectsStaleAndFutureData(updatedAt: String) throws {
        let data = try payload(updatedAt: updatedAt)
        #expect(throws: TiboResetForecastReader.DataError.staleResponse) {
            try TiboResetForecastReader.read(forecast: data, now: now)
        }
    }

    @Test(arguments: [(-1, 53), (32, 101), (54, 53)])
    func rejectsInvalidProbabilities(h24: Int, h48: Int) throws {
        let data = try payload(h24: h24, h48: h48)
        #expect(throws: TiboResetForecastReader.DataError.invalidResponse) {
            try TiboResetForecastReader.read(forecast: data, now: now)
        }
    }

    @Test func missingProbabilityPreservesTheDecodingFailure() {
        let data = Data(#"{"updated_at":"2026-10-23T07:05:25Z","probabilities":{"rounded_24h":32}}"#.utf8)
        #expect(throws: DecodingError.self) {
            try TiboResetForecastReader.read(forecast: data, now: now)
        }
    }
}
