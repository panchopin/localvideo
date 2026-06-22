import AppKit

/// Live state of a camera's stream, surfaced as a colored dot in the grid tile
/// and the Preferences list.
enum StreamStatus {
    case connecting   // ffmpeg launched, no frame yet
    case streaming    // first frame received
    case failed       // ffmpeg exited unexpectedly

    var color: NSColor {
        switch self {
        case .connecting: return .systemYellow
        case .streaming:  return .systemGreen
        case .failed:     return .systemRed
        }
    }
}
