//
//  MockConnectionDelegate.swift
//  connection-manager-kit
//
//  Created by Cole M on 9/26/25.
//
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOExtras
#if canImport(Network)
import Network
#endif
@testable import ConnectionManagerKit

final class MockConnectionDelegate<TestInbound: Sendable, TestOutbound: Sendable>: ConnectionDelegate, @unchecked Sendable {
    
    var responseStream = AsyncStream<TestInbound>.makeStream()
    var writer: NIOAsyncChannelOutboundWriter<TestOutbound>?
    
#if canImport(Network)
    func handleError(_ stream: AsyncStream<NWError>, id: String) {}
    
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {}
#else
    func handleError(_ stream: AsyncStream<IOError>, id: String) {}
    
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NIOEvent>, id: String) async {}
#endif
    
    func initializedChildChannel<Outbound, Inbound>(
        _ context: ConnectionManagerKit.ChannelContext<Inbound, Outbound>
    ) async where Outbound: Sendable, Inbound: Sendable {
        if let serverClientContextDelegate {
            await listener?.setContextDelegate(serverClientContextDelegate, key: context.id)
            print("Server context delegate set for channel: \(context.id)")
        }
    }
    
    nonisolated(unsafe) var servers = [ServerLocation]()
    let listenerDelegation: (any ListenerDelegate)?
    let listener: ConnectionListener<TestInbound, TestOutbound>?
    let serverClientContextDelegate: ChannelContextDelegate?
    nonisolated(unsafe) var networkEventTask: Task<Void, Never>?
    nonisolated(unsafe) var inactiveTask: Task<Void, Never>?
    nonisolated(unsafe) var errorTask: Task<Void, Never>?
    let manager: ConnectionManager<TestInbound, TestOutbound>?
    
    init(listener: ConnectionListener<TestInbound, TestOutbound>? = nil, serverClientContextDelegate: ChannelContextDelegate? = nil, manager: ConnectionManager<TestInbound, TestOutbound>? = nil, listenerDelegation: (any ListenerDelegate)?) {
        self.listener = listener
        self.serverClientContextDelegate = serverClientContextDelegate
        self.manager = manager
        self.listenerDelegation = listenerDelegation
    }
    
    private func tearDown() async {
        if let manager, await manager.connectionCache.isEmpty {
            networkEventTask?.cancel()
            errorTask?.cancel()
            inactiveTask?.cancel()
        }
    }
}
