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
    
    /// The continuation for the inbound stream.
    var inboundContinuation: AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.Continuation?
    
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
        try await exectuteTask()
    }
    
    /// Executes the main task for the child channel service.
    ///
    /// This private method handles the core logic of setting up streams, processing
    /// inbound and outbound data, and coordinating with delegates.
    nonisolated private func exectuteTask() async throws {
        guard let childChannel else { return }
        try await withThrowingDiscardingTaskGroup { group in
            try await childChannel.executeThenClose { [weak self] inbound, outbound in
                guard let self else { return }
                
                let channelId = await config.cacheKey
                let channelContext = ChannelContext<Inbound, Outbound>(
                    id: channelId,
                    channel: childChannel
                )
                
                await delegate.initializedChildChannel(channelContext)
                
                let (_inbound, _outbound) = await setUpStreams(
                    inbound: inbound,
                    outbound: outbound
                )
                
                group.addTask { [weak self] in
                    guard let self else { return }
                    for await writer in _outbound {
                        let writerContext = WriterContext(
                            id: channelId,
                            channel: childChannel,
                            writer: writer)
                        await contextDelegate?.deliverWriter(context: writerContext)
                    }
                }
                
                for await stream in _inbound {
                    //We need to make sure that the sequence is canceled when we finish the stream
                    for try await inbound in stream.cancelOnGracefulShutdown() {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            let streamContext = StreamContext<Inbound, Outbound>(
                                id: channelId,
                                channel: childChannel,
                                inbound: inbound)
                            await contextDelegate?.deliverInboundBuffer(context: streamContext)
                        }
                    }
                }
                
                // Ensure the outbound writer is finished to prevent memory leaks
                outbound.finish()
            }
        }
    }
    
    /// Sets up the inbound and outbound streams for data processing.
    ///
    /// This method creates async streams for both inbound and outbound data,
    /// allowing the service to process data asynchronously and coordinate with
    /// the context delegate.
    ///
    /// - Parameters:
    ///   - inbound: The inbound stream from the channel.
    ///   - outbound: The outbound writer for the channel.
    /// - Returns: A tuple containing the configured inbound and outbound streams.
    private func setUpStreams(
        inbound: NIOAsyncChannelInboundStream<Inbound>,
        outbound: NIOAsyncChannelOutboundWriter<Outbound>
    ) -> (AsyncStream<NIOAsyncChannelInboundStream<Inbound>>, AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>) {
        // Set up async streams without capturing the actor in producer closures
        let (_outbound, outboundCont) = AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.makeStream()
        self.continuation = outboundCont
        outboundCont.onTermination = { [weak self] status in
#if DEBUG
            Task { [weak self] in
                guard let self else { return }
                self.logger.log(level: .trace, message: "Writer Stream Terminated with status: \(status)")
            }
#endif
        }
        outboundCont.yield(outbound)

        let (_inbound, inboundCont) = AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.makeStream()
        self.inboundContinuation = inboundCont
        inboundCont.onTermination = { [weak self] status in
#if DEBUG
            Task { [weak self] in
                guard let self else { return }
                self.logger.log(level: .trace, message: "Inbound Stream Terminated with status: \(status)")
            }
#endif
        }
        inboundCont.yield(inbound)

        return (_inbound, _outbound)
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
        // Finish continuations if they exist
        if let inboundContinuation {
            inboundContinuation.finish()
        }
        if let continuation {
            continuation.finish()
        }
        
        // Only try to finish the outbound writer if we have a valid channel
        if let childChannel {
            try await childChannel.executeThenClose { inbound, outbound in
                outbound.finish()
            }
        }
    }
}
