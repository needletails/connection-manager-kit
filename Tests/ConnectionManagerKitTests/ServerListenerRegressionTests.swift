//
//  ServerListenerRegressionTests.swift
//  connection-manager-kit
//
//  TDD regression tests for CMK server inbound order, nil-delegate signal, max connections.
//

import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
@testable import ConnectionManagerKit

@Suite(.serialized)
struct ServerListenerRegressionTests {

    @Test
    func testNilContextDelegateDoesNotSilentlyDropWithoutSignal() async throws {
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
        #expect(await clientContext.waitForWriter())

        var buf = ByteBufferAllocator().buffer(capacity: 8)
        buf.writeString("ping")
        try await clientContext.send(buf)
        try await Task.sleep(for: .milliseconds(300))

        let drops = await listener.missingContextDelegateDropCount()
        #expect(drops > 0, "Nil context delegate must signal a drop, got \(drops)")

        await manager.gracefulShutdown()
        await listener.serviceGroup?.triggerGracefulShutdown()
        try await Task.sleep(for: .milliseconds(150))
        serverTask.cancel()
    }

    @Test
    func testMaxConcurrentConnectionsHonoredExactly() async throws {
        let maxConnections = 2
        let listenerConfig = ListenerConfiguration(maxConcurrentConnections: maxConnections)
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

        let configured = await listener.configuredMaxConcurrentConnections()
        #expect(configured == maxConnections, "ServerService max must be \(maxConnections), got \(String(describing: configured))")

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
