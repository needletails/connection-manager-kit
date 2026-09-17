//
//  ConnectionCache.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/27/24.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//  This file is part of the ConnectionManagerKit Project

import NeedleTailLogger
import NIOCore
import Foundation
import Metrics

/// Delegate protocol for receiving connection cache metrics updates
public protocol ConnectionCacheMetricsDelegate: AnyObject, Sendable {
    /// Called when cache metrics are updated
    /// - Parameters:
    ///   - cachedConnections: Current number of cached connections
    ///   - maxConnections: Maximum allowed connections
    ///   - lruEnabled: Whether LRU eviction is enabled
    ///   - ttlEnabled: Whether TTL is enabled
    func cacheMetricsDidUpdate(cachedConnections: Int, maxConnections: Int, lruEnabled: Bool, ttlEnabled: Bool)
    
    /// Called when a cache hit occurs
    /// - Parameter cacheKey: The cache key that was hit
    func cacheHitDidOccur(cacheKey: String)
    
    /// Called when a cache miss occurs
    /// - Parameter cacheKey: The cache key that was missed
    func cacheMissDidOccur(cacheKey: String)
    
    /// Called when a connection is evicted from cache
    /// - Parameter cacheKey: The cache key that was evicted
    func connectionDidEvict(cacheKey: String)
    
    /// Called when a connection expires due to TTL
    /// - Parameter cacheKey: The cache key that expired
    func connectionDidExpire(cacheKey: String)
}

/// Default implementation for optional delegate methods
public extension ConnectionCacheMetricsDelegate {
    func cacheHitDidOccur(cacheKey: String) {}
    func cacheMissDidOccur(cacheKey: String) {}
    func connectionDidEvict(cacheKey: String) {}
    func connectionDidExpire(cacheKey: String) {}
}

/// Configuration for connection cache behavior.
public struct CacheConfiguration: Sendable {
    /// Maximum number of connections to cache.
    public let maxConnections: Int
    /// Time-to-live for cached connections.
    public let ttl: TimeAmount?
    /// Whether to enable LRU eviction.
    public let enableLRU: Bool
    
    public init(maxConnections: Int = 100, ttl: TimeAmount? = nil, enableLRU: Bool = false) {
        precondition(maxConnections > 0, "maxConnections must be greater than zero")
        if let ttl {
            precondition(ttl.nanoseconds >= 0, "ttl must not be negative")
        }
        self.maxConnections = maxConnections
        self.ttl = ttl
        self.enableLRU = enableLRU
    }
}

/// Legacy pooling configuration retained for source compatibility.
///
/// ConnectionManagerKit provides a keyed cache and does not consume this configuration.
@available(*, deprecated, message: "ConnectionManagerKit provides a keyed connection cache, not a multi-checkout connection pool.")
public struct ConnectionPoolConfiguration: Sendable {
    /// Legacy minimum connection setting.
    public let minConnections: Int
    /// Legacy maximum connection setting.
    public let maxConnections: Int
    /// Legacy acquisition timeout setting.
    public let acquireTimeout: TimeAmount
    /// Legacy idle timeout setting.
    public let maxIdleTime: TimeAmount
    
    public init(
        minConnections: Int = 0,
        maxConnections: Int = 10,
        acquireTimeout: TimeAmount = .seconds(30),
        maxIdleTime: TimeAmount = .seconds(300)
    ) {
        self.minConnections = minConnections
        self.maxConnections = maxConnections
        self.acquireTimeout = acquireTimeout
        self.maxIdleTime = maxIdleTime
    }
}

/// A thread-safe cache for managing network connections.
///
/// `ConnectionCache` provides efficient storage and retrieval of active network connections
/// using unique cache keys. It's designed to work with the `ConnectionManager` to provide
/// connection reuse and lifecycle management.
///
/// ## Key Features
/// - **Thread Safety**: Implemented as an actor for safe concurrent access
/// - **Automatic Cleanup**: Connections are properly shut down when removed
/// - **Efficient Lookup**: O(1) average case lookup by cache key
/// - **Bulk Operations**: Support for removing all connections at once
/// - **LRU Eviction**: Optional LRU-based eviction for memory management
/// - **TTL Support**: Optional time-to-live for cached connections
///
/// ## Usage Example
/// ```swift
/// let config = CacheConfiguration(maxConnections: 50, ttl: .seconds(300), enableLRU: true)
/// let cache = ConnectionCache<ByteBuffer, ByteBuffer>(logger: NeedleTailLogger(), configuration: config)
/// 
/// // Cache a connection
/// await cache.cacheConnection(connection, for: "server-1")
/// 
/// // Find a connection
/// let found = await cache.findConnection(cacheKey: "server-1")
/// 
/// // Remove a connection
/// try await cache.removeConnection("server-1")
/// 
/// // Get all connections
/// let allConnections = await cache.fetchAllConnections()
/// ```
///
/// - Note: This class is implemented as an actor to ensure thread-safe access to its internal state.
/// - Note: All connections are automatically shut down when removed from the cache.
actor ConnectionCache<Inbound: Sendable, Outbound: Sendable> {
    
    /// The logger instance used for logging cache operations.
    private let logger: NeedleTailLogger
    
    /// The cache configuration.
    private let configuration: CacheConfiguration
    
    /// The internal storage for cached connections, keyed by cache key.
    private var connections: [String: ChildChannelService<Inbound, Outbound>] = [:]
    
    private struct OrderEntry {
        let key: String
        let generation: UInt64
    }

    /// Append-only access order with lazy invalidation and periodic compaction.
    private var connectionOrder: [OrderEntry] = []
    private var connectionOrderHead = 0
    private var orderGeneration: UInt64 = 0
    private var currentGenerationByKey: [String: UInt64] = [:]
    
    /// Timestamps for TTL tracking (only used when TTL is enabled).
    private var timestamps: [String: TimeAmount] = [:]
    
    /// The metrics delegate for receiving cache updates.
    public weak var metricsDelegate: ConnectionCacheMetricsDelegate?
    
    /// Reports authoritative cache membership changes to the manager.
    private var onConnectionCountChanged: (@Sendable (Int) async -> Void)?
    private var isRemovingAllConnections = false
    
    // Swift Metrics
    private let cachedConnectionsGauge = Gauge(label: "connection_cache_cached_connections", dimensions: [("component", "connection_cache")])
    private let cacheHitsCounter = Counter(label: "connection_cache_hits", dimensions: [("component", "connection_cache")])
    private let cacheMissesCounter = Counter(label: "connection_cache_misses", dimensions: [("component", "connection_cache")])
    private let cacheEvictionsCounter = Counter(label: "connection_cache_evictions", dimensions: [("component", "connection_cache")])
    private let cacheTTLExpirationsCounter = Counter(label: "connection_cache_ttl_expirations", dimensions: [("component", "connection_cache")])
    
    /// A boolean indicating whether the cache is empty.
    ///
    /// - Returns: `true` if the cache contains no connections, `false` otherwise.
    var isEmpty: Bool {
        return connections.isEmpty
    }
    
    /// The number of connections currently cached.
    ///
    /// - Returns: The total number of connections in the cache.
    var count: Int {
        return connections.count
    }
    
    /// Creates a new connection cache instance.
    ///
    /// - Parameter logger: The logger instance to use for logging cache operations.
    init(logger: NeedleTailLogger) {
        self.logger = logger
        self.configuration = CacheConfiguration()
    }
    
    /// Creates a new connection cache instance with custom configuration.
    ///
    /// - Parameters:
    ///   - logger: The logger instance to use for logging cache operations.
    ///   - configuration: The cache configuration.
    init(logger: NeedleTailLogger, configuration: CacheConfiguration) {
        self.logger = logger
        self.configuration = configuration
    }
    
    func setConnectionCountChangedCallback(
        _ callback: @escaping @Sendable (Int) async -> Void
    ) async {
        self.onConnectionCountChanged = callback
        await callback(connections.count)
    }
    
    /// Caches a new connection with the specified cache key.
    ///
    /// If a connection already exists with the same cache key, it will be replaced
    /// with the new connection. The old connection will be automatically shut down.
    /// If LRU is enabled and the cache is full, the least recently used connection
    /// will be evicted.
    ///
    /// - Parameters:
    ///   - connection: The connection to cache.
    ///   - cacheKey: A unique key used to identify the connection in the cache.
    ///
    /// ## Example
    /// ```swift
    /// let connection = ChildChannelService(...)
    /// await cache.cacheConnection(connection, for: "api-server")
    /// ```
    func cacheConnection(_ connection: ChildChannelService<Inbound, Outbound>, for cacheKey: String) async {
        guard !isRemovingAllConnections else {
            try? await connection.shutdown()
            return
        }

        let connectionToClose: ChildChannelService<Inbound, Outbound>?

        // Replacing a key does not consume additional capacity.
        if let existingConnection = connections[cacheKey] {
            connectionToClose = existingConnection
            removeFromLRU(cacheKey)
        } else if connections.count >= configuration.maxConnections {
            connectionToClose = evictOldestConnection()
        } else {
            connectionToClose = nil
        }
        
        connections[cacheKey] = connection
        addToLRU(cacheKey)
        
        // Update Swift Metrics
        cachedConnectionsGauge.record(connections.count)
        
        // Notify delegate
        metricsDelegate?.cacheMetricsDidUpdate(
            cachedConnections: connections.count,
            maxConnections: configuration.maxConnections,
            lruEnabled: configuration.enableLRU,
            ttlEnabled: configuration.ttl != nil
        )
        
        // Set timestamp for TTL tracking
        if configuration.ttl != nil {
            timestamps[cacheKey] = .now
        }

        await onConnectionCountChanged?(connections.count)

        if let connectionToClose {
            do {
                try await connectionToClose.shutdown()
            } catch {
                logger.log(level: .error, message: "Failed to shutdown replaced connection \(error)")
            }
        }
        
        logger.log(level: .info, message: "Cached connection for cacheKey: \(cacheKey)")
    }
    
    /// Updates an existing connection in the cache.
    ///
    /// This method is similar to `cacheConnection(_:for:)` but provides additional
    /// logging when updating existing connections. If no connection exists with the
    /// specified cache key, a new connection will be cached instead.
    ///
    /// - Parameters:
    ///   - connection: The connection to update or cache.
    ///   - cacheKey: A unique key used to identify the connection in the cache.
    ///
    /// ## Example
    /// ```swift
    /// let updatedConnection = ChildChannelService(...)
    /// await cache.updateConnection(updatedConnection, for: "api-server")
    /// ```
    func updateConnection(_ connection: ChildChannelService<Inbound, Outbound>, for cacheKey: String) async {
        if connections[cacheKey] != nil {
            connections[cacheKey] = connection
            updateLRU(cacheKey)
            
            // Update timestamp for TTL tracking
            if configuration.ttl != nil {
                timestamps[cacheKey] = .now
            }
            
            logger.log(level: .info, message: "Updated connection for cacheKey: \(cacheKey)")
        } else {
            logger.log(level: .info, message: "No existing connection found for cacheKey: \(cacheKey). Caching new connection instead.")
            await cacheConnection(connection, for: cacheKey)
        }
    }
    
    /// Finds a connection by its cache key.
    ///
    /// If TTL is enabled, this method will check if the connection has expired and
    /// remove it if necessary. If LRU is enabled, accessing a connection will update
    /// its position in the LRU order.
    ///
    /// - Parameter cacheKey: The unique key used to identify the connection.
    /// - Returns: The cached connection if found and not expired, `nil` otherwise.
    ///
    /// ## Example
    /// ```swift
    /// if let connection = await cache.findConnection(cacheKey: "api-server") {
    ///     // Use the connection
    ///     let config = await connection.config
    ///     print("Found connection to \(config.host)")
    /// } else {
    ///     print("No connection found for api-server")
    /// }
    /// ```
    func findConnection(cacheKey: String) async -> ChildChannelService<Inbound, Outbound>? {
        // Check if connection exists
        guard let connection = connections[cacheKey] else {
            logger.log(level: .debug, message: "No connection found for cacheKey: \(cacheKey)")
            cacheMissesCounter.increment()
            metricsDelegate?.cacheMissDidOccur(cacheKey: cacheKey)
            return nil
        }
        
        // Check TTL if enabled
        if let ttl = configuration.ttl, let timestamp = timestamps[cacheKey] {
            let now = TimeAmount.now
            if now - timestamp > ttl {
                logger.log(level: .info, message: "Connection expired for cacheKey: \(cacheKey)")
                cacheTTLExpirationsCounter.increment()
                metricsDelegate?.connectionDidExpire(cacheKey: cacheKey)
                connections[cacheKey] = nil
                removeFromLRU(cacheKey)
                timestamps[cacheKey] = nil
                cachedConnectionsGauge.record(connections.count)
                do {
                    try await connection.shutdown()
                } catch {
                    logger.log(level: .error, message: "Failed to shutdown expired connection \(error)")
                }
                
                // Notify delegate of metrics update
                metricsDelegate?.cacheMetricsDidUpdate(
                    cachedConnections: connections.count,
                    maxConnections: configuration.maxConnections,
                    lruEnabled: configuration.enableLRU,
                    ttlEnabled: configuration.ttl != nil
                )
                
                await onConnectionCountChanged?(connections.count)
                return nil
            }
        }
        
        // Update LRU order if enabled
        if configuration.enableLRU {
            updateLRU(cacheKey)
        }
        
        logger.log(level: .debug, message: "Found connection for cacheKey: \(cacheKey)")
        cacheHitsCounter.increment()
        metricsDelegate?.cacheHitDidOccur(cacheKey: cacheKey)
        return connection
    }
    
    /// Removes a connection from the cache by its cache key.
    ///
    /// The connection will be automatically shut down before being removed from the cache.
    /// If no connection exists with the specified cache key, this method does nothing.
    ///
    /// - Parameter cacheKey: The unique key used to identify the connection to remove.
    /// - Throws: An error if the connection cannot be shut down properly.
    ///
    /// ## Example
    /// ```swift
    /// do {
    ///     try await cache.removeConnection("api-server")
    ///     print("Connection removed successfully")
    /// } catch {
    ///     print("Failed to remove connection: \(error)")
    /// }
    /// ```
    func removeConnection(_ cacheKey: String) async throws {
        if let foundConnection = connections[cacheKey] {
            connections[cacheKey] = nil
            removeFromLRU(cacheKey)
            timestamps[cacheKey] = nil
            
            // Update Swift Metrics
            cachedConnectionsGauge.record(connections.count)
            
            await onConnectionCountChanged?(connections.count)
            try await foundConnection.shutdown()
            
            logger.log(level: .info, message: "Removed connection for cacheKey: \(cacheKey)")
        } else {
            logger.log(level: .info, message: "No connection found for cacheKey: \(cacheKey)")
        }
    }
    
    /// Removes all connections from the cache.
    ///
    /// All connections will be automatically shut down before being removed from the cache.
    /// This method is typically called during application shutdown to ensure proper cleanup.
    ///
    /// - Throws: An error if any connection cannot be shut down properly.
    ///
    /// ## Example
    /// ```swift
    /// do {
    ///     try await cache.removeAllConnection()
    ///     print("All connections removed successfully")
    /// } catch {
    ///     print("Failed to remove all connections: \(error)")
    /// }
    /// ```
    func removeAllConnection() async throws {
        guard !isRemovingAllConnections else { return }
        isRemovingAllConnections = true
        defer { isRemovingAllConnections = false }

        let connectionsToClose = Array(connections.values)
        
        connections.removeAll()
        connectionOrder.removeAll()
        connectionOrderHead = 0
        currentGenerationByKey.removeAll()
        timestamps.removeAll()
        
        cachedConnectionsGauge.record(0)
        await onConnectionCountChanged?(0)

        var firstError: Error?
        for connection in connectionsToClose {
            do {
                try await connection.shutdown()
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }
    
    /// Fetches all connections currently in the cache.
    ///
    /// - Returns: An array containing all cached connections.
    ///
    /// ## Example
    /// ```swift
    /// let allConnections = await cache.fetchAllConnections()
    /// print("Total connections: \(allConnections.count)")
    /// 
    /// for connection in allConnections {
    ///     let config = await connection.config
    ///     print("Connection to \(config.host):\(config.port)")
    /// }
    /// ```
    func fetchAllConnections() -> [ChildChannelService<Inbound, Outbound>] {
        return Array(connections.values)
    }
    
    /// Returns current cache metrics for consumer logging/processing
    public func getCurrentMetrics() -> (cachedConnections: Int, maxConnections: Int, lruEnabled: Bool, ttlEnabled: Bool) {
        return (
            cachedConnections: connections.count,
            maxConnections: configuration.maxConnections,
            lruEnabled: configuration.enableLRU,
            ttlEnabled: configuration.ttl != nil
        )
    }
    
    /// Returns formatted cache metrics string for consumer logging
    public func getFormattedMetrics() -> String {
        return """
        Connection Cache Metrics:
        - Cached Connections: \(connections.count)
        - Max Connections: \(configuration.maxConnections)
        - LRU Enabled: \(configuration.enableLRU)
        - TTL Enabled: \(configuration.ttl != nil)
        """
    }
    
    /// Cleans up expired connections based on TTL.
    ///
    /// This method should be called periodically to remove expired connections.
    /// It's automatically called when finding connections, but can also be called
    /// manually for bulk cleanup.
    func cleanupExpiredConnections() async {
        guard let ttl = configuration.ttl else { return }
        
        let now = TimeAmount.now
        let expiredKeys = timestamps.compactMap { key, timestamp in
            (now - timestamp) > ttl ? key : nil
        }
        
        for key in expiredKeys {
            if let connection = connections[key] {
                connections[key] = nil
                removeFromLRU(key)
                timestamps[key] = nil
                try? await connection.shutdown()
                logger.log(level: .info, message: "Cleaned up expired connection for cacheKey: \(key)")
            }
        }
        
        // Notify connection manager about expired connections being removed
        if !expiredKeys.isEmpty {
            cachedConnectionsGauge.record(connections.count)
            await onConnectionCountChanged?(connections.count)
        }
    }
    
    // MARK: - Private LRU Methods
    
    /// Adds a key to the LRU order.
    private func addToLRU(_ key: String) {
        orderGeneration &+= 1
        currentGenerationByKey[key] = orderGeneration
        connectionOrder.append(OrderEntry(key: key, generation: orderGeneration))
    }
    
    /// Updates a key's position in the LRU order (moves to end).
    private func updateLRU(_ key: String) {
        guard configuration.enableLRU else { return }
        addToLRU(key)
    }
    
    /// Removes a key from the LRU order.
    private func removeFromLRU(_ key: String) {
        currentGenerationByKey[key] = nil
    }
    
    /// Evicts the least recently used connection.
    private func evictOldestConnection() -> ChildChannelService<Inbound, Outbound>? {
        while connectionOrderHead < connectionOrder.count {
            let entry = connectionOrder[connectionOrderHead]
            connectionOrderHead += 1

            guard currentGenerationByKey[entry.key] == entry.generation else {
                continue
            }

            currentGenerationByKey[entry.key] = nil
            let connection = connections.removeValue(forKey: entry.key)
            timestamps[entry.key] = nil

            cacheEvictionsCounter.increment()
            cachedConnectionsGauge.record(connections.count)
            metricsDelegate?.connectionDidEvict(cacheKey: entry.key)
            metricsDelegate?.cacheMetricsDidUpdate(
                cachedConnections: connections.count,
                maxConnections: configuration.maxConnections,
                lruEnabled: configuration.enableLRU,
                ttlEnabled: configuration.ttl != nil
            )

            compactConnectionOrderIfNeeded()
            logger.log(level: .info, message: "Evicted oldest connection for cacheKey: \(entry.key)")
            return connection
        }

        compactConnectionOrderIfNeeded()
        return nil
    }

    private func compactConnectionOrderIfNeeded() {
        guard
            connectionOrderHead >= 256,
            connectionOrderHead * 2 >= connectionOrder.count
        else {
            return
        }
        connectionOrder.removeFirst(connectionOrderHead)
        connectionOrderHead = 0
    }
}

// MARK: - TimeAmount Extension for TTL Support

extension TimeAmount {
    /// Monotonic uptime used for elapsed-time calculations.
    static var now: TimeAmount {
        .nanoseconds(Int64(clamping: NIODeadline.now().uptimeNanoseconds))
    }
    
    /// Creates a TimeAmount from milliseconds.
    static func milliseconds(_ value: Int) -> TimeAmount {
        return .nanoseconds(Int64(value) * 1_000_000)
    }
}
