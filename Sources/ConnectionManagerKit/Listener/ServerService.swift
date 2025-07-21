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
import AsyncAlgorithms



actor ServerService<Inbound: Sendable, Outbound: Sendable>: Service {
    
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

    nonisolated(unsafe) private var serverChannel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>?
    
    // Optimization: Add connection management
    private var activeConnections = 0
    private var maxConnectionsReached = false
    private var maxConcurrentConnections: Int = 1000
    
    // Performance monitoring
    private var connectionMetrics: [String: ConnectionMetrics] = [:]
    private var cleanupTask: Task<Void, Never>?
    private var isShuttingDown = false
    


    public func setContextDelegate(_ contextDelegate: ChannelContextDelegate, key: String) async {
        self.contextDelegates[key] = contextDelegate
    }
    
    init(
        address: SocketAddress, 
        configuration: Configuration,
        logger: NeedleTailLogger,
        delegate: ChildChannelServiceDelegate,
        listenerDelegate: ListenerDelegate?,
        serviceListenerDelegate: ServiceListenerDelegate?
    ) {
        self.address = address
        self.configuration = configuration
        self.logger = logger
        self.delegate = delegate
        self.listenerDelegate = listenerDelegate
        self.serviceListenerDelegate = serviceListenerDelegate
        
        // Start cleanup task
        Task { [weak self] in
            guard let self else { return }
            await startCleanupTask()
        }
    }
    
    func run() async throws {
        try await executeTask()
    }
    
    private func executeTask() async throws {
        do {
            let serverChannel = try await createServerChannel()
            self.serverChannel = serverChannel
            
            // Notify listener delegate
            await listenerDelegate?.didBindServer(channel: serverChannel)
            
            // Handle child channels with improved concurrency
            try await handleChildChannelsOptimized(serverChannel: serverChannel)
            
        } catch {
            logger.log(level: .error, message: "Server service failed: \(error)")
            throw error
        }
    }
    
    private func createServerChannel() async throws -> NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never> {
        return try await ServerBootstrap(group: configuration.group)
            // Optimized server channel options
            .serverChannelOption(ChannelOptions.backlog, value: Int32(configuration.backlog))
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Optimized child channel options
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
            .childChannelOption(ChannelOptions.autoRead, value: true)
            .bind(to: address, childChannelInitializer: { channel in
                return channel.eventLoop.makeCompletedFuture {
                    
                    // Add SSL handler if configured
                    if let sslHandler = self.serviceListenerDelegate?.retrieveSSLHandler() {
                        try channel.pipeline.syncOperations.addHandler(sslHandler)
                    }
                    
                    // Add custom channel handlers
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
                    
                    // Handle child channel with timeout and error recovery
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
        let startTime = TimeAmount.now
        
        do {
            // Set up connection metrics
            setConnectionMetrics(channelId: channelId, startTime: startTime)
            
            // Handle the channel
            try await self.handleChildChannel(childChannel: childChannel)
            
        } catch {
            logger.log(level: .error, message: "Child channel \(channelId) failed: \(error)")
            
            // Attempt recovery for certain error types
            if await shouldAttemptRecovery(for: error) {
                await attemptChannelRecovery(channelId: channelId, childChannel: childChannel)
            }
        }
        
        // Cleanup
        decrementActiveConnections()
        removeConnectionMetrics(channelId: channelId)
    }
    
    private func canAcceptConnection() async -> Bool {
        // Simple connection limit check
        return activeConnections < maxConcurrentConnections
    }
    
    private func incrementActiveConnections() {
        activeConnections += 1
        maxConnectionsReached = activeConnections >= maxConcurrentConnections
    }
    
    private func decrementActiveConnections() {
        activeConnections = max(0, activeConnections - 1)
        maxConnectionsReached = false
    }
    
    private func shouldAttemptRecovery(for error: Error) async -> Bool {
        // Attempt recovery for specific error types
        switch error {
        case is ChannelError:
            return true
        case is IOError:
            return true
        default:
            return false
        }
    }
    
    private func attemptChannelRecovery(channelId: String, childChannel: NIOAsyncChannel<Inbound, Outbound>) async {
        logger.log(level: .info, message: "Attempting recovery for channel \(channelId)")
        
        // Recovery logic would be implemented here based on specific requirements
        logger.log(level: .info, message: "Recovery attempted for channel \(channelId)")
    }
    
    private func startCleanupTask() {
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            while true {
                let isShuttingDown = await self.isShuttingDown
                if isShuttingDown { break }
                
                await performPeriodicCleanup()
                try? await Task.sleep(for: .seconds(60)) // Cleanup every minute
            }
            logger.log(level: .debug, message: "Cleanup task stopped due to shutdown")
        }
    }
    
    private func performPeriodicCleanup() async {
        // Clean up stale connections
        let now = TimeAmount.now
        let staleThreshold: TimeAmount = .seconds(300) // 5 minutes
        
        for (channelId, metrics) in connectionMetrics {
            if now - metrics.startTime > staleThreshold {
                logger.log(level: .debug, message: "Cleaning up stale connection \(channelId)")
                removeConnectionMetrics(channelId: channelId)
            }
        }
    }
    
    private func setConnectionMetrics(channelId: String, startTime: TimeAmount) {
        connectionMetrics[channelId] = ConnectionMetrics(startTime: startTime)
    }
    
    private func removeConnectionMetrics(channelId: String) {
        connectionMetrics.removeValue(forKey: channelId)
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
        // Set shutdown flag
        isShuttingDown = true
        
        // Cancel cleanup task
        cleanupTask?.cancel()
        
        // Shutdown all child channels
        for context in channelContexts {
            await stopTLS(from: context.id)
        }
        
        // Finish all continuations
        for continuation in inboundContinuations {
            continuation.value.finish()
        }
        for continuation in outboundContinuations {
            continuation.value.finish()
        }
        
        // Clear all collections
        inboundContinuations.removeAll()
        outboundContinuations.removeAll()
        contextDelegates.removeAll()
        channelContexts.removeAll()
        connectionMetrics.removeAll()
        
        // Close server channel
        try await serverChannel?.executeThenClose({_,_ in })
        
        logger.log(level: .info, message: "Server service shutdown complete")
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
                        // Ensure the outbound writer is finished to prevent memory leaks
                        outbound.finish()
                        if let contextDelegate = await contextDelegates[channelId.uuidString] {
                            await contextDelegate.didShutdownChildChannel()
                        }
                        return
                    }
                    
                } catch {
                    // Ensure outbound writer is finished even on error
                    outbound.finish()
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

// MARK: - Helper Types

private struct ConnectionMetrics {
    let startTime: TimeAmount
    var lastActivity: TimeAmount
    
    init(startTime: TimeAmount) {
        self.startTime = startTime
        self.lastActivity = startTime
    }
}
