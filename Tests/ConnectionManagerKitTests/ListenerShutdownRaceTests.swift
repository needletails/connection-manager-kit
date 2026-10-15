//
//  ListenerShutdownRaceTests.swift
//  connection-manager-kit
//
//  Regression: shutting a listener down while children are still being accepted used to
//  let NIO drop a freshly wrapped child between the child initializer and the accept
//  loop. The child then became active and released an unfinished NIOAsyncWriter
//  ("Deinited NIOAsyncWriter without calling finish()"), or, with the other timing, was
//  never registered and stayed open forever.
//

import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOWebSocket
@testable import ConnectionManagerKit

@Suite(.serialized)
struct ListenerShutdownRaceTests {

    private static let iterations = 10
    private static let clientsPerIteration = 32

    /// Fires `count` connects at `port`, waits only for the TCP handshakes (the server's
    /// child initializers are still running), shuts the listener down, and returns every
    /// client channel that connected.
    private func stormAndShutdown<I: Sendable, O: Sendable>(
        _ listener: ConnectionListener<I, O>,
        task: Task<Void, Error>,
        port: Int,
        count: Int
    ) async -> [Channel] {
        let connects = (0..<count).map { _ in
            Task { try? await connectRaw(host: "127.0.0.1", port: port) }
        }
        var channels: [Channel] = []
        for connect in connects {
            if let channel = await connect.value {
                channels.append(channel)
            }
        }
        await stopListener(listener, task: task)
        return channels
    }

    private func expectAllClosed(_ channels: [Channel], _ comment: Comment) async {
        for channel in channels {
            let closed = await completes(within: .seconds(5)) {
                try? await channel.closeFuture.getAbandoningOnCancel()
            }
            #expect(closed, comment)
            if !closed {
                try? await channel.close()
            }
        }
    }

    @Test("TCP listener shutdown during a connect storm neither traps nor leaks children")
    func tcpListenerShutdownRace() async throws {
        for _ in 0..<Self.iterations {
            let listener = ConnectionListener<ByteBuffer, ByteBuffer>()
            // Slow child initializer: guarantees wrapped children are still travelling
            // to the accept loop when the listener closes, which is the failing window.
            let listenerDelegate = TCPListenerDelegation {
                Thread.sleep(forTimeInterval: 0.05)
                return []
            }
            let (port, serverTask) = try await startTCPListener(
                listener, delegate: nil, listenerDelegate: listenerDelegate)

            let channels = await stormAndShutdown(
                listener, task: serverTask, port: port, count: Self.clientsPerIteration)
            await expectAllClosed(channels, "every accepted child must be closed by listener shutdown")
        }
    }

    @Test("WebSocket listener shutdown during a connect storm neither traps nor leaks children")
    func webSocketListenerShutdownRace() async throws {
        for _ in 0..<Self.iterations {
            let listener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
            let listenerDelegate = WSListenerDelegation()
            let (port, serverTask) = try await startWSListener(
                listener, delegate: nil, listenerDelegate: listenerDelegate)

            let channels = await stormAndShutdown(
                listener, task: serverTask, port: port, count: Self.clientsPerIteration)
            await expectAllClosed(channels, "every accepted child must be closed by listener shutdown")
        }
    }
}
