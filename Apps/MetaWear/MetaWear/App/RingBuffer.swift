import Foundation

struct RingBuffer<Element> {
    private var storage: [Element] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    mutating func append(_ element: Element) {
        if storage.count == capacity {
            storage.removeFirst()
        }
        storage.append(element)
    }

    mutating func append(contentsOf newElements: some Sequence<Element>) {
        for element in newElements {
            append(element)
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
    }

    var elements: [Element] { storage }
    var count: Int { storage.count }
    var last: Element? { storage.last }
}
