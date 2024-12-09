//
//  Protcols.swift
//  connection-manager-kit
//
//  Created by Cole M on 12/2/24.
//
import Foundation
import NIOCore
#if canImport(Network)
import Network
#endif

protocol ChildChannelServiceDelelgate: Sendable {
    func initializedChildChannel<Outbound, Inbound>(_ context: ChannelContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable
}


public protocol ConnectionDelegate: AnyObject, Sendable {
#if canImport(Network)
    func handleError(_ stream: AsyncStream<NWError>)
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>)
#else
    func handleError(_ stream: AsyncStream<IOError>)
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NIOEvent>)
#endif
    func initializedChildChannel<Outbound, Inbound>(_ context: ChannelContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable
}

public protocol ChannelContextDelegate: AnyObject, Sendable {
    func channelActive(_ stream: AsyncStream<Void>)
    func channelInActive(_ stream: AsyncStream<Void>)
    func reportChildChannel(error: any Error) async
    func shutdownChildConfiguration() async
    func deliverWriter<Outbound, Inbound>(context: WriterContext<Inbound, Outbound>) async
    func deliverInboundBuffer<Inbound: Sendable, Outbound: Sendable>(context: StreamContext<Inbound, Outbound>) async
}


// MARK: Server Side
public protocol ListenerDelegate: AnyObject, Sendable {
    func didBindServer<Inbound: Sendable, Outbound: Sendable>(channel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>) async
}
