# Basic Usage

Learn common patterns and use cases for ConnectionManagerKit.

## Overview

This guide covers the most common usage patterns for ConnectionManagerKit, including client connections, server setup, and data handling.

## Client-Side Connections

### Single Server Connection

```swift
import ConnectionManagerKit

class MyApp {
    let manager = ConnectionManager()
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
    
    func deliverChannel(_ channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>, 
                       manager: ConnectionManager, 
                       cacheKey: String) async {
        await manager.setDelegates(
            connectionDelegate: connectionDelegate,
            contextDelegate: contextDelegate,
            cacheKey: cacheKey
        )
    }
}
```

## Server-Side Setup

### Basic Server

```swift
class MyServer {
    // Using the generic type directly
    let listener = ConnectionListener<ByteBuffer, ByteBuffer>()
    
    // Or using the convenience method for ByteBuffer types
    // let listener = ConnectionListener.byteBuffer()
    
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
    let manager = ConnectionManager()
    
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
    private var manager: ConnectionManager?
    
    func start() async throws {
        manager = ConnectionManager()
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

## Next Steps

Now that you understand the basic usage patterns, explore these advanced topics:

- <doc:TLSConfiguration> - Configure TLS for secure connections
- <doc:NetworkEvents> - Handle network events and state changes
- <doc:ErrorHandling> - Advanced error handling strategies
- <doc:Performance> - Optimize performance for your use case 
