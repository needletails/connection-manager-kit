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
import NIOConcurrencyHelpers
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
                            
                            let asyncChannel: NIOAsyncChannel<Inbound, Outbound> = try CancellableFuture.wrap(
                                channel,
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
    /// A child was accepted while the listener was shutting down; it was closed unwrapped.
    case listenerClosed
}


actor ServerService<Inbound: Sendable, Outbound: Sendable>: Service, WebSocketUpgrader {
    
    private let address: SocketAddress
    private let configuration: Configuration
    private let delegate: ChildChannelServiceDelegate
    private let logger: NeedleTailLogger
    private var contextDelegates: [String: ChannelContextDelegate] = [:]
    private var channelContexts = [ChannelContext<Inbound, Outbound>]()
    private var outboundContinuations: [String: AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.Continuation] = [:]
    /// Child channels the listener itself closed (`shutdownChildChannel` / `shutdown`).
    /// Their run loops end after the context delegate is gone, usually with
    /// `NIOSSLError.uncleanShutdown` when the peer answers our close_notify with a bare
    /// FIN; those errors are a consequence of the close, not a failure, and are logged
    /// at debug. An id is kept until that channel's run loop has returned.
    private var intentionalCloses: Set<String> = []
    private weak var listenerDelegate: ListenerDelegate?
    nonisolated(unsafe) private weak var serviceListenerDelegate: ServiceListenerDelegate?

    private var listeningChannel: Channel?
    /// Orders listener close against children still travelling from the child
    /// initializer to the accept loop (see `AcceptGate`).
    private let acceptGate = AcceptGate()
    /// Accepted WebSocket sockets whose HTTP upgrade has not completed. A peer that
    /// never sends an upgrade request would otherwise keep its accept task, and the
    /// listener's `run()`, alive forever after shutdown.
    private let pendingHandshakes = NIOLockedValueBox<[ObjectIdentifier: Channel]>([:])

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
                
                try await runAcceptLoop(serverChannel) { [self] inbound, stopped in
                    // Once this loop is gone nothing can own a delivered child; reject late ones.
                    defer { acceptGate.close() }
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await childChannelFuture in inbound {
                            acceptGate.endDelivery()
                            guard await canAcceptConnection() else {
                                logger.log(level: .warning, message: "Connection limit reached, rejecting new connection")
                                // The upgrade may still be in flight; finish and close whatever it produces.
                                childChannelFuture.whenSuccess { CancellableFuture.discard($0) }
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
                                    // afterward is finished and closed.
                                    childChannel = try await CancellableFuture.resolve(childChannelFuture) { channel in
                                        CancellableFuture.discard(channel)
                                    }
                                } catch {
                                    await self.upgradeDidFail(error)
                                    return
                                }
                                await self.handleChildChannelWithRecovery(childChannel)
                            }
                        }
                        // The listening socket is closed. Handshakes still waiting for an
                        // upgrade request can never finish; closing them fails their
                        // futures so the child tasks above return and this group ends.
                        closePendingHandshakes()
                        if stopped.isCancelled {
                            group.cancelAll()
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
            .bind(to: address, childChannelInitializer: { [weak self, acceptGate] channel in
                // NIO neither registers nor closes a child whose initializer fails, and it
                // drops the result silently once the listener is closing, so every failure
                // path here closes the raw socket itself.
                guard acceptGate.beginDelivery() else {
                    channel.close(promise: nil)
                    return channel.eventLoop.makeFailedFuture(ServerServiceErrors.listenerClosed)
                }
                guard let self else {
                    acceptGate.endDelivery()
                    channel.close(promise: nil)
                    return channel.eventLoop.makeFailedFuture(ServerServiceErrors.websocketUpgradeFailed)
                }
                let upgrade = upgradeWebSocket(channel: channel, configuration: websocketConfiguration)
                let pendingHandshakes = self.pendingHandshakes
                let key = ObjectIdentifier(channel)
                pendingHandshakes.withLockedValue { $0[key] = channel }
                upgrade.whenComplete { result in
                    switch result {
                    case .success(let upgraded):
                        upgraded.whenComplete { _ in
                            pendingHandshakes.withLockedValue { _ = $0.removeValue(forKey: key) }
                        }
                    case .failure:
                        pendingHandshakes.withLockedValue { _ = $0.removeValue(forKey: key) }
                        acceptGate.endDelivery()
                        channel.close(promise: nil)
                    }
                }
                return upgrade
            })

    }

    /// Closes every accepted socket still waiting for its WebSocket upgrade.
    nonisolated private func closePendingHandshakes() {
        let channels = pendingHandshakes.withLockedValue { pending in
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        for channel in channels {
            channel.close(promise: nil)
        }
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
            .bind(to: address, childChannelInitializer: { [weak self, acceptGate] channel in
                // Runs on the child's event loop. The wrapped channel owns an unfinished
                // writer, so it is only created once the gate guarantees the accept loop
                // will receive it; a failed initializer closes the raw socket because NIO
                // does not (see `AcceptGate`).
                let wrapped: EventLoopFuture<NIOAsyncChannel<Inbound, Outbound>> = channel.eventLoop.makeCompletedFuture {
                    guard acceptGate.beginDelivery() else {
                        throw ServerServiceErrors.listenerClosed
                    }
                    do {
                        if let sslHandler = self?.serviceListenerDelegate?.retrieveSSLHandler() {
                            try channel.pipeline.syncOperations.addHandler(sslHandler)
                        }
                        if let channelHandlers = self?.serviceListenerDelegate?.retrieveChannelHandlers(), !channelHandlers.isEmpty {
                            try channel.pipeline.syncOperations.addHandlers(channelHandlers)
                        }
                        return try CancellableFuture.wrap(channel)
                    } catch {
                        acceptGate.endDelivery()
                        throw error
                    }
                }
                wrapped.whenFailure { _ in channel.close(promise: nil) }
                return wrapped
            })
    }
    
    private func handleChildChannelsOptimized(
        serverChannel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>
    ) async throws {
        try await runAcceptLoop(serverChannel) { [self] inbound, stopped in
            // Once this loop is gone nothing can own a delivered child; reject late ones.
            defer { acceptGate.close() }
            // Use optimized task group for better concurrency
            try await withThrowingDiscardingTaskGroup { group in
                for try await childChannel in inbound {
                    acceptGate.endDelivery()
                    // Check connection limits before accepting
                    guard await canAcceptConnection() else {
                        logger.log(level: .warning, message: "Connection limit reached, rejecting new connection")
                        // Finished and closed off the accept loop so a rejected peer
                        // cannot head-of-line block the next accept.
                        CancellableFuture.discard(childChannel)
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
                if stopped.isCancelled {
                    group.cancelAll()
                }
            }
        }
    }

    /// Runs `body` as the accept loop of `serverChannel`.
    ///
    /// Graceful shutdown and task cancellation close the listening socket; they do not cancel
    /// the `inbound` iteration. Cancelling the iteration drops the accepted channels still
    /// buffered in `inbound`. Each of those owns an unfinished `NIOAsyncWriter`, and releasing
    /// it traps once the child becomes active ("Deinited NIOAsyncWriter without calling
    /// finish()"). Closing the socket ends `inbound` after the buffered children have been
    /// delivered, so every accepted channel is handled or discarded through `executeThenClose`.
    ///
    /// `stopped` is set when the surrounding task was cancelled, so `body` can cancel the
    /// connections it started once the loop ends.
    ///
    /// The socket is closed through `closeListeningSocket`, which first waits for children
    /// that are between the child initializer and `inbound` (see `AcceptGate`).
    private func runAcceptLoop<Element: Sendable>(
        _ serverChannel: NIOAsyncChannel<Element, Never>,
        _ body: @escaping @Sendable (NIOAsyncChannelInboundStream<Element>, CancelFlag) async throws -> Void
    ) async throws {
        let stopped = CancelFlag()
        // Unstructured on purpose: cancelling this task would cancel the iteration.
        // It ends when the listening socket closes, which the handlers below trigger.
        let acceptTask = Task {
            try await withGracefulShutdownHandler {
                try await serverChannel.executeThenClose { inbound in
                    try await body(inbound, stopped)
                }
            } onGracefulShutdown: { [self] in
                closeListeningSocket(serverChannel.channel)
            }
        }
        try await withTaskCancellationHandler {
            try await acceptTask.value
        } onCancel: { [self] in
            stopped.cancel()
            closeListeningSocket(serverChannel.channel)
        }
    }

    /// Closes the listening socket once no accepted child is still in flight to the accept
    /// loop. Synchronous callers (shutdown handlers) get the drain on a detached task.
    nonisolated private func closeListeningSocket(_ channel: Channel) {
        let gate = acceptGate
        let logger = logger
        Task {
            if await !gate.closeAndDrain() {
                logger.log(level: .warning, message: "Closing listener with children still in flight")
            }
            channel.close(promise: nil)
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
            if didCloseIntentionally(id: channelId) {
                logger.log(
                    level: Self.isExpectedAfterIntentionalClose(error) ? .debug : .warning,
                    message: "Child channel \(channelId) ended after listener-initiated close: \(error)")
            } else {
                logger.log(level: .error, message: "Child channel \(channelId) failed: \(error)")
            }
        }

        decrementActiveConnections()
        removeChildChannelState(id: channelId)
        intentionalCloses.remove(channelId)
        await delegate.childChannelDidClose(id: channelId)
    }

    /// Errors a child run loop raises because *we* closed the socket: the peer's TCP
    /// FIN/RST arriving before (or instead of) its TLS close_notify, writes against the
    /// closed channel, or the TLS shutdown timing out.
    nonisolated static func isExpectedAfterIntentionalClose(_ error: any Error) -> Bool {
        if let sslError = error as? NIOSSLError {
            switch sslError {
            case .uncleanShutdown:
                return true
            default:
                return false
            }
        }
        if error is NIOSSLCloseTimedOutError {
            return true
        }
        if let channelError = error as? ChannelError {
            switch channelError {
            case .ioOnClosedChannel, .alreadyClosed, .inputClosed, .outputClosed, .eof:
                return true
            default:
                return false
            }
        }
        if let ioError = error as? IOError {
            switch ioError.errnoCode {
            case ECONNRESET, EPIPE, ENOTCONN, EBADF:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func markIntentionalClose(id: String) {
        // Only a live channel can still produce a run-loop error; an id whose loop has
        // already returned must not be remembered forever.
        guard channelContexts.contains(where: { $0.id == id }) else { return }
        intentionalCloses.insert(id)
    }

    func didCloseIntentionally(id: String) -> Bool {
        intentionalCloses.contains(id)
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
        markIntentionalClose(id: id)
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

    /// A delegate that was removed by `shutdownChildChannel` is expected to be missing
    /// for whatever the run loop still produces; only an unexplained absence is an error.
    private func noteMissingContextDelegateDrop(channelId: String, path: String) {
        let level: Level = didCloseIntentionally(id: channelId) ? .debug : .error
        logger.log(level: level, message: "No context delegate for child channel; dropping \(path)", metadata: [
            "channelId": "\(channelId)"
        ])
    }

    func shutdown() async throws {
        let contexts = channelContexts
        for context in contexts {
            markIntentionalClose(id: context.id)
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
        if let listeningChannel {
            if await !acceptGate.closeAndDrain() {
                logger.log(level: .warning, message: "Closing listener with children still in flight")
            }
            listeningChannel.close(promise: nil)
        }
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
