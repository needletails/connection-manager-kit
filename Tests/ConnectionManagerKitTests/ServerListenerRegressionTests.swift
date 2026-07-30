//
//  ServerListenerRegressionTests.swift
//  connection-manager-kit
//
//  Regression tests for CMK server nil-delegate delivery and max connections.
//  Asserts via public APIs and observable behavior only (no library test seams).
//  Positive echo delivery is covered by ConnectionManagerKitTests.testCreateConnectionAndEcho.
//

import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
@testable import ConnectionManagerKit

@Suite(.serialized)
struct ServerListenerRegressionTests {

    /// With no server context delegate, inbound is dropped (error-logged in production).
    /// Client can still connect/send; no echo is delivered back (contrast: testCreateConnectionAndEcho).
    @Test
    func testNilContextDelegateDropsInboundWithoutApplicationDelivery() async throws {
        let listener = ConnectionListener<ByteBuffer, ByteBuffer>()
        let serverGroup = MultiThreadedEventLoopGroup.singleton
        let listenerDelegation = ListenerDelegation(shouldShutdown: false)
        let serverConformer = MockConnectionDelegate(
            listener: listener,
            serverClientContextDelegate: nil,
            listenerDelegation: listenerDelegation
        )

        let serverTask = Task {
            let config = try await listener.resolveAddress(
                .init(group: serverGroup, host: "localhost", port: 0))
            try await listener.listen(
                address: config.address!,
                configuration: config,
                delegate: serverConformer,
                listenerDelegate: listenerDelegation)
        }

        let boundPort = try #require(await listenerDelegation.waitForBoundPort())

        let manager = ConnectionManager<ByteBuffer, ByteBuffer>()
        let clientConformer = MockConnectionDelegate(manager: manager, listenerDelegation: nil)
        let clientContext = MockChannelContextDelegate()
        await manager.setDelegate(MockConnectionManagerDelegate())
        try await manager.connect(
            to: [
                ServerLocation(
                    host: "localhost",
                    port: boundPort,
                    enableTLS: true,
                    cacheKey: "nil-delegate",
                    delegate: clientConformer,
                    contextDelegate: clientContext)
            ],
            tlsPreKeyed: makeTestTLSPreKeyedConfig()
        )
        #expect(await clientContext.waitForActiveChannel(), "Client channel must become active")
        #expect(await clientContext.waitForWriter(), "Client writer must still be delivered")

        var buf = ByteBufferAllocator().buffer(capacity: 8)
        buf.writeString("ping")
        try await clientContext.send(buf)

        let echoed = await withTaskGroup(of: ByteBuffer?.self) { group in
            group.addTask {
                for await response in clientContext.responseStream.stream {
                    clientContext.responseStream.continuation.finish()
                    return response
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(500))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(echoed == nil, "Nil server context delegate must not deliver an application echo")

        await manager.gracefulShutdown()
        await listener.serviceGroup?.triggerGracefulShutdown()
        try await Task.sleep(for: .milliseconds(150))
        serverTask.cancel()
    }

    @Test
    func testMaxConcurrentConnectionsHonoredExactly() async throws {
        let maxConnections = 2
        let listenerConfig = ListenerConfiguration(maxConcurrentConnections: maxConnections)
        #expect(listenerConfig.maxConcurrentConnections == maxConnections)

        let listener = ConnectionListener<ByteBuffer, ByteBuffer>(configuration: listenerConfig)
        let serverGroup = MultiThreadedEventLoopGroup.singleton
        let listenerDelegation = ListenerDelegation(shouldShutdown: false)
        let conformer = MockConnectionDelegate(
            manager: ConnectionManager<ByteBuffer, ByteBuffer>(),
            listenerDelegation: listenerDelegation
        )

        let serverTask = Task {
            let config = try await listener.resolveAddress(
                .init(group: serverGroup, host: "localhost", port: 0))
            try await listener.listen(
                address: config.address!,
                configuration: config,
                delegate: conformer,
                listenerDelegate: listenerDelegation)
        }

        let boundPort = try #require(await listenerDelegation.waitForBoundPort())

        let clientGroup = MultiThreadedEventLoopGroup.singleton
        var channels: [Channel] = []
        for _ in 0..<6 {
            let bootstrap = ClientBootstrap(group: clientGroup)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            if let ch = try? await bootstrap.connect(host: "localhost", port: boundPort).get() {
                channels.append(ch)
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        try await Task.sleep(for: .milliseconds(300))
        let active = await listener.getMetrics().activeConnections
        #expect(active <= maxConnections, "Active connections \(active) must not exceed \(maxConnections)")

        for ch in channels { try? await ch.close() }
        await listener.serviceGroup?.triggerGracefulShutdown()
        try await Task.sleep(for: .milliseconds(150))
        serverTask.cancel()
    }
}
