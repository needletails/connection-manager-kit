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
        self.maxConnections = maxConnections
        self.ttl = ttl
        self.enableLRU = enableLRU
    }
}

/// Configuration for connection pooling behavior.
public struct ConnectionPoolConfiguration: Sendable {
    /// Minimum number of connections to maintain in the pool.
    public let minConnections: Int
    /// Maximum number of connections in the pool.
    public let maxConnections: Int
    /// Timeout for acquiring a connection from the pool.
    public let acquireTimeout: TimeAmount
    /// Maximum time a connection can remain idle before being closed.
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

/// A connection pool entry that tracks connection state and usage.
private struct PoolEntry<Inbound: Sendable, Outbound: Sendable>: Sendable {
    let connection: ChildChannelService<Inbound, Outbound>
    var lastUsed: TimeAmount
    var isInUse: Bool
    
    init(connection: ChildChannelService<Inbound, Outbound>) {
        self.connection = connection
        self.lastUsed = TimeAmount.now
        self.isInUse = false
    }
    
    func markAsUsed() -> PoolEntry<Inbound, Outbound> {
        var entry = self
        entry.lastUsed = TimeAmount.now
        entry.isInUse = true
        return entry
    }
    
    func markAsAvailable() -> PoolEntry<Inbound, Outbound> {
        var entry = self
        entry.lastUsed = TimeAmount.now
        entry.isInUse = false
        return entry
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
    
    /// LRU tracking for connections (only used when LRU is enabled).
    private var lruOrder: [String] = []
    
    /// Timestamps for TTL tracking (only used when TTL is enabled).
    private var timestamps: [String: TimeAmount] = [:]
    
    /// The metrics delegate for receiving cache updates.
    public weak var metricsDelegate: ConnectionCacheMetricsDelegate?
    
    /// Callback to notify when connections are removed (for metrics tracking)
    private var onConnectionRemoved: (() -> Void)?
    
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
    
    /// Sets a callback to be called when connections are removed (for metrics tracking)
    /// - Parameter callback: The closure to call when connections are removed
    func setConnectionRemovedCallback(_ callback: @escaping () -> Void) {
        self.onConnectionRemoved = callback
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
    func cacheConnection(_ connection: ChildChannelService<Inbound, Outbound>, for cacheKey: String) {
        // Check if we need to evict due to capacity
        if connections.count >= configuration.maxConnections {
            evictLRUConnection()
        }
        
        // Remove existing connection if it exists
        if let existingConnection = connections[cacheKey] {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await existingConnection.shutdown()
                } catch {
                    self.logger.log(level: .error, message: "Failed to shutdown existing connection \(error)")
                }
            }
            removeFromLRU(cacheKey)
            
            // Notify connection manager about connection replacement
            onConnectionRemoved?()
        }
        
        // Add new connection
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
    func updateConnection(_ connection: ChildChannelService<Inbound, Outbound>, for cacheKey: String) {
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
            cacheConnection(connection, for: cacheKey)
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
    func findConnection(cacheKey: String) -> ChildChannelService<Inbound, Outbound>? {
        // Check if connection exists
        guard let connection = connections[cacheKey] else {
            logger.log(level: .info, message: "No connection found for cacheKey: \(cacheKey)")
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
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await connection.shutdown()
                    } catch {
                        self.logger.log(level: .error, message: "Failed to shutdown existing connection \(error)")
                    }
                }
                connections[cacheKey] = nil
                removeFromLRU(cacheKey)
                timestamps[cacheKey] = nil
                cachedConnectionsGauge.record(connections.count)
                
                // Notify delegate of metrics update
                metricsDelegate?.cacheMetricsDidUpdate(
                    cachedConnections: connections.count,
                    maxConnections: configuration.maxConnections,
                    lruEnabled: configuration.enableLRU,
                    ttlEnabled: configuration.ttl != nil
                )
                
                // Notify connection manager about expired connection removal
                onConnectionRemoved?()
                return nil
            }
        }
        
        // Update LRU order if enabled
        if configuration.enableLRU {
            updateLRU(cacheKey)
        }
        
        logger.log(level: .info, message: "Found connection for cacheKey: \(cacheKey)")
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
            try await foundConnection.shutdown()
            connections[cacheKey] = nil
            removeFromLRU(cacheKey)
            timestamps[cacheKey] = nil
            
            // Update Swift Metrics
            cachedConnectionsGauge.record(connections.count)
            
            // Notify connection manager about connection removal
            onConnectionRemoved?()
            
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
        // Shutdown all connections
        for connection in connections.values {
            try await connection.shutdown()
        }
        
        connections.removeAll()
        lruOrder.removeAll()
        timestamps.removeAll()
        
        // Notify connection manager about all connections being removed
        onConnectionRemoved?()
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
                try? await connection.shutdown()
                connections[key] = nil
                removeFromLRU(key)
                timestamps[key] = nil
                logger.log(level: .info, message: "Cleaned up expired connection for cacheKey: \(key)")
            }
        }
        
        // Notify connection manager about expired connections being removed
        if !expiredKeys.isEmpty {
            onConnectionRemoved?()
        }
    }
    
    // MARK: - Private LRU Methods
    
    /// Adds a key to the LRU order.
    private func addToLRU(_ key: String) {
        guard configuration.enableLRU else { return }
        lruOrder.append(key)
    }
    
    /// Updates a key's position in the LRU order (moves to end).
    private func updateLRU(_ key: String) {
        guard configuration.enableLRU else { return }
        removeFromLRU(key)
        lruOrder.append(key)
    }
    
    /// Removes a key from the LRU order.
    private func removeFromLRU(_ key: String) {
        guard configuration.enableLRU else { return }
        lruOrder.removeAll { $0 == key }
    }
    
    /// Evicts the least recently used connection.
    private func evictLRUConnection() {
        guard configuration.enableLRU, let oldestKey = lruOrder.first else { return }
        
        if let connection = connections[oldestKey] {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await connection.shutdown()
                } catch {
                    self.logger.log(level: .error, message: "Failed to shutdown existing connection \(error)")
                }
            }
            connections[oldestKey] = nil
            removeFromLRU(oldestKey)
            timestamps[oldestKey] = nil
            
            // Update Swift Metrics
            cacheEvictionsCounter.increment()
            cachedConnectionsGauge.record(connections.count)
            
            // Notify delegate
            metricsDelegate?.connectionDidEvict(cacheKey: oldestKey)
            metricsDelegate?.cacheMetricsDidUpdate(
                cachedConnections: connections.count,
                maxConnections: configuration.maxConnections,
                lruEnabled: configuration.enableLRU,
                ttlEnabled: configuration.ttl != nil
            )
            
            // Notify connection manager about connection removal
            onConnectionRemoved?()
            
            logger.log(level: .info, message: "Evicted LRU connection for cacheKey: \(oldestKey)")
        }
    }
    
    // MARK: - Connection Pooling Methods
    
    /// Acquires a connection from the pool for a specific cache key.
    ///
    /// This method attempts to find an available connection in the pool. If no connection
    /// is available and the pool hasn't reached its maximum size, it will create a new one.
    ///
    /// - Parameters:
    ///   - cacheKey: The unique key used to identify the connection.
    ///   - poolConfig: The connection pool configuration.
    ///   - connectionFactory: A closure that creates a new connection if needed.
    /// - Returns: A connection from the pool, or `nil` if acquisition times out.
    /// - Throws: An error if the connection cannot be acquired or created.
    func acquireConnection(
        for cacheKey: String,
        poolConfig: ConnectionPoolConfiguration,
        connectionFactory: @escaping () async throws -> ChildChannelService<Inbound, Outbound>
    ) async throws -> ChildChannelService<Inbound, Outbound>? {
        // First, try to find an existing available connection
        if let existingConnection = connections[cacheKey] {
            return existingConnection
        }
        
        // If no connection exists and we haven't reached the pool limit, create a new one
        if connections.count < poolConfig.maxConnections {
            let newConnection = try await connectionFactory()
            connections[cacheKey] = newConnection
            return newConnection
        }
        
        // Pool is full, wait for a connection to become available
        let startTime = TimeAmount.now
        while TimeAmount.now - startTime < poolConfig.acquireTimeout {
            // Check if any connection has become available
            if let availableConnection = connections[cacheKey] {
                return availableConnection
            }
            
            // Wait a bit before checking again
            try await Task.sleep(for: Duration.nanoseconds(TimeAmount.milliseconds(100).nanoseconds))
        }
        
        // Timeout reached
        return nil
    }
    
    /// Returns a connection to the pool.
    ///
    /// This method marks a connection as available for reuse. If the connection
    /// has exceeded its idle time, it will be removed from the pool.
    ///
    /// - Parameters:
    ///   - cacheKey: The unique key used to identify the connection.
    ///   - poolConfig: The connection pool configuration.
    func returnConnection(
        _ cacheKey: String,
        poolConfig: ConnectionPoolConfiguration
    ) async {
        // Check if connection has exceeded idle time
        if let timestamp = timestamps[cacheKey] {
            let now = TimeAmount.now
            if now - timestamp > poolConfig.maxIdleTime {
                // Connection has been idle too long, remove it
                if let connection = connections[cacheKey] {
                    try? await connection.shutdown()
                }
                connections[cacheKey] = nil
                removeFromLRU(cacheKey)
                timestamps[cacheKey] = nil
                
                // Notify connection manager about idle connection removal
                onConnectionRemoved?()
                
                logger.log(level: .info, message: "Removed idle connection for cacheKey: \(cacheKey)")
            }
        }
    }
}

// MARK: - TimeAmount Extension for TTL Support

extension TimeAmount {
    /// The current time as a TimeAmount (approximate).
    static var now: TimeAmount {
        return .nanoseconds(Int64(Date().timeIntervalSince1970 * 1_000_000_000))
    }
    
    /// Creates a TimeAmount from milliseconds.
    static func milliseconds(_ value: Int) -> TimeAmount {
        return .nanoseconds(Int64(value) * 1_000_000)
    }
}
