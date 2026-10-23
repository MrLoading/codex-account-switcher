import Foundation

/// Experimental global-reset probabilities from codex-reset.com.
public struct TiboResetForecast: Equatable, Sendable {
    public let updatedAt: Date
    public let next24HourPercent: Int
    public let next48HourPercent: Int
}

public enum TiboResetForecastReader {
    public enum DataError: Error {
        case invalidResponse
        case staleResponse
    }

    public static func read(forecast: Data, now: Date = Date()) throws -> TiboResetForecast {
        let forecast = try JSONDecoder().decode(ForecastWire.self, from: forecast)
        guard let updatedAt = date(forecast.updatedAt),
              (0...100).contains(forecast.probabilities.rounded24h),
              (0...100).contains(forecast.probabilities.rounded48h),
              forecast.probabilities.rounded48h >= forecast.probabilities.rounded24h
        else { throw DataError.invalidResponse }

        guard updatedAt.timeIntervalSince(now) <= 300,
              now.timeIntervalSince(updatedAt) <= 7_200
        else { throw DataError.staleResponse }

        return TiboResetForecast(
            updatedAt: updatedAt,
            next24HourPercent: forecast.probabilities.rounded24h,
            next48HourPercent: forecast.probabilities.rounded48h
        )
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private struct ForecastWire: Decodable {
        let updatedAt: String
        let probabilities: Probabilities

        enum CodingKeys: String, CodingKey {
            case updatedAt = "updated_at"
            case probabilities
        }

        struct Probabilities: Decodable {
            let rounded24h: Int
            let rounded48h: Int

            enum CodingKeys: String, CodingKey {
                case rounded24h = "rounded_24h"
                case rounded48h = "rounded_48h"
            }
        }
    }
}
