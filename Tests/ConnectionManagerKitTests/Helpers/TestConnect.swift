//
//  TestConnect.swift
//  connection-manager-kit
//
//  Raw NIO connect/bind helpers for tests that do not go through
//  `ConnectionManager`. They wait with `CancellableFuture` instead of
//  `EventLoopFuture.get()`, so a cancelled test task returns promptly and a
//  channel that connects afterwards is closed rather than leaked.
//

import NIOCore
import NIOPosix
import NIOExtras
@testable import ConnectionManagerKit

/// Connects a raw TCP client to `host:port`, installing `handlers()` in its pipeline.
func connectRaw(
    host: String,
    port: Int,
    group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    handlers: @escaping @Sendable () -> [ChannelHandler] = { [] }
) async throws -> Channel {
    let bootstrap = ClientBootstrap(group: group)
        .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let handlers = handlers()
                if !handlers.isEmpty {
                    try channel.pipeline.syncOperations.addHandlers(handlers)
                }
            }
        }
    return try await CancellableFuture.resolveChannel(bootstrap.connect(host: host, port: port))
}

/// Binds a throwaway server socket (no child handling) on `host:port`.
func bindRaw(
    host: String,
    port: Int,
    group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
) async throws -> Channel {
    try await CancellableFuture.resolveChannel(
        ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port))
}

/// Length-field framing matching `ListenerDelegation.retrieveChannelHandlers()`.
@Sendable func lengthFieldClientHandlers() -> [ChannelHandler] {
    [ByteToMessageHandler(
        LengthFieldBasedFrameDecoder(lengthFieldBitLength: .threeBytes),
        maximumBufferSize: 16_777_216)]
}
