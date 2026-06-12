import Testing
@testable import MetaWearApp

@Suite("RingBuffer")
struct RingBufferTests {

    @Test func appendCapsAtCapacity() {
        var ring = RingBuffer<Int>(capacity: 3)
        ring.append(1)
        ring.append(2)
        ring.append(3)
        ring.append(4)
        #expect(ring.elements == [2, 3, 4])
        #expect(ring.count == 3)
    }

    @Test func appendContentsOf() {
        var ring = RingBuffer<Int>(capacity: 2)
        ring.append(contentsOf: [1, 2, 3, 4, 5])
        #expect(ring.elements == [4, 5])
    }

    @Test func removeAllKeepsCapacity() {
        var ring = RingBuffer<Int>(capacity: 5)
        ring.append(contentsOf: [1, 2, 3])
        ring.removeAll()
        #expect(ring.elements.isEmpty)
        #expect(ring.capacity == 5)
    }
}
