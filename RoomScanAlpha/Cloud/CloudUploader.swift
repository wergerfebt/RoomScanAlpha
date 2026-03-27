import Foundation
import Network

// MARK: - URLSession Protocol for testability

/// Protocol abstracting URLSession so tests can inject mock network responses.
protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func upload(for request: URLRequest, from data: Data) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

final class CloudUploader {
    static let shared = CloudUploader()

    private let apiBaseURL = "https://scan-api-839349778883.us-central1.run.app"

    /// Injected session for testability. Defaults to URLSession.shared.
    var session: URLSessionProtocol = URLSession.shared

    /// Whether an upload is currently in progress. Prevents concurrent uploads (9.4).
    private(set) var isUploading = false

    // MARK: - Retry Configuration

    struct RetryConfig {
        var maxRetries: Int = 3
        var initialDelaySeconds: TimeInterval = 1.0
        var maxDelaySeconds: TimeInterval = 30.0
        var retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    }

    var retryConfig = RetryConfig()

    /// Timestamps of retry attempts — exposed for test assertions.
    private(set) var retryTimestamps: [Date] = []

    private init() {}

    /// Check current network path — returns (isConnected, isCellular).
    func checkNetwork() -> (connected: Bool, cellular: Bool) {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Bool, Bool) = (false, false)

        monitor.pathUpdateHandler = { path in
            result = (path.status == .satisfied, path.usesInterfaceType(.cellular))
            semaphore.signal()
        }
        monitor.start(queue: DispatchQueue(label: "network-check"))
        _ = semaphore.wait(timeout: .now() + 3)
        monitor.cancel()
        return result
    }

    struct UploadResult {
        let scanId: String
        let status: String
    }

    struct ScanResult {
        let scanId: String
        let status: String
        let floorAreaSqft: Double?
        let wallAreaSqft: Double?
        let ceilingHeightFt: Double?
        let perimeterLinearFt: Double?
        let detectedComponents: [String]?
        let scanDimensions: [String: Double]?
    }

    /// Full upload flow: zip → sign → upload → complete.
    /// Calls onProgress with (step description, fraction 0.0–1.0).
    /// Throws `UploadError.concurrentUpload` if another upload is already in progress (9.4).
    func upload(
        scanDirectoryURL: URL,
        rfqId: String,
        onProgress: @escaping (String, Double) -> Void
    ) async throws -> UploadResult {
        // 9.4: Prevent concurrent uploads
        guard !isUploading else {
            throw UploadError.concurrentUpload
        }
        isUploading = true
        defer { isUploading = false }

        // 1. Sign in if needed
        onProgress("Authenticating...", 0.0)
        _ = try await AuthManager.shared.signInAnonymously()
        let token = try await AuthManager.shared.getToken()

        // 2. Zip the scan directory
        onProgress("Compressing scan...", 0.05)
        let zipURL = try zipDirectory(scanDirectoryURL)
        let zipSize = try FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int ?? 0
        print("[RoomScanAlpha] Zip created: \(zipSize / 1024 / 1024)MB at \(zipURL.path)")

        // 3. Get signed URL (with retry)
        onProgress("Requesting upload URL...", 0.10)
        let (signedURL, scanId) = try await getSignedURL(token: token, rfqId: rfqId)
        print("[RoomScanAlpha] Got signed URL for scan \(scanId)")

        // 4. Upload zip to GCS (with retry)
        onProgress("Uploading scan...", 0.15)
        try await uploadToGCS(fileURL: zipURL, signedURL: signedURL) { fraction in
            // Map upload progress to 0.15–0.90 range
            let mapped = 0.15 + fraction * 0.75
            onProgress("Uploading scan...", mapped)
        }
        print("[RoomScanAlpha] Upload complete for scan \(scanId)")

        // 5. Notify backend (with retry)
        onProgress("Finalizing...", 0.95)
        let status = try await notifyComplete(scanId: scanId, token: token, rfqId: rfqId)
        print("[RoomScanAlpha] Backend notified: \(status)")

        // 6. Persist scan ID
        persistScanId(scanId)

        onProgress("Upload complete", 1.0)

        // Clean up zip
        try? FileManager.default.removeItem(at: zipURL)

        return UploadResult(scanId: scanId, status: status)
    }

    // MARK: - Retry with Exponential Backoff (9.2)

    /// Execute an HTTP request with retry and exponential backoff for transient failures.
    func executeWithRetry(
        _ request: URLRequest,
        using networkSession: URLSessionProtocol? = nil
    ) async throws -> (Data, URLResponse) {
        let sess = networkSession ?? session
        retryTimestamps = []
        var lastError: Error?

        for attempt in 0...retryConfig.maxRetries {
            if attempt > 0 {
                let delay = min(
                    retryConfig.initialDelaySeconds * pow(2.0, Double(attempt - 1)),
                    retryConfig.maxDelaySeconds
                )
                retryTimestamps.append(Date())
                print("[RoomScanAlpha] Retry \(attempt)/\(retryConfig.maxRetries) after \(delay)s")
                try await Task.sleep(for: .seconds(delay))
            }

            do {
                let (data, response) = try await sess.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   retryConfig.retryableStatusCodes.contains(httpResponse.statusCode) {
                    lastError = UploadError.apiError("HTTP \(httpResponse.statusCode)")
                    continue
                }
                return (data, response)
            } catch let error as UploadError {
                throw error // Don't retry our own errors
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? UploadError.apiError("Request failed after \(retryConfig.maxRetries) retries")
    }

    // MARK: - Private

    func zipDirectory(_ directoryURL: URL) throws -> URL {
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan_upload_\(Int(Date().timeIntervalSince1970)).zip")

        let coordinator = NSFileCoordinator()
        var error: NSError?
        var resultURL: URL?

        coordinator.coordinate(readingItemAt: directoryURL, options: .forUploading, error: &error) { tempURL in
            do {
                try FileManager.default.copyItem(at: tempURL, to: zipURL)
                resultURL = zipURL
            } catch {
                print("[RoomScanAlpha] Zip copy error: \(error)")
            }
        }

        if let error { throw error }
        guard let result = resultURL else {
            throw UploadError.zipFailed
        }
        return result
    }

    private func getSignedURL(token: String, rfqId: String) async throws -> (URL, String) {
        let url = URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/scans/upload-url")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await executeWithRetry(request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UploadError.apiError("Failed to get signed URL (HTTP \(statusCode)): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let signedURLString = json?["signed_url"] as? String,
              let signedURL = URL(string: signedURLString),
              let scanId = json?["scan_id"] as? String else {
            throw UploadError.apiError("Invalid signed URL response")
        }

        return (signedURL, scanId)
    }

    private func uploadToGCS(
        fileURL: URL,
        signedURL: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let fileData = try Data(contentsOf: fileURL)
        let totalBytes = fileData.count

        var request = URLRequest(url: signedURL)
        request.httpMethod = "PUT"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate(totalBytes: totalBytes, onProgress: onProgress)
        let uploadSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        let (_, response) = try await uploadSession.upload(for: request, from: fileData)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UploadError.uploadFailed("GCS upload failed with HTTP \(statusCode)")
        }
    }

    private func notifyComplete(scanId: String, token: String, rfqId: String) async throws -> String {
        let url = URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/scans/complete")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = try JSONSerialization.data(withJSONObject: ["scan_id": scanId])
        request.httpBody = body

        let (data, response) = try await executeWithRetry(request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let respBody = String(data: data, encoding: .utf8) ?? ""
            throw UploadError.apiError("Upload complete notification failed (HTTP \(statusCode)): \(respBody)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["status"] as? String ?? "unknown"
    }

    func persistScanId(_ scanId: String) {
        var scanIds = UserDefaults.standard.stringArray(forKey: "completedScanIds") ?? []
        scanIds.append(scanId)
        UserDefaults.standard.set(scanIds, forKey: "completedScanIds")
        print("[RoomScanAlpha] Persisted scan ID: \(scanId)")
    }

    /// Poll the status endpoint until scan_ready or failed. Returns structured room data.
    func pollForResult(scanId: String, rfqId: String, intervalSeconds: TimeInterval = 5.0) async throws -> ScanResult {
        let token = try await AuthManager.shared.getToken()
        let url = URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/scans/\(scanId)/status")!

        while true {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw UploadError.apiError("Status poll failed (HTTP \(statusCode))")
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let status = json["status"] as? String ?? "unknown"

            print("[RoomScanAlpha] Poll status: \(status)")

            if status == "scan_ready" || status == "failed" {
                let components = json["detected_components"] as? [String]
                let dimensions = json["scan_dimensions"] as? [String: Double]

                return ScanResult(
                    scanId: scanId,
                    status: status,
                    floorAreaSqft: json["floor_area_sqft"] as? Double,
                    wallAreaSqft: json["wall_area_sqft"] as? Double,
                    ceilingHeightFt: json["ceiling_height_ft"] as? Double,
                    perimeterLinearFt: json["perimeter_linear_ft"] as? Double,
                    detectedComponents: components,
                    scanDimensions: dimensions
                )
            }

            try await Task.sleep(for: .seconds(intervalSeconds))
        }
    }

    enum UploadError: LocalizedError {
        case zipFailed
        case apiError(String)
        case uploadFailed(String)
        case concurrentUpload

        var errorDescription: String? {
            switch self {
            case .zipFailed: return "Failed to create zip archive"
            case .apiError(let msg): return msg
            case .uploadFailed(let msg): return msg
            case .concurrentUpload: return "Upload already in progress"
            }
        }
    }
}

// MARK: - Upload Progress Delegate

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let totalBytes: Int
    let onProgress: (Double) -> Void

    init(totalBytes: Int, onProgress: @escaping (Double) -> Void) {
        self.totalBytes = totalBytes
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let fraction = Double(totalBytesSent) / Double(max(totalBytesExpectedToSend, 1))
        DispatchQueue.main.async { [weak self] in
            self?.onProgress(fraction)
        }
    }
}
