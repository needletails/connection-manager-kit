//
//  ServerChildChannelService.swift
//  connection-manager-kit
//
//  Created by Cole M on 12/2/24.
//
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOExtras
import ServiceLifecycle
import NeedleTailLogger

actor ServerChildChannelService<Inbound: Sendable, Outbound: Sendable>: Service {
    
    let address: SocketAddress
    let configuration: Configuration
    let delegate: ChildChannelServiceDelelgate
    let logger: NeedleTailLogger
    var listenerDelegate: ListenerDelegate?
    var contextDelegates: [String: ChannelContextDelegate] = [:]
    var inboundContinuation: [String: AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.Continuation] = [:]
    var outboundContinuation: [String: AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.Continuation] = [:]
    private var sslHandler: NIOSSLHandler?

    func setSSLHandler(_ sslHandler: NIOSSLHandler) async {
        self.sslHandler = sslHandler
    }

    public func setContextDelegate(_ contextDelegate: ChannelContextDelegate, key: String) async {
        self.contextDelegates[key] = contextDelegate
    }
    
    init(
        address: SocketAddress, 
        configuration: Configuration,
        logger: NeedleTailLogger,
        delegate: ChildChannelServiceDelelgate,
        listenerDelegate: ListenerDelegate?
    ) {
        self.address = address
        self.configuration = configuration
        self.logger = logger
        self.delegate = delegate
        self.listenerDelegate = listenerDelegate
    }
    
    func run() async throws {
        try await executeTask()
    }
    
    nonisolated private func executeTask() async throws {
        let serverChannel = try await bindServer(address: address, configuration: configuration)
         if let sslHandler = await self.sslHandler {
            await self.logger.log(level: .info, message: "Supporting Secure Connections \(sslHandler)")
        }
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

        func bindServer(
        address: SocketAddress,
        configuration: Configuration
    ) async throws -> NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never> {
          let sslHandler = self.sslHandler
        return try await ServerBootstrap(group: configuration.group)
        // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: Int32(configuration.backlog))
        // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .bind(to: address, childChannelInitializer: { channel in
                return channel.eventLoop.makeCompletedFuture {
                    
                    if let sslHandler = sslHandler {
                        try channel.pipeline.syncOperations.addHandler(sslHandler)
                    }

                    try channel.pipeline.syncOperations.addHandlers([
                        LengthFieldPrepender(lengthFieldBitLength: .threeBytes),
                        ByteToMessageHandler(
                            LengthFieldBasedFrameDecoder(lengthFieldBitLength: .threeBytes),
                            maximumBufferSize: 16777216
                        ),
                    ])
                    return try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                }
            })
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
                for try await childChannel in inbound {
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
                for try await childChannel in inbound {
                    // For each new client that connects to the server, create a new group for that handler
                    group.addTask {
                        try await childChannelCompletion(childChannel)
                    }
                }
            }
        }
    }
    
    func shutdownChildChannel(id: String) async {
        self.inboundContinuation[id]?.finish()
        self.outboundContinuation[id]?.finish()
        self.inboundContinuation.removeValue(forKey: id)
        self.outboundContinuation.removeValue(forKey: id)
        contextDelegates.removeValue(forKey: id)
    }
    
    
    nonisolated func handleChildChannel(childChannel: NIOAsyncChannel<Inbound, Outbound>) async throws {
        try await childChannel.executeThenClose { inbound, outbound in
            try await withThrowingDiscardingTaskGroup { group in
                let channelId = UUID()
                do {
                    let channelContext = ChannelContext(
                        id: channelId.uuidString,
                        channel: childChannel)
                    await delegate.initializedChildChannel(channelContext)
                    
                    let (_outbound, outboundContinuation) = AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.makeStream()
                    await setOutboundContinuation(outboundContinuation, id: channelId.uuidString)
                    outboundContinuation.onTermination = { status in
#if DEBUG
                        print("Server Writer Stream Terminated with status: \(status)")
#endif
                    }
                    
                    let (_inbound, inboundContinuation) = AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.makeStream()
                    await setInboundContinuation(inboundContinuation, id: channelId.uuidString)
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
                        for try await inbound in stream {
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
            await logger.log(level: .info, message: "Finishing Child Channel")
        }
        await logger.log(level: .info, message: "Is Channel Active: \(childChannel.channel.isActive)")
    }
    
    func setInboundContinuation(_ continuation: AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.Continuation, id: String) async {
        self.inboundContinuation[id] = continuation
    }
    
    func setOutboundContinuation(_ continuation: AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.Continuation, id: String) async {
        self.outboundContinuation[id] = continuation
    }
}
