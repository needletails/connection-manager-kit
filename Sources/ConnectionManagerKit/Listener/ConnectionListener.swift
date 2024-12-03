//
//  ConnectionListener.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/28/24.
//
import Foundation
import NIOCore
import NIOPosix
import NIOExtras
import ServiceLifecycle

public actor ConnectionListener {
    
    
    public var serviceGroup: ServiceGroup?
    public nonisolated(unsafe) var delegate: ConnectionDelegate?
    public nonisolated(unsafe) var listenerDelegate: ListenerDelegate?
    var serverService: ServerChildChannelService<ByteBuffer, ByteBuffer>?
    
    public func setContextDelegate(_ delegate: ChannelContextDelegate, key: String) async {
        await serverService?.setContextDelegate(delegate, key: key)
    }
    
    public init() {}
    
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
        self.serverService = serverService
        serviceGroup = ServiceGroup(
            services: [serverService],
            logger: .init(label: "[Connection Listener]"))
        try await serverService.run()
    }
    
    public func shutdownChildChannel(id: String) async {
        await serverService?.shutdownChildChannel(id: id)
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
    func initializedChildChannel<Outbound, Inbound>(_ context: ChannelContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable {
        await delegate?.initializedChildChannel(context)
    }
}
