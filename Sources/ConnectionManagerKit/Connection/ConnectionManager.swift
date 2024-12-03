import NIOSSL
import NIOExtras
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
#if canImport(Network)
import Network
import NIOTransportServices
#endif
import Atomics
import Foundation
import ServiceLifecycle

public actor ConnectionManager {

    private let group: EventLoopGroup
    let connectionCache = ConnectionCache<ByteBuffer, ByteBuffer>()
    private var serviceGroup: ServiceGroup?
    
    public init() {
#if canImport(Network)
        self.group = NIOTSEventLoopGroup.singleton
#else
        self.group = MultiThreadedEventLoopGroup.singleton
#endif
    }
    
    public func connect(to servers: [ServerLocation]) async throws {

        for server in servers {
            do {
                //1. We must perform the connection to the endpoint
                let childChannel = try await createConnection(server: server)
                await connectionCache.cacheConnection(.init(
                    config: server,
                    childChannel: childChannel,
                    delegate: self), for: server.cacheKey)
            } catch {
                //2. If they are not online yet attempt to connect to them until they come online.
                print(error)
            }
        }
        
        serviceGroup = await ServiceGroup(
            services: connectionCache.fetchAllConnections(),
            logger: .init(label: "Connection Manager"))
        try await serviceGroup?.run()
    }
    
    /// This is the entry point for creating connections. After we create a connection we cache for retieval later
    private func createConnection(server: ServerLocation) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        func socketChannelCreator() async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
            let sslContext = try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
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
                .connectTimeout(.minutes(1))
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .connect(host: server.host, port: server.port) { channel in
                    return createHandlers(channel)
                }
        }
        
#if canImport(Network)
        var connection = NIOTSConnectionBootstrap(group: group)
        let tcpOptions = NWProtocolTCP.Options()
        connection = connection.tcpOptions(tcpOptions)
        
        if server.enableTLS {
            let tlsOptions = NWProtocolTLS.Options()
            connection = connection.tlsOptions(tlsOptions)
        }
        
        connection = connection
            .connectTimeout(.minutes(1))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

            return try await connection.connect(host: server.host, port: server.port) { channel in
                return createHandlers(channel)
            }
#else
        return try await socketChannelCreator()
#endif
        
        @Sendable func createHandlers(_ channel: Channel) -> EventLoopFuture<NIOAsyncChannel<ByteBuffer, ByteBuffer>> {
            let monitor = NetworkEventMonitor()
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandlers([
                    monitor,
                    LengthFieldPrepender(lengthFieldBitLength: .threeBytes),
                    ByteToMessageHandler(
                        LengthFieldBasedFrameDecoder(lengthFieldBitLength: .threeBytes),
                        maximumBufferSize: 16777216
                    ),
                ])
                //IS THIS THE CORRECT SPOT?
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
                return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            }
        }
    }
    
    public func shutdown(cacheKey: String) async {
        do {
            await serviceGroup?.triggerGracefulShutdown()
            try await connectionCache.removeConnection(cacheKey)
        } catch {
            print("Error shutting down connection group: \(error)")
            await serviceGroup?.triggerGracefulShutdown()
        }
    }
}
