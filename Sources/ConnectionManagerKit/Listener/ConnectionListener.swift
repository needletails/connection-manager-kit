//
//  ConnectionListener.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/28/24.
//
import NIOCore
import NIOPosix
import NIOExtras
import ServiceLifecycle

public struct Configuration: Sendable {
    
    let group: EventLoopGroup
    let host: String?
    let port: Int
    let backlog: Int = 256
    let loadBalancedServers: [ServerLocation]
    var origin: String?
    var address: SocketAddress?
    
    init(
        group: EventLoopGroup,
        host: String? = nil,
        port: Int = 0,
        loadBalancedServers: [ServerLocation] = []
    ) {
        self.group = group
        self.host = host
        self.port = port
        self.loadBalancedServers = loadBalancedServers
    }
}

protocol ListenerDelegate: AnyObject {
    func didBindServer(channel: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>) async
}

actor ConnectionListener {
    
    
    public var serviceGroup: ServiceGroup?
    public nonisolated(unsafe) var delegate: ConnectionDelegate?
    public nonisolated(unsafe) var listenerDelegate: ListenerDelegate?
    
    public func resolveAddress(_ configuration: Configuration) throws -> Configuration {
        var configuration = configuration
        let address: SocketAddress
        if let host = configuration.host {
            address = try SocketAddress
                .makeAddressResolvingHost(host, port: configuration.port)
        } else {
            var addr = sockaddr_in()
            addr.sin_port = in_port_t(configuration.port).bigEndian
            address = SocketAddress(addr, host: "*")
        }
        
        //We can have the ability for multiple servers connected through an IRC Network. We probably don't want to do that for what we are doing, but we can create a flow that adds an array of origins that we can loop through later when needed.
        let origin: String = {
            let s = configuration.origin ?? ""
            if !s.isEmpty { return s }
            if let s = configuration.host { return s }
            return "no-origin" // TBD
        }()
        configuration.origin = origin
        configuration.address = address
        return configuration
    }
    
    public func listen(
        address: SocketAddress,
        configuration: Configuration,
        delegate: ConnectionDelegate?,
        listenerDelegate: ListenerDelegate?
    ) async throws {
        self.delegate = delegate
        self.listenerDelegate = listenerDelegate
        let serverChannel = try await bindServer(
            address: address,
            configuration: configuration)
        await self.listenerDelegate?.didBindServer(channel: serverChannel)
        
        let serverService = ServerChildChannelService<ByteBuffer, ByteBuffer>(serverChannel: serverChannel, delegate: self)
        serviceGroup = ServiceGroup(
            services: [serverService],
            logger: .init(label: "[Connection Listener]"))
        try await serverService.run()
    }
    
    func bindServer(
        address: SocketAddress,
        configuration: Configuration
    ) async throws -> NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never> {
        return try await ServerBootstrap(group: configuration.group)
        // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: Int32(configuration.backlog))
        // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .bind(to: address, childChannelInitializer: { channel in
                channel.eventLoop.makeCompletedFuture {
#if !DEBUG
                    try channel.pipeline.syncOperations.addHandler(try self.getSSLHandler())
#endif
                    try channel.pipeline.syncOperations.addHandlers([
                        LengthFieldPrepender(lengthFieldBitLength: .threeBytes),
                        ByteToMessageHandler(
                            LengthFieldBasedFrameDecoder(lengthFieldBitLength: .threeBytes),
                            maximumBufferSize: 16777216
                        ),
                    ])
                    return try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                }
            })
    }
}


extension ConnectionListener: ChildChannelServiceDelelgate {
    func reportChildChannel(error: any Error) async {
        await delegate?.reportChildChannel(error: error)
    }
    
    func deliverWriter<Outbound>(writer: NIOCore.NIOAsyncChannelOutboundWriter<Outbound>) async where Outbound : Sendable {
        await delegate?.deliverWriter(writer: writer)
    }
    
    func deliverInboundBuffer<Inbound>(inbound: Inbound) async where Inbound : Sendable {
        await delegate?.deliverInboundBuffer(inbound: inbound)
    }
    
    func configureChildChannel() async {
        await delegate?.configureChildChannel()
    }
    
    func shutdownChildConfiguration() async {
        await delegate?.shutdownChildConfiguration()
    }
}



actor ServerChildChannelService<Inbound: Sendable, Outbound: Sendable>: Service {
    
    let serverChannel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>
    let delegate: ChildChannelServiceDelelgate
    init(
        serverChannel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>,
        delegate: ChildChannelServiceDelelgate
    ) {
        self.serverChannel = serverChannel
        self.delegate = delegate
    }
        
    func run() async throws {
        try await executeTask()
    }

    nonisolated private func executeTask() async throws {
        
        let serverChannelInTaskGroup = try await encapsulatedServerChannelInTaskGroup(serverChannel: serverChannel)
        try await handleChildTaskGroup(serverChannel: serverChannelInTaskGroup) { childChannel in
            do {
                try await self.handleChildChannel(childChannel: childChannel)
            } catch {
                try await childChannel.executeThenClose { inbound, outbound in
                    outbound.finish()
                }
            }
        }
    }
    
    func encapsulatedServerChannelInTaskGroup(
        serverChannel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>
    ) async throws -> NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never> {
        try await withThrowingTaskGroup(of: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>.self) { group in
            group.addTask {
                await withTaskGroup(of: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>.self) { _ in
                    return serverChannel
                }
            }
            return try await group.next()!
        }
    }
    
    
    func handleChildTaskGroup(
        serverChannel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>,
        inboundChannelCompletion: @Sendable @escaping () async throws -> Void,
        childChannelCompletion: @Sendable @escaping (NIOAsyncChannel<Inbound, Outbound>) async throws -> Void
    ) async throws {
        try await serverChannel.executeThenClose { inbound in
            try await inboundChannelCompletion()
            // Create a group for the child channel
            try await withThrowingDiscardingTaskGroup { group in
                for try await childChannel in inbound.cancelOnGracefulShutdown() {
                    // For each new client that connects to the server, create a new group for that handler
                    group.addTask {
                        try await childChannelCompletion(childChannel)
                    }
                }
            }
        }
    }
    
    func handleChildTaskGroup(
        serverChannel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>,
        childChannelCompletion: @Sendable @escaping (NIOAsyncChannel<Inbound, Outbound>) async throws -> Void
    ) async throws {
        try await serverChannel.executeThenClose { inbound in
            // Create a group for the child channel
            try await withThrowingDiscardingTaskGroup { group in
                for try await childChannel in inbound.cancelOnGracefulShutdown() {
                    // For each new client that connects to the server, create a new group for that handler
                    group.addTask {
                        try await childChannelCompletion(childChannel)
                    }
                }
            }
        }
    }
    
    
    nonisolated func handleChildChannel(childChannel: NIOAsyncChannel<Inbound, Outbound>) async throws {
        try await childChannel.executeThenClose { inbound, outbound in
            try await withThrowingDiscardingTaskGroup { group in
                
                await delegate.configureChildChannel()
                
                do {
                    let (_outbound, outboundContinuation) = AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.makeStream()
                    
                    outboundContinuation.onTermination = { status in
#if DEBUG
                        print("Server Writer Stream Terminated with status: \(status)")
#endif
                    }
                    
                    let (_inbound, inboundContinuation) = AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.makeStream()
                    inboundContinuation.onTermination = { status in
#if DEBUG
                        print("Server Inbound Stream Terminated with status: \(status)")
#endif
                        outboundContinuation.finish()
                    }
                    
                    outboundContinuation.yield(outbound)
                    inboundContinuation.yield(inbound)
                    
                    _ = group.addTaskUnlessCancelled { [weak self] in
                        guard let self else { return }
                        for await writer in _outbound {
                            await delegate.deliverWriter(writer: writer)
                        }
                    }
                    
                    try await handleStream(
                        group: group,
                        inboundStream: _inbound
                    )
                } catch {
                    await delegate.reportChildChannel(error: error)
                }
            }
        }
    }
    
    nonisolated func handleStream(
        group: ThrowingDiscardingTaskGroup<any Error>,
        inboundStream: AsyncStream<NIOAsyncChannelInboundStream<Inbound>>
    ) async throws {
        var group = group
        for await stream in inboundStream {
            for try await inbound in stream.cancelOnGracefulShutdown() {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await delegate.deliverInboundBuffer(inbound: inbound)
                }
            }
            await delegate.shutdownChildConfiguration()
            return
        }
    }
}
