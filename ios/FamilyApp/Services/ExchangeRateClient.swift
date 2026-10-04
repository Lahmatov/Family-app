import FamilyCore
import Foundation

/// Fetches the ECB reference rate to prefill the form; the person can always type another rate.
/// Any failure (offline, unsupported currency, unexpected answer) just means "no suggestion".
enum ExchangeRateClient {
    static func referenceRate(from: CurrencyCode, to: CurrencyCode, on day: LocalDate) async -> ReferenceRate? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing") { return nil }   // UI tests stay offline
        #endif
        guard let url = ExchangeRates.url(from: from, to: to, on: day, today: LocalDate(Date())) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.cachePolicy = .returnCacheDataElseLoad   // a past day's rate never changes
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return ExchangeRates.parse(data, to: to)
    }
}
