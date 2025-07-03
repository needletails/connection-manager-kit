# Getting Started

Learn how to set up and start using ConnectionManagerKit in your Swift project.

## Overview

This guide will walk you through the process of creating your first network connection using ConnectionManagerKit.

## Requirements

- Swift 6.0 or later
- iOS 17.0+, macOS 14.0+, tvOS 17.0+, watchOS 10.0+, or Linux

## Basic Setup

### 1. Import the Framework

```swift
import ConnectionManagerKit
```

### 2. Create a Connection Manager

```swift
let manager = ConnectionManager()
```

### 3. Set Up Delegates

Create a delegate to handle connection events:

```swift
class MyConnectionManagerDelegate: ConnectionManagerDelegate {
    func retrieveChannelHandlers() -> [ChannelHandler] {
        // Return any custom channel handlers you need
        return []
    }
    
    func deliverChannel(_ channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>, 
                       manager: ConnectionManager, 
                       cacheKey: String) async {
        // Set up connection-specific delegates
        await manager.setDelegates(
            connectionDelegate: connectionDelegate,
            contextDelegate: contextDelegate,
            cacheKey: cacheKey
        )
    }
}

// Set the delegate
manager.delegate = MyConnectionManagerDelegate()
```

### 4. Create Connection Delegates

Implement the connection and context delegates:

```swift
class MyConnectionDelegate: ConnectionDelegate {
    func handleError(_ stream: AsyncStream<NWError>, id: String) {
        Task {
            for await error in stream {
                print("Connection error: \(error)")
            }
        }
    }
    
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
        for await event in stream {
            switch event {
            case .viabilityChanged(let update):
                print("Network viability: \(update.isViable)")
            default:
                break
            }
        }
    }
    
    func initializedChildChannel<Outbound, Inbound>(_ context: ChannelContext<Inbound, Outbound>) async {
        print("Channel initialized: \(context.id)")
    }
}

class MyChannelContextDelegate: ChannelContextDelegate {
    func channelActive(_ stream: AsyncStream<Void>, id: String) {
        Task {
            for await _ in stream {
                print("Channel \(id) became active")
            }
        }
    }
    
    func channelInactive(_ stream: AsyncStream<Void>, id: String) {
        Task {
            for await _ in stream {
                print("Channel \(id) became inactive")
            }
        }
    }
    
    func reportChildChannel(error: any Error, id: String) async {
        print("Channel error: \(error)")
    }
    
    func didShutdownChildChannel() async {
        print("Channel shutdown")
    }
    
    func deliverWriter<Outbound, Inbound>(context: WriterContext<Inbound, Outbound>) async {
        // Store the writer for later use
        print("Writer available for channel: \(context.id)")
    }
    
    func deliverInboundBuffer<Inbound, Outbound>(context: StreamContext<Inbound, Outbound>) async {
        // Process received data
        print("Received data from channel: \(context.id)")
    }
}
```

### 5. Define Server Locations

```swift
let connectionDelegate = MyConnectionDelegate()
let contextDelegate = MyChannelContextDelegate()

let servers = [
    ServerLocation(
        host: "api.example.com",
        port: 443,
        enableTLS: true,
        cacheKey: "api-server",
        delegate: connectionDelegate,
        contextDelegate: contextDelegate
    )
]
```

### 6. Connect to Servers

```swift
do {
    try await manager.connect(
        to: servers,
        maxReconnectionAttempts: 5,
        timeout: .seconds(10)
    )
    print("Successfully connected to servers")
} catch {
    print("Failed to connect: \(error)")
}
```

### 7. Clean Up

When your application is shutting down:

```swift
await manager.gracefulShutdown()
```

## Complete Example

Here's a complete working example:

```swift
import Foundation
import ConnectionManagerKit

@main
struct MyApp {
    static func main() async throws {
        // Create connection manager
        let manager = ConnectionManager()
        
        // Set up delegates
        let connectionDelegate = MyConnectionDelegate()
        let contextDelegate = MyChannelContextDelegate()
        let managerDelegate = MyConnectionManagerDelegate()
        
        manager.delegate = managerDelegate
        
        // Define servers
        let servers = [
            ServerLocation(
                host: "api.example.com",
                port: 443,
                enableTLS: true,
                cacheKey: "api-server",
                delegate: connectionDelegate,
                contextDelegate: contextDelegate
            )
        ]
        
        // Connect
        try await manager.connect(to: servers)
        
        // Keep the app running
        try await Task.sleep(until: .now + .seconds(30))
        
        // Shutdown
        await manager.gracefulShutdown()
    }
}

// Delegate implementations...
class MyConnectionManagerDelegate: ConnectionManagerDelegate {
    func retrieveChannelHandlers() -> [ChannelHandler] { [] }
    
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

class MyConnectionDelegate: ConnectionDelegate {
    func handleError(_ stream: AsyncStream<NWError>, id: String) {
        Task {
            for await error in stream {
                print("Error: \(error)")
            }
        }
    }
    
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
        for await event in stream {
            print("Network event: \(event)")
        }
    }
    
    func initializedChildChannel<Outbound, Inbound>(_ context: ChannelContext<Inbound, Outbound>) async {
        print("Channel initialized: \(context.id)")
    }
}

class MyChannelContextDelegate: ChannelContextDelegate {
    func channelActive(_ stream: AsyncStream<Void>, id: String) {
        Task {
            for await _ in stream {
                print("Channel \(id) active")
            }
        }
    }
    
    func channelInactive(_ stream: AsyncStream<Void>, id: String) {
        Task {
            for await _ in stream {
                print("Channel \(id) inactive")
            }
        }
    }
    
    func reportChildChannel(error: any Error, id: String) async {
        print("Channel error: \(error)")
    }
    
    func didShutdownChildChannel() async {
        print("Channel shutdown")
    }
    
    func deliverWriter<Outbound, Inbound>(context: WriterContext<Inbound, Outbound>) async {
        print("Writer available: \(context.id)")
    }
    
    func deliverInboundBuffer<Inbound, Outbound>(context: StreamContext<Inbound, Outbound>) async {
        print("Data received: \(context.id)")
    }
}
```

## Next Steps

Now that you have the basics set up, explore these topics:

- <doc:BasicUsage> - Learn about common usage patterns
- <doc:ConnectionManager> - Understand the connection manager in detail
- <doc:ErrorHandling> - Handle errors and edge cases 