import Foundation

/// Rate-limited logging for the failures that would otherwise be invisible.
///
/// A menubar app has nowhere to show a stack trace, so a wrong dot used to be
/// indistinguishable from a right one. These lines are the only way to tell a
/// renamed API field from a genuinely idle server after the fact.
///
/// Nothing here ever logs the API key, a request body, or a response body:
/// endpoint, status and decoding context are enough to diagnose contract drift
/// and none of them are secret.
@MainActor
enum Diagnostics {
    /// One line per endpoint per minute. A wedged server polls every 750 ms;
    /// without this the log would be useless and enormous.
    private static let interval: TimeInterval = 60
    private static var lastLogged: [String: Date] = [:]

    static func log(endpoint: String, _ message: String) {
        let now = Date()
        if let last = lastLogged[endpoint], now.timeIntervalSince(last) < interval { return }
        lastLogged[endpoint] = now
        NSLog("omlxbar: %@ — %@", endpoint, message)
    }

    /// Describes a decoding failure precisely enough to name the field that
    /// moved, which is the whole point of noticing contract drift.
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else {
            return (error as NSError).localizedDescription
        }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue)
            return keys.isEmpty ? "<root>" : keys.joined(separator: ".")
        }
        switch error {
        case let .keyNotFound(key, context):
            return "missing field \"\(key.stringValue)\" at \(path(context))"
        case let .typeMismatch(type, context):
            return "expected \(type) at \(path(context))"
        case let .valueNotFound(type, context):
            return "null where \(type) was required at \(path(context))"
        case let .dataCorrupted(context):
            return "malformed JSON at \(path(context))"
        @unknown default:
            return "undecodable response"
        }
    }

    /// Test seam: forget the rate-limit window.
    static func reset() { lastLogged.removeAll() }
}
