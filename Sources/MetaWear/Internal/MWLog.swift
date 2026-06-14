import Foundation

/// Writes a debug line to stderr. Compiled out entirely in release builds.
@inline(__always)
func mwLog(_ message: @autoclosure () -> String) {
#if DEBUG
    fputs("\(message())\n", stderr)
#endif
}

/// Like `mwLog`, but for the high-frequency per-packet paths (inbound BLE
/// notifications and protocol routing, which fire for every 20-byte packet —
/// including thousands of entries during a log download). Off by default even
/// in DEBUG: writing to stderr on every packet floods the Xcode console, and
/// because that write is synchronous while the debugger is attached it makes
/// streaming and the whole UI feel laggy. Enable when you need wire-level
/// tracing via the `-MWLogVerbose` launch argument or `MW_LOG_VERBOSE=1`.
@inline(__always)
func mwLogVerbose(_ message: @autoclosure () -> String) {
#if DEBUG
    if MWVerboseLog.isEnabled {
        fputs("\(message())\n", stderr)
    }
#endif
}

#if DEBUG
enum MWVerboseLog {
    static let isEnabled: Bool = {
        let info = ProcessInfo.processInfo
        return info.arguments.contains("-MWLogVerbose")
            || info.environment["MW_LOG_VERBOSE"] == "1"
    }()
}
#endif
