//
//  ServerChildChannelService.swift
//  connection-manager-kit
//
//  Created by Cole M on 12/2/24.
//
import Foundation
import NIOCore
import ServiceLifecycle

actor ServerChildChannelService<Inbound: Sendable, Outbound: Sendable>: Service {
    
    let serverChannel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>
    let delegate: ChildChannelServiceDelelgate
    var listenerDelegate: ListenerDelegate?
    var contextDelegates: [String: ChannelContextDelegate] = [:]
    var inboundContinuation: AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.Continuation?
    var outboundContinuation: AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.Continuation?
    
    
    public func setContextDelegate(_ contextDelegate: ChannelContextDelegate, key: String) async {
        self.contextDelegates[key] = contextDelegate
    }
    
    init(
        serverChannel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>,
        delegate: ChildChannelServiceDelelgate,
        listenerDelegate: ListenerDelegate?
    ) {
        self.serverChannel = serverChannel
        self.delegate = delegate
        self.listenerDelegate = listenerDelegate
    }
    
    func run() async throws {
        try await executeTask()
    }
    
    nonisolated private func executeTask() async throws {
        
        let serverChannelInTaskGroup = try await encapsulatedServerChannelInTaskGroup(serverChannel: serverChannel)
        await self.listenerDelegate?.didBindServer(channel: serverChannel)
        try await handleChildTaskGroup(serverChannel: serverChannelInTaskGroup) { childChannel in
            do {
                try await self.handleChildChannel(childChannel: childChannel)
            } catch {
                try await childChannel.executeThenClose { inbound, outbound in
                    outbound.finish()
                }
            }
        }
    }
    
    func encapsulatedServerChannelInTaskGroup(
        serverChannel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>
    ) async throws -> NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never> {
        try await withThrowingTaskGroup(of: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>.self) { group in
            group.addTask {
                await withTaskGroup(of: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>.self) { _ in
                    return serverChannel
                }
            }
            return try await group.next()!
        }
    }
    
    
    func handleChildTaskGroup(
        serverChannel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>,
        inboundChannelCompletion: @Sendable @escaping () async throws -> Void,
        childChannelCompletion: @Sendable @escaping (NIOAsyncChannel<Inbound, Outbound>) async throws -> Void
    ) async throws {
        try await serverChannel.executeThenClose { inbound in
            try await inboundChannelCompletion()
            // Create a group for the child channel
            try await withThrowingDiscardingTaskGroup { group in
                for try await childChannel in inbound.cancelOnGracefulShutdown() {
                    // For each new client that connects to the server, create a new group for that handler
                    group.addTask {
                        try await childChannelCompletion(childChannel)
                    }
                }
            }
        }
    }
    
    func handleChildTaskGroup(
        serverChannel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>,
        childChannelCompletion: @Sendable @escaping (NIOAsyncChannel<Inbound, Outbound>) async throws -> Void
    ) async throws {
        try await serverChannel.executeThenClose { inbound in
            // Create a group for the child channel
            try await withThrowingDiscardingTaskGroup { group in
                for try await childChannel in inbound.cancelOnGracefulShutdown() {
                    // For each new client that connects to the server, create a new group for that handler
                    group.addTask {
                        try await childChannelCompletion(childChannel)
                    }
                }
            }
        }
    }
    
    func shutdownChildChannel(id: String) async {
        self.inboundContinuation?.finish()
        self.outboundContinuation?.finish()
        contextDelegates.removeValue(forKey: id)
    }
    
    
    nonisolated func handleChildChannel(childChannel: NIOAsyncChannel<Inbound, Outbound>) async throws {
        try await childChannel.executeThenClose { inbound, outbound in
            try await withThrowingDiscardingTaskGroup { group in
                
                let channelId = UUID()
                let channelContext = ChannelContext(
                    id: channelId.uuidString,
                    channel: childChannel)
                await delegate.initializedChildChannel(channelContext)

                do {
                    let (_outbound, outboundContinuation) = AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.makeStream()
                    await setOutboundContinuation(outboundContinuation)
                    outboundContinuation.onTermination = { status in
#if DEBUG
                        print("Server Writer Stream Terminated with status: \(status)")
#endif
                    }
                    
                    let (_inbound, inboundContinuation) = AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.makeStream()
                    await setInboundContinuation(inboundContinuation)
                    inboundContinuation.onTermination = { status in
#if DEBUG
                        print("Server Inbound Stream Terminated with status: \(status)")
#endif
                        outboundContinuation.finish()
                    }
                    
                    outboundContinuation.yield(outbound)
                    inboundContinuation.yield(inbound)
                    
                    _ = group.addTaskUnlessCancelled { [weak self] in
                        guard let self else { return }
                        for await writer in _outbound {
                            let writerContext = WriterContext(
                                id: channelId.uuidString,
                                channel: childChannel,
                                writer: writer)
                            if let contextDelegate = await contextDelegates[channelId.uuidString] {
                                await contextDelegate.deliverWriter(context: writerContext)
                            }
                        }
                    }
                    
                    for await stream in _inbound {
                        for try await inbound in stream.cancelOnGracefulShutdown() {
                            group.addTask { [weak self] in
                                guard let self else { return }
                                let streamContext = StreamContext(
                                    id: channelId.uuidString,
                                    channel: childChannel,
                                    inbound: inbound)
                                if let contextDelegate = await contextDelegates[channelId.uuidString] {
                                    await contextDelegate.deliverInboundBuffer(context: streamContext)
                                }
                            }
                        }
                        inboundContinuation.finish()
                        outboundContinuation.finish()
                        if let contextDelegate = await contextDelegates[channelId.uuidString] {
                            await contextDelegate.shutdownChildConfiguration()
                        }
                        return
                    }
                    
                } catch {
                    if let contextDelegate = await contextDelegates[channelId.uuidString] {
                        await contextDelegate.reportChildChannel(error: error)
                    }
                }
            }
        }
    }
    
    func setInboundContinuation(_ continuation: AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.Continuation) async {
        self.inboundContinuation = continuation
    }
    
    func setOutboundContinuation(_ continuation: AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.Continuation) async {
        self.outboundContinuation = continuation
    }
}
