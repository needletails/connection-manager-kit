//
//  ConnectionCache.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/27/24.
//
import NeedleTailLogger

actor ConnectionCache<Inbound: Sendable, Outbound: Sendable> {
    
    private let logger: NeedleTailLogger
    private var connections: [String: ChildChannelService<Inbound, Outbound>] = [:]
    
    var isEmpty: Bool {
        return connections.isEmpty
    }
    
    var count: Int {
        return connections.count
    }
    
    init(logger: NeedleTailLogger) {
        self.logger = logger
    }
    
    // Cache a new connection
    func cacheConnection(_ connection: ChildChannelService<Inbound, Outbound>, for cacheKey: String) {
        connections[cacheKey] = connection
        logger.log(level: .info, message: "Cached connection for cacheKey: \(cacheKey)")
    }
    
    // Update an existing connection
    func updateConnection(_ connection: ChildChannelService<Inbound, Outbound>, for cacheKey: String) {
        if connections[cacheKey] != nil {
            connections[cacheKey] = connection
            logger.log(level: .info, message: "Updated connection for cacheKey: \(cacheKey)")
        } else {
            logger.log(level: .info, message: "No existing connection found for cacheKey: \(cacheKey). Caching new connection instead.")
            cacheConnection(connection, for: cacheKey)
        }
    }
    
    // Find a connection by cacheKey
    func findConnection(cacheKey: String) -> ChildChannelService<Inbound, Outbound>? {
        if let connection = connections[cacheKey] {
            logger.log(level: .info, message: "Found connection for cacheKey: \(cacheKey)")
            return connection
        } else {
            logger.log(level: .info, message: "No connection found for cacheKey: \(cacheKey)")
            return nil
        }
    }
    
    // Remove a connection by cacheKey
    func removeConnection(_ cacheKey: String) async throws {
        if let foundConnection = connections[cacheKey] {
            try await foundConnection.shutdown()
            connections[cacheKey] = nil
            logger.log(level: .info, message: "Removed connection for cacheKey: \(cacheKey)")
        } else {
            logger.log(level: .info, message: "No connection found for cacheKey: \(cacheKey)")
        }
    }
    
    // Remove all connections
    func removeAllConnection() async throws {
        connections.removeAll()
    }
    
    // Fetch all connections as an array
    func fetchAllConnections() -> [ChildChannelService<Inbound, Outbound>] {
        return Array(connections.values)
    }
}
