import Foundation

/// The lifecycle states of a room scan session.
///
/// Valid transitions:
/// ```
/// idle → selectingRFQ → scanning → labelingRoom → exporting → uploading → viewingResults
///                ↑                       ↓                                       ↓
///                └───────────────────────┘                                       │
///                ↑                                                               │
///                └───── (scan another room on same RFQ) ─────────────────────────┘
///                ↑                                          ↓
///   idle ←──── (done) ←──── uploading (on error) ←── exporting (on error)
/// ```
///
/// - `idle`: No active scan. User can select a project or start scanning.
/// - `selectingRFQ`: User is choosing an RFQ (project) to associate with the scan.
/// - `scanning`: AR session is active, capturing mesh and keyframes.
/// - `labelingRoom`: Scan stopped; user is tagging the room (e.g., "Kitchen").
/// - `exporting`: Packaging keyframes + mesh + metadata into the upload directory.
/// - `uploading`: Uploading the scan package to GCS and notifying the backend.
/// - `viewingResults`: Displaying cloud-computed room dimensions and detected components.
enum ScanState {
    case idle
    case selectingRFQ
    case scanning
    case labelingRoom
    case exporting
    case uploading
    case viewingResults
}
