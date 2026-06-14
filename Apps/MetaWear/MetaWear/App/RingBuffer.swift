import Foundation

// `nonisolated`: this is a pure value type with no actor affinity — the app
// target's default MainActor isolation would otherwise make every member
// main-actor-only, which blocks nonisolated tests and any future off-main use.
/// Fixed-capacity FIFO buffer backed by a circular array.
///
/// `append` is O(1) — once full, the oldest element is overwritten in place
/// via a wrapping head index. (An earlier version used `Array.removeFirst()`,
/// which shifts every remaining element and made each append O(capacity);
/// at 100 Hz × several channels that put hundreds of thousands of element
/// moves per second on the main actor.)
nonisolated struct RingBuffer<Element> {
    private var storage: [Element] = []
    /// Index of the oldest element once the buffer has wrapped.
    /// Stays 0 until `storage` first reaches `capacity`.
    private var head: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    mutating func append(contentsOf newElements: some Sequence<Element>) {
        for element in newElements {
            append(element)
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Elements in insertion order (oldest first). O(n) when the buffer has
    /// wrapped — fine for the call pattern here: the throttle loop snapshots
    /// once per UI tick (33 ms), not per sample.
    var elements: [Element] {
        guard head > 0 else { return storage }
        return Array(storage[head...]) + Array(storage[..<head])
    }

    var count: Int { storage.count }

    var last: Element? {
        guard !storage.isEmpty else { return nil }
        guard head > 0 else { return storage.last }
        return storage[(head - 1 + capacity) % capacity]
    }
}
