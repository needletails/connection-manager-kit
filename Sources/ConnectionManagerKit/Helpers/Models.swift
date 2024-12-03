//
//  Models.swift
//  connection-manager-kit
//
//  Created by Cole M on 12/2/24.
//
import Foundation
import NIOCore

/// We need an object that allows us to know which Channel, Writer, and Stream we are dealing with in the Client. This allows the NIOAsyncChannels to be handled internally, but exposes them for use externally
public struct ChannelContext<Inbound: Sendable, Outbound: Sendable>: Sendable {
    public let id: String
    public let channel: NIOAsyncChannel<Inbound, Outbound>
}

public struct WriterContext<Inbound: Sendable, Outbound: Sendable>: Sendable {
    public let id: String
    public let channel: NIOAsyncChannel<Inbound, Outbound>
    public let writer: NIOAsyncChannelOutboundWriter<Outbound>
}

public struct StreamContext<Inbound: Sendable, Outbound: Sendable>: Sendable {
    public let id: String
    public let channel: NIOAsyncChannel<Inbound, Outbound>
    public let inbound: Inbound
}

///Connection Servers
public struct ServerLocation: Sendable {
    public var host: String
    public var port: Int
    public var enableTLS: Bool
    public var cacheKey: String
    /// Each connection delegate needs to map to it's own conformer
    public let delegate: ConnectionDelegate
    /// Each context delegate needs to map to it's own conformer
    public let contextDelegate: ChannelContextDelegate
    
    public init(
        host: String,
        port: Int,
        enableTLS: Bool,
        cacheKey: String,
        delegate: ConnectionDelegate,
        contextDelegate: ChannelContextDelegate
    ) {
        self.host = host
        self.port = port
        self.enableTLS = enableTLS
        self.cacheKey = cacheKey
        self.delegate = delegate
        self.contextDelegate = contextDelegate
    }
}

///Server Configuration
public struct Configuration: Sendable {
    
    public let group: EventLoopGroup
    public var host: String?
    public var port: Int
    public let backlog: Int = 256
    public var loadBalancedClients: [ServerLocation]
    public var origin: String?
    public var address: SocketAddress?
    
    public init(
        group: EventLoopGroup,
        host: String? = nil,
        port: Int = 0,
        loadBalancedServers: [ServerLocation] = []
    ) {
        self.group = group
        self.host = host
        self.port = port
        self.loadBalancedClients = loadBalancedServers
    }
}
