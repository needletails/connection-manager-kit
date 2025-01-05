import Atomics
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOExtras
import NIOPosix
import NIOSSL
import ServiceLifecycle

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

public actor ConnectionManager {

    private let group: EventLoopGroup
    let connectionCache = ConnectionCache<ByteBuffer, ByteBuffer>()
    private var serviceGroup: ServiceGroup?
    nonisolated(unsafe) var shutdownTask: Task<Void, Never>?
    nonisolated(unsafe) public var channelHandlers: [ChannelHandler] = []
    private var _shouldReconnect = true
    public var shouldReconnect: Bool {
        get async {
            _shouldReconnect
        }
    }
    
    public init() {
        #if canImport(Network)
            self.group = NIOTSEventLoopGroup.singleton
        #else
            self.group = MultiThreadedEventLoopGroup.singleton
        #endif
    }
    
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
                    config: server,
                    childChannel: childChannel,
                    delegate: self), for: server.cacheKey)
        } catch {
            // If the connection fails
            print("Failed to connect to the client. Attempt: \(currentAttempt + 1) of \(maxAttempts)")

            if currentAttempt < maxAttempts - 1 {
                // Recursively attempt to connect again
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
    
    enum Errors: Error {
        case tlsNotConfigured
    }
    
    /// This is the entry point for creating connections. After we create a connection we cache for retieval later
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
                    port: server.port) { [weak self] channel in
                        guard let self else { return group.next().makePromise(of: NIOAsyncChannel<ByteBuffer, ByteBuffer>.self).futureResult }
                    return createHandlers(channel, channelHandlers: self.channelHandlers)
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
                    connection = connection.tlsOptions(tlsOptions)
                }
            }

            connection = connection
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            
            return try await connection.connect(
                host: server.host,
                port: server.port) { [weak self] channel in
                    guard let self else { return group.next().makePromise(of: NIOAsyncChannel<ByteBuffer, ByteBuffer>.self).futureResult }
                    return createHandlers(channel, channelHandlers: self.channelHandlers)
            }
#else
            return try await socketChannelCreator()
#endif

        @Sendable func createHandlers(_
                                      channel: Channel,
                                      channelHandlers: [ChannelHandler]
        ) -> EventLoopFuture<NIOAsyncChannel<ByteBuffer, ByteBuffer>> {
            
            var handlers = [ChannelHandler]()
            let monitor = NetworkEventMonitor()
            handlers.append(monitor)
            handlers.append(contentsOf: channelHandlers)
            
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandlers(handlers)

                if let errorStream = monitor.errorStream {
                    server.delegate.handleError(errorStream)
                }
                if let eventStream = monitor.eventStream {
                    server.delegate.handleNetworkEvents(eventStream)
                }
                if let channelActiveStream = monitor.channelActiveStream {
                    server.contextDelegate.channelActive(channelActiveStream)
                }
                if let channelInActiveStream = monitor.channelInActiveStream {
                    server.contextDelegate.channelInActive(channelInActiveStream)
                }
                return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                    wrappingChannelSynchronously: channel)
            }
        }
    }

    public func shutdown(cacheKey: String) async {
        do {
            await serviceGroup?.triggerGracefulShutdown()
            try await connectionCache.removeConnection(cacheKey)
            print("Gracefully shutdown service and removed connection from cache")
        } catch {
            print("Error shutting down connection group: \(error)")
            await serviceGroup?.triggerGracefulShutdown()
        }
    }
}
