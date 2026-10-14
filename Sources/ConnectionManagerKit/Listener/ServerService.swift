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
                        // A plain HTTP request has no place on a WebSocket listener. The
                        // pipeline is still HTTP here, so wrapping it as a
                        // `NIOAsyncChannel<Inbound, Outbound>` would fatal-error on the
                        // first read (`HTTPPart` is not `Inbound`). Answer 426 and close;
                        // the accept loop treats the failed future as a rejected peer.
                        var headers = HTTPHeaders()
                        headers.add(name: "Connection", value: "close")
                        headers.add(name: "Upgrade", value: "websocket")
                        headers.add(name: "Content-Length", value: "0")
                        let head = HTTPResponseHead(version: .http1_1, status: .upgradeRequired, headers: headers)
                        channel.write(HTTPServerResponsePart.head(head), promise: nil)
                        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                            channel.close(promise: nil)
                        }
                        return channel.eventLoop.makeFailedFuture(ServerServiceErrors.nonWebSocketRequestRejected)
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
    /// A client spoke plain HTTP to a WebSocket listener; it was answered with 426 and closed.
    case nonWebSocketRequestRejected
}


actor ServerService<Inbound: Sendable, Outbound: Sendable>: Service, WebSocketUpgrader {
    
    private let address: SocketAddress
    private let configuration: Configuration
    private let delegate: ChildChannelServiceDelegate
    private let logger: NeedleTailLogger
    private var contextDelegates: [String: ChannelContextDelegate] = [:]
    private var channelContexts = [ChannelContext<Inbound, Outbound>]()
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
                            guard await canAcceptConnection() else {
                                logger.log(level: .warning, message: "Connection limit reached, rejecting new connection")
                                // The upgrade may still be in flight; close whatever it produces.
                                childChannelFuture.whenSuccess { $0.channel.close(promise: nil) }
                                continue
                            }
                            
                            // The slot is taken while the handshake is pending so the
                            // limit cannot be exceeded by many simultaneous upgrades.
                            await incrementActiveConnections()
                            
                            // Await the handshake inside the child task: a peer that
                            // disconnects, sends garbage, or speaks plain HTTP fails only
                            // its own future. Awaiting it in the accept loop killed the
                            // whole listener and head-of-line blocked every other accept.
                            group.addTask { [weak self] in
                                guard let self else { return }
                                let childChannel: NIOAsyncChannel<Inbound, Outbound>
                                do {
                                    // `.get()` ignores cancellation and left this task running
                                    // after the listener had shut down. A handshake that finishes
                                    // afterward closes its channel.
                                    childChannel = try await CancellableFuture.resolve(childChannelFuture) { channel in
                                        channel.channel.close(promise: nil)
                                    }
                                } catch {
                                    await self.upgradeDidFail(error)
                                    return
                                }
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
            .bind(to: address, childChannelInitializer: { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    if let sslHandler = self?.serviceListenerDelegate?.retrieveSSLHandler() {
                        try channel.pipeline.syncOperations.addHandler(sslHandler)
                    }
                    if let channelHandlers = self?.serviceListenerDelegate?.retrieveChannelHandlers(), !channelHandlers.isEmpty {
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
    
    /// A WebSocket handshake failed before a child channel existed; release the
    /// slot reserved in the accept loop.
    private func upgradeDidFail(_ error: Error) {
        decrementActiveConnections()
        if case ServerServiceErrors.nonWebSocketRequestRejected = error {
            logger.log(level: .info, message: "Rejected plain HTTP request on WebSocket listener")
            return
        }
        guard !(error is CancellationError) else { return }
        logger.log(level: .debug, message: "WebSocket upgrade failed: \(error)")
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
            try await stopPromise.futureResult.getAbandoningOnCancel()
        } catch is CancellationError {
            return
        } catch {
            logger.log(level: .trace, message: "There was a problem stopping TLS \(error)")
        }
    }
    
    func shutdownChildChannel(id: String) async {
        await self.stopTLS(from: id)
        if let context = channelContexts.first(where: { $0.id == id }) {
            context.channel.channel.close(promise: nil)
        }
        self.outboundContinuations[id]?.finish()
        removeChildChannelState(id: id)
    }

    private func removeChildChannelState(id: String) {
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
            context.channel.channel.close(promise: nil)
        }

        for continuation in outboundContinuations.values {
            continuation.finish()
        }

        outboundContinuations.removeAll()
        contextDelegates.removeAll()
        channelContexts.removeAll()

        // ServiceGroup / executeThenClose may already have closed the bind.
        // Awaiting close() here throws `alreadyClosed` on POSIX NIO.
        listeningChannel?.close(promise: nil)
        listeningChannel = nil
        
        logger.log(level: .info, message: "Server service shutdown complete")
    }
    
    nonisolated func handleChildChannel(
        childChannel: NIOAsyncChannel<Inbound, Outbound>,
        channelId: String
    ) async throws {
        try await childChannel.executeThenClose { inbound, outbound in
            let channelContext = ChannelContext(
                id: channelId,
                channel: childChannel)
            await appendContext(channelContext)
            await delegate.initializedChildChannel(channelContext)
            
            // The writer is delivered through a stream so `shutdownChildChannel`
            // can finish it; inbound is iterated directly from `executeThenClose`
            // so a channel close or graceful shutdown ends the loop.
            let (writerStream, writerContinuation) = AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.makeStream()
            await setOutboundContinuation(writerContinuation, id: channelId)
            writerContinuation.yield(outbound)
            
            var runError: (any Error)?
            do {
                try await withThrowingDiscardingTaskGroup { group in
                    group.addTask { [weak self] in
                        guard let self else { return }
                        for await writer in writerStream.cancelOnGracefulShutdown() {
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
                    
                    // Serial in-order delivery per connection (do not parallelize messages).
                    for try await message in inbound.cancelOnGracefulShutdown() {
                        let streamContext = StreamContext(
                            id: channelId,
                            channel: childChannel,
                            inbound: message)
                        if let contextDelegate = await contextDelegates[channelId] {
                            await contextDelegate.deliverInboundBuffer(context: streamContext)
                        } else {
                            await noteMissingContextDelegateDrop(channelId: channelId, path: "inbound")
                        }
                    }
                    // Inbound ended: finish the writer stream so the delivery task exits
                    // and the group can complete. Without this the group waited forever.
                    writerContinuation.finish()
                }
            } catch {
                runError = error
            }
            
            // Runs on every exit path (peer close, decode error, cancellation) so an
            // errored connection releases its slot instead of pinning it forever.
            writerContinuation.finish()
            outbound.finish()
            let contextDelegate = await contextDelegates[channelId]
            if let runError, !(runError is CancellationError) {
                if let contextDelegate {
                    await contextDelegate.reportChildChannel(error: runError, id: channelId)
                } else {
                    await noteMissingContextDelegateDrop(channelId: channelId, path: "error")
                }
            }
            await contextDelegate?.didShutdownChildChannel()
            if let runError {
                throw runError
            }
        }
    }
    
    func appendContext(_ context: ChannelContext<Inbound, Outbound>) async {
        self.channelContexts.append(context)
    }
    
    func setOutboundContinuation(_ continuation: AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.Continuation, id: String) async {
        self.outboundContinuations[id] = continuation
    }
}
