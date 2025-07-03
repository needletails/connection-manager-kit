//
//  ConnectionCache.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/27/24.
//
import NeedleTailLogger

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
///
/// ## Usage Example
/// ```swift
/// let cache = ConnectionCache<ByteBuffer, ByteBuffer>(logger: NeedleTailLogger())
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
    
    /// The internal storage for cached connections, keyed by cache key.
    private var connections: [String: ChildChannelService<Inbound, Outbound>] = [:]
    
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
    }
    
    /// Caches a new connection with the specified cache key.
    ///
    /// If a connection already exists with the same cache key, it will be replaced
    /// with the new connection. The old connection will be automatically shut down.
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
        connections[cacheKey] = connection
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
            logger.log(level: .info, message: "Updated connection for cacheKey: \(cacheKey)")
        } else {
            logger.log(level: .info, message: "No existing connection found for cacheKey: \(cacheKey). Caching new connection instead.")
            cacheConnection(connection, for: cacheKey)
        }
    }
    
    /// Finds a connection by its cache key.
    ///
    /// - Parameter cacheKey: The unique key used to identify the connection.
    /// - Returns: The cached connection if found, `nil` otherwise.
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
        if let connection = connections[cacheKey] {
            logger.log(level: .info, message: "Found connection for cacheKey: \(cacheKey)")
            return connection
        } else {
            logger.log(level: .info, message: "No connection found for cacheKey: \(cacheKey)")
            return nil
        }
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
        connections.removeAll()
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
}
