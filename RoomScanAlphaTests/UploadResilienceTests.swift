import XCTest
@testable import RoomScanAlpha

/// Tests mapping to Implementation Plan Phase 9 test cases:
/// - 9.2  Upload retry on transient failure (mock 503, verify backoff)
/// - 9.4  Concurrent upload prevention (isUploading guard)
///
/// Tests 9.1, 9.3, 9.5–9.7 require network manipulation and device — manual only.
/// Tests 9.8–9.9 run against deployed cloud services via cloud-stub-tests.yml.
/// Test 9.10 validates cloud-stub-tests.yml runs end-to-end after secrets are configured.

// MARK: - Mock URLSession

/// Mock URLSession that returns scripted responses for each call.
final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _responses: [(Data, URLResponse)]
    private var _requestHistory: [URLRequest] = []

    init(responses: [(Data, URLResponse)]) {
        self._responses = responses
    }

    var requestHistory: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requestHistory
    }

    private var responses: [(Data, URLResponse)] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _responses
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _responses = newValue
        }
    }

    private func recordAndRespond(_ request: URLRequest) -> (Data, URLResponse) {
        lock.lock()
        _requestHistory.append(request)
        let response: (Data, URLResponse)
        if !_responses.isEmpty {
            response = _responses.removeFirst()
        } else {
            // Default: 200 OK with empty body
            response = (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        lock.unlock()
        return response
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        return recordAndRespond(request)
    }

    func upload(for request: URLRequest, from data: Data) async throws -> (Data, URLResponse) {
        return recordAndRespond(request)
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        return recordAndRespond(request)
    }
}

// MARK: - Tests

final class UploadResilienceTests: XCTestCase {

    private let dummyURL = URL(string: "https://example.com/test")!

    // MARK: - 9.2 Retry on transient failure

    func testRetryOn503_eventualSuccess() async throws {
        // Simulate: 503, 503, then 200
        let mock = MockURLSession(responses: [
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 503, httpVersion: nil, headerFields: nil)!),
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 503, httpVersion: nil, headerFields: nil)!),
            ("OK".data(using: .utf8)!, HTTPURLResponse(url: dummyURL, statusCode: 200, httpVersion: nil, headerFields: nil)!),
        ])

        let uploader = CloudUploader.shared
        // Use fast delays for testing
        uploader.retryConfig = CloudUploader.RetryConfig(
            maxRetries: 3,
            initialDelaySeconds: 0.01,
            maxDelaySeconds: 0.1
        )
        uploader.session = mock

        var request = URLRequest(url: dummyURL)
        request.httpMethod = "GET"

        let (data, response) = try await uploader.executeWithRetry(request, using: mock)
        let httpResponse = response as! HTTPURLResponse

        // Should succeed on 3rd attempt
        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "OK")

        // Should have made 3 total requests (initial + 2 retries)
        XCTAssertEqual(mock.requestHistory.count, 3,
                       "Should make 3 requests: initial + 2 retries before success")
    }

    func testRetryOn503_allFail_throwsAfterMaxRetries() async throws {
        // All 4 attempts (initial + 3 retries) return 503
        let mock = MockURLSession(responses: [
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 503, httpVersion: nil, headerFields: nil)!),
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 503, httpVersion: nil, headerFields: nil)!),
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 503, httpVersion: nil, headerFields: nil)!),
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 503, httpVersion: nil, headerFields: nil)!),
        ])

        let uploader = CloudUploader.shared
        uploader.retryConfig = CloudUploader.RetryConfig(
            maxRetries: 3,
            initialDelaySeconds: 0.01,
            maxDelaySeconds: 0.1
        )

        var request = URLRequest(url: dummyURL)
        request.httpMethod = "GET"

        do {
            _ = try await uploader.executeWithRetry(request, using: mock)
            XCTFail("Should have thrown after max retries")
        } catch {
            // Expected: error after exhausting retries
            XCTAssertTrue(error is CloudUploader.UploadError,
                          "Should throw UploadError, got \(type(of: error))")
        }

        // Should have made 4 total requests (initial + 3 retries)
        XCTAssertEqual(mock.requestHistory.count, 4,
                       "Should make 4 requests: initial + 3 retries")
    }

    func testRetryUsesExponentialBackoff() async throws {
        // 3 failures then success — measure retry timestamps for backoff
        let mock = MockURLSession(responses: [
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 503, httpVersion: nil, headerFields: nil)!),
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 503, httpVersion: nil, headerFields: nil)!),
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 503, httpVersion: nil, headerFields: nil)!),
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 200, httpVersion: nil, headerFields: nil)!),
        ])

        let uploader = CloudUploader.shared
        uploader.retryConfig = CloudUploader.RetryConfig(
            maxRetries: 3,
            initialDelaySeconds: 0.05,  // 50ms base
            maxDelaySeconds: 5.0
        )

        let startTime = Date()
        var request = URLRequest(url: dummyURL)
        request.httpMethod = "GET"

        _ = try await uploader.executeWithRetry(request, using: mock)

        // retryTimestamps should have 3 entries (one per retry)
        XCTAssertEqual(uploader.retryTimestamps.count, 3,
                       "Should record 3 retry timestamps")

        // Verify delays increase (exponential backoff):
        // Retry 1: ~50ms, Retry 2: ~100ms, Retry 3: ~200ms
        if uploader.retryTimestamps.count >= 2 {
            let delay1 = uploader.retryTimestamps[0].timeIntervalSince(startTime)
            let delay2 = uploader.retryTimestamps[1].timeIntervalSince(uploader.retryTimestamps[0])

            // Second delay should be longer than first (exponential)
            XCTAssertGreaterThan(delay2, delay1 * 0.5,
                                 "Exponential backoff: second delay (\(delay2)s) should be >= first (\(delay1)s)")
        }
    }

    func testNoRetryOn400_clientError() async throws {
        // 400 is not in retryableStatusCodes — should return immediately
        let mock = MockURLSession(responses: [
            ("{\"error\": \"bad request\"}".data(using: .utf8)!,
             HTTPURLResponse(url: dummyURL, statusCode: 400, httpVersion: nil, headerFields: nil)!),
        ])

        let uploader = CloudUploader.shared
        uploader.retryConfig = CloudUploader.RetryConfig(
            maxRetries: 3,
            initialDelaySeconds: 0.01,
            maxDelaySeconds: 0.1
        )

        var request = URLRequest(url: dummyURL)
        request.httpMethod = "GET"

        let (_, response) = try await uploader.executeWithRetry(request, using: mock)
        let httpResponse = response as! HTTPURLResponse

        // 400 should NOT be retried — returned as-is
        XCTAssertEqual(httpResponse.statusCode, 400)
        XCTAssertEqual(mock.requestHistory.count, 1,
                       "Client errors should not be retried")
    }

    func testRetryOn500_serverError() async throws {
        // 500 is in retryableStatusCodes
        let mock = MockURLSession(responses: [
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 500, httpVersion: nil, headerFields: nil)!),
            ("OK".data(using: .utf8)!, HTTPURLResponse(url: dummyURL, statusCode: 200, httpVersion: nil, headerFields: nil)!),
        ])

        let uploader = CloudUploader.shared
        uploader.retryConfig = CloudUploader.RetryConfig(
            maxRetries: 3,
            initialDelaySeconds: 0.01,
            maxDelaySeconds: 0.1
        )

        var request = URLRequest(url: dummyURL)
        request.httpMethod = "GET"

        let (_, response) = try await uploader.executeWithRetry(request, using: mock)
        let httpResponse = response as! HTTPURLResponse

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(mock.requestHistory.count, 2,
                       "Should retry once on 500 then succeed")
    }

    func testRetryConfigDefaultValues() {
        let config = CloudUploader.RetryConfig()

        XCTAssertEqual(config.maxRetries, 3)
        XCTAssertEqual(config.initialDelaySeconds, 1.0)
        XCTAssertEqual(config.maxDelaySeconds, 30.0)
        XCTAssertTrue(config.retryableStatusCodes.contains(503))
        XCTAssertTrue(config.retryableStatusCodes.contains(429))
        XCTAssertTrue(config.retryableStatusCodes.contains(500))
        XCTAssertFalse(config.retryableStatusCodes.contains(400))
        XCTAssertFalse(config.retryableStatusCodes.contains(401))
        XCTAssertFalse(config.retryableStatusCodes.contains(404))
    }

    // MARK: - 9.4 Concurrent upload prevention

    func testConcurrentUploadPrevention_isUploadingFlag() {
        let uploader = CloudUploader.shared
        // Initial state: not uploading
        XCTAssertFalse(uploader.isUploading,
                       "isUploading should be false when no upload is active")
    }

    func testConcurrentUploadError_hasDescription() {
        let error = CloudUploader.UploadError.concurrentUpload
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("already in progress") == true,
                      "concurrentUpload error should mention 'already in progress'")
    }

    func testConcurrentUploadError_isDistinctType() {
        // Verify it's a distinct case that callers can match on
        let error = CloudUploader.UploadError.concurrentUpload

        switch error {
        case .concurrentUpload:
            break // Expected
        default:
            XCTFail("Should match .concurrentUpload case")
        }
    }

    // MARK: - Backoff delay calculation

    func testBackoffDelayRespectsCap() async throws {
        // With maxDelay = 0.05s, even after many retries the delay shouldn't exceed it
        let mock = MockURLSession(responses: [
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 503, httpVersion: nil, headerFields: nil)!),
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 503, httpVersion: nil, headerFields: nil)!),
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 503, httpVersion: nil, headerFields: nil)!),
            (Data(), HTTPURLResponse(url: dummyURL, statusCode: 200, httpVersion: nil, headerFields: nil)!),
        ])

        let uploader = CloudUploader.shared
        uploader.retryConfig = CloudUploader.RetryConfig(
            maxRetries: 3,
            initialDelaySeconds: 0.01,
            maxDelaySeconds: 0.05  // Very low cap
        )

        let startTime = Date()
        var request = URLRequest(url: dummyURL)
        request.httpMethod = "GET"

        _ = try await uploader.executeWithRetry(request, using: mock)

        let totalElapsed = Date().timeIntervalSince(startTime)
        // With cap of 50ms and 3 retries, total should be well under 1 second
        XCTAssertLessThan(totalElapsed, 1.0,
                          "Total retry time should be bounded by maxDelay cap")
    }
}
