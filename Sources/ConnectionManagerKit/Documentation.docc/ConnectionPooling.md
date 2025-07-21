# Connection Pooling

Efficiently manage and reuse network connections with configurable pooling strategies.

## Overview

Connection pooling in ConnectionManagerKit provides efficient connection reuse, reducing connection establishment overhead and improving application performance. The pooling system supports configurable pool sizes, timeouts, and automatic connection lifecycle management.

## Key Benefits

- **Reduced Latency**: Reuse existing connections instead of creating new ones
- **Resource Efficiency**: Limit the number of concurrent connections
- **Automatic Management**: Handle connection lifecycle and cleanup
- **Configurable**: Adjust pool size and behavior for your use case
- **Thread Safety**: Actor-based implementation for safe concurrent access
- **Timeout Support**: Configurable acquisition and idle timeouts

## Basic Usage

### Acquiring Connections

```swift
let manager = ConnectionManager<ByteBuffer, ByteBuffer>()

// Acquire a connection from the pool
let connection = try await manager.connectionCache.acquireConnection(
    for: "api-server",
    poolConfig: .init(maxConnections: 10)
) {
    // Connection factory - called when new connection needed
    return try await createNewConnection()
}

// Use the connection
// ... perform operations ...

// Return the connection to the pool
await manager.connectionCache.returnConnection(
    "api-server",
    poolConfig: .init(maxConnections: 10)
)
```

### Pool Configuration

```swift
let poolConfig = ConnectionPoolConfiguration(
    minConnections: 2,           // Minimum connections to maintain
    maxConnections: 10,          // Maximum connections in pool
    acquireTimeout: .seconds(5), // Timeout for acquiring connection
    maxIdleTime: .seconds(30)    // How long connections can be idle
)
```

## Advanced Usage

### Connection Pooling with Retry

```swift
let manager = ConnectionManager<ByteBuffer, ByteBuffer>()

// Connect with retry strategy
try await manager.connect(
    to: servers,
    retryStrategy: .exponential(initialDelay: .seconds(1))
)

// Use pooled connections with timeout
let connection = try await manager.connectionCache.acquireConnection(
    for: "server-key",
    poolConfig: .init(
        maxConnections: 5,
        acquireTimeout: .seconds(10)
    )
) {
    return try await createConnection()
}

// Connection will be automatically retried if acquisition fails
```

### Pool Monitoring and Statistics

```swift
let manager = ConnectionManager<ByteBuffer, ByteBuffer>()

// Check pool state
let isEmpty = await manager.connectionCache.isEmpty
let count = await manager.connectionCache.count

// Get all connections
let allConnections = await manager.connectionCache.fetchAllConnections()
print("Active connections: \(allConnections.count)")
```

### Custom Pool Behavior

```swift
// Configure different pools for different servers
let apiPoolConfig = ConnectionPoolConfiguration(
    maxConnections: 20,
    acquireTimeout: .seconds(5)
)

let cachePoolConfig = ConnectionPoolConfiguration(
    maxConnections: 5,
    acquireTimeout: .seconds(2)
)

// Use different configurations
let apiConnection = try await manager.connectionCache.acquireConnection(
    for: "api-server",
    poolConfig: apiPoolConfig
) {
    return try await createAPIConnection()
}

let cacheConnection = try await manager.connectionCache.acquireConnection(
    for: "cache-server",
    poolConfig: cachePoolConfig
) {
    return try await createCacheConnection()
}
```

## Pool Configuration Options

### ConnectionPoolConfiguration

```swift
struct ConnectionPoolConfiguration {
    let minConnections: Int      // Minimum connections to maintain
    let maxConnections: Int      // Maximum connections in pool
    let acquireTimeout: TimeAmount // Timeout for acquiring connection
    let maxIdleTime: TimeAmount  // Maximum idle time before cleanup
}
```

### Default Configuration

```swift
// Default values
let defaultConfig = ConnectionPoolConfiguration(
    minConnections: 0,           // No minimum connections
    maxConnections: 10,          // Maximum 10 connections
    acquireTimeout: .seconds(30), // 30 second timeout
    maxIdleTime: .seconds(300)   // 5 minute idle timeout
)
```

## Best Practices

### Choose Appropriate Pool Size

```swift
// Small pool for limited resources
let smallPool = ConnectionPoolConfiguration(
    maxConnections: 3,
    acquireTimeout: .seconds(10)
)

// Large pool for high-throughput scenarios
let largePool = ConnectionPoolConfiguration(
    maxConnections: 50,
    acquireTimeout: .seconds(5)
)
```

### Handle Connection Failures

```swift
let connection = try await manager.connectionCache.acquireConnection(
    for: "server-key",
    poolConfig: .init(maxConnections: 10)
) {
    // Implement robust connection creation
    do {
        return try await createConnection()
    } catch {
        // Log error and potentially retry
        logger.error("Failed to create connection: \(error)")
        throw error
    }
}

if let connection = connection {
    // Use connection safely
    try await performOperation(connection)
    
    // Always return to pool
    await manager.connectionCache.returnConnection(
        "server-key",
        poolConfig: .init(maxConnections: 10)
    )
} else {
    // Handle acquisition failure
    logger.error("Failed to acquire connection within timeout")
}
```

### Connection Lifecycle Management

```swift
// Reuse connections for multiple operations
let connection = try await manager.connectionCache.acquireConnection(
    for: "server-key",
    poolConfig: .init(maxConnections: 10)
) {
    return try await createConnection()
}

// Perform multiple operations with the same connection
for operation in operations {
    try await performOperation(connection, operation)
}

// Return connection only once
await manager.connectionCache.returnConnection(
    "server-key",
    poolConfig: .init(maxConnections: 10)
)
```

### Timeout Configuration

```swift
// Short timeout for fast operations
let fastConfig = ConnectionPoolConfiguration(
    maxConnections: 10,
    acquireTimeout: .seconds(1) // Quick timeout for fast operations
)

// Longer timeout for slow operations
let slowConfig = ConnectionPoolConfiguration(
    maxConnections: 10,
    acquireTimeout: .seconds(30) // Longer timeout for slow operations
)
```

## Integration with Other Features

### Connection Pooling with Parallel Connections

```swift
let manager = ConnectionManager<ByteBuffer, ByteBuffer>()

// Establish connections in parallel
try await manager.connectParallel(
    to: servers,
    maxConcurrentConnections: 5
)

// Use pooled connections for operations
let poolConfig = ConnectionPoolConfiguration(maxConnections: 10)

for server in servers {
    let connection = try await manager.connectionCache.acquireConnection(
        for: server.cacheKey,
        poolConfig: poolConfig
    ) {
        return try await createConnection(for: server)
    }
    
    // Use connection
    await manager.connectionCache.returnConnection(
        server.cacheKey,
        poolConfig: poolConfig
    )
}
```

### Pooling with Network Event Monitoring

```swift
// Pool connections and monitor network events
let manager = ConnectionManager<ByteBuffer, ByteBuffer>()

// Set up network event monitoring
manager.delegate = MyConnectionDelegate()

// Use pooled connections
let connection = try await manager.connectionCache.acquireConnection(
    for: "server-key",
    poolConfig: .init(maxConnections: 10)
) {
    return try await createConnection()
}

// Network events will be handled automatically
```

## Error Handling

### Acquisition Timeout

```swift
let connection = try await manager.connectionCache.acquireConnection(
    for: "server-key",
    poolConfig: .init(
        maxConnections: 1,
        acquireTimeout: .milliseconds(100)
    )
) {
    // Simulate slow connection creation
    try await Task.sleep(for: .seconds(1))
    throw NSError(domain: "test", code: 1, userInfo: nil)
}

// Should return nil due to timeout
if connection == nil {
    logger.error("Connection acquisition timed out")
}
```

### Connection Factory Errors

```swift
let connection = try await manager.connectionCache.acquireConnection(
    for: "server-key",
    poolConfig: .init(maxConnections: 10)
) {
    do {
        return try await createConnection()
    } catch ConnectionError.serverUnavailable {
        // Handle specific errors
        logger.error("Server unavailable")
        throw error
    } catch {
        // Handle other errors
        logger.error("Connection creation failed: \(error)")
        throw error
    }
}
```

## Performance Considerations

### Pool Size Optimization

```swift
// Calculate optimal pool size based on workload
let optimalPoolSize = min(
    max(5, concurrentRequests / 2), // At least 5, half of concurrent requests
    50                              // Maximum 50 connections
)

let poolConfig = ConnectionPoolConfiguration(
    maxConnections: optimalPoolSize,
    acquireTimeout: .seconds(5)
)
```

### Memory Management

```swift
// Monitor pool memory usage
let allConnections = await manager.connectionCache.fetchAllConnections()
let memoryUsage = estimateMemoryUsage(allConnections)

if memoryUsage > maxMemoryThreshold {
    // Reduce pool size or clean up idle connections
    logger.warning("Pool memory usage high: \(memoryUsage)")
}
```

## Testing Connection Pooling

### Unit Testing

```swift
func testConnectionPooling() async throws {
    let manager = ConnectionManager<ByteBuffer, ByteBuffer>()
    
    // Test pool configuration
    let poolConfig = ConnectionPoolConfiguration(
        maxConnections: 5,
        acquireTimeout: .seconds(5)
    )
    
    XCTAssertEqual(poolConfig.maxConnections, 5)
    XCTAssertEqual(poolConfig.acquireTimeout, .seconds(5))
}
```

### Integration Testing

```swift
func testConnectionPoolAcquireReturn() async throws {
    let manager = ConnectionManager<ByteBuffer, ByteBuffer>()
    
    // Test acquire and return operations
    let connection = try await manager.connectionCache.acquireConnection(
        for: "test-key",
        poolConfig: .init(maxConnections: 10)
    ) {
        return createMockConnection()
    }
    
    XCTAssertNotNil(connection)
    
    // Test return operation
    await manager.connectionCache.returnConnection(
        "test-key",
        poolConfig: .init(maxConnections: 10)
    )
}
```

## See Also

- <doc:RetryStrategies>
- <doc:ParallelConnections>
- <doc:NetworkEvents> 