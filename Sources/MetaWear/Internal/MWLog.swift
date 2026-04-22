import Foundation

/// Writes a debug line to stderr. Compiled out entirely in release builds.
@inline(__always)
func mwLog(_ message: @autoclosure () -> String) {
#if DEBUG
    fputs("\(message())\n", stderr)
#endif
}
