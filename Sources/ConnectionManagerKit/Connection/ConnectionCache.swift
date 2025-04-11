//
//  ConnectionCache.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/27/24.
//

actor ConnectionCache<Inbound: Sendable, Outbound: Sendable> {
    
    private var connections: [String: ChildChannelService<Inbound, Outbound>] = [:]
    
    var isEmpty: Bool {
        return connections.isEmpty
    }
    
    var count: Int {
        return connections.count
    }
    
    // Cache a new connection
    func cacheConnection(_ connection: ChildChannelService<Inbound, Outbound>, for cacheKey: String) {
        connections[cacheKey] = connection
        print("Cached connection for cacheKey: \(cacheKey)")
    }
    
    // Update an existing connection
    func updateConnection(_ connection: ChildChannelService<Inbound, Outbound>, for cacheKey: String) {
        if connections[cacheKey] != nil {
            connections[cacheKey] = connection
            print("Updated connection for cacheKey: \(cacheKey)")
        } else {
            print("No existing connection found for cacheKey: \(cacheKey). Caching new connection instead.")
            cacheConnection(connection, for: cacheKey)
        }
    }
    
    // Find a connection by cacheKey
    func findConnection(cacheKey: String) -> ChildChannelService<Inbound, Outbound>? {
        if let connection = connections[cacheKey] {
            print("Found connection for cacheKey: \(cacheKey)")
            return connection
        } else {
            print("No connection found for cacheKey: \(cacheKey)")
            return nil
        }
    }
    
    // Remove a connection by cacheKey
    func removeConnection(_ cacheKey: String) async throws {
        if let foundConnection = connections[cacheKey] {
            try await foundConnection.shutdown()
            connections[cacheKey] = nil
            print("Removed connection for cacheKey: \(cacheKey)")
        } else {
            print("No connection found for cacheKey: \(cacheKey)")
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
