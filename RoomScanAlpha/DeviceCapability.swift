import ARKit

struct DeviceCapability {
    static var supportsLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
    }

    static var supportsARKit: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    static var supportsSceneDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    static func logCapabilities() {
        print("[RoomScanAlpha] ARKit supported: \(supportsARKit)")
        print("[RoomScanAlpha] LiDAR supported: \(supportsLiDAR)")
        print("[RoomScanAlpha] Scene depth supported: \(supportsSceneDepth)")
    }
}
