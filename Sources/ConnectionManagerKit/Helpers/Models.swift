//
//  Models.swift
//  connection-manager-kit
//
//  Created by Cole M on 12/02/24.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//  This file is part of the ConnectionManagerKit Project

import Foundation
import NIOCore
import NIOHTTP1
#if canImport(Network)
import Network
#endif

/// A context object that provides access to a channel and its associated metadata.
///
/// This struct encapsulates a channel along with a unique identifier, allowing for easy
/// tracking and management of individual connections in a client application.
///
/// ## Usage Example
/// ```swift
/// let channelContext = ChannelContext<ByteBuffer, ByteBuffer>(
///     id: "connection-1",
///     channel: myChannel
/// )
/// ```
///
/// - Note: The generic parameters `Inbound` and `Outbound` define the data types
///   that can be sent and received through this channel.
public struct ChannelContext<Inbound: Sendable, Outbound: Sendable>: Sendable {
    /// A unique identifier for this channel context.
    public let id: String
    
    /// The underlying NIO async channel for this connection.
    public let channel: NIOAsyncChannel<Inbound, Outbound>
}

/// A context object that provides access to a channel's writer and associated metadata.
///
/// This struct extends `ChannelContext` by including a writer for sending data through
/// the channel. It's useful when you need to send data but don't need the full channel context.
///
/// ## Usage Example
/// ```swift
/// let writerContext = WriterContext<ByteBuffer, ByteBuffer>(
///     id: "connection-1",
///     channel: myChannel,
///     writer: myChannel.outboundWriter
/// )
/// 
/// // Send data through the writer
/// try await writerContext.writer.write(someData)
/// ```
public struct WriterContext<Inbound: Sendable, Outbound: Sendable>: Sendable {
    /// A unique identifier for this writer context.
    public let id: String
    
    /// The underlying NIO async channel for this connection.
    public let channel: NIOAsyncChannel<Inbound, Outbound>
    
    /// The writer for sending data through this channel.
    public let writer: NIOAsyncChannelOutboundWriter<Outbound>
}

/// A context object that provides access to inbound data and associated metadata.
///
/// This struct encapsulates inbound data received through a channel along with the
/// channel context. It's useful for processing received data while maintaining
/// connection context.
///
/// ## Usage Example
/// ```swift
/// let streamContext = StreamContext<ByteBuffer, ByteBuffer>(
///     id: "connection-1",
///     channel: myChannel,
///     inbound: receivedData
/// )
/// 
/// // Process the received data
/// processData(streamContext.inbound)
/// ```
public struct StreamContext<Inbound: Sendable, Outbound: Sendable>: Sendable {
    /// A unique identifier for this stream context.
    public let id: String
    
    /// The underlying NIO async channel for this connection.
    public let channel: NIOAsyncChannel<Inbound, Outbound>
    
    /// The inbound data received through this channel.
    public let inbound: Inbound
}

/// Configuration for a server location that can be connected to.
///
/// This struct defines all the necessary information to establish a connection to a server,
/// including network details, TLS configuration, and delegate assignments for handling
/// connection events.
///
/// ## Usage Example
/// ```swift
/// let serverLocation = ServerLocation(
///     host: "api.example.com",
///     port: 443,
///     enableTLS: true,
///     cacheKey: "api-server",
///     delegate: myConnectionDelegate,
///     contextDelegate: myContextDelegate
/// )
/// ```
public struct ServerLocation: Sendable {
    /// The hostname or IP address of the server.
    public var host: String
    
    /// The port number to connect to.
    public var port: Int
    
    /// Whether TLS/SSL should be enabled for this connection.
    public var enableTLS: Bool
    
    /// A unique key used for caching this connection.
    ///
    /// This key is used internally to identify and cache the connection.
    /// It should be unique across all server locations in your application.
    public var cacheKey: String
    
    /// The delegate responsible for handling connection-level events.
    ///
    /// This delegate will receive notifications about connection state changes,
    /// network events, and errors.
    public var delegate: ConnectionDelegate?
    
    /// The delegate responsible for handling channel context events.
    ///
    /// This delegate will receive notifications about channel lifecycle events,
    /// such as when data is received or when the channel becomes active/inactive.
    public var contextDelegate: ChannelContextDelegate?
    
    /// Creates a new server location configuration.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address of the server.
    ///   - port: The port number to connect to.
    ///   - enableTLS: Whether TLS/SSL should be enabled for this connection.
    ///   - cacheKey: A unique key used for caching this connection.
    ///   - delegate: The delegate responsible for handling connection-level events.
    ///   - contextDelegate: The delegate responsible for handling channel context events.
    public init(
        host: String,
        port: Int,
        enableTLS: Bool,
        cacheKey: String,
        delegate: ConnectionDelegate? = nil,
        contextDelegate: ChannelContextDelegate? = nil
    ) {
        self.host = host
        self.port = port
        self.enableTLS = enableTLS
        self.cacheKey = cacheKey
        self.delegate = delegate
        self.contextDelegate = contextDelegate
    }
}

/// WebSocket client options
public struct WebSocketOptions: Sendable {
    
    public var uri: String
    public var headers: HTTPHeaders
    public var subprotocols: [String]?
    public var maxFrameSize: Int
    public let minNonFinalFragmentSize: Int
    public let maxAccumulatedFrameCount: Int
    public let maxAccumulatedFrameSize: Int
    public var enableCompression: Bool
    
    public init(
        uri: String = "/",
        headers: HTTPHeaders = HTTPHeaders(),
        subprotocols: [String]? = nil,
        maxFrameSize: Int = 1 << 14,
        minNonFinalFragmentSize: Int = 0,
        maxAccumulatedFrameCount: Int = Int.max,
        maxAccumulatedFrameSize: Int = Int.max,
        enableCompression: Bool = false,
    ) {
        self.uri = uri
        self.headers = headers
        self.subprotocols = subprotocols
        self.maxFrameSize = maxFrameSize
        self.minNonFinalFragmentSize = minNonFinalFragmentSize
        self.maxAccumulatedFrameCount = maxAccumulatedFrameCount
        self.maxAccumulatedFrameSize = maxAccumulatedFrameSize
        self.enableCompression = enableCompression
    }
}


/// A single POSIX socket option `(level, name, value)` applied verbatim to
/// NIO channels via `ChannelOptions.socket(level, name)`.
public struct TCPSocketOption: Sendable {
    /// The protocol level (e.g. `SOL_SOCKET`, `IPPROTO_TCP`).
    public var level: CInt
    /// The option name (e.g. `SO_KEEPALIVE`, `TCP_NODELAY`).
    public var name: CInt
    /// The option value.
    public var value: CInt

    public init(level: CInt, name: CInt, value: CInt) {
        self.level = level
        self.name = name
        self.value = value
    }
}

/// Adopter-supplied TCP tuning, passed through verbatim to the underlying
/// transport. ConnectionManagerKit applies no TCP tuning of its own; adopters
/// opt in by passing options here.
///
/// Two backends exist, and each only consumes the part that applies to it:
/// - POSIX NIO bootstraps (`ClientBootstrap` on non-Apple platforms, and
///   `ServerBootstrap` child channels everywhere) apply `socketOptions`.
/// - Network.framework (`NIOTSConnectionBootstrap` on Apple platforms) invokes
///   `configureNWTCPOptions` with the `NWProtocolTCP.Options` used to connect.
public struct TCPTransportOptions: Sendable {
    /// Socket options applied to POSIX NIO channels (client connections on
    /// non-Apple platforms; accepted server child channels on all platforms).
    public var socketOptions: [TCPSocketOption]

#if canImport(Network)
    /// Configures the `NWProtocolTCP.Options` used by Network.framework
    /// client connections on Apple platforms.
    public var configureNWTCPOptions: (@Sendable (NWProtocolTCP.Options) -> Void)?

    public init(
        socketOptions: [TCPSocketOption] = [],
        configureNWTCPOptions: (@Sendable (NWProtocolTCP.Options) -> Void)? = nil
    ) {
        self.socketOptions = socketOptions
        self.configureNWTCPOptions = configureNWTCPOptions
    }
#else
    public init(socketOptions: [TCPSocketOption] = []) {
        self.socketOptions = socketOptions
    }
#endif

    /// Dead-peer detection preset: OS keepalive probes plus a bound on how
    /// long written data may sit unacknowledged, mapped to the current
    /// platform's option names.
    ///
    /// A half-open socket (peer or NAT silently dropped the path) otherwise
    /// stays "connected" indefinitely: writes buffer locally, reads never
    /// fail, and no `channelInactive` fires, so event-driven reconnect and
    /// failure paths never run. Keepalive probes cover the idle case; the
    /// unacknowledged-write timeout covers data written into a dead socket,
    /// which kernels otherwise retransmit for many minutes before erroring
    /// the connection.
    ///
    /// - Parameters:
    ///   - keepaliveIdleSeconds: Seconds a connection may sit idle before the first probe.
    ///   - keepaliveIntervalSeconds: Seconds between probes once they start.
    ///   - keepaliveProbeCount: Consecutive failed probes before the connection is declared dead.
    ///   - unacknowledgedWriteTimeoutSeconds: Seconds written data may remain unacknowledged
    ///     before the connection errors.
    public static func deadPeerDetection(
        keepaliveIdleSeconds: Int = 60,
        keepaliveIntervalSeconds: Int = 10,
        keepaliveProbeCount: Int = 3,
        unacknowledgedWriteTimeoutSeconds: Int = 30
    ) -> TCPTransportOptions {
        var socketOptions: [TCPSocketOption] = [
            TCPSocketOption(level: CInt(SOL_SOCKET), name: SO_KEEPALIVE, value: 1)
        ]
#if os(Linux) || os(Android)
        // Kernel defaults send the first probe only after ~2h idle, which
        // leaves half-open sockets undetected for the whole session.
        // TCP_USER_TIMEOUT (ms) additionally bounds how long written data may
        // sit unacknowledged before the kernel errors the connection.
        socketOptions.append(contentsOf: [
            TCPSocketOption(
                level: CInt(IPPROTO_TCP), name: TCP_KEEPIDLE,
                value: CInt(keepaliveIdleSeconds)),
            TCPSocketOption(
                level: CInt(IPPROTO_TCP), name: TCP_KEEPINTVL,
                value: CInt(keepaliveIntervalSeconds)),
            TCPSocketOption(
                level: CInt(IPPROTO_TCP), name: TCP_KEEPCNT,
                value: CInt(keepaliveProbeCount)),
            TCPSocketOption(
                level: CInt(IPPROTO_TCP), name: TCP_USER_TIMEOUT,
                value: CInt(unacknowledgedWriteTimeoutSeconds * 1000)),
        ])
#elseif canImport(Darwin)
        // Darwin spelling of the same tuning; applies to POSIX bootstraps
        // (server child channels) since NIOTS connections use NW options below.
        // TCP_KEEPALIVE is idle seconds; TCP_RXT_CONNDROPTIME is the
        // unacknowledged-retransmission bound in seconds.
        socketOptions.append(contentsOf: [
            TCPSocketOption(
                level: CInt(IPPROTO_TCP), name: TCP_KEEPALIVE,
                value: CInt(keepaliveIdleSeconds)),
            TCPSocketOption(
                level: CInt(IPPROTO_TCP), name: TCP_KEEPINTVL,
                value: CInt(keepaliveIntervalSeconds)),
            TCPSocketOption(
                level: CInt(IPPROTO_TCP), name: TCP_KEEPCNT,
                value: CInt(keepaliveProbeCount)),
            TCPSocketOption(
                level: CInt(IPPROTO_TCP), name: TCP_RXT_CONNDROPTIME,
                value: CInt(unacknowledgedWriteTimeoutSeconds)),
        ])
#endif

#if canImport(Network)
        return TCPTransportOptions(
            socketOptions: socketOptions,
            configureNWTCPOptions: { tcpOptions in
                // Keepalive probes surface an *idle* half-open socket as a
                // connection failure (the channelInactive event reconnect and
                // failure paths key off). connectionDropTime bounds how long
                // written data may go unacknowledged before the connection errors.
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = keepaliveIdleSeconds
                tcpOptions.keepaliveInterval = keepaliveIntervalSeconds
                tcpOptions.keepaliveCount = keepaliveProbeCount
                tcpOptions.connectionDropTime = unacknowledgedWriteTimeoutSeconds
            })
#else
        return TCPTransportOptions(socketOptions: socketOptions)
#endif
    }
}

/// Configuration for server-side networking setup.
///
/// This struct defines the configuration needed to set up a server that can accept
/// incoming connections. It includes network binding information, load balancing
/// configuration, and server-specific settings.
///
/// ## Usage Example
/// ```swift
/// let config = Configuration(
///     group: MultiThreadedEventLoopGroup.singleton,
///     host: "0.0.0.0",
///     port: 8080,
///     loadBalancedServers: []
/// )
/// ```
public struct Configuration: Sendable {
    
    /// The event loop group to use for network operations.
    public let group: EventLoopGroup
    
    /// The host address to bind to. If `nil`, binds to all available interfaces.
    public var host: String?
    
    /// The port number to bind to. If `0`, the system will assign an available port.
    public var port: Int
    
    /// The maximum number of pending connections in the accept queue.
    ///
    /// This value determines how many incoming connections can be queued
    /// before the server starts rejecting new connections.
    public let backlog: Int = 256
    
    /// An array of server locations for load balancing.
    ///
    /// These server locations can be used for load balancing or failover scenarios.
    /// Each server location defines a potential target for client connections.
    public var loadBalancedClients: [ServerLocation]
    
    /// The origin identifier for this server configuration.
    ///
    /// This is typically used for logging and identification purposes.
    /// If not specified, it will be derived from the host or set to "no-origin".
    public var origin: String?
    
    /// The resolved socket address for binding.
    ///
    /// This is set internally when the configuration is resolved and should
    /// not be modified directly.
    public var address: SocketAddress?
    
    /// TCP options applied to accepted child channels. Empty by default
    /// (kernel defaults); adopters opt in, e.g. `.deadPeerDetection()`.
    public var transportOptions: TCPTransportOptions
    
    /// Creates a new server configuration.
    ///
    /// - Parameters:
    ///   - group: The event loop group to use for network operations.
    ///   - host: The host address to bind to. Defaults to `nil` (all interfaces).
    ///   - port: The port number to bind to. Defaults to `0` (system-assigned).
    ///   - loadBalancedServers: An array of server locations for load balancing. Defaults to empty.
    ///   - transportOptions: TCP options for accepted child channels. Defaults to none.
    public init(
        group: EventLoopGroup,
        host: String? = nil,
        port: Int = 0,
        loadBalancedServers: [ServerLocation] = [],
        transportOptions: TCPTransportOptions = .init()
    ) {
        self.group = group
        self.host = host
        self.port = port
        self.loadBalancedClients = loadBalancedServers
        self.transportOptions = transportOptions
    }
}
