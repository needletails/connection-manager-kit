# Network Events

Handle network events and state changes in ConnectionManagerKit with real-time monitoring and reactive programming patterns.

## Overview

ConnectionManagerKit provides comprehensive network event monitoring through the `NetworkEventMonitor` class. This system allows you to respond to network conditions in real-time, including connection viability changes, path availability, and connectivity issues.

## Network Event Types

### Apple Platforms (Network Framework)

ConnectionManagerKit provides the following network events on Apple platforms:

```swift
public enum NetworkEvent: Sendable {
    /// A better network path has become available
    case betterPathAvailable(NIOTSNetworkEvents.BetterPathAvailable)
    
    /// A previously available better network path is no longer available
    case betterPathUnavailable
    
    /// The network viability has changed (e.g., network became available/unavailable)
    case viabilityChanged(NIOTSNetworkEvents.ViabilityUpdate)
    
    /// The system is attempting to connect to a Network framework endpoint
    case connectToNWEndpoint(NIOTSNetworkEvents.ConnectToNWEndpoint)
    
    /// The system is attempting to bind to a Network framework endpoint
    case bindToNWEndpoint(NIOTSNetworkEvents.BindToNWEndpoint)
    
    /// The system is waiting for connectivity to become available
    case waitingForConnectivity(NIOTSNetworkEvents.WaitingForConnectivity)
    
    /// The network path has changed (e.g., switching from WiFi to cellular)
    case pathChanged(NIOTSNetworkEvents.PathChanged)
}
```

### Linux (NIO)

On Linux platforms, ConnectionManagerKit provides NIO-specific events:

```swift
public enum NIOEvent: @unchecked Sendable {
    /// A generic NIO event
    case event(Any)
}
```

## Basic Network Event Handling

### Setting Up Event Monitoring

```swift
class MyConnectionDelegate: ConnectionDelegate {
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
        for await event in stream {
            switch event {
            case .viabilityChanged(let update):
                print("Connection \(id) viability: \(update.isViable)")
                
            case .betterPathAvailable(let path):
                print("Better path available for \(id)")
                
            case .betterPathUnavailable:
                print("Better path unavailable for \(id)")
                
            case .waitingForConnectivity(let error):
                print("Waiting for connectivity for \(id): \(error)")
                
            case .pathChanged(let path):
                print("Path changed for \(id)")
                
            case .connectToNWEndpoint(let endpoint):
                print("Connecting to endpoint for \(id)")
                
            case .bindToNWEndpoint(let endpoint):
                print("Binding to endpoint for \(id)")
            }
        }
    }
}
```

### Error Event Handling

```swift
class MyConnectionDelegate: ConnectionDelegate {
    func handleError(_ stream: AsyncStream<NWError>, id: String) {
        Task {
            for await error in stream {
                switch error {
                case .posix(.ECONNREFUSED):
                    print("Connection \(id) refused")
                    
                case .posix(.ENETDOWN):
                    print("Network \(id) is down")
                    
                case .posix(.ENOTCONN):
                    print("Connection \(id) is not connected")
                    
                case .dns(let code):
                    print("DNS error for \(id): \(code)")
                    
                case .tls(let code):
                    print("TLS error for \(id): \(code)")
                    
                default:
                    print("Other error for \(id): \(error)")
                }
            }
        }
    }
}
```

## Advanced Network Event Patterns

### Connection State Management

```swift
class ConnectionStateManager {
    private var connectionStates: [String: ConnectionState] = [:]
    private let manager = ConnectionManager()
    
    enum ConnectionState {
        case connecting
        case connected
        case disconnected
        case reconnecting
        case failed
    }
    
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
        for await event in stream {
            await updateConnectionState(for: id, event: event)
        }
    }
    
    private func updateConnectionState(for id: String, event: NetworkEventMonitor.NetworkEvent) async {
        switch event {
        case .viabilityChanged(let update):
            if update.isViable {
                connectionStates[id] = .connected
                await onConnectionRestored(id: id)
            } else {
                connectionStates[id] = .disconnected
                await onConnectionLost(id: id)
            }
            
        case .waitingForConnectivity(let error):
            connectionStates[id] = .reconnecting
            await onReconnecting(id: id, error: error)
            
        case .betterPathAvailable(let path):
            await onBetterPathAvailable(id: id, path: path)
            
        default:
            break
        }
    }
    
    private func onConnectionRestored(id: String) async {
        print("Connection \(id) restored")
        // Implement reconnection logic
    }
    
    private func onConnectionLost(id: String) async {
        print("Connection \(id) lost")
        // Implement fallback logic
    }
    
    private func onReconnecting(id: String, error: NIOTSNetworkEvents.WaitingForConnectivity) async {
        print("Reconnecting \(id): \(error)")
        // Implement retry logic
    }
    
    private func onBetterPathAvailable(id: String, path: NIOTSNetworkEvents.BetterPathAvailable) async {
        print("Better path available for \(id)")
        // Implement path switching logic
    }
}
```

### Network Quality Monitoring

```swift
class NetworkQualityMonitor {
    private var qualityMetrics: [String: NetworkQuality] = [:]
    
    struct NetworkQuality {
        var latency: TimeInterval
        var bandwidth: Double
        var reliability: Double
        var lastUpdate: Date
    }
    
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
        for await event in stream {
            await updateNetworkQuality(for: id, event: event)
        }
    }
    
    private func updateNetworkQuality(for id: String, event: NetworkEventMonitor.NetworkEvent) async {
        switch event {
        case .viabilityChanged(let update):
            if update.isViable {
                // Network is viable, measure quality
                await measureNetworkQuality(for: id)
            } else {
                // Network is not viable
                qualityMetrics[id] = NetworkQuality(
                    latency: .infinity,
                    bandwidth: 0,
                    reliability: 0,
                    lastUpdate: Date()
                )
            }
            
        case .pathChanged(let path):
            // Path changed, remeasure quality
            await measureNetworkQuality(for: id)
            
        default:
            break
        }
    }
    
    private func measureNetworkQuality(for id: String) async {
        // Implement network quality measurement
        // This could include ping tests, bandwidth tests, etc.
    }
}
```

### Adaptive Reconnection Strategy

```swift
class AdaptiveReconnectionManager {
    private var reconnectionAttempts: [String: Int] = [:]
    private var lastFailureTime: [String: Date] = [:]
    
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
        for await event in stream {
            await handleReconnectionEvent(for: id, event: event)
        }
    }
    
    private func handleReconnectionEvent(for id: String, event: NetworkEventMonitor.NetworkEvent) async {
        switch event {
        case .viabilityChanged(let update):
            if update.isViable {
                // Connection restored, reset counters
                reconnectionAttempts[id] = 0
                lastFailureTime[id] = nil
                print("Connection \(id) restored after \(reconnectionAttempts[id] ?? 0) attempts")
            } else {
                // Connection lost, increment counter
                reconnectionAttempts[id, default: 0] += 1
                lastFailureTime[id] = Date()
                
                let attempts = reconnectionAttempts[id] ?? 0
                let delay = calculateBackoffDelay(attempts: attempts)
                
                print("Connection \(id) lost, attempt \(attempts), retrying in \(delay) seconds")
                
                // Schedule reconnection with exponential backoff
                Task {
                    try await Task.sleep(until: .now + .seconds(delay))
                    await attemptReconnection(for: id)
                }
            }
            
        case .waitingForConnectivity(let error):
            print("Waiting for connectivity for \(id): \(error)")
            
        default:
            break
        }
    }
    
    private func calculateBackoffDelay(attempts: Int) -> Int64 {
        // Exponential backoff with jitter
        let baseDelay = min(30, Int64(pow(2.0, Double(attempts))))
        let jitter = Int64.random(in: 0...baseDelay / 4)
        return baseDelay + jitter
    }
    
    private func attemptReconnection(for id: String) async {
        // Implement reconnection logic
        print("Attempting reconnection for \(id)")
    }
}
```

## Channel Lifecycle Events

### Channel Active/Inactive Monitoring

```swift
class MyChannelContextDelegate: ChannelContextDelegate {
    private var activeChannels: Set<String> = []
    
    func channelActive(_ stream: AsyncStream<Void>, id: String) {
        Task {
            for await _ in stream {
                activeChannels.insert(id)
                print("Channel \(id) is now active")
                await onChannelActivated(id: id)
            }
        }
    }
    
    func channelInactive(_ stream: AsyncStream<Void>, id: String) {
        Task {
            for await _ in stream {
                activeChannels.remove(id)
                print("Channel \(id) is now inactive")
                await onChannelDeactivated(id: id)
            }
        }
    }
    
    private func onChannelActivated(id: String) async {
        // Channel is ready for communication
        print("Channel \(id) ready for data transfer")
    }
    
    private func onChannelDeactivated(id: String) async {
        // Channel is no longer available
        print("Channel \(id) no longer available")
    }
}
```

## Cross-Platform Event Handling

### Platform-Agnostic Event Handler

```swift
class CrossPlatformEventHandler {
    #if canImport(Network)
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
        for await event in stream {
            await handleAppleNetworkEvent(event, id: id)
        }
    }
    
    private func handleAppleNetworkEvent(_ event: NetworkEventMonitor.NetworkEvent, id: String) async {
        switch event {
        case .viabilityChanged(let update):
            await onNetworkViabilityChanged(id: id, isViable: update.isViable)
            
        case .betterPathAvailable(let path):
            await onBetterPathAvailable(id: id)
            
        case .waitingForConnectivity(let error):
            await onWaitingForConnectivity(id: id, error: error)
            
        default:
            break
        }
    }
    #else
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NIOEvent>, id: String) async {
        for await event in stream {
            await handleNIONetworkEvent(event, id: id)
        }
    }
    
    private func handleNIONetworkEvent(_ event: NetworkEventMonitor.NIOEvent, id: String) async {
        switch event {
        case .event(let anyEvent):
            // Handle NIO-specific events
            print("NIO event for \(id): \(anyEvent)")
        }
    }
    #endif
    
    // Platform-agnostic event handlers
    private func onNetworkViabilityChanged(id: String, isViable: Bool) async {
        if isViable {
            print("Network \(id) is viable")
        } else {
            print("Network \(id) is not viable")
        }
    }
    
    private func onBetterPathAvailable(id: String) async {
        print("Better path available for \(id)")
    }
    
    private func onWaitingForConnectivity(id: String, error: NIOTSNetworkEvents.WaitingForConnectivity) async {
        print("Waiting for connectivity for \(id): \(error)")
    }
}
```

## Event-Driven Architecture

### Event Bus Pattern

```swift
class NetworkEventBus {
    private var subscribers: [String: [NetworkEventSubscriber]] = [:]
    
    protocol NetworkEventSubscriber: AnyObject {
        func handleNetworkEvent(_ event: NetworkEventMonitor.NetworkEvent, id: String) async
    }
    
    func subscribe(_ subscriber: NetworkEventSubscriber, for eventType: String) {
        subscribers[eventType, default: []].append(subscriber)
    }
    
    func unsubscribe(_ subscriber: NetworkEventSubscriber, from eventType: String) {
        subscribers[eventType]?.removeAll { $0 === subscriber }
    }
    
    func publish(_ event: NetworkEventMonitor.NetworkEvent, id: String) async {
        let eventType = String(describing: type(of: event))
        
        for subscriber in subscribers[eventType] ?? [] {
            await subscriber.handleNetworkEvent(event, id: id)
        }
    }
}

// Usage
class MyConnectionDelegate: ConnectionDelegate {
    private let eventBus = NetworkEventBus()
    
    init() {
        eventBus.subscribe(ConnectionStateManager(), for: "viabilityChanged")
        eventBus.subscribe(NetworkQualityMonitor(), for: "pathChanged")
    }
    
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
        for await event in stream {
            await eventBus.publish(event, id: id)
        }
    }
}
```

## Best Practices

### 1. Handle Events Asynchronously

```swift
// Good: Handle events asynchronously
func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
    for await event in stream {
        await processEvent(event, id: id)
    }
}

// Avoid: Blocking event processing
func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
    for await event in stream {
        // Don't block here
        Thread.sleep(forTimeInterval: 1.0) // ❌ Bad
    }
}
```

### 2. Implement Proper Error Handling

```swift
func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
    do {
        for await event in stream {
            try await processEvent(event, id: id)
        }
    } catch {
        print("Error processing network events for \(id): \(error)")
        // Implement error recovery
    }
}
```

### 3. Use Event Filtering

```swift
func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
    for await event in stream {
        // Only process events for specific connections
        guard shouldProcessEvent(event, for: id) else { continue }
        
        await processEvent(event, id: id)
    }
}

private func shouldProcessEvent(_ event: NetworkEventMonitor.NetworkEvent, for id: String) -> Bool {
    // Implement filtering logic
    return true
}
```

### 4. Monitor Event Processing Performance

```swift
func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
    for await event in stream {
        let startTime = Date()
        
        await processEvent(event, id: id)
        
        let processingTime = Date().timeIntervalSince(startTime)
        if processingTime > 0.1 {
            print("Slow event processing for \(id): \(processingTime)s")
        }
    }
}
```

## Troubleshooting

### Common Issues

1. **Events Not Received**
   - Verify delegate is properly set
   - Check connection is active
   - Ensure event stream is not cancelled

2. **High Event Volume**
   - Implement event filtering
   - Use event batching
   - Monitor processing performance

3. **Memory Leaks**
   - Use weak references in closures
   - Properly cancel async streams
   - Clean up event subscribers

### Debug Network Events

```swift
class DebugNetworkEventHandler {
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
        print("Starting network event monitoring for \(id)")
        
        for await event in stream {
            print("Network event for \(id): \(event)")
            
            // Add detailed logging
            switch event {
            case .viabilityChanged(let update):
                print("  Viability: \(update.isViable)")
            case .betterPathAvailable(let path):
                print("  Better path: \(path)")
            case .waitingForConnectivity(let error):
                print("  Waiting: \(error)")
            default:
                break
            }
        }
        
        print("Stopped network event monitoring for \(id)")
    }
}
```

---

For more information about network events, see the [Basic Usage](BasicUsage) guide and [API Reference](Documentation). 