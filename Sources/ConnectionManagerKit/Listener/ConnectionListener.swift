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
import NIOSSL
import ServiceLifecycle
import NeedleTailLogger
import Logging

public actor ConnectionListener<Inbound: Sendable, Outbound: Sendable>: ServiceListenerDelegate {
    
    public var serviceGroup: ServiceGroup?
    public var delegate: ConnectionDelegate?
    nonisolated(unsafe) public var listenerDelegate: ListenerDelegate?
    var serverService: ServerService<Inbound, Outbound>?
    let logger: NeedleTailLogger
    
    nonisolated func retrieveSSLHandler() -> NIOSSL.NIOSSLServerHandler? {
        listenerDelegate?.retrieveSSLHandler()
    }
    
    nonisolated func retrieveChannelHandlers() -> [ChannelHandler] {
        guard let listenerDelegate else { return [] }
        return listenerDelegate.retrieveChannelHandlers()
    }
    
    public func setContextDelegate(_ delegate: ChannelContextDelegate, key: String) async {
        await serverService?.setContextDelegate(delegate, key: key)
    }
    
    public init(logger: NeedleTailLogger = NeedleTailLogger(.init(label: "[Connection Listener]"))) {
        self.logger = logger
    }
    
    /// Convenience initializer for ByteBuffer types (most common use case)
    public static func byteBuffer(logger: NeedleTailLogger = NeedleTailLogger(.init(label: "[Connection Listener]"))) -> ConnectionListener<ByteBuffer, ByteBuffer> {
        return ConnectionListener<ByteBuffer, ByteBuffer>(logger: logger)
    }
    
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
        
        let serverService = ServerService<Inbound, Outbound>(
            address: address,
            configuration: configuration,
            logger: logger,
            delegate: self,
            listenerDelegate: listenerDelegate,
            serviceListenerDelegate: self)
        
        self.serverService = serverService
        serviceGroup = ServiceGroup(
            services: [serverService],
            logger: .init(label: "[Listener Service Group]"))
        try await serverService.run()
    }
    
    public func shutdownChildChannel(id: String) async {
        await serverService?.shutdownChildChannel(id: id)
    }
    
    public func shutdown() async throws {
        try await serverService?.shutdown()
    }
}


extension ConnectionListener: ChildChannelServiceDelegate {
    func initializedChildChannel<OutboundType, InboundType>(_ context: ChannelContext<InboundType, OutboundType>) async where OutboundType : Sendable, InboundType : Sendable {
        await delegate?.initializedChildChannel(context)
    }
}

extension NIOSSLServerHandler: @retroactive @unchecked Sendable {}
