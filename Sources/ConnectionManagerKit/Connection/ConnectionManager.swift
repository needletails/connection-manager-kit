//
//  ConnectionManager.swift
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

import Atomics
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOExtras
import NIOPosix
import NIOSSL
import NIOHTTP1
import NIOWebSocket
import ServiceLifecycle
import NeedleTailLogger
import Metrics

/// Delegate protocol for receiving connection manager metrics updates
public protocol ConnectionManagerMetricsDelegate: AnyObject, Sendable {
    /// Called when connection manager metrics are updated
    /// - Parameters:
    ///   - totalConnections: Total number of connections managed
    ///   - activeConnections: Number of currently active connections
    ///   - failedConnections: Number of failed connection attempts
    ///   - averageConnectionTime: Average time to establish connections
    func connectionManagerMetricsDidUpdate(totalConnections: Int, activeConnections: Int, failedConnections: Int, averageConnectionTime: TimeAmount)
    
    /// Called when a connection attempt fails
    /// - Parameters:
    ///   - serverLocation: The server location that failed
    ///   - error: The error that occurred
    ///   - attemptNumber: The attempt number
    func connectionDidFail(serverLocation: String, error: Error, attemptNumber: Int)
    
    /// Called when a connection is successfully established
    /// - Parameters:
    ///   - serverLocation: The server location that succeeded
    ///   - connectionTime: Time taken to establish the connection
    func connectionDidSucceed(serverLocation: String, connectionTime: TimeAmount)
    
    /// Called when parallel connection operations complete
    /// - Parameters:
    ///   - totalAttempted: Total connections attempted
    ///   - successful: Number of successful connections
    ///   - failed: Number of failed connections
    func parallelConnectionDidComplete(totalAttempted: Int, successful: Int, failed: Int)
}

/// Default implementation for optional delegate methods
public extension ConnectionManagerMetricsDelegate {
    func connectionDidFail(serverLocation: String, error: Error, attemptNumber: Int) {}
    func connectionDidSucceed(serverLocation: String, connectionTime: TimeAmount) {}
    func parallelConnectionDidComplete(totalAttempted: Int, successful: Int, failed: Int) {}
}
#if canImport(Network)
import Network
import NIOTransportServices
#endif

/// Configuration for pre-configured TLS settings that can be applied to connections.
///
/// This struct provides a unified interface for TLS configuration across different platforms.
/// On Apple platforms, it wraps `NWProtocolTLS.Options`, while on other platforms it wraps `TLSConfiguration`.
///
/// ## Usage Example
/// ```swift
/// #if canImport(Network)
/// let tlsOptions = NWProtocolTLS.Options()
/// sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv13)
/// let tlsConfig = TLSPreKeyedConfiguration(tlsOption: tlsOptions)
/// #else
/// var tlsConfig = TLSConfiguration.makeClientConfiguration()
/// tlsConfig?.minimumTLSVersion = .tlsv13
/// let preKeyedConfig = TLSPreKeyedConfiguration(tlsConfiguration: tlsConfig!)
/// #endif
/// ```
public struct TLSPreKeyedConfiguration: Sendable {
#if canImport(Network)
    /// The TLS options for Apple platforms using Network framework.
    public let tlsOption: NWProtocolTLS.Options
    
    /// Creates a new TLS pre-keyed configuration for Apple platforms.
    /// - Parameter tlsOption: The Network framework TLS options to use.
    public init(tlsOption: NWProtocolTLS.Options) {
        self.tlsOption = tlsOption
    }
#else
    /// The TLS configuration for non-Apple platforms using NIO SSL.
    public let tlsConfiguration: TLSConfiguration
    
    /// Creates a new TLS pre-keyed configuration for non-Apple platforms.
    /// - Parameter tlsConfiguration: The NIO SSL TLS configuration to use.
    public init(tlsConfiguration: TLSConfiguration) {
        self.tlsConfiguration = tlsConfiguration
    }
#endif
}

/// A protocol that defines the delegate methods for managing connections in a network context.
///
/// Conforming types can provide custom channel handlers and receive the `NIOAsyncChannel` for further configuration.
/// This delegate is responsible for handling the lifecycle of connections and providing custom channel handlers.
///
/// ## Usage Example
/// ```swift
/// class MyConnectionManagerDelegate: ConnectionManagerDelegate {
///     func retrieveChannelHandlers() -> [ChannelHandler] {
///         return [MyCustomHandler()]
///     }
///
///     func deliverChannel(_ channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
///                        manager: ConnectionManager<ByteBuffer, ByteBuffer>,
///                        cacheKey: String) async {
///         await manager.setDelegates(
///             connectionDelegate: self,
///             contextDelegate: contextDelegate,
///             cacheKey: cacheKey
///         )
///     }
/// }
/// ```
public protocol ConnectionManagerDelegate: AnyObject, Sendable {
    
    associatedtype Inbound: Sendable
    associatedtype Outbound: Sendable
    
    /// Retrieves an array of custom channel handlers required by the consumer.
    ///
    /// This method allows the delegate to specify any additional handlers that should be added to the
    /// NIO pipeline. The returned handlers will be integrated into the connection's processing flow.
    ///
    /// - Returns: An array of `ChannelHandler` instances to be added to the connection pipeline.
    func retrieveChannelHandlers() -> [ChannelHandler]
    
    /// Delivers the `NIOAsyncChannel` to the delegate for further configuration.
    ///
    /// This method provides access to the underlying `NIOChannel`, allowing the delegate to set up
    /// connection-specific delegates. It is essential to call this method in order to properly configure
    /// the connection manager by invoking the `setDelegates(connectionDelegate:contextDelegate:cacheKey:)`
    /// method with the conforming instances of `ConnectionDelegate` and `ChannelContextDelegate`.
    ///
    /// - Parameters:
    ///   - channel: The `NIOAsyncChannel<Inbound, Outbound>` instance that represents the connection.
    ///   - manager: The `ConnectionManager<Inbound, Outbound>` instance responsible for managing the connection.
    ///   - cacheKey: A unique identifier for the connection in the cache.
    ///
    /// - Note: This method is asynchronous and should be awaited.
    @available(*, deprecated, message: "This method is deprecated and will be removed in a future version. Use channelCreated(_:cacheKey:) instead.")
    func deliverChannel(_ channel: NIOAsyncChannel<Inbound, Outbound>, manager: ConnectionManager<Inbound, Outbound>, cacheKey: String) async
    
    /// Called when a channel is created.
    ///
    /// This method is called when a channel is created. It is used to notify the delegate that a channel has been created.
    ///
    /// - Parameters:
    ///   - eventLoop: The event loop that the channel is created on.
    ///   - cacheKey: A unique identifier for the connection in the cache.
    func channelCreated(_ eventLoop: EventLoop, cacheKey: String) async
}

extension ConnectionManagerDelegate {
    public func deliverChannel(_ channel: NIOAsyncChannel<Inbound, Outbound>, manager: ConnectionManager<Inbound, Outbound>, cacheKey: String) async {}
}

/// Configuration for connection retry strategies.
public enum RetryStrategy: Sendable {
    /// Fixed delay between retries.
    case fixed(delay: TimeAmount)
    /// Exponential backoff with optional jitter.
    case exponential(initialDelay: TimeAmount, multiplier: Double = 2.0, maxDelay: TimeAmount, jitter: Bool = true)
    /// Custom retry strategy.
    case custom(@Sendable (_ attempt: Int, _ maxAttempts: Int) -> TimeAmount)
}

/// A manager responsible for handling network connections, including establishing, caching, and monitoring connections.
///
/// `ConnectionManager` provides a high-level interface for managing multiple network connections with automatic
/// reconnection, connection caching, and network event monitoring. It supports both TLS and non-TLS connections
/// and works across different platforms (Apple platforms using Network framework, others using NIO).
///
/// ## Key Features
/// - **Connection Caching**: Automatically caches connections for reuse
/// - **Automatic Reconnection**: Handles connection failures with configurable retry logic
/// - **TLS Support**: Built-in support for TLS connections with customizable configurations
/// - **Network Monitoring**: Monitors network events and connection state changes
/// - **Cross-Platform**: Works on iOS, macOS, tvOS, watchOS, and Linux
///
/// ## Usage Example
/// ```swift
/// let manager = ConnectionManager<ByteBuffer, ByteBuffer>(logger: NeedleTailLogger())
/// manager.delegate = MyConnectionManagerDelegate()
///
/// let servers = [
///     ServerLocation(
///         host: "api.example.com",
///         port: 443,
///         enableTLS: true,
///         cacheKey: "api-server",
///         delegate: connectionDelegate,
///         contextDelegate: contextDelegate
///     )
/// ]
///
/// try await manager.connect(
///     to: servers,
///     maxReconnectionAttempts: 5,
///     timeout: .seconds(10),
///     retryStrategy: .exponential(initialDelay: .seconds(1), maxDelay: .seconds(30))
/// )
///
/// // Later, when shutting down
/// await manager.gracefulShutdown()
/// ```
///
/// ## Thread Safety
/// This class is implemented as an actor, ensuring thread-safe access to its internal state.
/// All public methods are safe to call from any thread.
public actor ConnectionManager<Inbound: Sendable, Outbound: Sendable> {
    
    /// The internal connection cache that stores active connections.
    internal let connectionCache: ConnectionCache<Inbound, Outbound>
    
    /// The event loop group used for network operations.
    private let group: EventLoopGroup
    
    /// The service group for managing connection lifecycle.
    private var serviceGroup: ServiceGroup?
    /// Background task that runs the service lifecycle without blocking connect calls.
    private var serviceLifecycleTask: Task<Void, Never>?
    /// Optional WebSocket configuration applied to all connections created by this manager.
    public nonisolated(unsafe) var webSocketOptions: WebSocketOptions?
    private nonisolated(unsafe) var enabledWebsocket: Bool = false
    
    /// The logger instance for this connection manager.
    private let logger: NeedleTailLogger
    
    /// A weak reference to the delegate that conforms to `ConnectionManagerDelegate`.
    /// The delegate must have matching generic types.
    nonisolated(unsafe) public weak var delegate: (any ConnectionManagerDelegate)?
    
    /// A weak reference to the metrics delegate for receiving connection manager updates.
    public weak var metricsDelegate: ConnectionManagerMetricsDelegate?
    
    // MARK: - Metrics Tracking
    
    // Swift Metrics for external monitoring
    private let totalConnectionsGauge = Gauge(label: "connection_manager_total_connections", dimensions: [("component", "connection_manager")])
    private let activeConnectionsGauge = Gauge(label: "connection_manager_active_connections", dimensions: [("component", "connection_manager")])
    private let failedConnectionsCounter = Counter(label: "connection_manager_failed_connections", dimensions: [("component", "connection_manager")])
    private let successfulConnectionsCounter = Counter(label: "connection_manager_successful_connections", dimensions: [("component", "connection_manager")])
    private let averageConnectionTimeGauge = Gauge(label: "connection_manager_average_connection_time_ns", dimensions: [("component", "connection_manager")])
    private let connectionAttemptsCounter = Counter(label: "connection_manager_connection_attempts", dimensions: [("component", "connection_manager")])
    
    // Minimal state for internal calculations and delegate notifications
    private var connectionTimes: [TimeAmount] = []
    private var failedConnectionsCount: Int = 0
    
    // MARK: - Metrics Helper Methods
    
    /// Updates metrics when a connection attempt is made
    private func updateMetricsOnConnectionAttempt() {
        connectionAttemptsCounter.increment()
    }
    
    /// Updates metrics when a connection succeeds
    private func updateMetricsOnConnectionSuccess(serverLocation: String, connectionTime: TimeAmount) {
        connectionTimes.append(connectionTime)
        
        // Update Swift Metrics
        totalConnectionsGauge.record(Double(connectionTimes.count))
        activeConnectionsGauge.record(Double(connectionTimes.count))
        successfulConnectionsCounter.increment()
        
        // Calculate and record average connection time
        let totalTime = connectionTimes.reduce(TimeAmount.seconds(0)) { $0 + $1 }
        let averageTime = totalTime.nanoseconds / Int64(connectionTimes.count)
        averageConnectionTimeGauge.record(Double(averageTime))
        
        // Notify delegate with calculated values
        let totalConnections = connectionTimes.count
        let activeConnections = connectionTimes.count
        let failedConnections = failedConnectionsCount
        
        metricsDelegate?.connectionDidSucceed(serverLocation: serverLocation, connectionTime: connectionTime)
        metricsDelegate?.connectionManagerMetricsDidUpdate(
            totalConnections: totalConnections,
            activeConnections: activeConnections,
            failedConnections: failedConnections,
            averageConnectionTime: .nanoseconds(averageTime)
        )
    }
    
    /// Updates metrics when a connection fails
    private func updateMetricsOnConnectionFailure(serverLocation: String, error: Error, attemptNumber: Int) {
        failedConnectionsCount += 1
        
        // Update Swift Metrics
        failedConnectionsCounter.increment()
        
        // Notify delegate with calculated values
        let totalConnections = connectionTimes.count
        let activeConnections = connectionTimes.count
        let failedConnections = failedConnectionsCount
        let averageTime = connectionTimes.isEmpty ? 0 : connectionTimes.reduce(TimeAmount.seconds(0)) { $0 + $1 }.nanoseconds / Int64(connectionTimes.count)
        
        metricsDelegate?.connectionDidFail(serverLocation: serverLocation, error: error, attemptNumber: attemptNumber)
        metricsDelegate?.connectionManagerMetricsDidUpdate(
            totalConnections: totalConnections,
            activeConnections: activeConnections,
            failedConnections: failedConnections,
            averageConnectionTime: .nanoseconds(averageTime)
        )
    }
    
    /// Updates metrics when a connection is closed
    internal func updateMetricsOnConnectionClose() {
        // Update Swift Metrics (decrement active connections)
        let newActiveCount = max(0, connectionTimes.count - 1)
        activeConnectionsGauge.record(Double(newActiveCount))
        
        // Notify delegate with calculated values
        let totalConnections = connectionTimes.count
        let activeConnections = newActiveCount
        let failedConnections = failedConnectionsCount
        let averageTime = connectionTimes.isEmpty ? 0 : connectionTimes.reduce(TimeAmount.seconds(0)) { $0 + $1 }.nanoseconds / Int64(connectionTimes.count)
        
        metricsDelegate?.connectionManagerMetricsDidUpdate(
            totalConnections: totalConnections,
            activeConnections: activeConnections,
            failedConnections: failedConnections,
            averageConnectionTime: .nanoseconds(averageTime)
        )
    }
    
    /// Resets all metrics counters
    public func resetMetrics() {
        connectionTimes.removeAll()
        failedConnectionsCount = 0
        
        // Reset Swift Metrics (note: Swift Metrics doesn't have a reset method, so we set to 0)
        totalConnectionsGauge.record(0)
        activeConnectionsGauge.record(0)
        averageConnectionTimeGauge.record(0)
    }
    
    /// Returns current metrics for consumer logging/processing
    public func getCurrentMetrics() -> (totalConnections: Int, activeConnections: Int, failedConnections: Int, averageConnectionTime: TimeAmount) {
        let totalConnections = connectionTimes.count
        let activeConnections = connectionTimes.count
        let failedConnections = failedConnectionsCount
        let averageTime = connectionTimes.isEmpty ? 0 : connectionTimes.reduce(TimeAmount.seconds(0)) { $0 + $1 }.nanoseconds / Int64(connectionTimes.count)
        
        return (
            totalConnections: totalConnections,
            activeConnections: activeConnections,
            failedConnections: failedConnections,
            averageConnectionTime: .nanoseconds(averageTime)
        )
    }
    
    /// Returns formatted metrics string for consumer logging
    public func getFormattedMetrics() -> String {
        let metrics = getCurrentMetrics()
        return """
        Connection Manager Metrics:
        - Total Connections: \(metrics.totalConnections)
        - Active Connections: \(metrics.activeConnections)
        - Failed Connections: \(metrics.failedConnections)
        - Average Connection Time: \(metrics.averageConnectionTime.nanoseconds / 1_000_000_000)s
        """
    }
    
    /// Sets the delegate with proper type safety.
    ///
    /// This method ensures that the delegate has matching generic types.
    /// - Parameter delegate: The delegate to set, must have matching Inbound and Outbound types.
    public func setDelegate<D: ConnectionManagerDelegate>(_ delegate: D) where D.Inbound == Inbound, D.Outbound == Outbound {
        self.delegate = delegate
    }
    
    /// Sets the metrics delegate for receiving connection manager metrics updates.
    /// - Parameter metricsDelegate: The metrics delegate to set.
    public func setMetricsDelegate(_ metricsDelegate: ConnectionManagerMetricsDelegate?) {
        self.metricsDelegate = metricsDelegate
    }
    
    /// Internal flag for controlling reconnection behavior.
    private var _shouldReconnect = true
    
    /// A boolean indicating whether the manager should attempt to reconnect.
    ///
    /// This property is set to `false` when the maximum number of reconnection attempts is reached
    /// or when `gracefulShutdown()` is called.
    public var shouldReconnect: Bool {
        get async {
            _shouldReconnect
        }
    }
    
    /// Initializes a new `ConnectionManager` instance.
    ///
    /// - Parameter logger: The logger instance to use for logging connection events.
    ///   Defaults to a new `NeedleTailLogger` instance.
    ///
    /// ## Example
    /// ```swift
    /// let manager = ConnectionManager<ByteBuffer, ByteBuffer>(logger: NeedleTailLogger())
    /// ```
    public init(logger: NeedleTailLogger = NeedleTailLogger()) {
        self.logger = logger
        self.connectionCache = ConnectionCache<Inbound, Outbound>(logger: logger)
#if canImport(Network)
        self.group = NIOTSEventLoopGroup.singleton
#else
        self.group = MultiThreadedEventLoopGroup.singleton
#endif
        
        // Set up callback to update metrics when connections are removed from cache
        Task {
            await connectionCache.setConnectionRemovedCallback { [weak self] in
                Task { [weak self] in
                    await self?.updateMetricsOnConnectionClose()
                }
            }
        }
    }
    
    /// Connects to a list of server locations with advanced configuration options.
    ///
    /// This method provides advanced configuration options while maintaining backward compatibility.
    /// Use this method when you need custom retry strategies or other advanced features.
    ///
    /// - Parameters:
    ///   - servers: An array of `ServerLocation` instances to connect to.
    ///   - maxReconnectionAttempts: The maximum number of reconnection attempts for each server. Default is 6.
    ///   - timeout: The timeout duration for each connection attempt. Default is 10 seconds.
    ///   - tlsPreKeyed: Optional pre-configured TLS settings to use for all connections.
    ///   - retryStrategy: The retry strategy to use for failed connections.
    ///
    /// - Throws: An error if all connection attempts fail after the maximum number of retries.
    ///
    /// ## Example
    /// ```swift
    /// let servers = [
    ///     ServerLocation(host: "server1.example.com", port: 443, enableTLS: true, cacheKey: "server1"),
    ///     ServerLocation(host: "server2.example.com", port: 8080, enableTLS: false, cacheKey: "server2")
    /// ]
    ///
    /// try await manager.connect(
    ///     to: servers,
    ///     maxReconnectionAttempts: 5,
    ///     timeout: .seconds(15),
    ///     retryStrategy: .exponential(initialDelay: .seconds(1), maxDelay: .seconds(30))
    /// )
    /// ```
    public func connect(
        to servers: [ServerLocation],
        maxReconnectionAttempts: Int = 6,
        timeout: TimeAmount = .seconds(10),
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil,
        retryStrategy: RetryStrategy
    ) async throws {
        for await server in servers.async {
            try await attemptConnection(
                to: server,
                currentAttempt: 0,
                maxAttempts: maxReconnectionAttempts,
                timeout: timeout,
                tlsPreKeyed: tlsPreKeyed,
                retryStrategy: retryStrategy)
        }
        
        if serviceGroup == nil {
            serviceGroup = await ServiceGroup(
                services: connectionCache.fetchAllConnections(),
                logger: .init(label: "Connection Manager"))
            let group = serviceGroup
            serviceLifecycleTask = Task {
                do {
                    try await group?.run()
                } catch {
                    // Intentionally ignore; shutdown is coordinated via gracefulShutdown
                }
            }
        }
    }
    
    /// Sets the delegates for connection and context handling.
    ///
    /// This method allows you to update the delegates for an existing cached connection.
    /// If no connection exists for the given cache key, this method does nothing.
    ///
    /// - Parameters:
    ///   - connectionDelegate: The delegate responsible for handling connection events.
    ///   - contextDelegate: The delegate responsible for handling channel context events.
    ///   - cacheKey: A unique key for identifying the connection in the cache.
    ///
    /// ## Example
    /// ```swift
    /// await manager.setDelegates(
    ///     connectionDelegate: myConnectionDelegate,
    ///     contextDelegate: myContextDelegate,
    ///     cacheKey: "my-server"
    /// )
    /// ```
    public func setDelegates(
        connectionDelegate: ConnectionDelegate,
        contextDelegate: ChannelContextDelegate,
        cacheKey: String
    ) async {
        if let cachedConnection = await connectionCache.findConnection(cacheKey: cacheKey) {
            let config = await cachedConnection.config
            await cachedConnection.setConfig(.init(
                host: config.host,
                port: config.port,
                enableTLS: config.enableTLS,
                cacheKey: config.cacheKey,
                delegate: connectionDelegate,
                contextDelegate: contextDelegate))
            await connectionCache.updateConnection(cachedConnection, for: cacheKey)
        }
    }
    
    /// Connects to a list of server locations with specified parameters.
    ///
    /// This method attempts to establish connections to all provided servers. It will retry failed
    /// connections according to the `maxReconnectionAttempts` parameter and monitor network events
    /// for all established connections.
    ///
    /// - Parameters:
    ///   - servers: An array of `ServerLocation` instances to connect to.
    ///   - maxReconnectionAttempts: The maximum number of reconnection attempts for each server. Default is 6.
    ///   - timeout: The timeout duration for each connection attempt. Default is 10 seconds.
    ///   - tlsPreKeyed: Optional pre-configured TLS settings to use for all connections.
    ///
    /// - Throws: An error if all connection attempts fail after the maximum number of retries.
    ///
    /// ## Example
    /// ```swift
    /// let servers = [
    ///     ServerLocation(host: "server1.example.com", port: 443, enableTLS: true, cacheKey: "server1"),
    ///     ServerLocation(host: "server2.example.com", port: 8080, enableTLS: false, cacheKey: "server2")
    /// ]
    ///
    /// try await manager.connect(
    ///     to: servers,
    ///     maxReconnectionAttempts: 5,
    ///     timeout: .seconds(15)
    /// )
    /// ```
    public func connect(
        to servers: [ServerLocation],
        maxReconnectionAttempts: Int = 6,
        timeout: TimeAmount = .seconds(10),
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil
    ) async throws {
        // Use default retry strategy for backward compatibility
        let retryStrategy: RetryStrategy = .fixed(delay: .seconds(5))
        for await server in servers.async {
            try await attemptConnection(
                to: server,
                currentAttempt: 0,
                maxAttempts: maxReconnectionAttempts,
                timeout: timeout,
                tlsPreKeyed: tlsPreKeyed,
                retryStrategy: retryStrategy)
        }
        
        if serviceGroup == nil {
            serviceGroup = await ServiceGroup(
                services: connectionCache.fetchAllConnections(),
                logger: .init(label: "Connection Manager"))
            let group = serviceGroup
            serviceLifecycleTask = Task {
                do {
                    try await group?.run()
                } catch {
                    // Intentionally ignore; shutdown is coordinated via gracefulShutdown
                }
            }
        }
    }
    
    /// Attempts to connect to a specified server with retry logic.
    ///
    /// This private method implements the retry logic for connection attempts. It will retry failed
    /// connections according to the specified retry strategy until the maximum number of attempts is reached.
    ///
    /// - Parameters:
    ///   - server: The `ServerLocation` to connect to.
    ///   - currentAttempt: The current attempt number (0-based).
    ///   - maxAttempts: The maximum number of attempts allowed.
    ///   - timeout: The timeout duration for the connection.
    ///   - tlsPreKeyed: Optional pre-configured TLS settings.
    ///   - retryStrategy: The retry strategy to use for failed connections.
    ///
    /// - Throws: An error if the connection fails after all retry attempts.
    private func attemptConnection(
        to server: ServerLocation,
        currentAttempt: Int,
        maxAttempts: Int,
        timeout: TimeAmount,
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil,
        retryStrategy: RetryStrategy
    ) async throws {
        // Track connection attempt
        updateMetricsOnConnectionAttempt()
        
        let startTime = TimeAmount.now
        
        do {
            // Attempt to create a connection
            let childChannel: NIOAsyncChannel<Inbound, Outbound> = try await createConnection(
                server: server,
                group: self.group,
                timeout: timeout,
                tlsPreKeyed: tlsPreKeyed)
            
            let connectionTime = TimeAmount.now - startTime
            
            await connectionCache.cacheConnection(
                .init(
                    logger: logger,
                    config: server,
                    childChannel: childChannel,
                    delegate: self), for: server.cacheKey)
            
            await delegate?.channelCreated(childChannel.channel.eventLoop, cacheKey: server.cacheKey)
            
            let monitor = try await childChannel.channel.pipeline.handler(type: NetworkEventMonitor.self).get()
            if let foundConnection = await connectionCache.findConnection(cacheKey: server.cacheKey) {
                await delegateMonitorEvents(monitor: monitor, server: foundConnection.config)
            }
            
            // Track successful connection
            updateMetricsOnConnectionSuccess(serverLocation: server.cacheKey, connectionTime: connectionTime)
            
        } catch {
            // Track failed connection
            updateMetricsOnConnectionFailure(serverLocation: server.cacheKey, error: error, attemptNumber: currentAttempt + 1)
            
            // If the connection fails
            logger.log(level: .error, message: "Failed to connect to the server. Attempt: \(currentAttempt + 1) of \(maxAttempts)")
            
            if currentAttempt < maxAttempts - 1 {
                // Calculate delay based on retry strategy
                let delay = calculateRetryDelay(strategy: retryStrategy, attempt: currentAttempt, maxAttempts: maxAttempts)
                
                // Recursively attempt to connect again after the calculated delay
                try await Task.sleep(for: Duration.nanoseconds(delay.nanoseconds))
                try await attemptConnection(
                    to: server,
                    currentAttempt: currentAttempt + 1,
                    maxAttempts: maxAttempts,
                    timeout: timeout,
                    tlsPreKeyed: tlsPreKeyed,
                    retryStrategy: retryStrategy)
                
                if serviceGroup == nil {
                    serviceGroup = await ServiceGroup(
                        services: connectionCache.fetchAllConnections(),
                        logger: .init(label: "Connection Manager"))
                    let group = serviceGroup
                    serviceLifecycleTask = Task {
                        do {
                            try await group?.run()
                        } catch {
                            // Intentionally ignore; shutdown is coordinated via gracefulShutdown
                        }
                    }
                }
                
            } else {
                _shouldReconnect = false
                // If max attempts reached, rethrow the error
                throw error
            }
        }
    }
    
    /// Calculates the delay for the next retry attempt based on the retry strategy.
    ///
    /// - Parameters:
    ///   - strategy: The retry strategy to use.
    ///   - attempt: The current attempt number (0-based).
    ///   - maxAttempts: The maximum number of attempts allowed.
    /// - Returns: The calculated delay for the next retry attempt.
    private func calculateRetryDelay(strategy: RetryStrategy, attempt: Int, maxAttempts: Int) -> TimeAmount {
        switch strategy {
        case .fixed(let delay):
            return delay
            
        case .exponential(let initialDelay, let multiplier, let maxDelay, let jitter):
            let baseDelay = Double(initialDelay.nanoseconds) * pow(multiplier, Double(attempt))
            let cappedDelay = min(baseDelay, Double(maxDelay.nanoseconds))
            
            if jitter {
                // Add jitter to prevent thundering herd problem
                let jitterAmount = cappedDelay * 0.1 * Double.random(in: -1...1)
                return .nanoseconds(Int64(cappedDelay + jitterAmount))
            } else {
                return .nanoseconds(Int64(cappedDelay))
            }
            
        case .custom(let calculator):
            return calculator(attempt, maxAttempts)
        }
    }
    
    /// Errors that can occur within the `ConnectionManager`.
    enum Errors: Error {
        /// Indicates that TLS configuration is required but not provided.
        case tlsNotConfigured, websocketUpgradeFailed
    }
    
    /// Creates a connection to the specified server.
    ///
    /// This private method handles the platform-specific connection creation logic,
    /// including TLS configuration and channel setup.
    ///
    /// - Parameters:
    ///   - server: The `ServerLocation` to connect to.
    ///   - group: The `EventLoopGroup` to use for the connection.
    ///   - timeout: The timeout duration for the connection.
    ///   - tlsPreKeyed: Optional pre-configured TLS settings.
    ///
    /// - Returns: An `NIOAsyncChannel<Inbound, Outbound>` representing the established connection.
    /// - Throws: An error if the connection cannot be established.
    private func createConnection(
        server: ServerLocation,
        group: EventLoopGroup,
        timeout: TimeAmount,
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil
    ) async throws -> NIOAsyncChannel<Inbound, Outbound> {
        
#if !canImport(Network)
        func socketChannelCreator(tlsPreKeyed: TLSPreKeyedConfiguration? = nil) async throws -> NIOAsyncChannel<Inbound, Outbound> {
            let client = ClientBootstrap(group: group)

            var tlsConfiguration: TLSConfiguration?
            if server.enableTLS {
                logger.log(level: .info, message: "TLS enabled for connection to \(server.host):\(server.port)")
                if let tlsPreKeyed {
                    tlsConfiguration = tlsPreKeyed.tlsConfiguration
                } else {
                    tlsConfiguration = TLSConfiguration.makeClientConfiguration()
                    tlsConfiguration?.minimumTLSVersion = .tlsv13
                    tlsConfiguration?.maximumTLSVersion = .tlsv13
                }

                guard let tlsConfiguration = tlsConfiguration else {
                    throw Errors.tlsNotConfigured
                }
                let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
                let bootstrap = try NIOClientTCPBootstrap(
                    client,
                    tls: NIOSSLClientTLSProvider(
                        context: sslContext,
                        serverHostname: server.host
                    )
                )
                bootstrap.enableTLS()
            } else {
                logger.log(level: .info, message: "TLS not enabled for connection to \(server.host):\(server.port)")
            }
            
            if enabledWebsocket {
                let upgradeResult: EventLoopFuture<UpgradeResult> = try await client.connect(
                    host: server.host,
                    port: server.port) { channel in
                        upgradeSocket(channel, server: server)
                    }
                switch try await upgradeResult.get() {
                case .websocket(let websocketChannel):
                    return websocketChannel as! NIOAsyncChannel<Inbound, Outbound>
                case .notUpgraded:
                    throw Errors.websocketUpgradeFailed
                }
            } else {
                return try await client
                    .connectTimeout(timeout)
                    .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                    .connect(
                        host: server.host,
                        port: server.port) { channel in
                            return createHandlers(channel, server: server)
                        }
            }
        }
#endif
        
#if canImport(Network)
        var connection = NIOTSConnectionBootstrap(group: group)
        let tcpOptions = NWProtocolTCP.Options()
        connection = connection.tcpOptions(tcpOptions)
        
        if server.enableTLS {
            if let tlsPreKeyed {
                connection = connection.tlsOptions(tlsPreKeyed.tlsOption)
            } else {
                let tlsOptions = NWProtocolTLS.Options()
                sec_protocol_options_set_min_tls_protocol_version(
                    tlsOptions.securityProtocolOptions,
                    .TLSv13
                )
                
                sec_protocol_options_set_max_tls_protocol_version(
                    tlsOptions.securityProtocolOptions,
                    .TLSv13
                )
                connection = connection.tlsOptions(tlsOptions)
            }
        }
        
        connection = connection
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        
        if enabledWebsocket {
            let upgradeResult: EventLoopFuture<UpgradeResult> = try await connection.connect(
                host: server.host,
                port: server.port) { channel in
                    upgradeSocket(channel, server: server)
                }
            switch try await upgradeResult.get() {
            case .websocket(let websocketChannel):
                return websocketChannel as! NIOAsyncChannel<Inbound, Outbound>
            case .notUpgraded:
                throw Errors.websocketUpgradeFailed
            }
        } else {
            return try await connection.connect(
                host: server.host,
                port: server.port) { channel in
                    return createHandlers(channel, server: server)
                }
        }
#else
        return try await socketChannelCreator()
#endif
        
        @Sendable func upgradeSocket(_ channel: Channel, server: ServerLocation
        ) -> EventLoopFuture<EventLoopFuture<ConnectionManager<Inbound, Outbound>.UpgradeResult>> {
            let monitor = NetworkEventMonitor(connectionIdentifier: server.cacheKey)
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(monitor)
                if webSocketOptions == nil {
                    webSocketOptions = WebSocketOptions()
                }
                guard let webSocketOptions else {
                    throw Errors.websocketUpgradeFailed
                }
                
                
                let upgrader = NIOTypedWebSocketClientUpgrader<UpgradeResult>(
                    maxFrameSize: webSocketOptions.maxFrameSize,
                    enableAutomaticErrorHandling: true,
                    upgradePipelineHandler: { (channel, _) in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(NIOWebSocketFrameAggregator(
                                minNonFinalFragmentSize: webSocketOptions.minNonFinalFragmentSize,
                                maxAccumulatedFrameCount: webSocketOptions.maxAccumulatedFrameCount,
                                maxAccumulatedFrameSize: webSocketOptions.maxAccumulatedFrameSize
                            ))
                            let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel)
                            return .websocket(asyncChannel)
                        }
                    }
                )
                
                var headers = HTTPHeaders()
                let needsPort = !(server.port == 80 || server.port == 443)
                headers.add(name: "Host", value: needsPort ? "\(server.host):\(server.port)" : server.host)
                
                for (name, value) in webSocketOptions.headers {
                    headers.add(name: name, value: value)
                }
                if let subs = webSocketOptions.subprotocols, !subs.isEmpty {
                    headers.add(name: "Sec-WebSocket-Protocol", value: subs.joined(separator: ", "))
                }
                
                let requestHead = HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: webSocketOptions.uri,
                    headers: headers
                )
                
                let clientUpgradeConfiguration = NIOTypedHTTPClientUpgradeConfiguration(
                    upgradeRequestHead: requestHead,
                    upgraders: [upgrader],
                    notUpgradingCompletionHandler: { channel in
                        channel.eventLoop.makeCompletedFuture {
                            UpgradeResult.notUpgraded
                        }
                    }
                )
                
                let negotiationResultFuture = try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                    configuration: .init(
                        upgradeConfiguration: clientUpgradeConfiguration))
                return negotiationResultFuture
            }
        }
        
        /// Creates handlers for the channel and adds them to the pipeline.
        ///
        /// - Parameters:
        ///   - channel: The `Channel` to which handlers will be added.
        ///   - server: The `ServerLocation` associated with the channel.
        /// - Returns: An `EventLoopFuture` containing the `NIOAsyncChannel`.
        @Sendable func createHandlers(_ channel: Channel, server: ServerLocation) -> EventLoopFuture<NIOAsyncChannel<Inbound, Outbound>> {
            let monitor = NetworkEventMonitor(connectionIdentifier: server.cacheKey)
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(monitor)
                if let channelHandlers = delegate?.retrieveChannelHandlers(), !channelHandlers.isEmpty {
                    try channel.pipeline.syncOperations.addHandlers(channelHandlers)
                }
                return try NIOAsyncChannel<Inbound, Outbound>(
                    wrappingChannelSynchronously: channel)
            }
        }
    }
    
    public func connectWebSocket(
        to servers: [ServerLocation],
        maxReconnectionAttempts: Int = 6,
        timeout: TimeAmount = .seconds(10),
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil,
        retryStrategy: RetryStrategy = .fixed(delay: .seconds(5))
    ) async throws {
        enabledWebsocket = true
        for await server in servers.async {
            try await attemptConnection(
                to: server,
                currentAttempt: 0,
                maxAttempts: maxReconnectionAttempts,
                timeout: timeout,
                tlsPreKeyed: tlsPreKeyed,
                retryStrategy: retryStrategy)
        }
        
        if serviceGroup == nil {
            serviceGroup = await ServiceGroup(
                services: connectionCache.fetchAllConnections(),
                logger: .init(label: "Connection Manager"))
            let group = serviceGroup
            serviceLifecycleTask = Task {
                do {
                    try await group?.run()
                } catch {
                    // Intentionally ignore; shutdown is coordinated via gracefulShutdown
                }
            }
        }
    }
    
    enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case notUpgraded
    }
    
    /// Monitors events from the `NetworkEventMonitor` and delegates them to the appropriate server delegates.
    ///
    /// - Parameters:
    ///   - monitor: The `NetworkEventMonitor` instance to monitor events from.
    ///   - server: The `ServerLocation` associated with the connection.
    private func delegateMonitorEvents(monitor: NetworkEventMonitor, server: ServerLocation) async {
        if let errorStream = monitor.errorStream {
            server.delegate?.handleError(errorStream, id: monitor.connectionIdentifier)
        }
        if let eventStream = monitor.eventStream {
            await server.delegate?.handleNetworkEvents(eventStream, id: monitor.connectionIdentifier)
        }
        if let channelActiveStream = monitor.channelActiveStream {
            server.contextDelegate?.channelActive(channelActiveStream, id: monitor.connectionIdentifier)
        }
        if let channelInactiveStream = monitor.channelInactiveStream {
            server.contextDelegate?.channelInactive(channelInactiveStream, id: monitor.connectionIdentifier)
        }
    }
    
    /// Gracefully shuts down the connection manager and cleans up resources.
    ///
    /// This method triggers a graceful shutdown of the service group and removes all connections from the cache.
    /// After calling this method, the `shouldReconnect` property will return `false`.
    ///
    /// ## Example
    /// ```swift
    /// // When your application is shutting down
    /// await manager.gracefulShutdown()
    /// ```
    public func gracefulShutdown() async {
        do {
            await serviceGroup?.triggerGracefulShutdown()
            try await connectionCache.removeAllConnection()
            // Update metrics after removing all connections
            updateMetricsOnConnectionClose()
            logger.log(level: .info, message: "Gracefully shut down service and removed connections from cache.")
        } catch {
            logger.log(level: .error, message: "Error shutting down connection group: \(error)")
            await serviceGroup?.triggerGracefulShutdown()
        }
        let task = serviceLifecycleTask
        serviceLifecycleTask = nil
        await task?.value
        serviceGroup = nil
        _shouldReconnect = false
    }
    
    /// Connects to a list of server locations with parallel processing.
    ///
    /// This method attempts to establish connections to all provided servers in parallel,
    /// which can significantly improve performance when connecting to multiple servers.
    /// It maintains the same retry logic and error handling as the sequential version.
    ///
    /// - Parameters:
    ///   - servers: An array of `ServerLocation` instances to connect to.
    ///   - maxReconnectionAttempts: The maximum number of reconnection attempts for each server. Default is 6.
    ///   - timeout: The timeout duration for each connection attempt. Default is 10 seconds.
    ///   - tlsPreKeyed: Optional pre-configured TLS settings to use for all connections.
    ///   - maxConcurrentConnections: Maximum number of concurrent connection attempts. Default is 4.
    ///
    /// - Throws: An error if all connection attempts fail after the maximum number of retries.
    ///
    /// ## Example
    /// ```swift
    /// let servers = [
    ///     ServerLocation(host: "server1.example.com", port: 443, enableTLS: true, cacheKey: "server1"),
    ///     ServerLocation(host: "server2.example.com", port: 8080, enableTLS: false, cacheKey: "server2"),
    ///     ServerLocation(host: "server3.example.com", port: 443, enableTLS: true, cacheKey: "server3")
    /// ]
    ///
    /// try await manager.connectParallel(
    ///     to: servers,
    ///     maxReconnectionAttempts: 5,
    ///     timeout: .seconds(15),
    ///     maxConcurrentConnections: 3
    /// )
    /// ```
    public func connectParallel(
        to servers: [ServerLocation],
        maxReconnectionAttempts: Int = 6,
        timeout: TimeAmount = .seconds(10),
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil,
        maxConcurrentConnections: Int = 4
    ) async throws {
        // Use default retry strategy for backward compatibility
        let retryStrategy: RetryStrategy = .fixed(delay: .seconds(5))
        
        let totalAttempted = servers.count
        var successful = 0
        var failed = 0
        
        try await withThrowingTaskGroup(of: (success: Bool, error: Error?).self) { group in
            var activeConnections = 0
            var serverIndex = 0
            
            while serverIndex < servers.count || activeConnections > 0 {
                // Start new connections up to the concurrency limit
                while activeConnections < maxConcurrentConnections && serverIndex < servers.count {
                    let server = servers[serverIndex]
                    serverIndex += 1
                    activeConnections += 1
                    
                    group.addTask { [weak self] in
                        guard let self else { return (success: false, error: nil) }
                        do {
                            try await self.attemptConnection(
                                to: server,
                                currentAttempt: 0,
                                maxAttempts: maxReconnectionAttempts,
                                timeout: timeout,
                                tlsPreKeyed: tlsPreKeyed,
                                retryStrategy: retryStrategy)
                            return (success: true, error: nil)
                        } catch {
                            return (success: false, error: error)
                        }
                    }
                }
                
                // Wait for at least one connection to complete
                if activeConnections > 0 {
                    let result = try await group.next()
                    if let error = result?.error {
                        failed += 1
                        throw error
                    } else if result?.success == true {
                        successful += 1
                    } else {
                        failed += 1
                    }
                    activeConnections -= 1
                }
            }
        }
        
        // Notify delegate of parallel connection completion
        metricsDelegate?.parallelConnectionDidComplete(
            totalAttempted: totalAttempted,
            successful: successful,
            failed: failed
        )
        
        // Connections are managed individually through the connection cache
    }
    
    /// Connects to a list of server locations with parallel processing and advanced configuration.
    ///
    /// This method provides parallel connection processing with advanced configuration options.
    ///
    /// - Parameters:
    ///   - servers: An array of `ServerLocation` instances to connect to.
    ///   - maxReconnectionAttempts: The maximum number of reconnection attempts for each server. Default is 6.
    ///   - timeout: The timeout duration for each connection attempt. Default is 10 seconds.
    ///   - tlsPreKeyed: Optional pre-configured TLS settings to use for all connections.
    ///   - retryStrategy: The retry strategy to use for failed connections.
    ///   - maxConcurrentConnections: Maximum number of concurrent connection attempts. Default is 4.
    ///
    /// - Throws: An error if all connection attempts fail after the maximum number of retries.
    public func connectParallel(
        to servers: [ServerLocation],
        maxReconnectionAttempts: Int = 6,
        timeout: TimeAmount = .seconds(10),
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil,
        retryStrategy: RetryStrategy,
        maxConcurrentConnections: Int = 4
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var activeConnections = 0
            var serverIndex = 0
            
            while serverIndex < servers.count || activeConnections > 0 {
                // Start new connections up to the concurrency limit
                while activeConnections < maxConcurrentConnections && serverIndex < servers.count {
                    let server = servers[serverIndex]
                    serverIndex += 1
                    activeConnections += 1
                    
                    group.addTask { [weak self] in
                        guard let self else { return }
                        try await self.attemptConnection(
                            to: server,
                            currentAttempt: 0,
                            maxAttempts: maxReconnectionAttempts,
                            timeout: timeout,
                            tlsPreKeyed: tlsPreKeyed,
                            retryStrategy: retryStrategy)
                    }
                }
                
                // Wait for at least one connection to complete
                if activeConnections > 0 {
                    try await group.next()
                    activeConnections -= 1
                }
            }
        }
        
        // Connections are managed individually through the connection cache
    }
}
