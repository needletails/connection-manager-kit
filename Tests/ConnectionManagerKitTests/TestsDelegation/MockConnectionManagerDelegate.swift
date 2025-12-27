//
//  MockConnectionManagerDelegate.swift
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

final class MockConnectionManagerDelegate: ConnectionManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _deliveredChannels: [String: NIOAsyncChannel<ByteBuffer, ByteBuffer>] = [:]
    private var _channelCreatedEvents: [String: AsyncStream<EventLoop>] = [:]
    private var _retrievedHandlers: [ChannelHandler] = []
    
    var deliveredChannels: [String: NIOAsyncChannel<ByteBuffer, ByteBuffer>] {
        lock.lock()
        defer { lock.unlock() }
        return _deliveredChannels
    }
    
    var channelCreatedEvents: [String: AsyncStream<EventLoop>] {
        lock.lock()
        defer { lock.unlock() }
        return _channelCreatedEvents
    }
    
    var retrievedHandlers: [ChannelHandler] {
        lock.lock()
        defer { lock.unlock() }
        return _retrievedHandlers
    }
    
    func retrieveChannelHandlers() -> [ChannelHandler] {
        lock.lock()
        defer { lock.unlock() }
        let handlers: [ChannelHandler] = [
            LengthFieldPrepender(lengthFieldBitLength: .threeBytes),
            ByteToMessageHandler(LengthFieldBasedFrameDecoder(lengthFieldBitLength: .threeBytes), maximumBufferSize: 16_777_216)
        ]
        _retrievedHandlers = handlers
        return handlers
    }
    
    func deliverChannel(_ channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>, manager: ConnectionManager<ByteBuffer, ByteBuffer>, cacheKey: String) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            _deliveredChannels[cacheKey] = channel
            continuation.resume()
        }
    }
    
    func channelCreated(_ eventLoop: EventLoop, cacheKey: String) async {
        let stream = AsyncStream<EventLoop> { continuation in
            continuation.yield(eventLoop)
            continuation.onTermination = { @Sendable _ in
                self._channelCreatedEvents.removeValue(forKey: cacheKey)
            }
        }
        _channelCreatedEvents[cacheKey] = stream
    }
    
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        _deliveredChannels.removeAll()
        _channelCreatedEvents.removeAll()
        _retrievedHandlers.removeAll()
    }
}
