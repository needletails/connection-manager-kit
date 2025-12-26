//
//  ConnectionListener.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/28/24.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//  This file is part of the ConnectionManagerKit Project

import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import ServiceLifecycle
import NeedleTailLogger
import Logging
import Metrics

/// Configuration for listener performance and behavior optimization.
public struct ListenerConfiguration: Sendable {
    /// Maximum number of concurrent connections to accept.
    public let maxConcurrentConnections: Int
    /// Connection accept timeout.
    public let acceptTimeout: TimeAmount
    /// Whether to enable connection monitoring.
    public let enableConnectionMonitoring: Bool
    /// Whether to enable automatic recovery on errors.
    public let enableAutoRecovery: Bool
    /// Maximum number of recovery attempts.
    public let maxRecoveryAttempts: Int
    /// Recovery delay between attempts.
    public let recoveryDelay: TimeAmount
    
    public init(
        maxConcurrentConnections: Int = 1000,
        acceptTimeout: TimeAmount = .seconds(30),
        enableConnectionMonitoring: Bool = true,
        enableAutoRecovery: Bool = true,
        maxRecoveryAttempts: Int = 3,
        recoveryDelay: TimeAmount = .seconds(5)
    ) {
        self.maxConcurrentConnections = maxConcurrentConnections
        self.acceptTimeout = acceptTimeout
        self.enableConnectionMonitoring = enableConnectionMonitoring
        self.enableAutoRecovery = enableAutoRecovery
        self.maxRecoveryAttempts = maxRecoveryAttempts
        self.recoveryDelay = recoveryDelay
    }
}

/// Performance metrics for the listener.
public struct ListenerMetrics: Sendable {
    /// Number of active connections.
    public var activeConnections: Int
    /// Total connections accepted since start.
    public var totalConnectionsAccepted: Int
    /// Total connections closed since start.
    public var totalConnectionsClosed: Int
    /// Current accept rate (connections per second).
    public var acceptRate: Double
    /// Average connection duration.
    public var averageConnectionDuration: TimeAmount
    /// Number of recovery attempts.
    public var recoveryAttempts: Int
    /// Number of connection errors.
    public var connectionErrors: Int
    
    public init(
        activeConnections: Int = 0,
        totalConnectionsAccepted: Int = 0,
        totalConnectionsClosed: Int = 0,
        acceptRate: Double = 0.0,
        averageConnectionDuration: TimeAmount = .seconds(0),
        recoveryAttempts: Int = 0,
        connectionErrors: Int = 0
    ) {
        self.activeConnections = activeConnections
        self.totalConnectionsAccepted = totalConnectionsAccepted
        self.totalConnectionsClosed = totalConnectionsClosed
        self.acceptRate = acceptRate
        self.averageConnectionDuration = averageConnectionDuration
        self.recoveryAttempts = recoveryAttempts
        self.connectionErrors = connectionErrors
    }
}

/// Delegate protocol for receiving metrics updates from ConnectionListener
public protocol ListenerMetricsDelegate: AnyObject, Sendable {
    /// Called when listener metrics are updated
    /// - Parameter metrics: The updated metrics
    func listenerMetricsDidUpdate(_ metrics: ListenerMetrics)
    
    /// Called when a connection is accepted
    /// - Parameters:
    ///   - connectionId: The unique identifier of the accepted connection
    ///   - activeConnections: The current number of active connections
    func connectionDidAccept(connectionId: String, activeConnections: Int)
    
    /// Called when a connection is closed
    /// - Parameters:
    ///   - connectionId: The unique identifier of the closed connection
    ///   - activeConnections: The current number of active connections
    ///   - duration: The duration the connection was active
    func connectionDidClose(connectionId: String, activeConnections: Int, duration: TimeAmount)
    
    /// Called when recovery is attempted
    /// - Parameters:
    ///   - attemptNumber: The current recovery attempt number
    ///   - maxAttempts: The maximum number of recovery attempts
    func recoveryDidAttempt(attemptNumber: Int, maxAttempts: Int)
}

/// Default implementation for optional delegate methods
public extension ListenerMetricsDelegate {
    func connectionDidAccept(connectionId: String, activeConnections: Int) {}
    func connectionDidClose(connectionId: String, activeConnections: Int, duration: TimeAmount) {}
    func recoveryDidAttempt(attemptNumber: Int, maxAttempts: Int) {}
}

public actor ConnectionListener<Inbound: Sendable, Outbound: Sendable>: ServiceListenerDelegate {
    
    public var serviceGroup: ServiceGroup?
    public var delegate: ConnectionDelegate?
    nonisolated(unsafe) public var listenerDelegate: ListenerDelegate?
    public weak var metricsDelegate: ListenerMetricsDelegate?
    var serverService: ServerService<Inbound, Outbound>?
    let logger: NeedleTailLogger
    
    // Optimization: Add configuration and metrics
    private let configuration: ListenerConfiguration
    private var metrics: ListenerMetrics
    private var isShuttingDown = false
    private var recoveryTask: Task<Void, Never>?
    
    // Performance monitoring
    private var connectionStartTimes: [String: TimeAmount] = [:]
    private var acceptRateWindow: [TimeAmount] = []
    private let acceptRateWindowSize = 10
    
    // Swift Metrics
    private let activeConnectionsGauge = Gauge(label: "connection_listener_active_connections", dimensions: [("component", "listener")])
    private let totalConnectionsAcceptedCounter = Counter(label: "connection_listener_total_connections_accepted", dimensions: [("component", "listener")])
    private let totalConnectionsClosedCounter = Counter(label: "connection_listener_total_connections_closed", dimensions: [("component", "listener")])
    private let acceptRateGauge = Gauge(label: "connection_listener_accept_rate", dimensions: [("component", "listener")])
    private let averageConnectionDurationGauge = Gauge(label: "connection_listener_average_connection_duration_ns", dimensions: [("component", "listener")])
    private let recoveryAttemptsCounter = Counter(label: "connection_listener_recovery_attempts", dimensions: [("component", "listener")])
    private let connectionErrorsCounter = Counter(label: "connection_listener_connection_errors", dimensions: [("component", "listener")])
    
    nonisolated func retrieveSSLHandler() -> NIOSSL.NIOSSLServerHandler? {
        listenerDelegate?.retrieveSSLHandler()
    }
    
    nonisolated func retrieveChannelHandlers() -> [ChannelHandler] {
        guard let listenerDelegate else { return [] }
        return listenerDelegate.retrieveChannelHandlers()
    }
    
    public func setContextDelegate(_ delegate: ChannelContextDelegate, key: String) async {
        await serverService?.setContextDelegate(delegate, key: key)
    }
    
    public init(
        logger: NeedleTailLogger = NeedleTailLogger("[Connection Listener]"),
        configuration: ListenerConfiguration = ListenerConfiguration()
    ) {
        self.logger = logger
        self.configuration = configuration
        self.metrics = ListenerMetrics()
    }
    
    /// Convenience initializer for ByteBuffer types (most common use case)
    public static func byteBuffer(
        logger: NeedleTailLogger = NeedleTailLogger("[Connection Listener]"),
        configuration: ListenerConfiguration = ListenerConfiguration()
    ) -> ConnectionListener<ByteBuffer, ByteBuffer> {
        return ConnectionListener<ByteBuffer, ByteBuffer>(logger: logger, configuration: configuration)
    }
    
    /// Get current listener metrics.
    public func getMetrics() -> ListenerMetrics {
        return metrics
    }
    
    /// Reset metrics counters.
    public func resetMetrics() {
        metrics = ListenerMetrics()
        connectionStartTimes.removeAll()
        acceptRateWindow.removeAll()
    }
    
    public func resolveAddress(_ configuration: Configuration) throws -> Configuration {
        var configuration = configuration
        let address: SocketAddress
        if let host = configuration.host {
            address = try SocketAddress
                .makeAddressResolvingHost(host, port: configuration.port)
        } else {
            var addr = sockaddr_in()
            addr.sin_port = in_port_t(configuration.port).bigEndian
            address = SocketAddress(addr, host: "*")
        }
        
        let origin: String = {
            let s = configuration.origin ?? ""
            if !s.isEmpty { return s }
            if let s = configuration.host { return s }
            return "unknown-origin"
        }()
        configuration.origin = origin
        configuration.address = address
        return configuration
    }
    
    public func listen(
        address: SocketAddress,
        configuration: Configuration,
        delegate: ConnectionDelegate?,
        listenerDelegate: ListenerDelegate?
    ) async throws {
        self.delegate = delegate
        self.listenerDelegate = listenerDelegate
        
        // Reset metrics on new listen
        resetMetrics()
        
        let serverService = ServerService<Inbound, Outbound>(
            address: address,
            configuration: configuration,
            logger: logger,
            delegate: self,
            listenerDelegate: listenerDelegate,
            serviceListenerDelegate: self)
        
        try await runListener(serverService: serverService)
    }
    
    public func listen(
        address: SocketAddress,
        websocketConfiguration: WebSocketUpgradeConfig = .init(),
        configuration: Configuration,
        delegate: ConnectionDelegate?,
        listenerDelegate: ListenerDelegate?,
    ) async throws {
        self.delegate = delegate
        self.listenerDelegate = listenerDelegate
        
        // Reset metrics on new listen
        resetMetrics()
        
        let serverService = ServerService<Inbound, Outbound>(
            websocketConfiguration: websocketConfiguration,
            address: address,
            configuration: configuration,
            logger: logger,
            delegate: self,
            listenerDelegate: listenerDelegate,
            serviceListenerDelegate: self)
        try await runListener(serverService: serverService)
    }
    
    public func unmaskedData(_ frame: WebSocketFrame) -> ByteBuffer {
        var frameData = frame.data
        if let maskingKey = frame.maskKey {
            frameData.webSocketUnmask(maskingKey)
        }
        return frameData
    }
    
    private func runListener(serverService: ServerService<Inbound, Outbound>) async throws {
        self.serverService = serverService
        serviceGroup = ServiceGroup(
            services: [serverService],
            logger: .init(label: "[Listener Service Group]"))
        
        // Start monitoring task if enabled
        if self.configuration.enableConnectionMonitoring {
            startMonitoringTask()
        }
        
        // Start with auto-recovery if enabled
        if self.configuration.enableAutoRecovery {
            startRecoveryTask()
        }
        
        try await serverService.run()
    }
    
    public func shutdownChildChannel(id: String) async {
        await serverService?.shutdownChildChannel(id: id)
        updateMetricsOnConnectionClose(id: id)
    }
    
    public func shutdown() async throws {
        isShuttingDown = true
        
        // Cancel monitoring and recovery tasks
        recoveryTask?.cancel()
        
        try await serverService?.shutdown()
        
        logger.log(level: .info, message: "Listener shutdown complete. Final metrics: \(metrics)")
    }
    
    // MARK: - Performance Monitoring
    
    private func startMonitoringTask() {
        Task { [weak self] in
            guard let self else { return }
            while true {
                let isShuttingDown = await self.isShuttingDown
                if isShuttingDown { break }
                
                await self.updateAcceptRate()
                // Let consumer decide if/when to log metrics
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
    
    private func startRecoveryTask() {
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            var recoveryAttempts = 0
            
            while true {
                let isShuttingDown = await self.isShuttingDown
                let maxAttempts = self.configuration.maxRecoveryAttempts
                
                if isShuttingDown || recoveryAttempts >= maxAttempts { break }
                
                // Monitor for potential issues and attempt recovery
                if await self.shouldAttemptRecovery() {
                    recoveryAttempts += 1
                    
                    // Update Swift Metrics
                    self.recoveryAttemptsCounter.increment()
                    
                    // Notify delegate
                    await self.metricsDelegate?.recoveryDidAttempt(attemptNumber: recoveryAttempts, maxAttempts: maxAttempts)
                    await self.metricsDelegate?.listenerMetricsDidUpdate(await self.metrics)
                    
                    self.logger.log(level: .warning, message: "Attempting listener recovery (attempt \(recoveryAttempts)/\(maxAttempts))")
                    
                    do {
                        try await self.performRecovery()
                        self.logger.log(level: .info, message: "Listener recovery successful")
                        break
                    } catch {
                        self.logger.log(level: .error, message: "Listener recovery failed: \(error)")
                        
                        if recoveryAttempts < maxAttempts {
                            let recoveryDelay = self.configuration.recoveryDelay
                            try? await Task.sleep(for: Duration.nanoseconds(recoveryDelay.nanoseconds))
                        }
                    }
                } else {
                    // If no recovery is needed, just wait and continue monitoring
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            
            // Log when recovery task exits
            let finalIsShuttingDown = await self.isShuttingDown
            if finalIsShuttingDown {
                self.logger.log(level: .debug, message: "Recovery task stopped due to shutdown")
            } else {
                self.logger.log(level: .debug, message: "Recovery task stopped after \(recoveryAttempts) attempts")
            }
        }
    }
    
    private func shouldAttemptRecovery() async -> Bool {
        // Check if recovery is needed based on metrics
        let currentMetrics = metrics
        
        // Recovery triggers:
        // 1. High error rate
        // 2. No connections being accepted
        // 3. Memory pressure (if we had memory monitoring)
        
        return currentMetrics.activeConnections == 0 && 
               currentMetrics.totalConnectionsAccepted > 0 &&
               currentMetrics.recoveryAttempts < configuration.maxRecoveryAttempts
    }
    
    private func performRecovery() async throws {
        // Recovery logic would be implemented here based on specific requirements
        logger.log(level: .info, message: "Performing listener recovery")
    }
    
    private func updateMetricsOnConnectionAccept(id: String) {
        let now = TimeAmount.now
        connectionStartTimes[id] = now
        metrics.totalConnectionsAccepted += 1
        metrics.activeConnections += 1
        
        // Update Swift Metrics
        totalConnectionsAcceptedCounter.increment()
        activeConnectionsGauge.record(metrics.activeConnections)
        
        // Update accept rate window
        acceptRateWindow.append(now)
        if acceptRateWindow.count > acceptRateWindowSize {
            acceptRateWindow.removeFirst()
        }
        
        // Notify delegate
        metricsDelegate?.connectionDidAccept(connectionId: id, activeConnections: metrics.activeConnections)
        metricsDelegate?.listenerMetricsDidUpdate(metrics)
    }
    
    private func updateMetricsOnConnectionClose(id: String) {
        metrics.totalConnectionsClosed += 1
        metrics.activeConnections = max(0, metrics.activeConnections - 1)
        
        // Update Swift Metrics
        totalConnectionsClosedCounter.increment()
        activeConnectionsGauge.record(metrics.activeConnections)
        
        // Calculate connection duration if we have start time
        var duration: TimeAmount = .seconds(0)
        if let startTime = connectionStartTimes.removeValue(forKey: id) {
            duration = TimeAmount.now - startTime
            // Update average duration (simplified calculation)
            let currentAvg = metrics.averageConnectionDuration
            let totalConnections = metrics.totalConnectionsClosed
            metrics.averageConnectionDuration = .nanoseconds(
                (currentAvg.nanoseconds * Int64(totalConnections - 1) + duration.nanoseconds) / Int64(totalConnections)
            )
            
            // Update Swift Metrics for average duration
            averageConnectionDurationGauge.record(Double(metrics.averageConnectionDuration.nanoseconds))
        }
        
        // Notify delegate
        metricsDelegate?.connectionDidClose(connectionId: id, activeConnections: metrics.activeConnections, duration: duration)
        metricsDelegate?.listenerMetricsDidUpdate(metrics)
    }
    
    private func updateAcceptRate() {
        guard acceptRateWindow.count >= 2 else { return }
        
        let windowStart = acceptRateWindow.first!
        let windowEnd = acceptRateWindow.last!
        let windowDuration = windowEnd - windowStart
        
        if windowDuration.nanoseconds > 0 {
            let rate = Double(acceptRateWindow.count) / (Double(windowDuration.nanoseconds) / 1_000_000_000.0)
            metrics.acceptRate = rate
            
            // Update Swift Metrics
            acceptRateGauge.record(metrics.acceptRate)
        }
    }
    
    /// Updates metrics when a connection error occurs
    private func updateMetricsOnConnectionError() {
        metrics.connectionErrors += 1
        
        // Update Swift Metrics
        connectionErrorsCounter.increment()
        
        // Notify delegate
        metricsDelegate?.listenerMetricsDidUpdate(metrics)
    }
    
    /// Returns current metrics for consumer logging/processing
    public func getCurrentMetrics() -> ListenerMetrics {
        return metrics
    }
    
    /// Returns formatted metrics string for consumer logging
    public func getFormattedMetrics() -> String {
        return """
        Listener Metrics:
        - Active Connections: \(metrics.activeConnections)
        - Total Accepted: \(metrics.totalConnectionsAccepted)
        - Total Closed: \(metrics.totalConnectionsClosed)
        - Accept Rate: \(String(format: "%.2f", metrics.acceptRate)) conn/s
        - Avg Duration: \(metrics.averageConnectionDuration.nanoseconds / 1_000_000_000)s
        - Recovery Attempts: \(metrics.recoveryAttempts)
        - Connection Errors: \(metrics.connectionErrors)
        """
    }
    
    /// Reports a connection error from the server service
    public func reportConnectionError() {
        updateMetricsOnConnectionError()
    }
}


extension ConnectionListener: ChildChannelServiceDelegate {
    func initializedChildChannel<OutboundType, InboundType>(_ context: ChannelContext<InboundType, OutboundType>) async where OutboundType : Sendable, InboundType : Sendable {
        updateMetricsOnConnectionAccept(id: context.id)
        await delegate?.initializedChildChannel(context)
    }
}

extension NIOSSLServerHandler: @retroactive @unchecked Sendable {}

