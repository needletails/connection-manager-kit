# ``ConnectionManagerKit``

A modern, cross-platform networking framework built on SwiftNIO for managing network connections with automatic reconnection, TLS support, and comprehensive event monitoring.

## Overview

ConnectionManagerKit provides a high-level interface for managing network connections in Swift applications. It's designed to work seamlessly across Apple platforms (iOS, macOS, tvOS, watchOS) and Linux, offering automatic connection management, TLS support, and robust error handling.

## Key Features

- **Cross-Platform Support**: Works on Apple platforms using Network framework and Linux using NIO
- **Automatic Reconnection**: Built-in retry logic with configurable attempts and backoff
- **TLS Support**: Native TLS/SSL support with customizable configurations
- **Connection Caching**: Efficient connection reuse and management
- **Network Monitoring**: Real-time network event monitoring and state tracking
- **Modern Swift**: Built with Swift concurrency (async/await) and actors
- **Graceful Shutdown**: Proper resource cleanup and connection termination

## Quick Start

### Basic Client Usage

```swift
import ConnectionManagerKit

// Create a connection manager
let manager = ConnectionManager()
manager.delegate = MyConnectionManagerDelegate()

// Define server locations
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

// Connect to servers
try await manager.connect(
    to: servers,
    maxReconnectionAttempts: 5,
    timeout: .seconds(10)
)

// Graceful shutdown when done
await manager.gracefulShutdown()
```

### Basic Server Usage

```swift
import ConnectionManagerKit

// Create a connection listener
let listener = ConnectionListener<ByteBuffer, ByteBuffer>()

// Resolve server address
let config = try await listener.resolveAddress(
    .init(group: MultiThreadedEventLoopGroup.singleton, host: "0.0.0.0", port: 8080)
)

// Start listening
try await listener.listen(
    address: config.address!,
    configuration: config,
    delegate: connectionDelegate,
    listenerDelegate: listenerDelegate
)
```

## Architecture

ConnectionManagerKit is built around several core components:

- **ConnectionManager**: Manages client-side connections with caching and reconnection
- **ConnectionListener**: Handles server-side connection acceptance
- **ConnectionCache**: Efficient connection storage and retrieval
- **NetworkEventMonitor**: Monitors network events and connection state changes
- **ChannelService**: Manages individual channel lifecycle and data flow

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:BasicUsage>

### Client-Side

- <doc:ConnectionManager>
- <doc:ConnectionDelegate>
- <doc:ChannelContextDelegate>

### Server-Side

- <doc:ConnectionListener>
- <doc:ListenerDelegate>
- <doc:ServerService>

### Data Models

- <doc:ServerLocation>
- <doc:Configuration>
- <doc:ChannelContext>
- <doc:WriterContext>
- <doc:StreamContext>

### Advanced Topics

- <doc:TLSConfiguration>
- <doc:NetworkEvents>
- <doc:ErrorHandling>
- <doc:Performance> 