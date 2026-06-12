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

    // The circular implementation overwrites in place with a wrapping head
    // index — pin the ordering and `last` semantics across multiple wraps.

    @Test func elementsStayOrdered_acrossMultipleWraps() {
        var ring = RingBuffer<Int>(capacity: 3)
        ring.append(contentsOf: 1...8)   // wraps the 3-slot buffer twice
        #expect(ring.elements == [6, 7, 8])
        #expect(ring.count == 3)
    }

    @Test func last_tracksNewestAfterWrap() {
        var ring = RingBuffer<Int>(capacity: 3)
        #expect(ring.last == nil)
        ring.append(1)
        #expect(ring.last == 1)
        ring.append(contentsOf: [2, 3, 4, 5])
        #expect(ring.last == 5)
    }

    @Test func removeAll_resetsWrapState() {
        var ring = RingBuffer<Int>(capacity: 3)
        ring.append(contentsOf: 1...5)   // wrapped: head is mid-buffer
        ring.removeAll()
        ring.append(contentsOf: [10, 20])
        #expect(ring.elements == [10, 20])
        #expect(ring.last == 20)
    }
}
