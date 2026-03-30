import Foundation

/// The lifecycle states of a room scan session.
///
/// Valid transitions:
/// ```
/// idle → selectingRFQ → scanReady → scanning → annotatingCorners → labelingRoom → exporting → uploading → viewingResults
///                         ↑            │                                                                          │
///                         └── redo ────┘                                                                          │
///                         ↑                                                                                       │
///                         └──────────────────────── "Scan Another Room" ──────────────────────────────────────────┘
///                         ↑                                                    ↓
///   idle ←──── (done) ←──── uploading (on error) ←── exporting (on error)
/// ```
///
/// - `idle`: No active scan. User can select a project or start scanning.
/// - `selectingRFQ`: User is choosing an RFQ (project) to associate with the scan.
/// - `scanReady`: AR preview visible; user sees "Start Scan" button before committing.
/// - `scanning`: AR session is active, capturing mesh and keyframes.
/// - `annotatingCorners`: Scan stopped; user traces room corners on AR view. AR session stays running.
/// - `capturingPanorama`: User stands at room center and rotates 360° for texture capture.
/// - `labelingRoom`: User is tagging the room (e.g., "Kitchen").
/// - `exporting`: Packaging keyframes + mesh + metadata into the upload directory.
/// - `uploading`: Uploading the scan package to GCS and notifying the backend.
/// - `viewingResults`: Displaying cloud-computed room dimensions and detected components.
enum ScanState {
    case idle
    case selectingRFQ
    case scanReady
    case scanning
    case annotatingCorners
    case capturingPanorama
    case labelingRoom
    case exporting
    case uploading
    case viewingResults
}
