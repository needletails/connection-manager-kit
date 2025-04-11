//
//  Protcols.swift
//  connection-manager-kit
//
//  Created by Cole M on 12/2/24.
//
import Foundation
import NIOCore
import NIOSSL
#if canImport(Network)
import Network
#endif

protocol ChildChannelServiceDelelgate: Sendable {
    func initializedChildChannel<Outbound, Inbound>(_ context: ChannelContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable
}


public protocol ConnectionDelegate: AnyObject, Sendable {
#if canImport(Network)
    func handleError(_ stream: AsyncStream<NWError>, id: String)
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async
#else
    func handleError(_ stream: AsyncStream<IOError>, id: String)
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NIOEvent>, id: String) async
#endif
    func initializedChildChannel<Outbound, Inbound>(_ context: ChannelContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable
}

public protocol ChannelContextDelegate: AnyObject, Sendable {
    func channelActive(_ stream: AsyncStream<Void>, id: String)
    func channelInactive(_ stream: AsyncStream<Void>, id: String)
    func reportChildChannel(error: any Error, id: String) async
    func didShutdownChildChannel() async
    func deliverWriter<Outbound, Inbound>(context: WriterContext<Inbound, Outbound>) async
    func deliverInboundBuffer<Inbound: Sendable, Outbound: Sendable>(context: StreamContext<Inbound, Outbound>) async
}


// MARK: Server Side
public protocol ListenerDelegate: AnyObject, Sendable {
    func didBindServer<Inbound: Sendable, Outbound: Sendable>(channel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>) async
    nonisolated func retrieveSSLHandler() -> NIOSSLServerHandler?
    nonisolated func retrieveChannelHandlers() -> [ChannelHandler]
}

protocol ServiceListenerDelegate: AnyObject {
    func retrieveSSLHandler() -> NIOSSLServerHandler?
    func retrieveChannelHandlers() -> [ChannelHandler]
}
