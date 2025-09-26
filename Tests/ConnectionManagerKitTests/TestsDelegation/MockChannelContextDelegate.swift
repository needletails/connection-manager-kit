//
//  MockChannelContextDelegate.swift
//  connection-manager-kit
//
//  Created by Cole M on 9/26/25.
//
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOExtras
@testable import ConnectionManagerKit

final class MockChannelContextDelegate: ChannelContextDelegate, @unchecked Sendable {
    
    var responseStream = AsyncStream<ByteBuffer>.makeStream()
    var writer: NIOAsyncChannelOutboundWriter<ByteBuffer>?
    nonisolated(unsafe) var networkEventTask: Task<Void, Never>?
    nonisolated(unsafe) var inactiveTask: Task<Void, Never>?
    nonisolated(unsafe) var errorTask: Task<Void, Never>?
    
    func reportChildChannel(error: any Error, id: String) async { }
    
    func configureChildChannel() async {}
    
    func didShutdownChildChannel() async {}
    
    func channelActive(_ stream: AsyncStream<Void>, id: String) {
#if !canImport(Network)
        Task {
            for await _ in stream.cancelOnGracefulShutdown() {
                if !servers.isEmpty {
                    try! await Task.sleep(until: .now + .milliseconds(500))
                    for server in servers {
                        let fc1 = await manager.connectionCache.findConnection(
                            cacheKey: server.cacheKey)
                        await #expect(fc1?.config.host == server.host)
                        await manager.gracefulShutdown()
                    }
                }
            }
        }
#endif
    }
    
    func channelInactive(_ stream: AsyncStream<Void>, id: String) {
        inactiveTask = Task {
            for await _ in stream.cancelOnGracefulShutdown() {
                await tearDown()
            }
        }
    }
    func deliverWriter<Outbound, Inbound>(context: WriterContext<Inbound, Outbound>) async {
        self.writer = context.writer as? NIOAsyncChannelOutboundWriter<ByteBuffer>
    }
    
    func send(_ buffer: ByteBuffer) async {
        try! await writer?.write(buffer)
    }
    
    func deliverInboundBuffer<Inbound: Sendable, Outbound: Sendable>(context: StreamContext<Inbound, Outbound>) async {
        responseStream.continuation.yield(context.inbound as! ByteBuffer)
        let receivedMessage = (context.inbound as! ByteBuffer).getString(at: 0, length: (context.inbound as! ByteBuffer).readableBytes)
    }
    
    private func tearDown() async {
        networkEventTask?.cancel()
        errorTask?.cancel()
        inactiveTask?.cancel()
    }
}
