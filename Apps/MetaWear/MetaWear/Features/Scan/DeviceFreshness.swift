import Foundation

/// Shared advertisement-freshness rule for the scan screen.
///
/// A board is treated as "on air" only if an advertisement arrived within
/// `window`. Both the Remembered rows' status and the Nearby list use this —
/// a board that powers off, dies, or connects to another phone stops
/// advertising, and must stop looking present/connectable here.
enum DeviceFreshness {
    /// MetaWear boards advertise several times per second, so 8 s tolerates
    /// a missed scan cycle without flicker while still dropping silent
    /// boards promptly.
    static let window: TimeInterval = 8

    static func isFresh(lastSeen: Date?, now: Date) -> Bool {
        guard let lastSeen else { return false }
        return now.timeIntervalSince(lastSeen) < window
    }
}
