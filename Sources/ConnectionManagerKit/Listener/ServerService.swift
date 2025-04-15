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

actor ServerService<Inbound: Sendable, Outbound: Sendable>: Service {
    
    private let address: SocketAddress
    private let configuration: Configuration
    private let delegate: ChildChannelServiceDelelgate
    private let logger: NeedleTailLogger
    private var contextDelegates: [String: ChannelContextDelegate] = [:]
    private var channelContexts = [ChannelContext<Inbound, Outbound>]()
    private var inboundContinuations: [String: AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.Continuation] = [:]
    private var outboundContinuations: [String: AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.Continuation] = [:]
    private weak var listenerDelegate: ListenerDelegate?
    nonisolated(unsafe) private weak var serviceListenerDelegate: ServiceListenerDelegate?
    nonisolated(unsafe) private var serverChannel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>?

    public func setContextDelegate(_ contextDelegate: ChannelContextDelegate, key: String) async {
        self.contextDelegates[key] = contextDelegate
    }
    
    init(
        address: SocketAddress, 
        configuration: Configuration,
        logger: NeedleTailLogger,
        delegate: ChildChannelServiceDelelgate,
        listenerDelegate: ListenerDelegate?,
        serviceListenerDelegate: ServiceListenerDelegate?
    ) {
        self.address = address
        self.configuration = configuration
        self.logger = logger
        self.delegate = delegate
        self.listenerDelegate = listenerDelegate
        self.serviceListenerDelegate = serviceListenerDelegate
    }
    
    func run() async throws {
        try await executeTask()
    }
    
    nonisolated func executeTask() async throws {
        let serverChannel = try await bindServer(address: address, configuration: configuration)
        self.serverChannel = serverChannel
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
        return try await ServerBootstrap(group: configuration.group)
        // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: Int32(configuration.backlog))
        // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .bind(to: address, childChannelInitializer: { channel in
                return channel.eventLoop.makeCompletedFuture {
                    
                    if let sslHandler = self.serviceListenerDelegate?.retrieveSSLHandler() {
                        try channel.pipeline.syncOperations.addHandler(sslHandler)
                    }
                    
                    if let channelHandlers = self.serviceListenerDelegate?.retrieveChannelHandlers(), !channelHandlers.isEmpty {
                        try channel.pipeline.syncOperations.addHandlers(channelHandlers)
                    }
        
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
    
    private func stopTLS(from id: String) async {
        if let childChannel = self.channelContexts.first(where: { $0.id == id })?.channel {
            let stopPromise: EventLoopPromise<Void> = childChannel.channel.eventLoop.makePromise()
            do {
                let tlsHandler = try await childChannel.channel.pipeline.handler(type: NIOSSLServerHandler.self).get()
                tlsHandler.stopTLS(promise: stopPromise)
                stopPromise.futureResult.whenComplete { result in
                    switch result {
                    case .success(_):
                        stopPromise.succeed()
                    case .failure(let error):
                        stopPromise.fail(error)
                    }
                }
            } catch {
                stopPromise.fail(error)
                logger.log(level: .trace, message: "There was a problem stopping TLS \(error)")
            }
        }
    }
    
    func shutdownChildChannel(id: String) async {
        await self.stopTLS(from: id)
        self.inboundContinuations[id]?.finish()
        self.outboundContinuations[id]?.finish()
        self.inboundContinuations.removeValue(forKey: id)
        self.outboundContinuations.removeValue(forKey: id)
        self.channelContexts.removeAll(where: { $0.id == id })
        self.contextDelegates.removeValue(forKey: id)
    }
    
    func shutdown() async throws {
        for context in channelContexts {
            await stopTLS(from: context.id)
        }
        for continuation in inboundContinuations {
            continuation.value.finish()
        }
        for continuation in outboundContinuations {
            continuation.value.finish()
        }
        inboundContinuations.removeAll()
        outboundContinuations.removeAll()
        contextDelegates.removeAll()
        channelContexts.removeAll()
        try await serverChannel?.executeThenClose({_,_ in })
    }
    
    
    nonisolated func handleChildChannel(childChannel: NIOAsyncChannel<Inbound, Outbound>) async throws {
        try await childChannel.executeThenClose { inbound, outbound in
            try await withThrowingDiscardingTaskGroup { group in
                let channelId = UUID()
                do {
                    let channelContext = ChannelContext(
                        id: channelId.uuidString,
                        channel: childChannel)
                    await appendContext(channelContext)
                    await delegate.initializedChildChannel(channelContext)
                    
                    let (_outbound, outboundContinuation) = AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.makeStream()
                    await setOutboundContinuation(outboundContinuation, id: channelId.uuidString)
                    outboundContinuation.onTermination = { [weak self] status in
#if DEBUG
                        guard let self else { return }
                        self.logger.log(level: .trace, message: "Server Writer Stream Terminated with status: \(status)")
#endif
                    }
                    
                    let (_inbound, inboundContinuation) = AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.makeStream()
                    await setInboundContinuation(inboundContinuation, id: channelId.uuidString)
                    inboundContinuation.onTermination = { [weak self] status in
#if DEBUG
                        guard let self else { return }
                        self.logger.log(level: .trace, message: "Server Inbound Stream Terminated with status: \(status)")
#endif
                        outboundContinuation.finish()
                    }
                    
                    outboundContinuation.yield(outbound)
                    inboundContinuation.yield(inbound)
                    
                    _ = group.addTaskUnlessCancelled { [weak self] in
                        guard let self else { return }
                        for await writer in _outbound.cancelOnGracefulShutdown() {
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
                            await contextDelegate.didShutdownChildChannel()
                        }
                        return
                    }
                    
                } catch {
                    if let contextDelegate = await contextDelegates[channelId.uuidString] {
                        await contextDelegate.reportChildChannel(error: error, id: channelId.uuidString)
                    }
                }
            }
        }
    }
    
    func appendContext(_ context: ChannelContext<Inbound, Outbound>) async {
        self.channelContexts.append(context)
    }
    
    func setInboundContinuation(_ continuation: AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.Continuation, id: String) async {
        self.inboundContinuations[id] = continuation
    }
    
    func setOutboundContinuation(_ continuation: AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.Continuation, id: String) async {
        self.outboundContinuations[id] = continuation
    }
}
