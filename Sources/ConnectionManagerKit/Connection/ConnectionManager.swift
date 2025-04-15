import Atomics
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOExtras
import NIOPosix
import NIOSSL
import ServiceLifecycle
import NeedleTailLogger
#if canImport(Network)
import Network
import NIOTransportServices
#endif

public struct TLSPreKeyedConfiguration: Sendable {
#if canImport(Network)
    public let tlsOption: NWProtocolTLS.Options
    public init(tlsOption: NWProtocolTLS.Options) {
        self.tlsOption = tlsOption
    }
#else
    public let tlsConfiguration: TLSConfiguration
    public init(tlsConfiguration: TLSConfiguration) {
        self.tlsConfiguration = tlsConfiguration
    }
#endif
}


/// A protocol that defines the delegate methods for managing connections in a network context.
///
/// Conforming types can provide custom channel handlers and receive the `NIOAsyncChannel` for further configuration.
public protocol ConnectionManagerDelegate: AnyObject, Sendable {
    
    /// Retrieves an array of custom channel handlers required by the consumer.
    ///
    /// This method allows the delegate to specify any additional handlers that should be added to the
    /// *NIO* pipeline. The returned handlers will be integrated into the connection's processing flow.
    ///
    /// - Returns: An array of `ChannelHandler` instances.
    func retrieveChannelHandlers() -> [ChannelHandler]
    
    /// Delivers the `NIOAsyncChannel` to the delegate for further configuration.
    ///
    /// This method provides access to the underlying `NIOChannel`, allowing the delegate to set a custom
    /// executor on the connection actor. It is essential to call this method in order to properly configure
    /// the connection manager by invoking the `setDelegates(connectionDelegate:contextDelegate:cacheKey:)`
    /// method with the conforming instances of `ConnectionDelegate` and `ChannelContextDelegate`.
    ///
    /// - Parameters:
    ///   - channel: The `NIOAsyncChannel<ByteBuffer, ByteBuffer>` instance that represents the connection.
    ///   - manager: The `ConnectionManager` instance responsible for managing the connection.
    ///
    /// - Note: This method is asynchronous and should be awaited.
    func deliverChannel(_ channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>, manager: ConnectionManager, cacheKey: String) async
}

/// A manager responsible for handling network connections, including establishing, caching, and monitoring connections.
public actor ConnectionManager {
    
    internal let connectionCache: ConnectionCache<ByteBuffer, ByteBuffer>
    private let group: EventLoopGroup
    private var serviceGroup: ServiceGroup?
    private let logger: NeedleTailLogger
    /// A weak reference to the delegate that conforms to `ConnectionManagerDelegate`.
    nonisolated(unsafe) public weak var delegate: ConnectionManagerDelegate?
    
    private var _shouldReconnect = true
    
    /// A boolean indicating whether the manager should attempt to reconnect.
    public var shouldReconnect: Bool {
        get async {
            _shouldReconnect
        }
    }
    
    /// Initializes a new `ConnectionManager` instance.
    public init(logger: NeedleTailLogger = NeedleTailLogger()) {
        self.logger = logger
        self.connectionCache = ConnectionCache<ByteBuffer, ByteBuffer>(logger: logger)
        #if canImport(Network)
        self.group = NIOTSEventLoopGroup.singleton
        #else
        self.group = MultiThreadedEventLoopGroup.singleton
        #endif
    }
    
    /// Sets the delegates for connection and context handling.
    ///
    /// - Parameters:
    ///   - connectionDelegate: The delegate responsible for handling connection events.
    ///   - contextDelegate: The delegate responsible for handling channel context events.
    ///   - cacheKey: A unique key for caching the connection.
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
    /// - Parameters:
    ///   - servers: An array of `ServerLocation` instances to connect to.
    ///   - maxReconnectionAttempts: The maximum number of reconnection attempts (default is 6).
    ///   - timeout: The timeout duration for the connection (default is 10 seconds).
    ///   - tlsPreKeyed: Optional pre-configured TLS settings.
    /// - Throws: An error if the connection fails.
    public func connect(
        to servers: [ServerLocation],
        maxReconnectionAttempts: Int = 6,
        timeout: TimeAmount = .seconds(10),
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil
    ) async throws {
        for await server in servers.async {
            try await attemptConnection(
                to: server,
                currentAttempt: 0,
                maxAttempts: maxReconnectionAttempts,
                timeout: timeout,
                tlsPreKeyed: tlsPreKeyed)
        }
        
        serviceGroup = await ServiceGroup(
            services: connectionCache.fetchAllConnections(),
            logger: .init(label: "Connection Manager"))
        try await serviceGroup?.run()
    }
    
    /// Attempts to connect to a specified server with retry logic.
    ///
    /// - Parameters:
    ///   - server: The `ServerLocation` to connect to.
    ///   - currentAttempt: The current attempt number.
    ///   - maxAttempts: The maximum number of attempts allowed.
    ///   - timeout: The timeout duration for the connection.
    ///   - tlsPreKeyed: Optional pre-configured TLS settings.
    /// - Throws: An error if the connection fails.
    private func attemptConnection(
        to server: ServerLocation,
        currentAttempt: Int,
        maxAttempts: Int,
        timeout: TimeAmount,
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil
    ) async throws {
        do {
            // Attempt to create a connection
            let childChannel = try await createConnection(
                server: server,
                group: self.group,
                timeout: timeout,
                tlsPreKeyed: tlsPreKeyed)
            await connectionCache.cacheConnection(
                .init(
                    logger: logger,
                    config: server,
                    childChannel: childChannel,
                    delegate: self), for: server.cacheKey)
            await delegate?.deliverChannel(childChannel, manager: self, cacheKey: server.cacheKey)
            
            let monitor = try await childChannel.channel.pipeline.handler(type: NetworkEventMonitor.self).get()
            if let foundConnection = await connectionCache.findConnection(cacheKey: server.cacheKey) {
                await delegateMonitorEvents(monitor: monitor, server: foundConnection.config)
            }
        } catch {
            // If the connection fails
            logger.log(level: .error, message: "Failed to connect to the server. Attempt: \(currentAttempt + 1) of \(maxAttempts)")
            
            if currentAttempt < maxAttempts - 1 {
                // Recursively attempt to connect again after a delay
                try await Task.sleep(until: .now + .seconds(5))
                try await attemptConnection(
                    to: server,
                    currentAttempt: currentAttempt + 1,
                    maxAttempts: maxAttempts,
                    timeout: timeout,
                    tlsPreKeyed: tlsPreKeyed)
            } else {
                _shouldReconnect = false
                // If max attempts reached, rethrow the error
                throw error
            }
        }
    }
    
    /// Errors that can occur within the `ConnectionManager`.
    enum Errors: Error {
        case tlsNotConfigured
    }
    
    /// Creates a connection to the specified server.
    ///
    /// - Parameters:
    ///   - server: The `ServerLocation` to connect to.
    ///   - group: The `EventLoopGroup` to use for the connection.
    ///   - timeout: The timeout duration for the connection.
    ///   - tlsPreKeyed: Optional pre-configured TLS settings.
    /// - Returns: An `NIOAsyncChannel<ByteBuffer, ByteBuffer>` representing the established connection.
    /// - Throws: An error if the connection cannot be established.
    private func createConnection(
        server: ServerLocation,
        group: EventLoopGroup,
        timeout: TimeAmount,
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil
    ) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        
        #if !canImport(Network)
        func socketChannelCreator(tlsPreKeyed: TLSPreKeyedConfiguration? = nil) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
            var tlsConfiguration = tlsPreKeyed?.tlsConfiguration
            if tlsPreKeyed == nil {
                tlsConfiguration = TLSConfiguration.makeClientConfiguration()
                tlsConfiguration?.minimumTLSVersion = .tlsv13
                tlsConfiguration?.maximumTLSVersion = .tlsv13
            }
            guard let tlsConfiguration = tlsConfiguration else { throw Errors.tlsNotConfigured }
            
            let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
            let client = ClientBootstrap(group: group)
            let bootstrap = try NIOClientTCPBootstrap(
                client,
                tls: NIOSSLClientTLSProvider(
                    context: sslContext,
                    serverHostname: server.host
                )
            )
            
            if server.enableTLS {
                bootstrap.enableTLS()
            }
            
            return try await client
                .connectTimeout(timeout)
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .connect(
                    host: server.host,
                    port: server.port) { channel in
                        return createHandlers(channel, server: server)
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
        
        return try await connection.connect(
            host: server.host,
            port: server.port) { channel in
                return createHandlers(channel, server: server)
            }
        #else
        return try await socketChannelCreator()
        #endif
        
        /// Creates handlers for the channel and adds them to the pipeline.
        ///
        /// - Parameters:
        ///   - channel: The `Channel` to which handlers will be added.
        ///   - server: The `ServerLocation` associated with the channel.
        /// - Returns: An `EventLoopFuture` containing the `NIOAsyncChannel`.
        @Sendable func createHandlers(_ channel: Channel, server: ServerLocation) -> EventLoopFuture<NIOAsyncChannel<ByteBuffer, ByteBuffer>> {
            
            let monitor = NetworkEventMonitor(connectionIdentifier: server.cacheKey)
            
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(monitor)
                if let channelHandlers = delegate?.retrieveChannelHandlers(), !channelHandlers.isEmpty {
                    try channel.pipeline.syncOperations.addHandlers(channelHandlers)
                }
                
                return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                    wrappingChannelSynchronously: channel)
            }
    }
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
    public func gracefulShutdown() async {
        do {
            await serviceGroup?.triggerGracefulShutdown()
            try await connectionCache.removeAllConnection()
            logger.log(level: .info, message: "Gracefully shut down service and removed connections from cache.")
        } catch {
            logger.log(level: .error, message: "Error shutting down connection group: \(error)")
            await serviceGroup?.triggerGracefulShutdown()
        }
        serviceGroup = nil
    }
}
