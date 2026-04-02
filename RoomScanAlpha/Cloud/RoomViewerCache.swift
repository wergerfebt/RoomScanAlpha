// Caches room viewer data (API JSON + 3D assets) on disk for instant repeat loads.
// First load fetches from cloud, subsequent loads serve from cache (~10-15MB per room).

import Foundation

final class RoomViewerCache {
    static let shared = RoomViewerCache()

    private let cacheDir: URL
    private let session = URLSession.shared

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = base.appendingPathComponent("room_viewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Cached room data — JSON + local file paths for 3D assets.
    struct CachedRoom {
        let json: [String: Any]
        let objLocalURL: URL?
        let atlasLocalURL: URL?
        let mtlLocalURL: URL?
    }

    // MARK: - Public API

    /// Get room data, from cache or network. Downloads 3D assets to disk.
    func getRoom(rfqId: String, scanId: String) async throws -> CachedRoom {
        let roomDir = cacheDir.appendingPathComponent("\(rfqId)/\(scanId)", isDirectory: true)

        // Check cache first
        let jsonFile = roomDir.appendingPathComponent("room.json")
        if FileManager.default.fileExists(atPath: jsonFile.path) {
            let data = try Data(contentsOf: jsonFile)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            return CachedRoom(
                json: json,
                objLocalURL: localFileIfExists(roomDir, "textured.obj"),
                atlasLocalURL: localFileIfExists(roomDir, "textured.jpg"),
                mtlLocalURL: localFileIfExists(roomDir, "textured.mtl")
            )
        }

        // Fetch from network
        let url = URL(string: "https://scan-api-839349778883.us-central1.run.app/api/rfqs/\(rfqId)/contractor-view")!
        let (data, _) = try await session.data(from: url)
        let fullJson = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard let rooms = fullJson["rooms"] as? [[String: Any]] else {
            throw CacheError.noRooms
        }

        // Find the specific room
        guard let roomJson = rooms.first(where: { ($0["scan_id"] as? String ?? $0["id"] as? String) == scanId }) else {
            throw CacheError.roomNotFound
        }

        // Save JSON
        try FileManager.default.createDirectory(at: roomDir, withIntermediateDirectories: true)
        let roomData = try JSONSerialization.data(withJSONObject: roomJson, options: .prettyPrinted)
        try roomData.write(to: jsonFile)

        // Download 3D assets
        let textureUrls = roomJson["texture_urls"] as? [String: Any] ?? [:]
        let objURL = await downloadAsset(textureUrls["obj"] as? String, to: roomDir, filename: "textured.obj")
        let atlasURL = await downloadAsset(textureUrls["atlas"] as? String, to: roomDir, filename: "textured.jpg")
        let mtlURL = await downloadAsset(textureUrls["mtl"] as? String, to: roomDir, filename: "textured.mtl")

        print("[RoomViewerCache] Cached room \(scanId): obj=\(objURL != nil), atlas=\(atlasURL != nil)")

        return CachedRoom(
            json: roomJson,
            objLocalURL: objURL,
            atlasLocalURL: atlasURL,
            mtlLocalURL: mtlURL
        )
    }

    /// Clear cache for a specific room.
    func clearRoom(rfqId: String, scanId: String) {
        let roomDir = cacheDir.appendingPathComponent("\(rfqId)/\(scanId)")
        try? FileManager.default.removeItem(at: roomDir)
    }

    /// Clear all cached data.
    func clearAll() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Total cache size in bytes.
    var cacheSize: Int {
        let enumerator = FileManager.default.enumerator(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let url = enumerator?.nextObject() as? URL {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    // MARK: - Private

    private func downloadAsset(_ urlString: String?, to dir: URL, filename: String) async -> URL? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        let dest = dir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        do {
            let (data, _) = try await session.data(from: url)
            try data.write(to: dest)
            return dest
        } catch {
            print("[RoomViewerCache] Failed to download \(filename): \(error.localizedDescription)")
            return nil
        }
    }

    private func localFileIfExists(_ dir: URL, _ filename: String) -> URL? {
        let path = dir.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    enum CacheError: LocalizedError {
        case noRooms, roomNotFound

        var errorDescription: String? {
            switch self {
            case .noRooms: return "No rooms found"
            case .roomNotFound: return "Room not found"
            }
        }
    }
}
