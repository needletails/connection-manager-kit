# Basic Usage

Learn common patterns and use cases for ConnectionManagerKit.

## Overview

This guide covers the most common usage patterns for ConnectionManagerKit, including client connections, server setup, and data handling.

## Client-Side Connections

### Single Server Connection

```swift
import ConnectionManagerKit

class MyApp {
    let manager = ConnectionManager<ByteBuffer, ByteBuffer>()
    let connectionDelegate = MyConnectionDelegate()
    let contextDelegate = MyChannelContextDelegate()
    
    func connectToServer() async throws {
        // Set up the manager delegate
        manager.delegate = MyConnectionManagerDelegate()
        
        // Define the server
        let server = ServerLocation(
            host: "api.example.com",
            port: 443,
            enableTLS: true,
            cacheKey: "api-server",
            delegate: connectionDelegate,
            contextDelegate: contextDelegate
        )
        
        // Connect
        try await manager.connect(to: [server])
    }
}
```

### Multiple Server Connections

```swift
func connectToMultipleServers() async throws {
    let servers = [
        ServerLocation(
            host: "api1.example.com",
            port: 443,
            enableTLS: true,
            cacheKey: "api-server-1",
            delegate: connectionDelegate,
            contextDelegate: contextDelegate
        ),
        ServerLocation(
            host: "api2.example.com",
            port: 443,
            enableTLS: true,
            cacheKey: "api-server-2",
            delegate: connectionDelegate,
            contextDelegate: contextDelegate
        ),
        ServerLocation(
            host: "api3.example.com",
            port: 8080,
            enableTLS: false,
            cacheKey: "api-server-3",
            delegate: connectionDelegate,
            contextDelegate: contextDelegate
        )
    ]
    
    try await manager.connect(
        to: servers,
        maxReconnectionAttempts: 3,
        timeout: .seconds(15)
    )
}
```

### Custom Channel Handlers

```swift
class MyConnectionManagerDelegate: ConnectionManagerDelegate {
    func retrieveChannelHandlers() -> [ChannelHandler] {
        return [
            // Add length field prepender for framing
            LengthFieldPrepender(lengthFieldBitLength: .fourBytes),
            
            // Add custom protocol handler
            MyProtocolHandler(),
            
            // Add logging handler
            LoggingHandler(label: "MyApp")
        ]
    }
    
    func channelCreated(_ eventLoop: EventLoop, cacheKey: String) async {
        // Called when a channel is created for the given cache key
        // This is the preferred method for handling channel creation events
        print("Channel created for cache key: \(cacheKey) on event loop: \(eventLoop)")
        
        // Set up connection-specific delegates if needed
        // await manager.setDelegates(
        //     connectionDelegate: connectionDelegate,
        //     contextDelegate: contextDelegate,
        //     cacheKey: cacheKey
        // )
    }
    
    // Note: deliverChannel is deprecated and will be removed in a future version
    // Use channelCreated instead for new implementations
}
```

## Server-Side Setup

### Basic Server

```swift
class MyServer {
    let listener = ConnectionListener<ByteBuffer, ByteBuffer>()
    let connectionDelegate = MyConnectionDelegate()
    let listenerDelegate = MyListenerDelegate()
    
    func startServer() async throws {
        // Resolve server address
        let config = try await listener.resolveAddress(
            .init(
                group: MultiThreadedEventLoopGroup.singleton,
                host: "0.0.0.0",
                port: 8080
            )
        )
        
        // Start listening
        try await listener.listen(
            address: config.address!,
            configuration: config,
            delegate: connectionDelegate,
            listenerDelegate: listenerDelegate
        )
        
        print("Server started on port \(config.port)")
    }
}

class MyListenerDelegate: ListenerDelegate {
    func didBindServer<Inbound, Outbound>(channel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>) async {
        print("Server bound successfully")
    }
    
    func retrieveSSLHandler() -> NIOSSLServerHandler? {
        // Return nil for non-TLS server
        return nil
    }
    
    func retrieveChannelHandlers() -> [ChannelHandler] {
        return [
            LengthFieldPrepender(lengthFieldBitLength: .fourBytes),
            MyProtocolHandler()
        ]
    }
}
```

### TLS Server

```swift
class MyTLSListenerDelegate: ListenerDelegate {
    func didBindServer<Inbound, Outbound>(channel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>) async {
        print("TLS Server bound successfully")
    }
    
    func retrieveSSLHandler() -> NIOSSLServerHandler? {
        do {
            let tlsConfig = TLSConfiguration.makeServerConfiguration(
                certificateChain: [.certificate(certificate)],
                privateKey: .privateKey(privateKey)
            )
            let sslContext = try NIOSSLContext(configuration: tlsConfig)
            return try NIOSSLServerHandler(context: sslContext)
        } catch {
            print("Failed to create SSL handler: \(error)")
            return nil
        }
    }
    
    func retrieveChannelHandlers() -> [ChannelHandler] {
        return [
            LengthFieldPrepender(lengthFieldBitLength: .fourBytes),
            MyProtocolHandler()
        ]
    }
}
```

### Custom Types

```swift
// Define custom message types
struct ChatMessage: Sendable {
    let sender: String
    let content: String
    let timestamp: Date
}

class MyCustomServer {
    // Use custom types with ConnectionListener
    let listener = ConnectionListener<ChatMessage, ChatMessage>()
    let connectionDelegate = MyConnectionDelegate()
    let listenerDelegate = MyListenerDelegate()
    
    func startServer() async throws {
        let config = try await listener.resolveAddress(
            .init(
                group: MultiThreadedEventLoopGroup.singleton,
                host: "0.0.0.0",
                port: 8080
            )
        )
        
        try await listener.listen(
            address: config.address!,
            configuration: config,
            delegate: connectionDelegate,
            listenerDelegate: listenerDelegate
        )
    }
}
```

## Data Handling

### Sending Data

```swift
class MyChannelContextDelegate: ChannelContextDelegate {
    private var writers: [String: NIOAsyncChannelOutboundWriter<ByteBuffer>] = [:]
    
    func deliverWriter<Outbound, Inbound>(context: WriterContext<Inbound, Outbound>) async {
        // Store the writer for later use
        writers[context.id] = context.writer as? NIOAsyncChannelOutboundWriter<ByteBuffer>
    }
    
    func sendData(_ data: ByteBuffer, to channelId: String) async throws {
        guard let writer = writers[channelId] else {
            throw MyError.writerNotFound
        }
        
        try await writer.write(data)
    }
    
    func broadcastData(_ data: ByteBuffer) async throws {
        for writer in writers.values {
            try await writer.write(data)
        }
    }
}
```

### Receiving Data

```swift
class MyChannelContextDelegate: ChannelContextDelegate {
    func deliverInboundBuffer<Inbound, Outbound>(context: StreamContext<Inbound, Outbound>) async {
        // Process received data
        if let data = context.inbound as? ByteBuffer {
            await processReceivedData(data, from: context.id)
        }
    }
    
    private func processReceivedData(_ data: ByteBuffer, from channelId: String) async {
        // Parse and handle the received data
        let message = String(buffer: data)
        print("Received from \(channelId): \(message)")
        
        // Handle different message types
        if message.hasPrefix("HEARTBEAT") {
            await handleHeartbeat(from: channelId)
        } else if message.hasPrefix("DATA") {
            await handleDataMessage(message, from: channelId)
        }
    }
    
    private func handleHeartbeat(from channelId: String) async {
        // Send heartbeat response
        let response = ByteBuffer(string: "HEARTBEAT_ACK")
        try? await sendData(response, to: channelId)
    }
    
    private func handleDataMessage(_ message: String, from channelId: String) async {
        // Process data message
        print("Processing data message from \(channelId)")
    }
}
```

## Connection Management

### Connection State Monitoring

```swift
class MyConnectionDelegate: ConnectionDelegate {
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
        for await event in stream {
            switch event {
            case .viabilityChanged(let update):
                if update.isViable {
                    print("Connection \(id) is viable")
                } else {
                    print("Connection \(id) is not viable")
                }
                
            case .betterPathAvailable(let path):
                print("Better path available for \(id)")
                
            case .waitingForConnectivity(let error):
                print("Waiting for connectivity for \(id): \(error)")
                
            case .pathChanged(let path):
                print("Path changed for \(id)")
                
            default:
                break
            }
        }
    }
    
    func handleError(_ stream: AsyncStream<NWError>, id: String) {
        Task {
            for await error in stream {
                print("Connection error for \(id): \(error)")
                
                switch error {
                case .posix(.ECONNREFUSED):
                    print("Connection refused")
                case .posix(.ENETDOWN):
                    print("Network is down")
                case .dns(let code):
                    print("DNS error: \(code)")
                default:
                    print("Other error: \(error)")
                }
            }
        }
    }
}
```

### Graceful Shutdown

```swift
class MyApp {
    let manager = ConnectionManager<ByteBuffer, ByteBuffer>()
    
    func shutdown() async {
        // Trigger graceful shutdown
        await manager.gracefulShutdown()
        
        // Wait for shutdown to complete
        while await manager.shouldReconnect {
            try? await Task.sleep(until: .now + .milliseconds(100))
        }
        
        print("Shutdown complete")
    }
    
    // Handle application termination
    func handleTermination() {
        Task {
            await shutdown()
            exit(0)
        }
    }
}
```

## Connection Pooling and Caching (Accurate API)

### Using CacheConfiguration and ConnectionPoolConfiguration

```swift
let cacheConfig = CacheConfiguration(
    maxConnections: 50,
    ttl: .seconds(300),
    enableLRU: true
)

let poolConfig = ConnectionPoolConfiguration(
    minConnections: 2,
    maxConnections: 20,
    acquireTimeout: .seconds(10),
    maxIdleTime: .seconds(60)
)

let manager = ConnectionManager<ByteBuffer, ByteBuffer>()

// Acquire a connection from the pool (factory closure required)
let acquiredConnection = try await manager.connectionCache.acquireConnection(
    for: "api-server",
    poolConfig: poolConfig
) {
    // Connection factory: create and return a new ChildChannelService if needed
    // Example:
    return ChildChannelService<ByteBuffer, ByteBuffer>(
        logger: .init(),
        config: .init(
            host: "api.example.com",
            port: 443,
            enableTLS: true,
            cacheKey: "api-server",
            delegate: connectionDelegate,
            contextDelegate: contextDelegate
        ),
        childChannel: nil,
        delegate: manager
    )
}

// Return the connection to the pool
await manager.connectionCache.returnConnection(
    "api-server",
    poolConfig: poolConfig
)
```

## Error Handling

### Custom Error Types

```swift
enum MyConnectionError: Error {
    case connectionFailed(String)
    case timeout(TimeAmount)
    case writerNotFound
    case invalidData
}

class MyConnectionManager {
    func connectWithRetry(to servers: [ServerLocation]) async throws {
        do {
            try await manager.connect(to: servers)
        } catch {
            throw MyConnectionError.connectionFailed(error.localizedDescription)
        }
    }
}
```

### Retry Logic

```swift
func connectWithCustomRetry(to servers: [ServerLocation]) async throws {
    var attempts = 0
    let maxAttempts = 5
    
    while attempts < maxAttempts {
        do {
            try await manager.connect(
                to: servers,
                maxReconnectionAttempts: 0, // Disable built-in retry
                timeout: .seconds(10)
            )
            return // Success
        } catch {
            attempts += 1
            print("Connection attempt \(attempts) failed: \(error)")
            
            if attempts < maxAttempts {
                // Wait before retry with exponential backoff
                let delay = TimeAmount.seconds(Int64(pow(2.0, Double(attempts))))
                try await Task.sleep(until: .now + delay)
            }
        }
    }
    
    throw MyConnectionError.connectionFailed("Failed after \(maxAttempts) attempts")
}
```

## Best Practices

### 1. Use Unique Cache Keys

```swift
// Good: Unique cache keys
let servers = [
    ServerLocation(host: "api1.example.com", port: 443, enableTLS: true, cacheKey: "api1-443-tls"),
    ServerLocation(host: "api1.example.com", port: 8080, enableTLS: false, cacheKey: "api1-8080-plain"),
    ServerLocation(host: "api2.example.com", port: 443, enableTLS: true, cacheKey: "api2-443-tls")
]

// Bad: Duplicate cache keys
let servers = [
    ServerLocation(host: "api1.example.com", port: 443, enableTLS: true, cacheKey: "api-server"),
    ServerLocation(host: "api2.example.com", port: 443, enableTLS: true, cacheKey: "api-server") // Duplicate!
]
```

### 2. Handle Connection Lifecycle

```swift
class MyChannelContextDelegate: ChannelContextDelegate {
    private var activeChannels: Set<String> = []
    
    func channelActive(_ stream: AsyncStream<Void>, id: String) {
        Task {
            for await _ in stream {
                activeChannels.insert(id)
                print("Channel \(id) is now active. Total active: \(activeChannels.count)")
            }
        }
    }
    
    func channelInactive(_ stream: AsyncStream<Void>, id: String) {
        Task {
            for await _ in stream {
                activeChannels.remove(id)
                print("Channel \(id) is now inactive. Total active: \(activeChannels.count)")
            }
        }
    }
}
```

### 3. Proper Resource Cleanup

```swift
class MyApp {
    private var manager: ConnectionManager<ByteBuffer, ByteBuffer>?
    
    func start() async throws {
        manager = ConnectionManager<ByteBuffer, ByteBuffer>()
        // ... setup and connect
    }
    
    func stop() async {
        await manager?.gracefulShutdown()
        manager = nil
    }
    
    deinit {
        // Ensure cleanup on deallocation
        Task {
            await stop()
        }
    }
}
```

## Metrics and Logging Strategy

The ConnectionManagerKit provides real-time metrics updates through delegation patterns, focusing on the most valuable operational metrics.

### Core Metrics Components

**Public Metrics APIs:**
- **ConnectionListener**: Server-side connection performance and health
- **ConnectionCache**: Cache efficiency and resource utilization  
- **ConnectionManager**: Client-side connection establishment and management

**Internal Metrics:**
- **ServerService**: Internal server implementation details (not exposed publicly)

### Using the Delegation Pattern

```swift
class MyConnectionManager: ListenerMetricsDelegate, ConnectionCacheMetricsDelegate, ConnectionManagerMetricsDelegate {
    private let manager = ConnectionManager<ByteBuffer, ByteBuffer>()
    private let listener = ConnectionListener<ByteBuffer, ByteBuffer>()
    private let logger = NeedleTailLogger()
    
    func setupMetricsDelegation() {
        // Set up delegation for real-time updates
        listener.metricsDelegate = self
        manager.connectionCache.metricsDelegate = self
        manager.metricsDelegate = self
    }
    
    // MARK: - ListenerMetricsDelegate (Server-side)
    
    func listenerMetricsDidUpdate(_ metrics: ListenerMetrics) {
        logger.info("Server: \(metrics.activeConnections) active connections")
        
        if metrics.activeConnections > 100 {
            logger.warning("High server connection count: \(metrics.activeConnections)")
        }
    }
    
    func connectionDidAccept(connectionId: String, activeConnections: Int) {
        logger.debug("Server accepted connection: \(connectionId)")
    }
    
    func connectionDidClose(connectionId: String, activeConnections: Int, duration: TimeAmount) {
        logger.debug("Server closed connection: \(connectionId), duration: \(duration.nanoseconds / 1_000_000_000)s")
    }
    
    func recoveryDidAttempt(attemptNumber: Int, maxAttempts: Int) {
        logger.warning("Server recovery attempt \(attemptNumber)/\(maxAttempts)")
    }
    
    // MARK: - ConnectionCacheMetricsDelegate (Cache Performance)
    
    func cacheMetricsDidUpdate(cachedConnections: Int, maxConnections: Int, lruEnabled: Bool, ttlEnabled: Bool) {
        logger.debug("Cache: \(cachedConnections)/\(maxConnections) connections")
    }
    
    func cacheHitDidOccur(cacheKey: String) {
        logger.trace("Cache hit: \(cacheKey)")
    }
    
    func cacheMissDidOccur(cacheKey: String) {
        logger.debug("Cache miss: \(cacheKey)")
    }
    
    func connectionDidEvict(cacheKey: String) {
        logger.info("Cache evicted: \(cacheKey)")
    }
    
    func connectionDidExpire(cacheKey: String) {
        logger.info("Cache expired: \(cacheKey)")
    }
    
    // MARK: - ConnectionManagerMetricsDelegate (Client-side)
    
    func connectionManagerMetricsDidUpdate(totalConnections: Int, activeConnections: Int, failedConnections: Int, averageConnectionTime: TimeAmount) {
        logger.info("Client: \(activeConnections)/\(totalConnections) connections active")
        
        if failedConnections > 10 {
            logger.warning("High client failure rate: \(failedConnections) failures")
        }
    }
    
    func connectionDidFail(serverLocation: String, error: Error, attemptNumber: Int) {
        logger.error("Client failed to connect to \(serverLocation): \(error) (attempt \(attemptNumber))")
    }
    
    func connectionDidSucceed(serverLocation: String, connectionTime: TimeAmount) {
        logger.debug("Client connected to \(serverLocation) in \(connectionTime.nanoseconds / 1_000_000_000)s")
    }
    
    func parallelConnectionDidComplete(totalAttempted: Int, successful: Int, failed: Int) {
        logger.info("Parallel connections: \(successful)/\(totalAttempted) successful")
    }
}
```

### Metrics Strategy Benefits

- **Focused Value**: Only expose metrics that provide operational value
- **Clear Separation**: Server-side vs client-side vs cache metrics
- **Performance**: Real-time updates without polling overhead
- **Flexibility**: Choose which metrics to handle and how to log them

### Alternative: Polling (Still Available)

```swift
// Get current metrics
let listenerMetrics = await listener.getCurrentMetrics()
let cacheMetrics = await manager.connectionCache.getCurrentMetrics()

// Get formatted strings
let listenerString = await listener.getFormattedMetrics()
let cacheString = await manager.connectionCache.getFormattedMetrics()
```

The delegation pattern is recommended for production use as it provides better performance and real-time responsiveness.

## Next Steps

Now that you understand the basic usage patterns, explore these advanced topics:

- <doc:TLSConfiguration> - Configure TLS for secure connections
- <doc:NetworkEvents> - Handle network events and state changes
- <doc:ErrorHandling> - Advanced error handling strategies
- <doc:Performance> - Optimize performance for your use case 
