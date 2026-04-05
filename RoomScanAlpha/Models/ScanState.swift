import Foundation

/// The lifecycle states of a room scan session.
///
/// Valid transitions:
/// ```
/// idle → selectingRFQ → projectOverview → scanReady → scanning → reviewingCoverage → annotatingCorners → labelingRoom → exporting → uploading → viewingResults
///                                           ↑            │                                                                                          │
///                                           └── redo ────┘                                                                                          │
///                                           ↑                                                                                                       │
///                         projectOverview ←──── "Scan Another Room" ←────────────────────────────────────────────────────────────────────────────────┘
///                         ↑                                                    ↓
///   idle ←──── (done) ←──── uploading (on error) ←── exporting (on error)
/// ```
///
/// - `idle`: No active scan. User can select a project or start scanning.
/// - `selectingRFQ`: User is choosing an RFQ (project) to associate with the scan.
/// - `projectOverview`: Viewing existing rooms, scope, and dimensions for the selected project.
/// - `scanReady`: AR preview visible; user sees "Start Scan" button before committing.
/// - `scanning`: AR session is active, capturing mesh and keyframes (8°/0.3s dense capture).
/// - `reviewingCoverage`: Mesh coverage analysis — shows uncovered faces before annotation.
/// - `annotatingCorners`: Scan stopped; user traces room corners on AR view.
/// - `labelingRoom`: User is tagging the room (e.g., "Kitchen").
/// - `exporting`: Packaging keyframes + mesh + metadata into the upload directory.
/// - `uploading`: Uploading the scan package to GCS and notifying the backend.
/// - `viewingResults`: Displaying cloud-computed room dimensions and detected components.
enum ScanState {
    case idle
    case selectingRFQ
    case projectOverview
    case scanReady
    case scanning
    case reviewingCoverage
    case annotatingCorners
    case capturingPanorama  // Deprecated: kept for backward compat, no longer used in flow
    case relocalizingForRescan  // Loading ARWorldMap and waiting for relocalization
    case rescanningGaps         // Relocalized — capturing supplemental frames at gap locations
    case labelingRoom
    case exporting
    case uploading
    case viewingResults
}
