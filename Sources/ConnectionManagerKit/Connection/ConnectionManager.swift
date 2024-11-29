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

public struct ServerLocation: Sendable {
    public var host: String
    public var port: Int
    public var enableTLS: Bool
    public var cacheKey: String
    
    public init(
        host: String,
        port: Int,
        enableTLS: Bool,
        cacheKey: String
    ) {
        self.host = host
        self.port = port
        self.enableTLS = enableTLS
        self.cacheKey = cacheKey
    }
}

public protocol ConnectionDelegate: Sendable {
#if canImport(Network)
    func handleError(_ stream: AsyncStream<NWError>)
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>)
#else
    func handleError(_ stream: AsyncStream<IOError>)
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NIOEvent>)
#endif
    func channelActive(_ stream: AsyncStream<Void>)
    func channelInActive(_ stream: AsyncStream<Void>)
    func reportChildChannel(error: any Error) async
    func deliverWriter<Outbound>(writer: NIOCore.NIOAsyncChannelOutboundWriter<Outbound>) async where Outbound : Sendable
    func deliverInboundBuffer<Inbound>(inbound: Inbound) async where Inbound : Sendable
    func configureChildChannel() async
    func shutdownChildConfiguration() async
}

public actor ConnectionManager {
    
    public nonisolated(unsafe) var delegate: ConnectionDelegate?
    fileprivate nonisolated(unsafe) var childChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>?
    private let lock = NIOLock()
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
    
    public func connect(
        to servers: [ServerLocation],
        delegate: ConnectionDelegate?
    ) async throws {
        self.delegate = delegate
        

        for server in servers {
            do {
                //1. We must perform the connection to the endpoint
                let childChannel = try await createConnection(
                    host: server.host,
                    port: server.port,
                    enableTLS: server.enableTLS
                )
                await connectionCache.cacheConnection(.init(config: server, childChannel: childChannel, delegate: self), for: server.cacheKey)
            } catch {
                //2. If they are not online yet attempt to connect to them until they come online.
                print(error)
            }
        }
        
        serviceGroup = await ServiceGroup(
            services: connectionCache.fetchAllConnections(),
            logger: .init(label: "Synchronization"))
        try await serviceGroup?.run()
    }
    
    
    public func createConnection(
        host: String,
        port: Int,
        enableTLS: Bool = true
    ) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        func socketChannelCreator() async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
            let sslContext = try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
            let client = ClientBootstrap(group: group)
            let bootstrap = try NIOClientTCPBootstrap(
                client,
                tls: NIOSSLClientTLSProvider(
                    context: sslContext,
                    serverHostname: host
                )
            )
            
            if enableTLS {
                bootstrap.enableTLS()
            }
            
            return try await client
                .connectTimeout(.minutes(1))
                .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .connect(host: host, port: port) { channel in
                    return createHandlers(channel)
                }
        }
        
#if canImport(Network)
        var connection = NIOTSConnectionBootstrap(group: group)
        let tcpOptions = NWProtocolTCP.Options()
        connection = connection.tcpOptions(tcpOptions)
        
        if enableTLS {
            let tlsOptions = NWProtocolTLS.Options()
            connection = connection.tlsOptions(tlsOptions)
        }
        
        connection = connection
            .connectTimeout(.minutes(1))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        
        var channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        do {
            channel = try await connection.connect(host: host, port: port) { channel in
                return createHandlers(channel)
            }
        } catch {
            try await childChannel?.executeThenClose { inbound, outbound in
                outbound.finish()
            }
            throw error
        }
        return channel
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
                let childChannel = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                setChannel(childChannel: childChannel)

                if let errorStream = monitor.errorStream {
                    delegate?.handleError(errorStream)
                }
                if let eventStream = monitor.eventStream {
                    delegate?.handleNetworkEvents(eventStream)
                }
                if let channelActiveStream = monitor.channelActiveStream {
                    delegate?.channelActive(channelActiveStream)
                }
                if let channelInActiveStream = monitor.channelInActiveStream {
                    delegate?.channelInActive(channelInActiveStream)
                }
                return childChannel
            }
        }
    }
    
    nonisolated private func setChannel(childChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>?) {
        lock.lock()
        defer { lock.unlock() }
        self.childChannel = childChannel
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

public final class NetworkEventMonitor: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    
    private let didSetError = ManagedAtomic(false)
#if canImport(Network)
    var errorStream: AsyncStream<NWError>?
    private var errorContinuation: AsyncStream<NWError>.Continuation?
    var eventStream: AsyncStream<NetworkEvent>?
    private var eventContinuation: AsyncStream<NetworkEvent>.Continuation?
#else
    var errorStream: AsyncStream<IOError>?
    private var errorContinuation: AsyncStream<IOError>.Continuation?
    var eventStream: AsyncStream<NIOEvent>?
    private var eventContinuation: AsyncStream<NIOEvent>.Continuation?
#endif
    var channelActiveStream: AsyncStream<Void>?
    private var channelActiveContinuation: AsyncStream<Void>.Continuation?
    var channelInActiveStream: AsyncStream<Void>?
    private var channelInActiveContinuation: AsyncStream<Void>.Continuation?

    
    init() {
#if canImport(Network)
        errorStream = AsyncStream<NWError>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.errorContinuation = continuation
        }
        
        eventStream = AsyncStream<NetworkEvent>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.eventContinuation = continuation
        }
#else
        errorStream = AsyncStream<IOError>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.errorContinuation = continuation
        }
        
        eventStream = AsyncStream<NIOEvent>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.eventContinuation = continuation
        }
#endif
        channelActiveStream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.channelActiveContinuation = continuation
        }
        channelInActiveStream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.channelInActiveContinuation = continuation
        }
    }
    
    public func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.fireErrorCaught(error)
#if canImport(Network)
        let nwError = error as? NWError
        if nwError == .posix(.ENETDOWN) || nwError == .posix(.ENOTCONN), !didSetError.load(ordering: .acquiring) {
            didSetError.store(true, ordering: .relaxed)
            if let nwError = nwError {
                errorContinuation?.yield(nwError)
            } 
        }
#else
    let error = error as? IOError
    if error?.errnoCode == ENETDOWN || error?.errnoCode == ENOTCONN, !didSetError.load(ordering: .acquiring) {
        didSetError.store(true, ordering: .relaxed)
        if let error: IOError = error {
                errorContinuation?.yield(error)
            } 
    }
#endif
    }
    
#if canImport(Network)
    public enum NetworkEvent: Sendable {
        case betterPathAvailable(NIOTSNetworkEvents.BetterPathAvailable)
        case betterPathUnavailable
        case viabilityChanged(NIOTSNetworkEvents.ViabilityUpdate)
        case connectToNWEndpoint(NIOTSNetworkEvents.ConnectToNWEndpoint)
        case bindToNWEndpoint(NIOTSNetworkEvents.BindToNWEndpoint)
        case waitingForConnectivity(NIOTSNetworkEvents.WaitingForConnectivity)
        case pathChanged(NIOTSNetworkEvents.PathChanged)
    }
#else
    public enum NIOEvent: @unchecked Sendable {
        case event(Any)
    }
#endif
    
    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        context.fireUserInboundEventTriggered(event)
#if canImport(Network)
        guard let networkEvent = event as? any NIOTSNetworkEvent else {
            return
        }
        
        let eventType: NetworkEvent?
        
        switch networkEvent {
        case let event as NIOTSNetworkEvents.BetterPathAvailable:
            eventType = .betterPathAvailable(event)
        case is NIOTSNetworkEvents.BetterPathUnavailable:
            eventType = .betterPathUnavailable
        case let event as NIOTSNetworkEvents.ViabilityUpdate:
            eventType = .viabilityChanged(event)
        case let event as NIOTSNetworkEvents.ConnectToNWEndpoint:
            eventType = .connectToNWEndpoint(event)
        case let event as NIOTSNetworkEvents.BindToNWEndpoint:
            eventType = .bindToNWEndpoint(event)
        case let event as NIOTSNetworkEvents.WaitingForConnectivity:
            eventType = .waitingForConnectivity(event)
        case let event as NIOTSNetworkEvents.PathChanged:
            eventType = .pathChanged(event)
        default:
            eventType = nil
        }
        if let eventType = eventType {
            eventContinuation?.yield(eventType)
        }
#else
        eventContinuation?.yield(NIOEvent.event(event))
#endif
    }

    public func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        channelActiveContinuation?.yield()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        context.fireChannelInactive()
        channelInActiveContinuation?.yield()
    }
}
