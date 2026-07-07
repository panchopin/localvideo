import Cocoa

// Prints "FOUND <w> <h>" and exits 0 if an on-screen window owned by the
// LocalVideo app exists (reasonable size), else "NONE" and exits 1.
//
// Uses CGWindowListCopyWindowInfo, which returns the window OWNER name and BOUNDS
// without Screen Recording permission (only pixel *capture* is gated). Works even
// when the app isn't frontmost, as long as its window is on screen.
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
    guard owner.contains("LocalVideo") else { continue }
    if let b = w[kCGWindowBounds as String] as? [String: Any],
       let ww = b["Width"] as? CGFloat, let hh = b["Height"] as? CGFloat,
       ww > 300, hh > 200 {
        print("FOUND \(Int(ww)) \(Int(hh))")
        exit(0)
    }
}
print("NONE")
exit(1)
