# ``ConnectionManagerKit``

A modern, cross-platform networking framework built on SwiftNIO for managing network connections with automatic reconnection, TLS support, and comprehensive event monitoring.

## Overview

ConnectionManagerKit provides a high-level interface for managing network connections in Swift applications. It's designed to work seamlessly across Apple platforms (iOS, macOS, tvOS, watchOS) and Linux, offering automatic connection management, TLS support, and robust error handling.

## Key Features

- **Cross-Platform Support**: Works on Apple platforms using Network framework and Linux using NIO
- **Automatic Reconnection**: Built-in retry logic with configurable attempts and backoff
- **Advanced Retry Strategies**: Fixed delay, exponential backoff with jitter, and custom retry policies
- **Parallel Connection Establishment**: Concurrent connection setup for improved performance
- **Connection Pooling**: Efficient connection reuse with acquire/return semantics and configurable pool sizes
- **Connection Caching**: LRU eviction, TTL support, and automatic cleanup
- **TLS Support**: Native TLS/SSL support with customizable configurations
- **Network Monitoring**: Real-time network event monitoring and state tracking
- **Modern Swift**: Built with Swift concurrency (async/await) and actors
- **Graceful Shutdown**: Proper resource cleanup and connection termination
- **Thread Safety**: Actor-based implementation for safe concurrent access

## Quick Start

### Basic Client Usage

```swift
import ConnectionManagerKit

// Create a connection manager
let manager = ConnectionManager<ByteBuffer, ByteBuffer>()
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

// Connect to servers with retry strategy
try await manager.connect(
    to: servers,
    maxReconnectionAttempts: 5,
    timeout: .seconds(10),
    retryStrategy: .exponential(initialDelay: .seconds(1), maxDelay: .seconds(30))
)

// Use connection pooling for efficient resource management
let poolConfig = ConnectionPoolConfiguration(
    minConnections: 2,
    maxConnections: 10,
    acquireTimeout: .seconds(5),
    maxIdleTime: .seconds(60)
)

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

// Graceful shutdown when done
await manager.gracefulShutdown()
```

### Advanced Client Usage with Parallel Connections

```swift
import ConnectionManagerKit

let manager = ConnectionManager<ByteBuffer, ByteBuffer>()

// Connect to multiple servers in parallel for improved performance
try await manager.connectParallel(
    to: servers,
    maxConcurrentConnections: 5,
    retryStrategy: .exponential(
        initialDelay: .seconds(1),
        maxDelay: .seconds(30),
        multiplier: 2.0,
        jitter: true
    )
)

// Use custom retry strategy for specific error handling
try await manager.connect(
    to: servers,
    retryStrategy: .custom { attempt, maxAttempts in
        // Don't retry after 3 attempts
        if attempt >= 3 {
            return .seconds(0)
        }
        // Exponential backoff with custom logic
        return .seconds(Int64(pow(2.0, Double(attempt))))
    }
)
```

### Connection Pooling and Caching (Accurate API)

#### Using CacheConfiguration and ConnectionPoolConfiguration

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

### Basic Server Usage

```swift
import ConnectionManagerKit

// Create a connection listener
let listener = ConnectionListener<ByteBuffer, ByteBuffer>()

// Resolve server address
let config = try await listener.resolveAddress(
    .init(group: MultiThreadedEventLoopGroup.singleton, host: "0.0.0.0", port: 8080)
)

// Start listening with network event monitoring
try await listener.listen(
    address: config.address!,
    configuration: config,
    delegate: connectionDelegate,
    listenerDelegate: listenerDelegate
)
```

## Architecture

The ConnectionManagerKit is built on a modular architecture with several key components:

- **ConnectionManager**: Central orchestrator for connection lifecycle management
- **ConnectionCache**: Thread-safe cache with LRU eviction and TTL support
- **ConnectionListener**: Optimized server-side connection handling with metrics
- **NetworkEventMonitor**: Real-time network connectivity monitoring
- **Configuration Structs**: Type-safe configuration for all components

## Metrics and Logging

The ConnectionManagerKit provides comprehensive metrics collection using Swift Metrics, but gives consumers full control over logging decisions.

### Metrics Collection

The library automatically collects metrics for:
- Connection counts (active, total accepted/closed)
- Performance indicators (accept rate, connection duration)
- Cache operations (hits, misses, evictions)
- Error rates and recovery attempts

### Consumer-Controlled Logging

Instead of automatic logging, the library provides methods for consumers to access metrics data:

```swift
// Get current metrics
let listenerMetrics = await listener.getCurrentMetrics()
let cacheMetrics = await manager.connectionCache.getCurrentMetrics()

// Get formatted strings for logging
let listenerMetricsString = await listener.getFormattedMetrics()
let cacheMetricsString = await manager.connectionCache.getFormattedMetrics()

// Custom logging based on metrics
if listenerMetrics.activeConnections > 100 {
    logger.warning("High connection count: \(listenerMetrics.activeConnections)")
}

// Periodic metrics logging
Task {
    while true {
        let metrics = await listener.getFormattedMetrics()
        logger.info("Listener metrics: \(metrics)")
        try await Task.sleep(for: .seconds(60))
    }
}
```

### Benefits of This Approach

- **Performance**: No automatic logging overhead
- **Flexibility**: Consumers choose what and when to log
- **Integration**: Easy integration with existing logging systems
- **Observability**: Swift Metrics integration for monitoring systems

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

### Advanced Features

- <doc:RetryStrategies>
- <doc:ConnectionPooling>
- <doc:ParallelConnections>
- <doc:TLSConfiguration>
- <doc:NetworkEvents>
- <doc:ErrorHandling>
- <doc:Performance> 