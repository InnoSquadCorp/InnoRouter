import Testing

@testable import InnoRouterCore

@Suite("Event broadcaster concurrency")
@MainActor
struct EventBroadcasterTests {
    @Test("Every subscriber receives an independent ordered stream")
    func multicastOrdering() async {
        let broadcaster = EventBroadcaster<Int>(bufferingPolicy: .unbounded)
        let first = broadcaster.stream()
        let second = broadcaster.stream()
        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()

        broadcaster.broadcast(1)
        broadcaster.broadcast(2)

        #expect(await firstIterator.next() == 1)
        #expect(await firstIterator.next() == 2)
        #expect(await secondIterator.next() == 1)
        #expect(await secondIterator.next() == 2)
        #expect(broadcaster.subscriberCount == 2)
    }

    @Test("Newest buffering drops only the oldest stalled events")
    func bufferingNewest() async {
        let broadcaster = EventBroadcaster<Int>(bufferingPolicy: .bufferingNewest(2))
        let stream = broadcaster.stream()
        var iterator = stream.makeAsyncIterator()

        broadcaster.broadcast(1)
        broadcaster.broadcast(2)
        broadcaster.broadcast(3)

        #expect(await iterator.next() == 2)
        #expect(await iterator.next() == 3)
    }

    @Test("Oldest buffering preserves the first bounded events")
    func bufferingOldest() async {
        let broadcaster = EventBroadcaster<Int>(bufferingPolicy: .bufferingOldest(2))
        let stream = broadcaster.stream()
        var iterator = stream.makeAsyncIterator()

        broadcaster.broadcast(1)
        broadcaster.broadcast(2)
        broadcaster.broadcast(3)

        #expect(await iterator.next() == 1)
        #expect(await iterator.next() == 2)
    }

    @Test("Broadcaster deallocation terminates every outstanding stream")
    func deallocationFinishesStream() async {
        var broadcaster: EventBroadcaster<Int>? = EventBroadcaster()
        let stream = broadcaster!.stream()
        var iterator = stream.makeAsyncIterator()
        weak let weakBroadcaster = broadcaster

        broadcaster = nil

        #expect(weakBroadcaster == nil)
        #expect(await iterator.next() == nil)
    }
}
