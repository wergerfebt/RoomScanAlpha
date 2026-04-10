import Foundation
import Network

// MARK: - URLSession Protocol for testability

/// Protocol abstracting URLSession so tests can inject mock network responses.
protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func upload(for request: URLRequest, from data: Data) async throws -> (Data, URLResponse)
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            task.resume()
        }
    }
}

/// Handles the full scan upload lifecycle: zip → signed URL → GCS upload → backend notification.
///
/// Upload flow:
///   1. Authenticate via Firebase Auth (anonymous or email/password).
///   2. Zip the scan package directory (~50-100MB compressed).
///   3. Request a time-limited signed URL from the REST API.
///   4. PUT the zip directly to GCS (bypasses Cloud Run's 32MB request limit).
///   5. Notify the backend that upload is complete (triggers Cloud Tasks processing).
///
/// Progress is reported as a 0.0–1.0 fraction mapped across all steps:
///   0.00–0.05  auth + zip
///   0.05–0.15  signed URL + upload start
///   0.15–0.90  GCS upload (proportional to bytes sent)
///   0.90–1.00  backend notification
///
/// Resilience: all HTTP requests use `executeWithRetry()` with exponential backoff for
/// transient failures (408, 429, 5xx). Only one upload is allowed at a time.
final class CloudUploader {
    static let shared = CloudUploader()

    private let apiBaseURL = "https://scan-api-839349778883.us-central1.run.app"

    /// Injected session for testability. Defaults to URLSession.shared.
    var session: URLSessionProtocol = URLSession.shared

    /// Whether an upload is currently in progress. Prevents concurrent uploads.
    private(set) var isUploading = false

    // MARK: - Retry Configuration

    struct RetryConfig {
        var maxRetries: Int = 3
        var initialDelaySeconds: TimeInterval = 1.0
        var maxDelaySeconds: TimeInterval = 30.0
        /// HTTP status codes considered transient/retryable:
        /// 408 (timeout), 429 (rate limited), 500-504 (server errors).
        var retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    }

    var retryConfig = RetryConfig()

    /// Timestamps of retry attempts — exposed for test assertions.
    private(set) var retryTimestamps: [Date] = []

    private init() {}

    /// Check current network path — returns (isConnected, isCellular).
    func checkNetwork() async -> (connected: Bool, cellular: Bool) {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: (path.status == .satisfied, path.usesInterfaceType(.cellular)))
            }
            monitor.start(queue: DispatchQueue(label: "network-check"))
        }
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
        /// Miro format: label_keys from SCAN_COMPONENT_LABELS (e.g. "floor_hardwood").
        /// Extracted from detected_components JSONB `{ "detected": ["label_key", ...] }`.
        let detectedComponents: [String]?
        /// Standardized scan dimension keys for auto-population, plus nested bbox.
        let scanDimensions: [String: Any]?
        /// Room polygon corners in feet [[x, z], ...], CCW winding. Nil for old/unannotated scans.
        let roomPolygonFt: [[Double]]?
        /// Per-corner wall heights in feet. Nil for old/unannotated scans.
        let wallHeightsFt: [Double]?
        /// How the polygon was derived: "annotated", "geometric", or "dnn".
        let polygonSource: String?
        /// Signed GCS URL for the PLY mesh (7-day expiry). Nil if not available.
        let scanMeshUrl: String?
        /// Fast camera-viability coverage from Phase 1 processing.
        /// Available with "metrics_ready" status, before full UV-based analysis.
        let fastCoverage: FastCoverage?
        /// Accurate UV-based coverage computed inline during processing.
        /// Available with "complete" status — eliminates need for separate /coverage call.
        let inlineCoverage: CoverageResult?
    }

    struct FastCoverage {
        let coverageRatio: Float
        let totalFaces: Int
        let uncoveredCount: Int
        let uncoveredFaces: [[String: Any]]
    }

    /// Full upload flow: zip → sign → upload → complete.
    /// Calls onProgress with (step description, fraction 0.0–1.0).
    /// Throws `UploadError.concurrentUpload` if another upload is already in progress.
    func upload(
        scanDirectoryURL: URL,
        rfqId: String,
        roomLabel: String = "",
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
        let status = try await notifyComplete(scanId: scanId, token: token, rfqId: rfqId, roomLabel: roomLabel)
        print("[RoomScanAlpha] Backend notified: \(status)")

        // 6. Persist scan ID
        persistScanId(scanId)

        onProgress("Upload complete", 1.0)

        // Clean up zip
        try? FileManager.default.removeItem(at: zipURL)

        return UploadResult(scanId: scanId, status: status)
    }

    /// Upload a supplemental scan package for an existing scan.
    /// Gets a signed URL for supplemental_scan.zip, uploads, then triggers merge + reprocess.
    func uploadSupplemental(
        scanDirectoryURL: URL,
        rfqId: String,
        scanId: String,
        onProgress: @escaping (String, Double) -> Void
    ) async throws -> UploadResult {
        guard !isUploading else {
            throw UploadError.concurrentUpload
        }
        isUploading = true
        defer { isUploading = false }

        // 1. Auth
        onProgress("Authenticating...", 0.0)
        _ = try await AuthManager.shared.signInAnonymously()
        let token = try await AuthManager.shared.getToken()

        // 2. Zip
        onProgress("Compressing supplemental scan...", 0.05)
        let zipURL = try zipDirectory(scanDirectoryURL)
        let zipSize = try FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int ?? 0
        print("[RoomScanAlpha] Supplemental zip: \(zipSize / 1024 / 1024)MB")

        // 3. Get signed URL for supplemental_scan.zip
        onProgress("Requesting upload URL...", 0.10)
        let signedURL = try await getSupplementalSignedURL(token: token, rfqId: rfqId, scanId: scanId)

        // 4. Upload to GCS
        onProgress("Uploading supplemental scan...", 0.15)
        try await uploadToGCS(fileURL: zipURL, signedURL: signedURL) { fraction in
            let mapped = 0.15 + fraction * 0.75
            onProgress("Uploading supplemental scan...", mapped)
        }
        print("[RoomScanAlpha] Supplemental upload complete for scan \(scanId)")

        // 5. Trigger merge + reprocess
        onProgress("Triggering reprocessing...", 0.95)
        let status = try await notifySupplementalComplete(scanId: scanId, token: token, rfqId: rfqId)
        print("[RoomScanAlpha] Supplemental merge triggered: \(status)")

        onProgress("Reprocessing started", 1.0)

        try? FileManager.default.removeItem(at: zipURL)

        return UploadResult(scanId: scanId, status: status)
    }

    // MARK: - Retry with Exponential Backoff

    /// Execute an HTTP request with retry and exponential backoff for transient failures.
    /// Delay doubles each attempt (1s, 2s, 4s, ...) up to `maxDelaySeconds`.
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

    /// Create a zip archive of a directory using NSFileCoordinator.
    /// NSFileCoordinator with `.forUploading` automatically produces a zip of the directory
    /// at a temporary path; we copy it to our own temp location for upload.
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
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let totalBytes = fileAttrs[.size] as? Int ?? 0

        var request = URLRequest(url: signedURL)
        request.httpMethod = "PUT"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.setValue("\(totalBytes)", forHTTPHeaderField: "Content-Length")

        let delegate = UploadProgressDelegate(totalBytes: totalBytes, onProgress: onProgress)
        let uploadSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        // Stream from disk instead of loading entire file into memory to avoid OOM on large scans.
        let (_, response) = try await uploadSession.upload(for: request, fromFile: fileURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UploadError.uploadFailed("GCS upload failed with HTTP \(statusCode)")
        }
    }

    private func notifyComplete(scanId: String, token: String, rfqId: String, roomLabel: String = "") async throws -> String {
        let url = URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/scans/complete")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = try JSONSerialization.data(withJSONObject: ["scan_id": scanId, "room_label": roomLabel])
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

    private func getSupplementalSignedURL(token: String, rfqId: String, scanId: String) async throws -> URL {
        let url = URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/scans/\(scanId)/supplemental-upload-url")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await executeWithRetry(request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UploadError.apiError("Failed to get supplemental signed URL (HTTP \(statusCode)): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let signedURLString = json?["signed_url"] as? String,
              let signedURL = URL(string: signedURLString) else {
            throw UploadError.apiError("Invalid supplemental signed URL response")
        }

        return signedURL
    }

    private func notifySupplementalComplete(scanId: String, token: String, rfqId: String) async throws -> String {
        let url = URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/scans/\(scanId)/supplemental")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await executeWithRetry(request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let respBody = String(data: data, encoding: .utf8) ?? ""
            throw UploadError.apiError("Supplemental notification failed (HTTP \(statusCode)): \(respBody)")
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

    /// Poll the status endpoint until the scan reaches a terminal state ("scan_ready" or "failed").
    /// Times out after maxAttempts polls (default 120 = 10 minutes at 5s intervals).
    /// Poll the status endpoint until the scan reaches an actionable state.
    ///
    /// Returns on "metrics_ready" (fast results available), "complete" (texturing done),
    /// or "failed". Uses adaptive polling: 2s for first 30s, 5s for 30-120s, 10s after.
    func pollForResult(
        scanId: String,
        rfqId: String,
        maxAttempts: Int = 120
    ) async throws -> ScanResult {
        let token = try await AuthManager.shared.getToken()
        let url = URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/scans/\(scanId)/status")!
        let startTime = Date()

        for attempt in 1...maxAttempts {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw UploadError.apiError("Status poll failed (HTTP \(statusCode))")
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let status = json["status"] as? String ?? "unknown"

            print("[RoomScanAlpha] Poll status: \(status) (attempt \(attempt)/\(maxAttempts))")

            if status == "metrics_ready" || status == "complete" || status == "scan_ready" || status == "failed" {
                return _parseScanResult(scanId: scanId, status: status, json: json)
            }

            // Adaptive polling: fast at first (metrics_ready expected ~20s), slower later
            let elapsed = Date().timeIntervalSince(startTime)
            let interval: TimeInterval = elapsed < 30 ? 2.0 : elapsed < 120 ? 5.0 : 10.0
            try await Task.sleep(for: .seconds(interval))
        }

        throw UploadError.pollTimeout
    }

    /// Continue polling after metrics_ready until "complete" or "failed".
    /// Called by ContentView after showing fast results to get final texture status.
    func pollForComplete(
        scanId: String,
        rfqId: String,
        maxAttempts: Int = 120
    ) async throws -> ScanResult {
        let token = try await AuthManager.shared.getToken()
        let url = URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/scans/\(scanId)/status")!

        for attempt in 1...maxAttempts {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw UploadError.apiError("Status poll failed (HTTP \(statusCode))")
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let status = json["status"] as? String ?? "unknown"

            if status == "complete" || status == "scan_ready" || status == "failed" {
                return _parseScanResult(scanId: scanId, status: status, json: json)
            }

            try await Task.sleep(for: .seconds(5.0))
        }

        throw UploadError.pollTimeout
    }

    private func _parseScanResult(scanId: String, status: String, json: [String: Any]) -> ScanResult {
        let componentsObj = json["detected_components"] as? [String: Any]
        let components = componentsObj?["detected"] as? [String]
        let dimensions = json["scan_dimensions"] as? [String: Any]
        let polygon = json["room_polygon_ft"] as? [[Double]]
        let wallHeights = json["wall_heights_ft"] as? [Double]
        let polySource = json["polygon_source"] as? String
        let meshUrl = json["scan_mesh_url"] as? String

        // Parse fast_coverage (fallback if texturing failed)
        var fastCov: FastCoverage?
        if let fc = json["fast_coverage"] as? [String: Any] {
            fastCov = FastCoverage(
                coverageRatio: (fc["coverage_ratio"] as? Double).map { Float($0) } ?? 0,
                totalFaces: fc["total_faces"] as? Int ?? 0,
                uncoveredCount: fc["uncovered_count"] as? Int ?? 0,
                uncoveredFaces: fc["uncovered_faces"] as? [[String: Any]] ?? []
            )
        }

        // Parse inline UV-based coverage (accurate, from processing)
        var inlineCov: CoverageResult?
        if let cov = json["coverage"] as? [String: Any] {
            let uncoveredRaw = (cov["uncovered_faces"] as? [[String: Any]]) ?? []
            let uncoveredFaces = uncoveredRaw.compactMap { face -> UncoveredFace? in
                guard let verts = face["vertices"] as? [[Double]], verts.count == 3 else { return nil }
                return UncoveredFace(vertices: verts.map { $0.map { Float($0) } })
            }
            let holeRaw = (cov["hole_faces"] as? [[String: Any]]) ?? []
            let holeFaces = holeRaw.compactMap { face -> UncoveredFace? in
                guard let verts = face["vertices"] as? [[Double]], verts.count == 3 else { return nil }
                return UncoveredFace(vertices: verts.map { $0.map { Float($0) } })
            }
            inlineCov = CoverageResult(
                coverageRatio: (cov["coverage_ratio"] as? Double).map { Float($0) } ?? 0,
                totalFaces: cov["total_faces"] as? Int ?? 0,
                uncoveredCount: cov["uncovered_count"] as? Int ?? 0,
                uncoveredFaces: uncoveredFaces,
                holeCount: cov["hole_count"] as? Int ?? 0,
                holeFaces: holeFaces
            )
        }

        return ScanResult(
            scanId: scanId,
            status: status,
            floorAreaSqft: json["floor_area_sqft"] as? Double,
            wallAreaSqft: json["wall_area_sqft"] as? Double,
            ceilingHeightFt: json["ceiling_height_ft"] as? Double,
            perimeterLinearFt: json["perimeter_linear_ft"] as? Double,
            detectedComponents: components,
            scanDimensions: dimensions,
            roomPolygonFt: polygon,
            wallHeightsFt: wallHeights,
            polygonSource: polySource,
            scanMeshUrl: meshUrl,
            fastCoverage: fastCov,
            inlineCoverage: inlineCov
        )
    }

    // MARK: - Coverage Check

    struct CoverageResult {
        let coverageRatio: Float
        let totalFaces: Int
        let uncoveredCount: Int
        let uncoveredFaces: [UncoveredFace]
        let holeCount: Int
        let holeFaces: [UncoveredFace]
    }

    struct UncoveredFace {
        let vertices: [[Float]]  // [[x,y,z], [x,y,z], [x,y,z]] triangle vertices in meters
    }

    /// Call the cloud coverage endpoint to check which mesh faces lack camera coverage.
    func checkCoverage(scanId: String, rfqId: String) async throws -> CoverageResult {
        let token = try await AuthManager.shared.getToken()
        let url = URL(string: "\(apiBaseURL)/api/rfqs/\(rfqId)/scans/\(scanId)/coverage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90  // Coverage check downloads + decimates mesh

        let (data, response) = try await executeWithRetry(request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UploadError.apiError("Coverage check failed (HTTP \(statusCode)): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard json["status"] as? String == "ok" else {
            let error = json["error"] as? String ?? "Unknown error"
            throw UploadError.apiError("Coverage check error: \(error)")
        }

        let faces = (json["uncovered_faces"] as? [[String: Any]] ?? []).compactMap { face -> UncoveredFace? in
            guard let rawVerts = face["vertices"] as? [Any] else { return nil }
            let verts: [[Float]] = rawVerts.compactMap { rawV in
                guard let arr = rawV as? [Any] else { return nil }
                let floats = arr.compactMap { ($0 as? NSNumber)?.floatValue }
                return floats.count == 3 ? floats : nil
            }
            guard verts.count == 3 else { return nil }
            return UncoveredFace(vertices: verts)
        }

        let holes = (json["hole_faces"] as? [[String: Any]] ?? []).compactMap { face -> UncoveredFace? in
            guard let rawVerts = face["vertices"] as? [Any] else { return nil }
            let verts: [[Float]] = rawVerts.compactMap { rawV in
                guard let arr = rawV as? [Any] else { return nil }
                let floats = arr.compactMap { ($0 as? NSNumber)?.floatValue }
                return floats.count == 3 ? floats : nil
            }
            guard verts.count == 3 else { return nil }
            return UncoveredFace(vertices: verts)
        }

        return CoverageResult(
            coverageRatio: (json["coverage_ratio"] as? Double).map { Float($0) } ?? 0,
            totalFaces: json["total_faces"] as? Int ?? 0,
            uncoveredCount: json["uncovered_count"] as? Int ?? 0,
            uncoveredFaces: faces,
            holeCount: json["hole_count"] as? Int ?? 0,
            holeFaces: holes
        )
    }

    enum UploadError: LocalizedError {
        /// NSFileCoordinator zip creation failed.
        case zipFailed
        /// REST API call failed (signed URL, upload-complete notification).
        case apiError(String)
        /// GCS PUT upload failed.
        case uploadFailed(String)
        /// Another upload is already in progress.
        case concurrentUpload
        /// Status polling exceeded maxAttempts without reaching a terminal state.
        case pollTimeout

        var errorDescription: String? {
            switch self {
            case .zipFailed: return "Failed to create zip archive"
            case .apiError(let msg): return msg
            case .uploadFailed(let msg): return msg
            case .concurrentUpload: return "Upload already in progress"
            case .pollTimeout: return "Scan processing timed out — try again later"
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
