//
//  RemoteCloseLifecycleTests.swift
//  connection-manager-kit
//
//  Regression: when the peer closes the socket, the client's ChildChannelService.run()
//  must return, notify didShutdownChildChannel, and evict the cache entry.
//  Previously the outbound writer stream was only finished by shutdown(), so the
//  run task hung forever after a remote close and the dead connection stayed cached.
//

import Testing
import Foundation
import NIOCore
import NIOPosix
@testable import ConnectionManagerKit

final class ShutdownRecordingContextDelegate: ChannelContextDelegate, @unchecked Sendable {
    nonisolated(unsafe) private(set) var didShutdown = false
    nonisolated(unsafe) private(set) var writer: NIOAsyncChannelOutboundWriter<ByteBuffer>?

    func reportChildChannel(error: any Error, id: String) async {}
    func didShutdownChildChannel() async { didShutdown = true }
    func channelActive(_ stream: AsyncStream<Void>, id: String) {}
    func channelInactive(_ stream: AsyncStream<Void>, id: String) {}
    func deliverWriter<Outbound, Inbound>(context: WriterContext<Inbound, Outbound>) async {
        writer = context.writer as? NIOAsyncChannelOutboundWriter<ByteBuffer>
    }
    func deliverInboundBuffer<Inbound: Sendable, Outbound: Sendable>(context: StreamContext<Inbound, Outbound>) async {}

    func waitForWriter(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, writer == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return writer != nil
    }

    func waitForShutdown(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !didShutdown {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return didShutdown
    }
}

@Suite(.serialized)
struct RemoteCloseLifecycleTests {

    @Test("Remote close finishes the client run and evicts the cache entry")
    func remoteCloseFinishesClientRun() async throws {
        let listener = ConnectionListener<ByteBuffer, ByteBuffer>()
        let listenerDelegation = ListenerDelegation(shouldShutdown: false)
        let serverConformer = MockConnectionDelegate<ByteBuffer, ByteBuffer>(listenerDelegation: listenerDelegation)
        let serverTask = Task {
            let config = try await listener.resolveAddress(
                .init(group: MultiThreadedEventLoopGroup.singleton, host: "localhost", port: 0))
            try await listener.listen(
                address: config.address!,
                configuration: config,
                delegate: serverConformer,
                listenerDelegate: listenerDelegation)
        }
        let port = try #require(await listenerDelegation.waitForBoundPort())

        let manager = ConnectionManager<ByteBuffer, ByteBuffer>()
        let clientConformer = MockConnectionDelegate<ByteBuffer, ByteBuffer>(manager: manager, listenerDelegation: nil)
        let context = ShutdownRecordingContextDelegate()
        try await manager.connect(to: [
            ServerLocation(
                host: "localhost", port: port, enableTLS: false, cacheKey: "remote-close",
                delegate: clientConformer, contextDelegate: context)
        ])
        #expect(await context.waitForWriter(), "client writer must be delivered")
        #expect(await manager.connectionCache.count == 1)

        // Peer closes: tear the whole server down.
        try await listener.shutdown()
        await listener.serviceGroup?.triggerGracefulShutdown()
        serverTask.cancel()

        #expect(await context.waitForShutdown(), "client run() must return after remote close")

        var count = await manager.connectionCache.count
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline, count != 0 {
            try? await Task.sleep(for: .milliseconds(50))
            count = await manager.connectionCache.count
        }
        #expect(count == 0, "dead connection must be evicted from the cache")

        await manager.gracefulShutdown()
    }
}
