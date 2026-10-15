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

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOHTTP1
import NIOWebSocket
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
    
    /// Retrieves an array of custom channel handlers required by the consumer.
    ///
    /// This method allows the delegate to specify any additional handlers that should be added to the
    /// NIO pipeline. The returned handlers will be integrated into the connection's processing flow.
    ///
    /// - Returns: An array of `ChannelHandler` instances to be added to the connection pipeline.
    func retrieveChannelHandlers() -> [ChannelHandler]

    /// Called when a channel is created.
    ///
    /// This method is called when a channel is created. It is used to notify the delegate that a channel has been created.
    ///
    /// - Parameters:
    ///   - eventLoop: The event loop that the channel is created on.
    ///   - cacheKey: A unique identifier for the connection in the cache.
    func channelCreated(_ eventLoop: EventLoop, cacheKey: String) async
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
/// `ConnectionManager` provides a high-level interface for managing multiple network connections with
/// retried connection establishment, connection caching, and network event monitoring. It supports both
/// TLS and non-TLS connections and works across different platforms (Apple platforms using Network
/// framework, others using NIO).
///
/// ## Key Features
/// - **Connection Caching**: Automatically caches connections for reuse
/// - **Connect Retries**: Retries the initial connection to each server with a configurable `RetryStrategy`
/// - **TLS Support**: Built-in support for TLS connections with customizable configurations
/// - **Network Monitoring**: Monitors network events and connection state changes
/// - **Cross-Platform**: Works on iOS, macOS, tvOS, watchOS, and Linux
///
/// ## Lifecycle of an established connection
/// `maxReconnectionAttempts` and `retryStrategy` apply to establishing a connection only. Once a
/// connection is up and later closes (peer close, network loss, error), the manager evicts it from
/// the cache and notifies `ChannelContextDelegate.didShutdownChildChannel()`; it does not reconnect
/// on its own. Reconnect by calling `connect(to:)` again from that event (or from
/// `channelInactive`). There are no timers involved: the close event is the trigger.
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
    
    private struct ConnectionRun {
        let cacheKey: String
        let task: Task<Void, Never>
    }

    /// Every cached service owns exactly one run task. Runs are keyed by a token so a
    /// replaced service can finish without removing its replacement's task.
    private var connectionRuns: [UUID: ConnectionRun] = [:]
    private var currentRunTokenByCacheKey: [String: UUID] = [:]
    private var isShuttingDown = false
    private var cacheMetricsCallbackInstalled = false
    /// Optional WebSocket configuration applied to all connections created by this manager.
    public nonisolated(unsafe) var webSocketOptions: WebSocketOptions?

    /// How a given `connect*` call should establish its channels. Passed per call
    /// rather than stored on the manager so a `connectWebSocket` never changes
    /// the behavior of a later plain `connect`.
    enum Transport: Sendable {
        case tcp
        case webSocket
    }
    
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
    
    // O(1) connection metrics.
    private var totalConnectionsEstablished = 0
    private var activeConnectionsCount = 0
    private var totalConnectionTimeNanoseconds: Int64 = 0
    private var failedConnectionsCount: Int = 0
    
    // MARK: - Metrics Helper Methods
    
    /// Updates metrics when a connection attempt is made
    private func updateMetricsOnConnectionAttempt() {
        connectionAttemptsCounter.increment()
    }
    
    /// Updates metrics when a connection succeeds
    private func updateMetricsOnConnectionSuccess(serverLocation: String, connectionTime: TimeAmount) {
        totalConnectionsEstablished += 1
        totalConnectionTimeNanoseconds += connectionTime.nanoseconds
        let averageTime = totalConnectionTimeNanoseconds / Int64(totalConnectionsEstablished)
        
        totalConnectionsGauge.record(Double(totalConnectionsEstablished))
        activeConnectionsGauge.record(Double(activeConnectionsCount))
        successfulConnectionsCounter.increment()
        averageConnectionTimeGauge.record(Double(averageTime))
        
        metricsDelegate?.connectionDidSucceed(serverLocation: serverLocation, connectionTime: connectionTime)
        metricsDelegate?.connectionManagerMetricsDidUpdate(
            totalConnections: totalConnectionsEstablished,
            activeConnections: activeConnectionsCount,
            failedConnections: failedConnectionsCount,
            averageConnectionTime: .nanoseconds(averageTime)
        )
    }
    
    /// Updates metrics when a connection fails
    private func updateMetricsOnConnectionFailure(serverLocation: String, error: Error, attemptNumber: Int) {
        failedConnectionsCount += 1
        
        // Update Swift Metrics
        failedConnectionsCounter.increment()
        
        let averageTime = totalConnectionsEstablished == 0
            ? 0
            : totalConnectionTimeNanoseconds / Int64(totalConnectionsEstablished)
        
        metricsDelegate?.connectionDidFail(serverLocation: serverLocation, error: error, attemptNumber: attemptNumber)
        metricsDelegate?.connectionManagerMetricsDidUpdate(
            totalConnections: totalConnectionsEstablished,
            activeConnections: activeConnectionsCount,
            failedConnections: failedConnectionsCount,
            averageConnectionTime: .nanoseconds(averageTime)
        )
    }
    
    private func updateActiveConnectionCount(_ count: Int) {
        activeConnectionsCount = count
        activeConnectionsGauge.record(Double(count))
        let averageTime = totalConnectionsEstablished == 0
            ? 0
            : totalConnectionTimeNanoseconds / Int64(totalConnectionsEstablished)
        
        metricsDelegate?.connectionManagerMetricsDidUpdate(
            totalConnections: totalConnectionsEstablished,
            activeConnections: count,
            failedConnections: failedConnectionsCount,
            averageConnectionTime: .nanoseconds(averageTime)
        )
    }
    
    /// Resets all metrics counters
    public func resetMetrics() {
        totalConnectionsEstablished = 0
        totalConnectionTimeNanoseconds = 0
        failedConnectionsCount = 0
        
        totalConnectionsGauge.record(0)
        activeConnectionsGauge.record(Double(activeConnectionsCount))
        averageConnectionTimeGauge.record(0)
    }
    
    /// Returns current metrics for consumer logging/processing
    public func getCurrentMetrics() -> (totalConnections: Int, activeConnections: Int, failedConnections: Int, averageConnectionTime: TimeAmount) {
        let averageTime = totalConnectionsEstablished == 0
            ? 0
            : totalConnectionTimeNanoseconds / Int64(totalConnectionsEstablished)
        
        return (
            totalConnections: totalConnectionsEstablished,
            activeConnections: activeConnectionsCount,
            failedConnections: failedConnectionsCount,
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
    
    /// Sets the delegate that supplies channel handlers and receives channel-created events.
    /// - Parameter delegate: The delegate to set.
    public func setDelegate(_ delegate: any ConnectionManagerDelegate) {
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
    
    /// TCP options applied to every connection this manager creates. Empty by
    /// default (kernel defaults); adopters opt in, e.g. `.deadPeerDetection()`.
    private let transportOptions: TCPTransportOptions
    
    /// Initializes a new `ConnectionManager` instance.
    ///
    /// - Parameters:
    ///   - logger: The logger instance to use for logging connection events.
    ///     Defaults to a new `NeedleTailLogger` instance.
    ///   - transportOptions: TCP options applied to every connection this
    ///     manager creates. Defaults to none (kernel defaults); pass
    ///     `.deadPeerDetection()` or custom options to opt in.
    ///
    /// ## Example
    /// ```swift
    /// let manager = ConnectionManager<ByteBuffer, ByteBuffer>(logger: NeedleTailLogger())
    /// ```
    public init(
        logger: NeedleTailLogger = NeedleTailLogger(),
        transportOptions: TCPTransportOptions = .init(),
        cacheConfiguration: CacheConfiguration = .init()
    ) {
        self.logger = logger
        self.transportOptions = transportOptions
        self.connectionCache = ConnectionCache(
            logger: logger,
            configuration: cacheConfiguration
        )
#if canImport(Network)
        self.group = NIOTSEventLoopGroup.singleton
#else
        self.group = MultiThreadedEventLoopGroup.singleton
#endif
        
    }
    
    /// Connects to a list of server locations with advanced configuration options.
    ///
    /// This method provides advanced configuration options while maintaining backward compatibility.
    /// Use this method when you need custom retry strategies or other advanced features.
    ///
    /// Servers are connected sequentially. If a server exhausts its attempts the error is thrown
    /// immediately and the remaining servers are not attempted; use `connectParallel` to attempt
    /// every server regardless.
    ///
    /// - Parameters:
    ///   - servers: An array of `ServerLocation` instances to connect to.
    ///   - maxReconnectionAttempts: The maximum number of attempts for the initial connection to each server. Default is 6.
    ///   - timeout: The timeout duration for each connection attempt. Default is 10 seconds.
    ///   - tlsPreKeyed: Optional pre-configured TLS settings to use for all connections.
    ///   - retryStrategy: The retry strategy to use between failed attempts.
    ///
    /// - Throws: The error from the first server that could not be connected after `maxReconnectionAttempts`.
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
        _shouldReconnect = true
        for server in servers {
            try await attemptConnection(
                to: server,
                currentAttempt: 0,
                maxAttempts: maxReconnectionAttempts,
                timeout: timeout,
                tlsPreKeyed: tlsPreKeyed,
                retryStrategy: retryStrategy)
        }
    }
    
    /// Sets the delegates for connection and context handling.
    ///
    /// This method allows you to update the delegates for an existing cached connection.
    /// If no connection exists for the given cache key, this method does nothing.
    ///
    /// - Important: The monitor streams (`handleError`, `handleNetworkEvents`, `channelActive`,
    ///   `channelInactive`) are handed to the delegates exactly once, immediately after
    ///   `ConnectionManagerDelegate.channelCreated(_:cacheKey:)` returns. Call this method from
    ///   `channelCreated` (or pass the delegates in the `ServerLocation`) so they are in place at
    ///   that moment; delegates set later still receive inbound data and writers but never those
    ///   streams.
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
    /// This method attempts to establish connections to all provided servers, sequentially. It
    /// retries each initial connection according to `maxReconnectionAttempts` (fixed 5 second
    /// delay) and monitors network events for all established connections. If a server exhausts
    /// its attempts the error is thrown immediately and the remaining servers are not attempted.
    ///
    /// - Parameters:
    ///   - servers: An array of `ServerLocation` instances to connect to.
    ///   - maxReconnectionAttempts: The maximum number of attempts for the initial connection to each server. Default is 6.
    ///   - timeout: The timeout duration for each connection attempt. Default is 10 seconds.
    ///   - tlsPreKeyed: Optional pre-configured TLS settings to use for all connections.
    ///
    /// - Throws: The error from the first server that could not be connected after `maxReconnectionAttempts`.
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
        _shouldReconnect = true
        for server in servers {
            try await attemptConnection(
                to: server,
                currentAttempt: 0,
                maxAttempts: maxReconnectionAttempts,
                timeout: timeout,
                tlsPreKeyed: tlsPreKeyed,
                retryStrategy: retryStrategy)
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
        retryStrategy: RetryStrategy,
        transport: Transport = .tcp
    ) async throws {
        await ensureCacheMetricsCallback()
        guard !isShuttingDown else { throw CancellationError() }

        // Track connection attempt
        updateMetricsOnConnectionAttempt()
        
        let startTime = TimeAmount.now
        
        do {
            // Attempt to create a connection
            let childChannel: NIOAsyncChannel<Inbound, Outbound> = try await createConnection(
                server: server,
                group: self.group,
                timeout: timeout,
                tlsPreKeyed: tlsPreKeyed,
                transport: transport)

            // A wrapped channel nobody will run must be finished through
            // `executeThenClose`, not just closed: dropping it after a bare close
            // relies on NIO finishing the writer sink before the close promise fires.
            guard !isShuttingDown else {
                CancellableFuture.discard(childChannel)
                throw CancellationError()
            }

            let connectionTime = TimeAmount.now - startTime
            let monitor: NetworkEventMonitor
            do {
                monitor = try await CancellableFuture.resolve(
                    childChannel.channel.pipeline.handler(type: NetworkEventMonitor.self)
                ) {
                    CancellableFuture.discard(childChannel)
                }
            } catch {
                CancellableFuture.discard(childChannel)
                throw error
            }
            
            let service = ChildChannelService(
                logger: logger,
                config: server,
                childChannel: childChannel,
                delegate: self
            )
            retireConnectionRun(cacheKey: server.cacheKey)
            await connectionCache.cacheConnection(service, for: server.cacheKey)
            
            await delegate?.channelCreated(childChannel.channel.eventLoop, cacheKey: server.cacheKey)
            
            if let foundConnection = await connectionCache.findConnection(cacheKey: server.cacheKey) {
                await delegateMonitorEvents(monitor: monitor, server: foundConnection.config)
            }

            startConnectionService(service, cacheKey: server.cacheKey)
            
            // Track successful connection
            updateMetricsOnConnectionSuccess(serverLocation: server.cacheKey, connectionTime: connectionTime)
            
        } catch {
            if isShuttingDown || error is CancellationError {
                throw error
            }

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
                    retryStrategy: retryStrategy,
                    transport: transport)
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

    private func ensureCacheMetricsCallback() async {
        guard !cacheMetricsCallbackInstalled else { return }
        cacheMetricsCallbackInstalled = true
        await connectionCache.setConnectionCountChangedCallback { [weak self] count in
            await self?.updateActiveConnectionCount(count)
        }
    }
    
    /// Errors that can occur within the `ConnectionManager`.
    enum Errors: Error {
        /// Indicates that TLS configuration is required but not provided.
        case tlsNotConfigured, websocketUpgradeFailed, connectionSetupFailed
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
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil,
        transport: Transport
    ) async throws -> NIOAsyncChannel<Inbound, Outbound> {
        // Snapshot on the actor. `upgradeSocket` runs on the event loop and must
        // not read or write the `nonisolated(unsafe)` property from there.
        let webSocketOptions = self.webSocketOptions ?? WebSocketOptions()
        let useWebSocket = transport == .webSocket
        
#if !canImport(Network)
        @Sendable func addClientTLSHandlerIfNeeded(
            to channel: Channel,
            server: ServerLocation,
            tlsPreKeyed: TLSPreKeyedConfiguration?
        ) throws {
            guard server.enableTLS else { return }

            let tlsConfiguration: TLSConfiguration
            if let tlsPreKeyed {
                tlsConfiguration = tlsPreKeyed.tlsConfiguration
            } else {
                var defaultTLSConfiguration = TLSConfiguration.makeClientConfiguration()
                defaultTLSConfiguration.minimumTLSVersion = .tlsv13
                defaultTLSConfiguration.maximumTLSVersion = .tlsv13
                tlsConfiguration = defaultTLSConfiguration
            }

            let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
            let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: server.host)
            try channel.pipeline.syncOperations.addHandler(sslHandler)
        }

        func socketChannelCreator() async throws -> NIOAsyncChannel<Inbound, Outbound> {
            var client = ClientBootstrap(group: group)
                .connectTimeout(timeout)
            // Adopter-supplied TCP options (e.g. dead-peer detection). Applied
            // to the shared bootstrap so both the websocket-upgrade and plain
            // TCP branches get them.
            for option in transportOptions.socketOptions {
                client = client.channelOption(
                    ChannelOptions.socket(
                        SocketOptionLevel(option.level), SocketOptionName(option.name)),
                    value: SocketOptionValue(option.value))
            }

            if server.enableTLS {
                logger.log(level: .info, message: "TLS enabled for connection to \(server.host):\(server.port)")
            } else {
                logger.log(level: .info, message: "TLS not enabled for connection to \(server.host):\(server.port)")
            }
            
            if useWebSocket {
                let upgrades = ChannelProducts<EventLoopFuture<UpgradeResult>>(discard: discardUpgrade)
                // The async `connect` overload waits with `EventLoopFuture.get()`, which ignores
                // cancellation. The future-returning connect is resolved below instead.
                let connected = client.channelInitializer { channel in
                    upgradeSocket(channel, server: server).map { upgrades.store($0, on: channel) }
                }.connect(host: server.host, port: server.port)
                return try await finishWebSocket(connected, upgrades: upgrades)
            } else {
                let produced = ChannelProducts<NIOAsyncChannel<Inbound, Outbound>>(discard: CancellableFuture.discard)
                let connected = client
                    .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                    .channelInitializer { channel in
                        createHandlers(channel, server: server).map { produced.store($0, on: channel) }
                    }
                    .connect(host: server.host, port: server.port)
                return try await finish(connected, produced: produced)
            }
        }
#endif
        
#if canImport(Network)
        var connection = NIOTSConnectionBootstrap(group: group)
        let tcpOptions = NWProtocolTCP.Options()
        // Adopter-supplied TCP tuning (e.g. dead-peer detection).
        transportOptions.configureNWTCPOptions?(tcpOptions)
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
        
        if useWebSocket {
            let upgrades = ChannelProducts<EventLoopFuture<UpgradeResult>>(discard: discardUpgrade)
            // The async `connect` overload waits with `EventLoopFuture.get()`, which ignores
            // cancellation. The future-returning connect is resolved below instead.
            let connected = connection.channelInitializer { channel in
                upgradeSocket(channel, server: server).map { upgrades.store($0, on: channel) }
            }.connect(host: server.host, port: server.port)
            return try await finishWebSocket(connected, upgrades: upgrades)
        } else {
            let produced = ChannelProducts<NIOAsyncChannel<Inbound, Outbound>>(discard: CancellableFuture.discard)
            let connected = connection.channelInitializer { channel in
                createHandlers(channel, server: server).map { produced.store($0, on: channel) }
            }.connect(host: server.host, port: server.port)
            return try await finish(connected, produced: produced)
        }
#else
        return try await socketChannelCreator()
#endif

        @Sendable func finish(
            _ connected: EventLoopFuture<Channel>,
            produced: ChannelProducts<NIOAsyncChannel<Inbound, Outbound>>
        ) async throws -> NIOAsyncChannel<Inbound, Outbound> {
            let channel = try await CancellableFuture.resolveChannel(connected)
            guard let asyncChannel = produced.take(from: channel) else {
                CancellableFuture.discard(channel)
                throw Errors.connectionSetupFailed
            }
            return asyncChannel
        }

        @Sendable func finishWebSocket(
            _ connected: EventLoopFuture<Channel>,
            upgrades: ChannelProducts<EventLoopFuture<UpgradeResult>>
        ) async throws -> NIOAsyncChannel<Inbound, Outbound> {
            let channel = try await CancellableFuture.resolveChannel(connected)
            guard let upgradeResult = upgrades.take(from: channel) else {
                CancellableFuture.discard(channel)
                throw Errors.websocketUpgradeFailed
            }
            return try await resolveUpgrade(upgradeResult, channel: channel)
        }

        /// Drops an upgrade nobody will consume; a completed upgrade owns a wrapped channel
        /// whose writer must be finished rather than released.
        @Sendable func discardUpgrade(_ upgrade: EventLoopFuture<UpgradeResult>) {
            upgrade.whenSuccess { result in
                if case .websocket(let websocketChannel) = result {
                    CancellableFuture.discard(websocketChannel)
                }
            }
        }
        
        /// Resolves the upgrade future into a typed channel. `connectWebSocket` is
        /// constrained to `WebSocketFrame` managers, so the cast only fails if the
        /// generic path is misused; it throws rather than trapping.
        @Sendable func resolveUpgrade(
            _ upgradeResult: EventLoopFuture<UpgradeResult>,
            channel: Channel
        ) async throws -> NIOAsyncChannel<Inbound, Outbound> {
            let result: UpgradeResult
            do {
                result = try await CancellableFuture.resolve(upgradeResult) {
                    // The upgrade may still complete; finish whatever it produces.
                    discardUpgrade(upgradeResult)
                    CancellableFuture.discard(channel)
                }
            } catch {
                CancellableFuture.discard(channel)
                throw error
            }
            switch result {
            case .websocket(let websocketChannel):
                guard let typed = websocketChannel as? NIOAsyncChannel<Inbound, Outbound> else {
                    CancellableFuture.discard(websocketChannel)
                    throw Errors.websocketUpgradeFailed
                }
                return typed
            case .notUpgraded:
                CancellableFuture.discard(channel)
                throw Errors.websocketUpgradeFailed
            }
        }
        
        @Sendable func upgradeSocket(_ channel: Channel, server: ServerLocation
        ) -> EventLoopFuture<EventLoopFuture<ConnectionManager<Inbound, Outbound>.UpgradeResult>> {
            let monitor = NetworkEventMonitor(connectionIdentifier: server.cacheKey)
            return channel.eventLoop.makeCompletedFuture {
#if !canImport(Network)
                try addClientTLSHandlerIfNeeded(to: channel, server: server, tlsPreKeyed: tlsPreKeyed)
#endif
                try channel.pipeline.syncOperations.addHandler(monitor)
                
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
                            let asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame> = try CancellableFuture.wrap(channel)
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
#if !canImport(Network)
                try addClientTLSHandlerIfNeeded(to: channel, server: server, tlsPreKeyed: tlsPreKeyed)
#endif
                try channel.pipeline.syncOperations.addHandler(monitor)
                if let channelHandlers = delegate?.retrieveChannelHandlers(), !channelHandlers.isEmpty {
                    try channel.pipeline.syncOperations.addHandlers(channelHandlers)
                }
                return try CancellableFuture.wrap(channel)
            }
        }
    }
    
    enum UpgradeResult: Sendable {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case notUpgraded
    }
    
    /// Monitors events from the `NetworkEventMonitor` and delegates them to the appropriate server delegates.
    ///
    /// - Parameters:
    ///   - monitor: The `NetworkEventMonitor` instance to monitor events from.
    ///   - server: The `ServerLocation` associated with the connection.
    private func delegateMonitorEvents(monitor: NetworkEventMonitor, server: ServerLocation) async {
        let id = monitor.connectionIdentifier
        if let errorStream = monitor.errorStream {
            server.delegate?.handleError(errorStream, id: id)
        }
        if let eventStream = monitor.eventStream, let delegate = server.delegate {
            // Do not await: a delegate that iterates the stream inline must not
            // block `connect(to:)` from returning or the connection service from starting.
            Task { await delegate.handleNetworkEvents(eventStream, id: id) }
        }
        if let channelActiveStream = monitor.channelActiveStream {
            server.contextDelegate?.channelActive(channelActiveStream, id: id)
        }
        if let channelInactiveStream = monitor.channelInactiveStream {
            server.contextDelegate?.channelInactive(channelInactiveStream, id: id)
        }
    }

    private func startConnectionService(
        _ service: ChildChannelService<Inbound, Outbound>,
        cacheKey: String
    ) {
        guard !isShuttingDown else { return }

        let token = UUID()
        let logger = self.logger
        let task = Task { [weak self, service] in
            do {
                try await service.run()
            } catch {
                // A closed-channel error after we intentionally closed the channel
                // (shutdown, replacement, or eviction) is the expected end of the run.
                let intentionalClose = await self?.isShuttingDown ?? true
                let closedChannel: Bool
                if let channelError = error as? ChannelError, case .ioOnClosedChannel = channelError {
                    closedChannel = true
                } else {
                    closedChannel = false
                }
                if Task.isCancelled || intentionalClose || closedChannel {
                    logger.log(
                        level: .debug,
                        message: "Connection service \(cacheKey) finished: \(error)"
                    )
                } else {
                    logger.log(
                        level: .error,
                        message: "Connection service \(cacheKey) stopped with error: \(error)"
                    )
                }
            }
            await self?.connectionServiceDidFinish(token: token, cacheKey: cacheKey)
        }

        connectionRuns[token] = ConnectionRun(cacheKey: cacheKey, task: task)
        currentRunTokenByCacheKey[cacheKey] = token
    }

    private func retireConnectionRun(cacheKey: String) {
        guard let token = currentRunTokenByCacheKey.removeValue(forKey: cacheKey) else {
            return
        }
        connectionRuns[token]?.task.cancel()
    }

    private func connectionServiceDidFinish(token: UUID, cacheKey: String) async {
        connectionRuns[token] = nil
        guard currentRunTokenByCacheKey[cacheKey] == token else {
            return
        }
        currentRunTokenByCacheKey[cacheKey] = nil
        // gracefulShutdown() already emptied the cache.
        guard !isShuttingDown else { return }
        do {
            try await connectionCache.removeConnection(cacheKey)
        } catch {
            logger.log(
                level: .error,
                message: "Failed to remove finished connection \(cacheKey): \(error)"
            )
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
        isShuttingDown = true

        let runs = Array(connectionRuns.values)
        for run in runs {
            run.task.cancel()
        }

        do {
            try await connectionCache.removeAllConnection()
        } catch {
            logger.log(level: .error, message: "Error shutting down connections: \(error)")
        }

        for run in runs {
            await run.task.value
        }
        connectionRuns.removeAll()
        currentRunTokenByCacheKey.removeAll()

        _shouldReconnect = false
        // Shutdown is complete; the manager may be reused for new connections.
        isShuttingDown = false
        logger.log(level: .info, message: "Gracefully shut down services and removed connections from cache.")
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
    /// - Throws: The first error encountered, after every server has been attempted. Servers that
    ///   succeeded stay connected. `ConnectionManagerMetricsDelegate.parallelConnectionDidComplete`
    ///   is always reported before the error is rethrown.
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
        try await connectParallel(
            to: servers,
            maxReconnectionAttempts: maxReconnectionAttempts,
            timeout: timeout,
            tlsPreKeyed: tlsPreKeyed,
            retryStrategy: .fixed(delay: .seconds(5)),
            maxConcurrentConnections: maxConcurrentConnections)
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
    /// - Throws: The first error encountered, after every server has been attempted. Servers that
    ///   succeeded stay connected. `ConnectionManagerMetricsDelegate.parallelConnectionDidComplete`
    ///   is always reported before the error is rethrown.
    public func connectParallel(
        to servers: [ServerLocation],
        maxReconnectionAttempts: Int = 6,
        timeout: TimeAmount = .seconds(10),
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil,
        retryStrategy: RetryStrategy,
        maxConcurrentConnections: Int = 4
    ) async throws {
        _shouldReconnect = true
        let totalAttempted = servers.count
        var successful = 0
        var failed = 0
        var firstError: (any Error)?
        
        await withTaskGroup(of: Result<Void, any Error>.self) { group in
            var activeConnections = 0
            var serverIndex = 0
            
            while serverIndex < servers.count || activeConnections > 0 {
                // Start new connections up to the concurrency limit
                while activeConnections < maxConcurrentConnections && serverIndex < servers.count {
                    let server = servers[serverIndex]
                    serverIndex += 1
                    activeConnections += 1
                    
                    group.addTask { [weak self] in
                        guard let self else { return .failure(CancellationError()) }
                        do {
                            try await self.attemptConnection(
                                to: server,
                                currentAttempt: 0,
                                maxAttempts: maxReconnectionAttempts,
                                timeout: timeout,
                                tlsPreKeyed: tlsPreKeyed,
                                retryStrategy: retryStrategy)
                            return .success(())
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                
                // Wait for at least one connection to complete. Every server is
                // attempted so the summary below is accurate; the first error is
                // rethrown after the group drains.
                if activeConnections > 0, let result = await group.next() {
                    switch result {
                    case .success:
                        successful += 1
                    case .failure(let error):
                        failed += 1
                        if firstError == nil { firstError = error }
                    }
                    activeConnections -= 1
                }
            }
        }
        
        metricsDelegate?.parallelConnectionDidComplete(
            totalAttempted: totalAttempted,
            successful: successful,
            failed: failed
        )
        
        if let firstError {
            throw firstError
        }
        // Connections are managed individually through the connection cache
    }
}

// MARK: - WebSocket

extension ConnectionManager where Inbound == WebSocketFrame, Outbound == WebSocketFrame {
    /// Connects to a list of server locations over WebSocket.
    ///
    /// Each connection performs an HTTP/1.1 upgrade using `webSocketOptions` (URI, headers,
    /// subprotocols, frame limits). The resulting channels carry `WebSocketFrame`s, which is why
    /// this method is only available on `ConnectionManager<WebSocketFrame, WebSocketFrame>`.
    ///
    /// The WebSocket transport applies to this call only: a later plain `connect(to:)` on the
    /// same manager establishes raw TCP channels.
    ///
    /// - Parameters:
    ///   - servers: An array of `ServerLocation` instances to connect to.
    ///   - maxReconnectionAttempts: The maximum number of attempts for the initial connection to each server. Default is 6.
    ///   - timeout: The timeout duration for each connection attempt. Default is 10 seconds.
    ///   - tlsPreKeyed: Optional pre-configured TLS settings to use for all connections.
    ///   - retryStrategy: The retry strategy to use between failed attempts.
    ///
    /// - Throws: An error if a server cannot be reached or upgraded after `maxReconnectionAttempts`.
    public func connectWebSocket(
        to servers: [ServerLocation],
        maxReconnectionAttempts: Int = 6,
        timeout: TimeAmount = .seconds(10),
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil,
        retryStrategy: RetryStrategy = .fixed(delay: .seconds(5))
    ) async throws {
        _shouldReconnect = true
        for server in servers {
            try await attemptConnection(
                to: server,
                currentAttempt: 0,
                maxAttempts: maxReconnectionAttempts,
                timeout: timeout,
                tlsPreKeyed: tlsPreKeyed,
                retryStrategy: retryStrategy,
                transport: .webSocket)
        }
    }
}
