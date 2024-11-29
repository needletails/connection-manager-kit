import Testing
import Foundation
import NIOCore
import NIOPosix
#if canImport(Network)
import Network
#endif
@testable import ConnectionManagerKit


struct ConnectionManagerKitTests {
    
    let listener = ConnectionListener()
    let manager = ConnectionManager()
    
    func createServer() async throws {
        let serverConformer = MockConnectionDelegate(manager: manager)
        let config = try await listener.resolveAddress(.init(group: MultiThreadedEventLoopGroup.singleton, host: "localhost", port: 6667))
        try await listener.listen(address: config.address!, configuration: config, delegate: serverConformer)
    }
    
    
    @Test func testCreateConnection () async throws {
        let endpoint = "localhost"
        let conformer = MockConnectionDelegate(manager: manager)
        Task {
            try await createServer()
        }
        
        let servers = [
            ServerLocation(host: endpoint, port: 6667, enableTLS: false, cacheKey: "s1"),
            ServerLocation(host: endpoint, port: 6667, enableTLS: false, cacheKey: "s2"),
            ServerLocation(host: endpoint, port: 6667, enableTLS: false, cacheKey: "s3"),
            ServerLocation(host: endpoint, port: 6667, enableTLS: false, cacheKey: "s4"),
        ]
        
        conformer.servers.append(contentsOf: servers)
        try await manager.connect(to: servers, delegate: conformer)
    }
    
    @Test func testCreateCachedConnections() async {
        
        let c1 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l1", port: 0, enableTLS: false, cacheKey: "s1"), childChannel: nil, delegate: manager)
        let c2 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l2", port: 1, enableTLS: false, cacheKey: "s2"), childChannel: nil, delegate: manager)
        let c3 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l3", port: 2, enableTLS: false, cacheKey: "s3"), childChannel: nil, delegate: manager)
        let c4 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l4", port: 3, enableTLS: false, cacheKey: "s4"), childChannel: nil, delegate: manager)
        let c5 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l5", port: 4, enableTLS: false, cacheKey: "s5"), childChannel: nil, delegate: manager)
        let c6 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l6", port: 5, enableTLS: false, cacheKey: "s6"), childChannel: nil, delegate: manager)
        
        
        for connection in [c1,c2,c3,c4,c5,c6] {
            await manager.connectionCache.cacheConnection(connection, for: connection.config.cacheKey)
        }
        
        await #expect(manager.connectionCache.count == 6)
    }
    
    @Test func testFindConnection() async throws {
        let c1 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l1", port: 0, enableTLS: false, cacheKey: "s1"), childChannel: nil, delegate: manager)
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
        let c1 = ChildChannelService<ByteBuffer, ByteBuffer>(config: .init(host: "l1", port: 0, enableTLS: false, cacheKey: "s1"), childChannel: nil, delegate: manager)
        await manager.connectionCache.cacheConnection(c1, for: c1.config.cacheKey)
        try await manager.connectionCache.removeConnection(c1.config.cacheKey)
        await #expect(manager.connectionCache.fetchAllConnections().isEmpty)
    }
}


final class MockConnectionDelegate: ConnectionDelegate {
    
    nonisolated(unsafe) var servers = [ServerLocation]()
    let manager: ConnectionManager
    
    init(manager: ConnectionManager) {
        self.manager = manager
    }
    
    func configureChildChannel() async {}
    
    func shutdownChildConfiguration() async {}
    
#if canImport(Network)
    func handleError(_ stream: AsyncStream<NWError>) {
        Task {
            for await error in stream.cancelOnGracefulShutdown() {
                print("RECEIVED ERROR", error)
            }
        }
    }

    func handleNetworkEvents(_ stream: AsyncStream<ConnectionManagerKit.NetworkEventMonitor.NetworkEvent>) {
        Task {
            for await event in stream.cancelOnGracefulShutdown() {
                switch event {
                case .betterPathAvailable(_):
                    break
                case .betterPathUnavailable:
                    break
                case .viabilityChanged(let state):
                    if state.isViable, !servers.isEmpty {
                        for server in servers {
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
#if !canImport(Network)        
         Task {
            for await _ in stream.cancelOnGracefulShutdown() {
                print("RECEIVED CHANNEL INACTIVE")
            }
        }
#endif
    }

    func reportChildChannel(error: any Error) async {
        print("REPORTED CHILD CHANNEL ERROR")
    }
    
    func deliverWriter<Outbound>(writer: NIOCore.NIOAsyncChannelOutboundWriter<Outbound>) async where Outbound : Sendable {}
    
    func deliverInboundBuffer<Inbound>(inbound: Inbound) async where Inbound : Sendable {}
    
    
    
}
