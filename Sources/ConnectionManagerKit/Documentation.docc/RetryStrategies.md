# Retry Strategies

Configure flexible retry policies for connection failures with built-in strategies and custom implementations.

## Overview

ConnectionManagerKit provides a comprehensive retry system through the `RetryStrategy` enum, allowing you to define how the framework should handle connection failures. The retry strategies are designed to be flexible, efficient, and suitable for various network conditions.

## Available Strategies

### Fixed Delay Strategy

The simplest retry strategy that waits a fixed amount of time between attempts.

```swift
let strategy = RetryStrategy.fixed(delay: .seconds(2))
```

**Use cases:**
- Simple retry scenarios
- When you need predictable timing
- Testing and debugging
- Quick recovery from temporary issues

**Example:**
```swift
let manager = ConnectionManager<ByteBuffer, ByteBuffer>()

try await manager.connect(
    to: servers,
    retryStrategy: .fixed(delay: .seconds(5))
)
```

### Exponential Backoff Strategy

A sophisticated retry strategy that increases delay exponentially with optional jitter to prevent thundering herd problems.

```swift
let strategy = RetryStrategy.exponential(
    initialDelay: .seconds(1),
    maxDelay: .seconds(30),
    multiplier: 2.0,
    jitter: true
)
```

**Parameters:**
- `initialDelay`: The delay before the first retry
- `maxDelay`: Maximum delay cap to prevent excessive wait times
- `multiplier`: Factor by which delay increases (default: 2.0)
- `jitter`: Randomization factor to prevent synchronized retries (default: true)

**Use cases:**
- Production environments
- When dealing with temporary network issues
- High-traffic scenarios
- Load balancing scenarios

**Example:**
```swift
let manager = ConnectionManager<ByteBuffer, ByteBuffer>()

try await manager.connect(
    to: servers,
    retryStrategy: .exponential(
        initialDelay: .seconds(1),
        maxDelay: .seconds(30),
        multiplier: 2.0,
        jitter: true
    )
)
```

### Custom Strategy

Define your own retry logic based on attempt number and maximum attempts.

```swift
let strategy = RetryStrategy.custom { attempt, maxAttempts in
    if attempt < 3 {
        return .seconds(Double(attempt) * 2.0)
    }
    return .seconds(0) // Stop retrying
}
```

**Use cases:**
- Error-specific retry logic
- Complex retry requirements
- Integration with external systems
- Custom business logic

**Example:**
```swift
let manager = ConnectionManager<ByteBuffer, ByteBuffer>()

try await manager.connect(
    to: servers,
    retryStrategy: .custom { attempt, maxAttempts in
        // Don't retry after 3 attempts
        if attempt >= 3 {
            return .seconds(0)
        }
        
        // Exponential backoff with custom logic
        let delay = min(pow(2.0, Double(attempt)), 15.0)
        return .seconds(Int64(delay))
    }
)
```

## Usage Examples

### Basic Usage

```swift
let manager = ConnectionManager<ByteBuffer, ByteBuffer>()

// Connect with fixed delay retry
try await manager.connect(
    to: servers,
    retryStrategy: .fixed(delay: .seconds(1))
)
```

### Advanced Usage with Error Handling

```swift
let manager = ConnectionManager<ByteBuffer, ByteBuffer>()

// Custom retry strategy with error-specific logic
let customStrategy = RetryStrategy.custom { attempt, maxAttempts in
    // Don't retry on authentication errors
    if attempt >= maxAttempts {
        return .seconds(0)
    }
    
    // Exponential backoff for network errors
    let delay = min(pow(2.0, Double(attempt)), 30.0)
    return .seconds(Int64(delay))
}

try await manager.connect(
    to: servers,
    retryStrategy: customStrategy
)
```

### Parallel Connections with Retry

```swift
let manager = ConnectionManager<ByteBuffer, ByteBuffer>()

// Connect to multiple servers in parallel with exponential backoff
let connections = try await manager.connectParallel(
    to: servers,
    maxConcurrentConnections: 3,
    retryStrategy: .exponential(
        initialDelay: .seconds(1),
        maxDelay: .seconds(10),
        multiplier: 1.5,
        jitter: true
    )
)
```

## Best Practices

### Choose the Right Strategy

- **Fixed Delay**: Use for simple scenarios and testing
- **Exponential Backoff**: Use for production environments
- **Custom**: Use when you need error-specific logic

### Configure Appropriate Timeouts

```swift
// Set reasonable timeouts based on your retry strategy
let strategy = RetryStrategy.exponential(
    initialDelay: .seconds(1),
    maxDelay: .seconds(30) // Don't exceed your application timeout
)
```

### Handle Different Error Types

```swift
let strategy = RetryStrategy.custom { attempt, maxAttempts in
    // Don't retry on permanent failures
    if attempt >= maxAttempts {
        return .seconds(0)
    }
    
    // Aggressive retry for temporary issues
    if attempt < 3 {
        return .seconds(1)
    }
    
    // Moderate retry for network issues
    let delay = Double(attempt) * 2.0
    return .seconds(Int64(delay))
}
```

### Monitor Retry Behavior

```swift
// Log retry attempts for monitoring
let strategy = RetryStrategy.custom { attempt, maxAttempts in
    print("Retry attempt \(attempt) of \(maxAttempts)")
    
    if attempt < 3 {
        return .seconds(Int64(attempt) * 2)
    }
    
    print("Max retry attempts reached")
    return .seconds(0)
}
```

## Performance Considerations

### Jitter for High-Concurrency

When multiple clients might retry simultaneously, use jitter to prevent thundering herd:

```swift
let strategy = RetryStrategy.exponential(
    initialDelay: .seconds(1),
    maxDelay: .seconds(30),
    multiplier: 2.0,
    jitter: true // 10% randomization
)
```

### Memory Management

Custom retry strategies should avoid capturing large objects:

```swift
// Good: Minimal capture
let strategy = RetryStrategy.custom { attempt, maxAttempts in
    return .seconds(Int64(attempt))
}

// Avoid: Capturing large objects
var largeData = [String: Any]()
let strategy = RetryStrategy.custom { attempt, maxAttempts in
    // Don't capture largeData here
    return .seconds(1)
}
```

## Integration with Connection Pooling

Retry strategies work seamlessly with connection pooling:

```swift
let manager = ConnectionManager<ByteBuffer, ByteBuffer>()

// Connect with retry strategy
try await manager.connect(
    to: servers,
    retryStrategy: .exponential(initialDelay: .seconds(1))
)

// Use pooled connections
let connection = await manager.connectionCache.acquireConnection(
    for: "server-key",
    poolConfiguration: .init(maxConnections: 10)
)

// Return connection to pool
await manager.connectionCache.returnConnection(connection, for: "server-key")
```

## Error Handling

### Connection Timeout

```swift
let strategy = RetryStrategy.custom { attempt, maxAttempts in
    // Handle timeout errors specifically
    if attempt < 3 {
        return .seconds(Int64(attempt) * 2)
    }
    return .seconds(0)
}
```

### Network Errors

```swift
let strategy = RetryStrategy.custom { attempt, maxAttempts in
    // Different strategies for different error types
    switch attempt {
    case 0..<3:
        return .seconds(1) // Quick retry
    case 3..<5:
        return .seconds(Int64(attempt) * 2) // Exponential backoff
    default:
        return .seconds(0) // Stop retrying
    }
}
```

## Testing Retry Strategies

### Unit Testing

```swift
func testRetryStrategy() async throws {
    let strategy = RetryStrategy.fixed(delay: .seconds(5))
    
    switch strategy {
    case .fixed(let delay):
        XCTAssertEqual(delay, .seconds(5))
    default:
        XCTFail("Expected fixed strategy")
    }
}
```

### Integration Testing

```swift
func testRetryStrategyWithConnection() async throws {
    let manager = ConnectionManager<ByteBuffer, ByteBuffer>()
    
    // Test with mock server that fails initially
    try await manager.connect(
        to: servers,
        retryStrategy: .fixed(delay: .milliseconds(100))
    )
}
```

## See Also

- <doc:ConnectionPooling>
- <doc:ParallelConnections>
- <doc:ErrorHandling> 