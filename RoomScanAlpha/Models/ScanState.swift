import Foundation

enum ScanState {
    case idle
    case selectingRFQ
    case scanning
    case labelingRoom
    case exporting
    case uploading
    case viewingResults
}
