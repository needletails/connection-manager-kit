//
//  ServerChildChannelService.swift
//  connection-manager-kit
//
//  Created by Cole M on 12/2/24.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//  This file is part of the ConnectionManagerKit Project

import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOHTTP1
import NIOWebSocket
import ServiceLifecycle
import NeedleTailLogger
import AsyncAlgorithms

// Add to ConnectionListener without breaking existing API
public struct WebSocketUpgradeConfig: Sendable {
    public let subprotocols: [String]
    public let customHeaders: HTTPHeaders
    public let minNonFinalFragmentSize: Int
    public let maxAccumulatedFrameCount: Int
    public let maxAccumulatedFrameSize: Int
    public let maxFrameSize: Int
    
    public init(
        subprotocols: [String] = [],
        customHeaders: HTTPHeaders = HTTPHeaders(),
        minNonFinalFragmentSize: Int = 0,
        maxAccumulatedFrameCount: Int = Int.max,
        maxAccumulatedFrameSize: Int = Int.max,
        maxFrameSize: Int = 1 << 14
    ) {
        self.subprotocols = subprotocols
        self.customHeaders = customHeaders
        self.minNonFinalFragmentSize = minNonFinalFragmentSize
        self.maxAccumulatedFrameCount = maxAccumulatedFrameCount
        self.maxAccumulatedFrameSize = maxAccumulatedFrameSize
        self.maxFrameSize = maxFrameSize
    }
}

public protocol WebSocketUpgrader: Sendable {
    associatedtype Inbound: Sendable
    associatedtype Outbound: Sendable
    
    func upgradeWebSocket(channel: Channel, configuration: WebSocketUpgradeConfig?) -> EventLoopFuture<EventLoopFuture<NIOAsyncChannel<Inbound, Outbound>>>
}

extension WebSocketUpgrader {
        
    public func upgradeWebSocket(channel: Channel, configuration: WebSocketUpgradeConfig?) -> EventLoopFuture<EventLoopFuture<NIOAsyncChannel<Inbound, Outbound>>> {
            return channel.eventLoop.makeCompletedFuture {
                
                guard let configuration else {
                    throw ServerServiceErrors.websocketUpgradeFailed
                }
                let upgrader = NIOTypedWebSocketServerUpgrader<NIOAsyncChannel<Inbound, Outbound>>(
                    maxFrameSize: configuration.maxFrameSize,
                    shouldUpgrade: { channel, head in
                        channel.eventLoop.makeSucceededFuture(configuration.customHeaders)
                    },
                    upgradePipelineHandler: { channel, handler in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(
                                NIOWebSocketFrameAggregator(
                                    minNonFinalFragmentSize: configuration.minNonFinalFragmentSize,
                                    maxAccumulatedFrameCount: configuration.maxAccumulatedFrameCount,
                                    maxAccumulatedFrameSize: configuration.maxAccumulatedFrameSize))
                            
                            let asyncChannel = try NIOAsyncChannel<Inbound, Outbound>(
                                wrappingChannelSynchronously: channel,
                                configuration: .init(isOutboundHalfClosureEnabled: true)
                            )
                            return asyncChannel
                        }
                    }
                )
                
                let serverUpgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration(
                    upgraders: [upgrader],
                    notUpgradingCompletionHandler: { channel in
                        return channel.eventLoop.makeCompletedFuture {
                            return try NIOAsyncChannel<Inbound, Outbound>(
                                wrappingChannelSynchronously: channel)
                        }
                    })
                
                var upgradeConfiguration = NIOUpgradableHTTPServerPipelineConfiguration<NIOAsyncChannel<Inbound, Outbound>>(upgradeConfiguration: serverUpgradeConfiguration)
                upgradeConfiguration.enablePipelining = false
                upgradeConfiguration.enableResponseHeaderValidation = false
                
                let negotiationResultFuture = try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                    configuration: upgradeConfiguration
                )
                return negotiationResultFuture
            }
        }
}

enum ServerServiceErrors: Error {
    case tlsNotConfigured, websocketUpgradeFailed
}


actor ServerService<Inbound: Sendable, Outbound: Sendable>: Service, WebSocketUpgrader {
    
    private let address: SocketAddress
    private let configuration: Configuration
    private let delegate: ChildChannelServiceDelegate
    private let logger: NeedleTailLogger
    private var contextDelegates: [String: ChannelContextDelegate] = [:]
    private var channelContexts = [ChannelContext<Inbound, Outbound>]()
    private var inboundContinuations: [String: AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.Continuation] = [:]
    private var outboundContinuations: [String: AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.Continuation] = [:]
    private weak var listenerDelegate: ListenerDelegate?
    nonisolated(unsafe) private weak var serviceListenerDelegate: ServiceListenerDelegate?

    private var listeningChannel: Channel?
    
    // Optimization: Add connection management
    private var activeConnections = 0
    private var maxConcurrentConnections: Int = 1000
    
    private var createWebsocketServer: Bool = false
    nonisolated(unsafe) internal var websocketConfiguration: WebSocketUpgradeConfig?
    
    public func setContextDelegate(_ contextDelegate: ChannelContextDelegate, key: String) async {
        self.contextDelegates[key] = contextDelegate
    }
    
    init(
        websocketConfiguration: WebSocketUpgradeConfig? = nil,
        address: SocketAddress,
        configuration: Configuration,
        logger: NeedleTailLogger,
        delegate: ChildChannelServiceDelegate,
        listenerDelegate: ListenerDelegate?,
        serviceListenerDelegate: ServiceListenerDelegate?,
        maxConcurrentConnections: Int = 1000
    ) {
        if let websocketConfiguration {
            self.createWebsocketServer = true
            self.websocketConfiguration = websocketConfiguration
        }
        self.address = address
        self.configuration = configuration
        self.logger = logger
        self.delegate = delegate
        self.listenerDelegate = listenerDelegate
        self.serviceListenerDelegate = serviceListenerDelegate
        self.maxConcurrentConnections = maxConcurrentConnections
    }
    
    func run() async throws {
        try await executeTask()
    }
    
    private func executeTask() async throws {
        do {
            if createWebsocketServer {
                let serverChannel = try await createWebSocketChannel()
                self.listeningChannel = serverChannel.channel
                
                await listenerDelegate?.didBindWebSocketServer(channel: serverChannel)
                
                    try await serverChannel.executeThenClose { @Sendable inbound in
                        try await withThrowingDiscardingTaskGroup { group in
                        for try await childChannelFuture in inbound.cancelOnGracefulShutdown() {
                            let childChannel = try await childChannelFuture.get()
                            guard await canAcceptConnection() else {
                                logger.log(level: .warning, message: "Connection limit reached, rejecting new connection")
                                try? await childChannel.channel.close()
                                continue
                            }
                            
                            // Accept connection and increment counter
                            await incrementActiveConnections()
                            
                            // Each accepted channel is owned by one child task.
                            group.addTask { [weak self] in
                                guard let self else { return }
                                await self.handleChildChannelWithRecovery(childChannel)
                            }
                        }
                    }
                }
                
            } else {
                let serverChannel = try await createTCPServerChannel()
                self.listeningChannel = serverChannel.channel
                
                // Notify listener delegate
                await listenerDelegate?.didBindTCPServer(channel: serverChannel)
                
                // Handle child channels with improved concurrency
                try await handleChildChannelsOptimized(serverChannel: serverChannel)
            }
            
        } catch {
            logger.log(level: .error, message: "Server service failed: \(error)")
            throw error
        }
    }

    /// Applies adopter-supplied TCP options to accepted child channels
    /// (`Configuration.transportOptions`), e.g. dead-peer detection so a
    /// client whose path silently died does not keep a "registered" session
    /// with a live writer — traffic routed to such a session bypasses
    /// offline spooling.
    private static func withTransportOptions(
        _ bootstrap: ServerBootstrap,
        options: TCPTransportOptions
    ) -> ServerBootstrap {
        var bootstrap = bootstrap
        for option in options.socketOptions {
            bootstrap = bootstrap.childChannelOption(
                ChannelOptions.socket(
                    SocketOptionLevel(option.level), SocketOptionName(option.name)),
                value: SocketOptionValue(option.value))
        }
        return bootstrap
    }

    private func createWebSocketChannel() async throws -> NIOAsyncChannel<EventLoopFuture<NIOAsyncChannel<Inbound, Outbound>>, Never> {
        return try await Self.withTransportOptions(ServerBootstrap(group: configuration.group)
        // Optimized server channel options
            .serverChannelOption(ChannelOptions.backlog, value: Int32(configuration.backlog))
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        // Optimized child channel options
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
            .childChannelOption(ChannelOptions.autoRead, value: true),
            options: configuration.transportOptions)
            .bind(to: address, childChannelInitializer: { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(ServerServiceErrors.websocketUpgradeFailed)
                }
                    return upgradeWebSocket(channel: channel, configuration: websocketConfiguration)
            })
        
    }
    
    private func createTCPServerChannel() async throws -> NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never> {
        return try await Self.withTransportOptions(ServerBootstrap(group: configuration.group)
        // Optimized server channel options
            .serverChannelOption(ChannelOptions.backlog, value: Int32(configuration.backlog))
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        // Optimized child channel options
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
            .childChannelOption(ChannelOptions.autoRead, value: true),
            options: configuration.transportOptions)
            .bind(to: address, childChannelInitializer: { channel in
                channel.eventLoop.makeCompletedFuture {
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
    
    private func handleChildChannelsOptimized(
        serverChannel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>
    ) async throws {
        try await serverChannel.executeThenClose { @Sendable inbound in
            // Use optimized task group for better concurrency
            try await withThrowingDiscardingTaskGroup { group in
                for try await childChannel in inbound.cancelOnGracefulShutdown() {
                    // Check connection limits before accepting
                    guard await canAcceptConnection() else {
                        logger.log(level: .warning, message: "Connection limit reached, rejecting new connection")
                        try? await childChannel.channel.close()
                        continue
                    }
                    
                    // Accept connection and increment counter
                    await incrementActiveConnections()
                    
                    // Each accepted channel is owned by one child task.
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.handleChildChannelWithRecovery(childChannel)
                    }
                }
            }
        }
    }
    
    private func handleChildChannelWithRecovery(_ childChannel: NIOAsyncChannel<Inbound, Outbound>) async {
        let channelId = UUID().uuidString
        
        do {
            try await self.handleChildChannel(
                childChannel: childChannel,
                channelId: channelId
            )
            
        } catch {
            logger.log(level: .error, message: "Child channel \(channelId) failed: \(error)")
        }
        
        decrementActiveConnections()
        removeChildChannelState(id: channelId)
        await delegate.childChannelDidClose(id: channelId)
    }
    
    private func canAcceptConnection() async -> Bool {
        // Simple connection limit check
        return activeConnections < maxConcurrentConnections
    }
    
    private func incrementActiveConnections() {
        activeConnections += 1
    }
    
    private func decrementActiveConnections() {
        activeConnections = max(0, activeConnections - 1)
    }
    
    private func stopTLS(from id: String) async {
        guard let childChannel = self.channelContexts.first(where: { $0.id == id })?.channel else {
            return
        }
        let channel = childChannel.channel
        let stopPromise: EventLoopPromise<Void> = channel.eventLoop.makePromise()

        channel.pipeline.handler(type: NIOSSLServerHandler.self).whenComplete { result in
            switch result {
            case .success(let tlsHandler):
                tlsHandler.stopTLS(promise: stopPromise)
            case .failure(let error):
                stopPromise.fail(error)
            }
        }

        do {
            try await stopPromise.futureResult.get()
        } catch {
            logger.log(level: .trace, message: "There was a problem stopping TLS \(error)")
        }
    }
    
    func shutdownChildChannel(id: String) async {
        await self.stopTLS(from: id)
        if let context = channelContexts.first(where: { $0.id == id }) {
            try? await context.channel.channel.close()
        }
        self.inboundContinuations[id]?.finish()
        self.outboundContinuations[id]?.finish()
        removeChildChannelState(id: id)
    }

    private func removeChildChannelState(id: String) {
        self.inboundContinuations.removeValue(forKey: id)
        self.outboundContinuations.removeValue(forKey: id)
        self.channelContexts.removeAll(where: { $0.id == id })
        self.contextDelegates.removeValue(forKey: id)
    }

    private func noteMissingContextDelegateDrop(channelId: String, path: String) {
        logger.log(level: .error, message: "No context delegate for child channel; dropping \(path)", metadata: [
            "channelId": "\(channelId)"
        ])
    }
    
    func shutdown() async throws {
        let contexts = channelContexts
        for context in contexts {
            await stopTLS(from: context.id)
            try? await context.channel.channel.close()
        }

        for continuation in inboundContinuations.values {
            continuation.finish()
        }
        for continuation in outboundContinuations.values {
            continuation.finish()
        }

        inboundContinuations.removeAll()
        outboundContinuations.removeAll()
        contextDelegates.removeAll()
        channelContexts.removeAll()

        if let listeningChannel, listeningChannel.isActive {
            try await listeningChannel.close()
        }
        listeningChannel = nil
        
        logger.log(level: .info, message: "Server service shutdown complete")
    }
    
    nonisolated func handleChildChannel(
        childChannel: NIOAsyncChannel<Inbound, Outbound>,
        channelId: String
    ) async throws {
        try await childChannel.executeThenClose { inbound, outbound in
            try await withThrowingDiscardingTaskGroup { group in
                do {
                    let channelContext = ChannelContext(
                        id: channelId,
                        channel: childChannel)
                    await appendContext(channelContext)
                    await delegate.initializedChildChannel(channelContext)
                    
                    let (_outbound, outboundContinuation) = AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.makeStream()
                    await setOutboundContinuation(outboundContinuation, id: channelId)
                    outboundContinuation.onTermination = { [weak self] status in
#if DEBUG
                        guard let self else { return }
                        self.logger.log(level: .trace, message: "Server Writer Stream Terminated with status: \(status)")
#endif
                    }
                    
                    let (_inbound, inboundContinuation) = AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.makeStream()
                    await setInboundContinuation(inboundContinuation, id: channelId)
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
                                id: channelId,
                                channel: childChannel,
                                writer: writer)
                            if let contextDelegate = await contextDelegates[channelId] {
                                await contextDelegate.deliverWriter(context: writerContext)
                            } else {
                                await noteMissingContextDelegateDrop(channelId: channelId, path: "writer")
                            }
                        }
                    }
                    
                    for await stream in _inbound {
                        // Serial in-order delivery per connection (do not parallelize messages).
                        for try await inbound in stream.cancelOnGracefulShutdown() {
                            let streamContext = StreamContext(
                                id: channelId,
                                channel: childChannel,
                                inbound: inbound)
                            if let contextDelegate = await contextDelegates[channelId] {
                                await contextDelegate.deliverInboundBuffer(context: streamContext)
                            } else {
                                await noteMissingContextDelegateDrop(channelId: channelId, path: "inbound")
                            }
                        }
                        inboundContinuation.finish()
                        outboundContinuation.finish()
                        // Ensure the outbound writer is finished to prevent memory leaks
                        outbound.finish()
                        if let contextDelegate = await contextDelegates[channelId] {
                            await contextDelegate.didShutdownChildChannel()
                        }
                        return
                    }
                    
                } catch {
                    // Ensure outbound writer is finished even on error
                    outbound.finish()
                    if let contextDelegate = await contextDelegates[channelId] {
                        await contextDelegate.reportChildChannel(error: error, id: channelId)
                    } else {
                        await noteMissingContextDelegateDrop(channelId: channelId, path: "error")
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
