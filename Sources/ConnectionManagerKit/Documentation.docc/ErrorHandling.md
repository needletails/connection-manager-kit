# Error Handling

Implement advanced error handling strategies in ConnectionManagerKit with robust recovery patterns and graceful degradation.

## Overview

ConnectionManagerKit provides comprehensive error handling capabilities across different platforms and network conditions. Understanding how to handle errors effectively is crucial for building reliable networking applications.

## Error Types

### Platform-Specific Errors

#### Apple Platforms (Network Framework)

```swift
#if canImport(Network)
import Network

// NWError types
enum NWError: Error {
    case posix(POSIXError)           // POSIX system errors
    case dns(DNSServiceErrorType)    // DNS resolution errors
    case tls(OSStatus)               // TLS/SSL errors
    case url(URLError)               // URL-related errors
    case unknown                     // Unknown errors
}

// Common POSIX errors
enum POSIXError: Error {
    case ECONNREFUSED    // Connection refused
    case ENETDOWN        // Network is down
    case ENOTCONN        // Not connected
    case ETIMEDOUT       // Connection timeout
    case EHOSTUNREACH    // Host unreachable
    case ENETUNREACH     // Network unreachable
}
#endif
```

#### Linux (NIO)

```swift
#if !canImport(Network)
import NIOCore

// IOError types
struct IOError: Error {
    let errnoCode: Int32
    let reason: String
}

// Common error codes
let ENETDOWN: Int32 = 50      // Network is down
let ENOTCONN: Int32 = 57      // Not connected
let ECONNREFUSED: Int32 = 61  // Connection refused
let ETIMEDOUT: Int32 = 60     // Connection timeout
#endif
```

### ConnectionManager Errors

```swift
extension ConnectionManager {
    enum Errors: Error {
        case tlsNotConfigured
        case connectionFailed(String)
        case timeout(TimeAmount)
        case invalidConfiguration
    }
}
```

## Basic Error Handling

### Error Stream Processing

```swift
class MyConnectionDelegate: ConnectionDelegate {
    #if canImport(Network)
    func handleError(_ stream: AsyncStream<NWError>, id: String) {
        Task {
            for await error in stream {
                await handleNetworkError(error, id: id)
            }
        }
    }
    #else
    func handleError(_ stream: AsyncStream<IOError>, id: String) {
        Task {
            for await error in stream {
                await handleIOError(error, id: id)
            }
        }
    }
    #endif
    
    private func handleNetworkError(_ error: NWError, id: String) async {
        switch error {
        case .posix(.ECONNREFUSED):
            await handleConnectionRefused(id: id)
            
        case .posix(.ENETDOWN):
            await handleNetworkDown(id: id)
            
        case .posix(.ETIMEDOUT):
            await handleTimeout(id: id)
            
        case .dns(let code):
            await handleDNSError(code: code, id: id)
            
        case .tls(let code):
            await handleTLSError(code: code, id: id)
            
        default:
            await handleUnknownError(error, id: id)
        }
    }
    
    private func handleIOError(_ error: IOError, id: String) async {
        switch error.errnoCode {
        case ENETDOWN:
            await handleNetworkDown(id: id)
        case ENOTCONN:
            await handleNotConnected(id: id)
        case ECONNREFUSED:
            await handleConnectionRefused(id: id)
        case ETIMEDOUT:
            await handleTimeout(id: id)
        default:
            await handleUnknownError(error, id: id)
        }
    }
}
```

### Error Recovery Strategies

```swift
class ErrorRecoveryManager {
    private var recoveryStrategies: [String: RecoveryStrategy] = [:]
    
    enum RecoveryStrategy {
        case retry(maxAttempts: Int, backoff: TimeAmount)
        case fallback(to: String)
        case circuitBreaker(threshold: Int, timeout: TimeAmount)
        case gracefulDegradation
    }
    
    func handleConnectionRefused(id: String) async {
        let strategy = recoveryStrategies[id] ?? .retry(maxAttempts: 3, backoff: .seconds(5))
        
        switch strategy {
        case .retry(let maxAttempts, let backoff):
            await retryConnection(id: id, maxAttempts: maxAttempts, backoff: backoff)
            
        case .fallback(let fallbackId):
            await switchToFallback(from: id, to: fallbackId)
            
        case .circuitBreaker(let threshold, let timeout):
            await handleCircuitBreaker(id: id, threshold: threshold, timeout: timeout)
            
        case .gracefulDegradation:
            await enableGracefulDegradation(id: id)
        }
    }
    
    private func retryConnection(id: String, maxAttempts: Int, backoff: TimeAmount) async {
        for attempt in 1...maxAttempts {
            print("Retrying connection \(id), attempt \(attempt)/\(maxAttempts)")
            
            do {
                // Attempt reconnection
                try await reconnect(id: id)
                print("Reconnection successful for \(id)")
                return
            } catch {
                print("Reconnection attempt \(attempt) failed: \(error)")
                
                if attempt < maxAttempts {
                    try? await Task.sleep(until: .now + backoff)
                }
            }
        }
        
        print("All reconnection attempts failed for \(id)")
        await onPermanentFailure(id: id)
    }
}
```

## Advanced Error Handling Patterns

### Circuit Breaker Pattern

```swift
class CircuitBreaker {
    private var failureCount: [String: Int] = [:]
    private var lastFailureTime: [String: Date] = [:]
    private var state: [String: CircuitState] = [:]
    
    enum CircuitState {
        case closed      // Normal operation
        case open        // Circuit is open, requests fail fast
        case halfOpen    // Testing if service is recovered
    }
    
    func execute<T>(id: String, threshold: Int, timeout: TimeAmount, operation: () async throws -> T) async throws -> T {
        let currentState = state[id] ?? .closed
        
        switch currentState {
        case .closed:
            return try await executeInClosedState(id: id, threshold: threshold, operation: operation)
            
        case .open:
            return try await executeInOpenState(id: id, timeout: timeout, operation: operation)
            
        case .halfOpen:
            return try await executeInHalfOpenState(id: id, operation: operation)
        }
    }
    
    private func executeInClosedState<T>(id: String, threshold: Int, operation: () async throws -> T) async throws -> T {
        do {
            let result = try await operation()
            // Success, reset failure count
            failureCount[id] = 0
            return result
        } catch {
            // Increment failure count
            failureCount[id, default: 0] += 1
            lastFailureTime[id] = Date()
            
            if failureCount[id] ?? 0 >= threshold {
                // Open the circuit
                state[id] = .open
                print("Circuit breaker opened for \(id)")
            }
            
            throw error
        }
    }
    
    private func executeInOpenState<T>(id: String, timeout: TimeAmount, operation: () async throws -> T) async throws -> T {
        guard let lastFailure = lastFailureTime[id] else {
            throw CircuitBreakerError.circuitOpen
        }
        
        let timeSinceLastFailure = Date().timeIntervalSince(lastFailure)
        let timeoutSeconds = TimeAmount.seconds(timeout.nanoseconds / 1_000_000_000)
        
        if timeSinceLastFailure >= timeoutSeconds {
            // Try to close the circuit
            state[id] = .halfOpen
            return try await executeInHalfOpenState(id: id, operation: operation)
        } else {
            throw CircuitBreakerError.circuitOpen
        }
    }
    
    private func executeInHalfOpenState<T>(id: String, operation: () async throws -> T) async throws -> T {
        do {
            let result = try await operation()
            // Success, close the circuit
            state[id] = .closed
            failureCount[id] = 0
            lastFailureTime[id] = nil
            print("Circuit breaker closed for \(id)")
            return result
        } catch {
            // Failure, open the circuit again
            state[id] = .open
            lastFailureTime[id] = Date()
            print("Circuit breaker reopened for \(id)")
            throw error
        }
    }
    
    enum CircuitBreakerError: Error {
        case circuitOpen
    }
}
```

### Retry with Exponential Backoff

```swift
class ExponentialBackoffRetry {
    private var retryCounts: [String: Int] = [:]
    
    func retry<T>(
        id: String,
        maxAttempts: Int,
        baseDelay: TimeAmount,
        maxDelay: TimeAmount,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 1...maxAttempts {
            do {
                let result = try await operation()
                // Success, reset retry count
                retryCounts[id] = 0
                return result
            } catch {
                lastError = error
                retryCounts[id, default: 0] += 1
                
                if attempt < maxAttempts {
                    let delay = calculateBackoffDelay(
                        attempt: attempt,
                        baseDelay: baseDelay,
                        maxDelay: maxDelay
                    )
                    
                    print("Retry \(attempt)/\(maxAttempts) for \(id) in \(delay) seconds")
                    try await Task.sleep(until: .now + delay)
                }
            }
        }
        
        throw lastError ?? RetryError.maxAttemptsExceeded
    }
    
    private func calculateBackoffDelay(
        attempt: Int,
        baseDelay: TimeAmount,
        maxDelay: TimeAmount
    ) -> TimeAmount {
        let exponentialDelay = baseDelay * Int64(pow(2.0, Double(attempt - 1)))
        let jitter = TimeAmount.nanoseconds(Int64.random(in: 0...exponentialDelay.nanoseconds / 4))
        let delay = exponentialDelay + jitter
        
        return min(delay, maxDelay)
    }
    
    enum RetryError: Error {
        case maxAttemptsExceeded
    }
}
```

### Graceful Degradation

```swift
class GracefulDegradationManager {
    private var degradedServices: Set<String> = []
    private var fallbackServices: [String: String] = [:]
    
    func handleServiceDegradation(id: String) async {
        degradedServices.insert(id)
        
        if let fallbackId = fallbackServices[id] {
            await switchToFallbackService(from: id, to: fallbackId)
        } else {
            await enableReducedFunctionality(id: id)
        }
    }
    
    private func switchToFallbackService(from: String, to: String) async {
        print("Switching from \(from) to fallback service \(to)")
        
        // Implement fallback logic
        // This could involve:
        // - Using a different server
        // - Using cached data
        // - Using a different protocol
    }
    
    private func enableReducedFunctionality(id: String) async {
        print("Enabling reduced functionality for \(id)")
        
        // Implement reduced functionality
        // This could involve:
        // - Using offline mode
        // - Showing cached content
        // - Disabling non-essential features
    }
    
    func isServiceDegraded(_ id: String) -> Bool {
        return degradedServices.contains(id)
    }
    
    func recoverService(_ id: String) async {
        degradedServices.remove(id)
        print("Service \(id) recovered")
    }
}
```

## Error Monitoring and Logging

### Structured Error Logging

```swift
class ErrorLogger {
    private let logger = NeedleTailLogger()
    
    func logError(_ error: Error, context: ErrorContext) {
        let errorInfo = ErrorInfo(
            error: error,
            context: context,
            timestamp: Date(),
            severity: determineSeverity(error)
        )
        
        logger.log(level: errorInfo.severity, message: formatError(errorInfo))
        
        // Send to monitoring service
        Task {
            await sendToMonitoringService(errorInfo)
        }
    }
    
    struct ErrorContext {
        let connectionId: String
        let operation: String
        let userInfo: [String: Any]
    }
    
    struct ErrorInfo {
        let error: Error
        let context: ErrorContext
        let timestamp: Date
        let severity: Logger.Level
    }
    
    private func determineSeverity(_ error: Error) -> Logger.Level {
        #if canImport(Network)
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(.ECONNREFUSED), .posix(.ENETDOWN):
                return .error
            case .posix(.ETIMEDOUT):
                return .warning
            default:
                return .info
            }
        }
        #endif
        
        return .error
    }
    
    private func formatError(_ errorInfo: ErrorInfo) -> String {
        return """
        Error: \(errorInfo.error)
        Context: \(errorInfo.context.connectionId) - \(errorInfo.context.operation)
        Timestamp: \(errorInfo.timestamp)
        Severity: \(errorInfo.severity)
        """
    }
    
    private func sendToMonitoringService(_ errorInfo: ErrorInfo) async {
        // Send error to monitoring service (e.g., Crashlytics, Sentry)
    }
}
```

### Error Metrics Collection

```swift
class ErrorMetricsCollector {
    private var errorCounts: [String: Int] = [:]
    private var errorTimestamps: [String: [Date]] = [:]
    
    func recordError(_ error: Error, id: String) {
        let errorType = String(describing: type(of: error))
        errorCounts[errorType, default: 0] += 1
        errorTimestamps[errorType, default: []].append(Date())
        
        // Clean up old timestamps (keep last 24 hours)
        cleanupOldTimestamps()
    }
    
    func getErrorRate(for errorType: String, timeWindow: TimeInterval) -> Double {
        let cutoff = Date().addingTimeInterval(-timeWindow)
        let recentErrors = errorTimestamps[errorType]?.filter { $0 > cutoff } ?? []
        return Double(recentErrors.count) / (timeWindow / 3600) // errors per hour
    }
    
    func getMostCommonErrors() -> [(String, Int)] {
        return errorCounts.sorted { $0.value > $1.value }
    }
    
    private func cleanupOldTimestamps() {
        let cutoff = Date().addingTimeInterval(-86400) // 24 hours ago
        
        for (errorType, timestamps) in errorTimestamps {
            errorTimestamps[errorType] = timestamps.filter { $0 > cutoff }
        }
    }
}
```

## Error Recovery Best Practices

### 1. Implement Proper Error Classification

```swift
enum ErrorCategory {
    case transient      // Temporary, can be retried
    case permanent      // Permanent, cannot be retried
    case userError      // User input error
    case systemError    // System-level error
}

func categorizeError(_ error: Error) -> ErrorCategory {
    #if canImport(Network)
    if let nwError = error as? NWError {
        switch nwError {
        case .posix(.ETIMEDOUT), .posix(.ECONNREFUSED):
            return .transient
        case .posix(.ENETDOWN):
            return .systemError
        case .dns:
            return .transient
        case .tls:
            return .permanent
        default:
            return .systemError
        }
    }
    #endif
    
    return .systemError
}
```

### 2. Use Appropriate Recovery Strategies

```swift
func handleError(_ error: Error, id: String) async {
    let category = categorizeError(error)
    
    switch category {
    case .transient:
        await retryWithBackoff(error: error, id: id)
        
    case .permanent:
        await handlePermanentError(error: error, id: id)
        
    case .userError:
        await notifyUser(error: error, id: id)
        
    case .systemError:
        await handleSystemError(error: error, id: id)
    }
}
```

### 3. Implement Timeout Handling

```swift
func executeWithTimeout<T>(
    _ operation: () async throws -> T,
    timeout: TimeAmount
) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(until: .now + timeout)
            throw TimeoutError()
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

struct TimeoutError: Error {}
```

### 4. Handle Cascading Failures

```swift
class CascadingFailureHandler {
    private var failureChain: [String] = []
    
    func handleCascadingFailure(_ error: Error, id: String) async {
        failureChain.append(id)
        
        if failureChain.count > 3 {
            // Too many failures in chain, implement circuit breaker
            await enableCircuitBreaker()
        } else {
            // Try to isolate the failure
            await isolateFailure(id: id)
        }
    }
    
    private func isolateFailure(id: String) async {
        // Implement failure isolation logic
        print("Isolating failure for \(id)")
    }
    
    private func enableCircuitBreaker() async {
        // Implement circuit breaker logic
        print("Enabling circuit breaker due to cascading failures")
    }
}
```

## Testing Error Handling

### Error Injection Testing

```swift
class ErrorInjectionTest {
    func testConnectionRefusedHandling() async throws {
        let manager = ConnectionManager()
        let delegate = MockConnectionDelegate()
        
        // Inject connection refused error
        delegate.injectError(.posix(.ECONNREFUSED))
        
        // Verify error handling behavior
        let result = await delegate.handleError()
        XCTAssertEqual(result, .retry)
    }
    
    func testTimeoutHandling() async throws {
        let manager = ConnectionManager()
        let delegate = MockConnectionDelegate()
        
        // Inject timeout error
        delegate.injectError(.posix(.ETIMEDOUT))
        
        // Verify timeout handling behavior
        let result = await delegate.handleError()
        XCTAssertEqual(result, .backoff)
    }
}

class MockConnectionDelegate: ConnectionDelegate {
    private var injectedError: NWError?
    
    func injectError(_ error: NWError) {
        injectedError = error
    }
    
    func handleError(_ stream: AsyncStream<NWError>, id: String) {
        if let error = injectedError {
            // Simulate error handling
        }
    }
}
```

## Troubleshooting

### Common Error Handling Issues

1. **Infinite Retry Loops**
   - Implement maximum retry limits
   - Use exponential backoff
   - Add circuit breaker pattern

2. **Memory Leaks**
   - Properly cancel async tasks
   - Use weak references
   - Clean up error handlers

3. **Error Swallowing**
   - Always log errors
   - Implement proper error propagation
   - Use structured error handling

### Debug Error Handling

```swift
class DebugErrorHandler {
    func handleError(_ error: Error, id: String) async {
        print("=== Error Debug Info ===")
        print("Error: \(error)")
        print("Type: \(type(of: error))")
        print("Connection ID: \(id)")
        print("Stack trace: \(Thread.callStackSymbols)")
        print("========================")
        
        // Continue with normal error handling
        await normalErrorHandling(error, id: id)
    }
}
```

---

For more information about error handling, see the [Basic Usage](BasicUsage) guide and [API Reference](Documentation). 