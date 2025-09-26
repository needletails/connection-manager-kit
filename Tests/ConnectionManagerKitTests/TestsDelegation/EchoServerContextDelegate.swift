//
//  EchoServerContextDelegate.swift
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

final class EchoServerContextDelegate: ChannelContextDelegate, @unchecked Sendable {
    
    var writer: NIOAsyncChannelOutboundWriter<ByteBuffer>?
    nonisolated(unsafe) var networkEventTask: Task<Void, Never>?
    nonisolated(unsafe) var inactiveTask: Task<Void, Never>?
    nonisolated(unsafe) var errorTask: Task<Void, Never>?
    
    func reportChildChannel(error: any Error, id: String) async { }
    
    func configureChildChannel() async {}
    
    func didShutdownChildChannel() async {}
    
    func channelActive(_ stream: AsyncStream<Void>, id: String) {
        // No special handling needed for echo server
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
        print("Echo server writer set for channel: \(context.id)")
    }

    func deliverInboundBuffer<Inbound: Sendable, Outbound: Sendable>(context: StreamContext<Inbound, Outbound>) async {
        // Echo the received message back to the client
        if let inboundBuffer = context.inbound as? ByteBuffer {
            print("Echo server received message for channel: \(context.id)")
            print("Echo server received: \(inboundBuffer)")
            if let writer = self.writer {
                try! await writer.write(inboundBuffer)
                print("Echo server sent back: \(inboundBuffer)")
            } else {
                print("Echo server writer is nil!")
            }
        } else {
            print("Echo server received non-ByteBuffer message")
        }
    }
    
    private func tearDown() async {
        networkEventTask?.cancel()
        errorTask?.cancel()
        inactiveTask?.cancel()
    }
}
