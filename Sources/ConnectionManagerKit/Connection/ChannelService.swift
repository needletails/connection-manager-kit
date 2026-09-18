//
//  ChannelService.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/27/24.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//  This file is part of the ConnectionManagerKit Project

import Foundation
import NeedleTailLogger
import NIOCore
#if canImport(Network)
import Network
#endif
import ServiceLifecycle

/// A service that manages the lifecycle of a child channel and its associated data streams.
///
/// `ChildChannelService` is responsible for managing individual network connections,
/// including setting up inbound and outbound data streams, handling channel lifecycle
/// events, and coordinating with delegates for custom behavior.
///
/// ## Key Features
/// - **Stream Management**: Handles inbound and outbound data streams
/// - **Lifecycle Coordination**: Manages channel initialization and shutdown
/// - **Delegate Integration**: Coordinates with connection and context delegates
/// - **Service Lifecycle**: Implements `Service` protocol for proper lifecycle management
///
/// ## Usage Example
/// ```swift
/// let service = ChildChannelService(
///     logger: NeedleTailLogger(),
///     config: serverLocation,
///     childChannel: channel,
///     delegate: connectionManager
/// )
/// 
/// // Start the service
/// try await service.run()
/// 
/// // Update configuration
/// await service.setConfig(newConfig)
/// 
/// // Shutdown
/// try await service.shutdown()
/// ```
///
/// - Note: This class is implemented as an actor to ensure thread-safe access to its internal state.
/// - Note: The service automatically handles stream setup and cleanup when started or stopped.
public actor ChildChannelService<Inbound: Sendable, Outbound: Sendable>: Service {
    
    /// The server location configuration for this channel.
    public var config: ServerLocation
    
    /// The logger instance used for logging channel events.
    let logger: NeedleTailLogger
    
    /// The underlying NIO async channel for this connection.
    let childChannel: NIOAsyncChannel<Inbound, Outbound>?
    
    /// The delegate responsible for handling child channel lifecycle events.
    let delegate: ChildChannelServiceDelegate
    
    /// The delegate responsible for handling connection-level events.
    private var connectionDelegate: ConnectionDelegate?
    
    /// The delegate responsible for handling channel context events.
    public private(set) var contextDelegate: ChannelContextDelegate?
    
    /// The continuation for the outbound writer stream.
    var continuation: AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.Continuation?
    
    /// Updates the configuration for this channel service.
    ///
    /// This method allows you to update the server location configuration and
    /// associated delegates after the service has been created.
    ///
    /// - Parameter config: The new server location configuration.
    ///
    /// ## Example
    /// ```swift
    /// let newConfig = ServerLocation(
    ///     host: "new-server.example.com",
    ///     port: 8080,
    ///     enableTLS: false,
    ///     cacheKey: "new-server",
    ///     delegate: newConnectionDelegate,
    ///     contextDelegate: newContextDelegate
    /// )
    /// await service.setConfig(newConfig)
    /// ```
    public func setConfig(_ config: ServerLocation) async {
        self.config = config
        self.contextDelegate = config.contextDelegate
        self.connectionDelegate = config.delegate
    }
    
    /// Creates a new child channel service instance.
    ///
    /// - Parameters:
    ///   - logger: The logger instance to use for logging channel events.
    ///   - config: The server location configuration for this channel.
    ///   - childChannel: The underlying NIO async channel for this connection.
    ///   - delegate: The delegate responsible for handling child channel lifecycle events.
    ///
    /// ## Example
    /// ```swift
    /// let service = ChildChannelService(
    ///     logger: NeedleTailLogger(),
    ///     config: ServerLocation(
    ///         host: "api.example.com",
    ///         port: 443,
    ///         enableTLS: true,
    ///         cacheKey: "api-server",
    ///         delegate: connectionDelegate,
    ///         contextDelegate: contextDelegate
    ///     ),
    ///     childChannel: channel,
    ///     delegate: connectionManager
    /// )
    /// ```
    init(
        logger: NeedleTailLogger,
        config: ServerLocation,
        childChannel: NIOAsyncChannel<Inbound, Outbound>?,
        delegate: ChildChannelServiceDelegate
    ) {
        self.logger = logger
        self.config = config
        self.childChannel = childChannel
        self.delegate = delegate
        self.connectionDelegate = config.delegate
        self.contextDelegate = config.contextDelegate
    }
    
    /// Runs the child channel service.
    ///
    /// This method sets up the inbound and outbound streams, initializes the channel,
    /// and begins processing data. It will continue running until the channel is closed
    /// or the service is shut down.
    ///
    /// - Throws: An error if the service cannot be started or encounters an error during execution.
    ///
    /// ## Example
    /// ```swift
    /// do {
    ///     try await service.run()
    /// } catch {
    ///     print("Service failed: \(error)")
    /// }
    /// ```
    public func run() async throws {
        do {
            try await exectuteTask()
        } catch {
            // Cancellation is an orderly shutdown, not a channel fault.
            if !(error is CancellationError) {
                await contextDelegate?.reportChildChannel(error: error, id: config.cacheKey)
            }
            await contextDelegate?.didShutdownChildChannel()
            throw error
        }
        await contextDelegate?.didShutdownChildChannel()
    }
    
    /// Executes the main task for the child channel service.
    ///
    /// This private method handles the core logic of setting up streams, processing
    /// inbound and outbound data, and coordinating with delegates.
    nonisolated private func exectuteTask() async throws {
        guard let childChannel else { return }
        // Close the socket from cancellation so POSIX NIO unblocks executeThenClose.
        // Awaiting channel.close() from shutdown() while this iterator is live
        // deadlocks the shared event loop on Linux.
        try await withTaskCancellationHandler {
            try await withThrowingDiscardingTaskGroup { group in
                try await childChannel.executeThenClose { [weak self] inbound, outbound in
                    guard let self else { return }
                    
                    let channelId = await config.cacheKey
                    let channelContext = ChannelContext<Inbound, Outbound>(
                        id: channelId,
                        channel: childChannel
                    )
                    
                    await delegate.initializedChildChannel(channelContext)
                    
                    let outboundStream = await setUpOutboundStream(outbound: outbound)
                    
                    group.addTask { [weak self] in
                        guard let self else { return }
                        for await writer in outboundStream {
                            let writerContext = WriterContext(
                                id: channelId,
                                channel: childChannel,
                                writer: writer)
                            await contextDelegate?.deliverWriter(context: writerContext)
                        }
                    }
                    
                    for try await message in inbound {
                        let streamContext = StreamContext<Inbound, Outbound>(
                            id: channelId,
                            channel: childChannel,
                            inbound: message)
                        await contextDelegate?.deliverInboundBuffer(context: streamContext)
                    }
                    
                    outbound.finish()
                    // Inbound ended (peer closed or we closed). Finish the writer stream so the
                    // delivery child task exits; otherwise the task group waits forever and
                    // run() never returns on a remote close.
                    await finishOutboundStream()
                }
            }
        } onCancel: {
            childChannel.channel.close(promise: nil)
        }
    }
    
    private func finishOutboundStream() {
        continuation?.finish()
        continuation = nil
    }
    
    /// Yields the outbound writer to the context delegate without wrapping inbound.
    ///
    /// Inbound is iterated directly from `executeThenClose` so a channel close or
    /// task cancellation can finish the run loop. An extra inbound `AsyncStream`
    /// cannot be cancelled from `shutdown()` and left POSIX NIO waiting forever.
    private func setUpOutboundStream(
        outbound: NIOAsyncChannelOutboundWriter<Outbound>
    ) -> AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>> {
        let (stream, continuation) = AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.makeStream()
        self.continuation = continuation
        continuation.onTermination = { [weak self] status in
#if DEBUG
            Task { [weak self] in
                guard let self else { return }
                self.logger.log(level: .trace, message: "Writer Stream Terminated with status: \(status)")
            }
#endif
        }
        continuation.yield(outbound)
        return stream
    }
    
    /// Shuts down the child channel service.
    ///
    /// This method properly closes the inbound and outbound streams and finishes
    /// any ongoing operations. It should be called when the service is no longer needed.
    ///
    /// - Throws: An error if the shutdown process fails.
    ///
    /// ## Example
    /// ```swift
    /// do {
    ///     try await service.shutdown()
    ///     print("Service shut down successfully")
    /// } catch {
    ///     print("Failed to shut down service: \(error)")
    /// }
    /// ```
    func shutdown() async throws {
        finishOutboundStream()
        // Fire-and-forget: executeThenClose owns the close. Waiting here races
        // the inbound iterator on the same event loop and hangs on Linux.
        childChannel?.channel.close(promise: nil)
    }
}
