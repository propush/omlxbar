import Foundation

/// One canned HTTP answer.
struct StubReply {
    var status = 200
    var contentType: String? = "application/json"
    var body: Data = Data("{}".utf8)
    /// Simulated latency, used to provoke the ordering and concurrency races
    /// these tests exist to pin down.
    var delay: TimeInterval = 0

    static func json(_ raw: String, status: Int = 200) -> StubReply {
        StubReply(status: status, body: Data(raw.utf8))
    }

    static func html(_ raw: String) -> StubReply {
        StubReply(status: 200, contentType: "text/html; charset=utf-8", body: Data(raw.utf8))
    }
}

/// A `URLProtocol` that answers from a closure, and records what was asked.
///
/// Records peak concurrency as well as the request log, because "how many at
/// once" is itself one of the properties under test.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> StubReply)?
    nonisolated(unsafe) private static var requestLog: [String] = []
    nonisolated(unsafe) private static var inFlight = 0
    nonisolated(unsafe) private static var peak = 0

    /// A session wired to this stub. Timeouts mirror the real client's.
    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 4
        return URLSession(configuration: cfg)
    }

    static func install(_ handler: @escaping (URLRequest) -> StubReply) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        requestLog = []
        inFlight = 0
        peak = 0
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        requestLog = []
        inFlight = 0
        peak = 0
    }

    /// Every path+query asked for, in the order the requests started.
    static var log: [String] {
        lock.lock(); defer { lock.unlock() }
        return requestLog
    }

    static var peakConcurrency: Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    static func paths(containing needle: String) -> [String] {
        log.filter { $0.contains(needle) }
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let path = (request.url?.path ?? "") + (request.url?.query.map { "?\($0)" } ?? "")

        Self.lock.lock()
        Self.requestLog.append(path)
        Self.inFlight += 1
        Self.peak = max(Self.peak, Self.inFlight)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler, let url = request.url else {
            finish(with: .init(status: 500, contentType: nil, body: Data()), url: request.url)
            return
        }
        let reply = handler(request)
        let deliver: @Sendable () -> Void = { [weak self] in self?.finish(with: reply, url: url) }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver)
        } else {
            DispatchQueue.global().async(execute: deliver)
        }
    }

    override func stopLoading() {}

    private func finish(with reply: StubReply, url: URL?) {
        Self.lock.lock()
        Self.inFlight -= 1
        Self.lock.unlock()

        guard let url else { return }
        var headers: [String: String] = [:]
        if let type = reply.contentType { headers["Content-Type"] = type }
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Payload builders

enum Payload {
    /// A well-formed `/admin/api/activity` body.
    static func activity(models: [String] = [], activeRequests: Int = 0) -> String {
        let entries = models.map { #"{"id":"\#($0)","is_loading":false}"# }.joined(separator: ",")
        return """
        {"active_models":{"models":[\(entries)],"total_active_requests":\(activeRequests),
         "total_waiting_requests":0,"model_memory_used":0,"model_memory_max":0}}
        """
    }

    static func stats(requests: Int) -> String {
        #"{"total_requests":\#(requests),"total_tokens_served":\#(requests * 10)}"#
    }

    static func models(_ ids: [String]) -> String {
        let entries = ids.map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
        return #"{"models":[\#(entries)]}"#
    }
}
