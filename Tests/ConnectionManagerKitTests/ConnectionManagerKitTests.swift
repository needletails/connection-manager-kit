import Testing
import Foundation
import NIOCore
import NIOPosix
#if canImport(Network)
import Network
#endif
@testable import ConnectionManagerKit

final class ListenerDelegation: ListenerDelegate {
    
    let shouldShutdown: Bool
    var serverChannel: NIOCore.NIOAsyncChannel<NIOCore.NIOAsyncChannel<NIOCore.ByteBuffer, NIOCore.ByteBuffer>, Never>?
    
    init(shouldShutdown: Bool) {
        self.shouldShutdown = shouldShutdown
    }
    
    func didBindServer(channel: NIOCore.NIOAsyncChannel<NIOCore.NIOAsyncChannel<NIOCore.ByteBuffer, NIOCore.ByteBuffer>, Never>) async {
        serverChannel = channel
        if shouldShutdown {
            try! await channel.executeThenClose({ _, _ in } )
        }
    }
}

struct ConnectionManagerKitTests {
    
    let listener = ConnectionListener()
    let manager = ConnectionManager()
    let serverGroup = MultiThreadedEventLoopGroup.singleton
    
    @Test func testServerBinding() async throws {
        await #expect(throws: Never.self, performing: {
            let listenerDelegation = ListenerDelegation(shouldShutdown: true)
            let serverConformer = MockConnectionDelegate(manager: manager, listenerDelegation: listenerDelegation)
            let config = try await listener.resolveAddress(.init(group: serverGroup, host: "localhost", port: 6668))
            try await listener.listen(
                address: config.address!,
                configuration: config,
                delegate: serverConformer,
                listenerDelegate: listenerDelegation)
            await listener.serviceGroup?.triggerGracefulShutdown()
        })
    }
    
    @Test func testCreateConnection () async throws {
        let endpoint = "localhost"
        let conformer = MockConnectionDelegate(manager: manager, listenerDelegation: ListenerDelegation(shouldShutdown: false))
        let serverTask = Task {
            let listenerDelegation = ListenerDelegation(shouldShutdown: false)
            let serverConformer = MockConnectionDelegate(manager: manager, listenerDelegation: listenerDelegation)
            let config = try await listener.resolveAddress(.init(group: serverGroup, host: "localhost", port: 6667))
            try await listener.listen(
                address: config.address!,
                configuration: config,
                delegate: serverConformer,
                listenerDelegate: listenerDelegation)
            await listener.serviceGroup?.triggerGracefulShutdown()
        }
        
        let servers = [
            ServerLocation(host: endpoint, port: 6667, enableTLS: false, cacheKey: "s1", delegate: conformer, contextDelegate: MockChannelContextDelegate()),
            ServerLocation(host: endpoint, port: 6667, enableTLS: false, cacheKey: "s2", delegate: conformer, contextDelegate: MockChannelContextDelegate()),
            ServerLocation(host: endpoint, port: 6667, enableTLS: false, cacheKey: "s3", delegate: conformer, contextDelegate: MockChannelContextDelegate()),
            ServerLocation(host: endpoint, port: 6667, enableTLS: false, cacheKey: "s4", delegate: conformer, contextDelegate: MockChannelContextDelegate())
        ]
        
        conformer.servers.append(contentsOf: servers)
        try await manager.connect(to: servers)
        serverTask.cancel()
    }
    
    @Test func testCreateCachedConnections() async {
        let conformer = MockConnectionDelegate(manager: manager, listenerDelegation: ListenerDelegation(shouldShutdown: false))
        let c1 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l1", port: 0, enableTLS: false, cacheKey: "s1", delegate: conformer, contextDelegate: MockChannelContextDelegate()), childChannel: nil, delegate: manager)
        let c2 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l2", port: 1, enableTLS: false, cacheKey: "s2", delegate: conformer, contextDelegate: MockChannelContextDelegate()), childChannel: nil, delegate: manager)
        let c3 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l3", port: 2, enableTLS: false, cacheKey: "s3", delegate: conformer, contextDelegate: MockChannelContextDelegate()), childChannel: nil, delegate: manager)
        let c4 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l4", port: 3, enableTLS: false, cacheKey: "s4", delegate: conformer, contextDelegate: MockChannelContextDelegate()), childChannel: nil, delegate: manager)
        let c5 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l5", port: 4, enableTLS: false, cacheKey: "s5", delegate: conformer, contextDelegate: MockChannelContextDelegate()), childChannel: nil, delegate: manager)
        let c6 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l6", port: 5, enableTLS: false, cacheKey: "s6", delegate: conformer, contextDelegate: MockChannelContextDelegate()), childChannel: nil, delegate: manager)
        
        
        for connection in [c1,c2,c3,c4,c5,c6] {
            await manager.connectionCache.cacheConnection(connection, for: connection.config.cacheKey)
        }
        
        await #expect(manager.connectionCache.count == 6)
    }
    
    @Test func testFindConnection() async throws {
         let conformer = MockConnectionDelegate(manager: manager, listenerDelegation: ListenerDelegation(shouldShutdown: false))
        let c1 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l1", port: 0, enableTLS: false, cacheKey: "s1", delegate: conformer, contextDelegate: MockChannelContextDelegate()), childChannel: nil, delegate: manager)
        await manager.connectionCache.cacheConnection(c1, for: c1.config.cacheKey)
        let fc1 = await manager.connectionCache.findConnection(cacheKey: c1.config.cacheKey)
        let location1 = await getLocation(connection: fc1)
        let location2 = await getLocation(connection: c1)
        #expect(location1 == location2)
    }
    
    private func getLocation(connection: ChildChannelService<ByteBuffer, ByteBuffer>?) async -> String {
        if let connection {
            return await connection.config.cacheKey
        } else {
            return ""
        }
    }
    
    @Test func testDeleteConnection() async throws {
         let conformer = MockConnectionDelegate(manager: manager, listenerDelegation: ListenerDelegation(shouldShutdown: false))
        let c1 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l1", port: 0, enableTLS: false, cacheKey: "s1", delegate: conformer, contextDelegate: MockChannelContextDelegate()), childChannel: nil, delegate: manager)
        await manager.connectionCache.cacheConnection(c1, for: c1.config.cacheKey)
        try await manager.connectionCache.removeConnection(c1.config.cacheKey)
        await #expect(manager.connectionCache.fetchAllConnections().isEmpty)
    }
}


final class MockConnectionDelegate: ConnectionDelegate {

    func initializedChildChannel<Outbound, Inbound>(_ context: ConnectionManagerKit.ChannelContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable {
        
    }

    
    nonisolated(unsafe) var servers = [ServerLocation]()
    nonisolated(unsafe) let listenerDelegation: ListenerDelegation
    nonisolated(unsafe) var networkEventTask: Task<Void, Never>?
    nonisolated(unsafe) var inactiveTask: Task<Void, Never>?
    nonisolated(unsafe) var errorTask: Task<Void, Never>?
    let manager: ConnectionManager
    
    init(manager: ConnectionManager, listenerDelegation: ListenerDelegation) {
        self.manager = manager
        self.listenerDelegation = listenerDelegation
    }
    
    func configureChildChannel() async {}
    
    func shutdownChildConfiguration() async {}
    
#if canImport(Network)
    func handleError(_ stream: AsyncStream<NWError>) {
        errorTask = Task {
            for await error in stream.cancelOnGracefulShutdown() {
                print("RECEIVED ERROR", error)
            }
        }
    }

    func handleNetworkEvents(_ stream: AsyncStream<ConnectionManagerKit.NetworkEventMonitor.NetworkEvent>) {
        networkEventTask = Task {
            for await event in stream.cancelOnGracefulShutdown() {
                switch event {
                case .betterPathAvailable(_):
                    break
                case .betterPathUnavailable:
                    break
                case .viabilityChanged(let state):
                    if state.isViable, !servers.isEmpty {
                        var _servers = 0
                        
                        for server in servers {
                            _servers += 1
                            let fc1 = await manager.connectionCache.findConnection(cacheKey: server.cacheKey)
                            await #expect(fc1?.config.host == server.host)
                            try! await Task.sleep(until: .now + .seconds(5))
                            await manager.shutdown(cacheKey: server.cacheKey)
                        }
                    } else {
                        break
                    }
                case .connectToNWEndpoint(_):
                    break
                case .bindToNWEndpoint(_):
                    break
                case .waitingForConnectivity(_):
                    break
                case .pathChanged(_):
                    break
                }
            }
        }
    }
    
#else
    func handleError(_ stream: AsyncStream<IOError>) {
        Task {
            for await error in stream {
                print("RECEIVED ERROR", error)
            }
        }
    }
    
    func handleNetworkEvents(_ stream: AsyncStream<ConnectionManagerKit.NetworkEventMonitor.NIOEvent>) {
        Task {
            for await event in stream.cancelOnGracefulShutdown() {
                switch event {
                default:
                    print("RECEVIED", event)
                }
            }
        }
    }
    
#endif
    
    func channelActive(_ stream: AsyncStream<Void>) {
#if !canImport(Network)
        Task {
            for await _ in stream.cancelOnGracefulShutdown() {
                if !servers.isEmpty {
                    try! await Task.sleep(until: .now + .seconds(5))
                    for server in servers {
                        print(server)
                        let fc1 = await manager.connectionCache.findConnection(cacheKey: server.cacheKey)
                        await #expect(fc1?.config.host == server.host)
                        await manager.shutdown(cacheKey: server.cacheKey)
                    }
                }
            }
        }
#endif
    }
    
    func channelInActive(_ stream: AsyncStream<Void>) {
        inactiveTask = Task {
            for await _ in stream.cancelOnGracefulShutdown() {
                await tearDown()
            }
        }
    }
    
    func reportChildChannel(error: any Error) async {

    }
    
    func deliverWriter<Outbound>(writer: NIOCore.NIOAsyncChannelOutboundWriter<Outbound>) async where Outbound : Sendable {}
    
    func deliverInboundBuffer<Inbound>(inbound: Inbound) async where Inbound : Sendable {}
    
    
    private func tearDown() async {
        if await manager.connectionCache.isEmpty {
            networkEventTask?.cancel()
            errorTask?.cancel()
            inactiveTask?.cancel()
        }
    }
    
}

final class MockChannelContextDelegate: ChannelContextDelegate {
    func channelActive(_ stream: AsyncStream<Void>) {
        
    }

    func channelInActive(_ stream: AsyncStream<Void>) {
        
    }

    func reportChildChannel(error: any Error) async {
        
    }

    func shutdownChildConfiguration() async {
        
    }

    func deliverWriter<Outbound, Inbound>(context: ConnectionManagerKit.WriterContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable {
        
    }

    func deliverInboundBuffer<Inbound, Outbound>(context: ConnectionManagerKit.StreamContext<Inbound, Outbound>) async where Inbound : Sendable, Outbound : Sendable {
        
    }


}