import Foundation

/// Verbose diagnostics that only exist in DEBUG builds. Release builds compile the call
/// away (the message autoclosure is never evaluated), so user ids, asset ids, file paths
/// and similarity scores never reach a shipped device log.
@inline(__always)
func dlog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
