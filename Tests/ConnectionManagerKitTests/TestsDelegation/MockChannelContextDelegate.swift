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
    enum Errors: Error {
        case writerUnavailable
    }
    
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
                break
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
    
    func send(_ buffer: ByteBuffer) async throws {
        guard let writer else {
            throw Errors.writerUnavailable
        }
        try await writer.write(buffer)
    }

    func waitForWriter(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if writer != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return writer != nil
    }
    
    func deliverInboundBuffer<Inbound: Sendable, Outbound: Sendable>(context: StreamContext<Inbound, Outbound>) async {
        responseStream.continuation.yield(context.inbound as! ByteBuffer)
    }
    
    private func tearDown() async {
        networkEventTask?.cancel()
        errorTask?.cancel()
        inactiveTask?.cancel()
    }
}
