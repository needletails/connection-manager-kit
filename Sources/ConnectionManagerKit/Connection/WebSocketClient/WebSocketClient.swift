//
//  WebSocketClient.swift
//  connection-manager-kit
//
//  Created by Cole M on 8/16/25.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//  This file is part of the ConnectionManagerKit Project

import Foundation
#if canImport(Observation) && !os(Linux)
import Observation
#endif
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOHTTP1
#if canImport(Network)
import Network
#endif

/// A main-actor observable that surfaces inbound WebSocket messages and network events.
///
/// Consumers can observe the `messageStream` and `eventStream` to react to frames
/// and channel lifecycle updates. Streams are lazily created and explicitly
/// finished during `WebSocketClient.shutDown()` to avoid resource leaks.
@MainActor
#if canImport(Observation) && !os(Linux)
@Observable
#endif
public final class SocketReceiver: Sendable {
    
    public init() {
        prepareForConnection()
    }

    /// Inbound WebSocket message kinds delivered to `messageStream`.
    public enum WebSocketOpcode: Sendable, Equatable {
        case text(String)
        case binary(Data?)
        case ping(Data?)
        case pong(Data?)
        case continuation
        case connectionClose
    }
    
    /// Channel and network events delivered to `eventStream`.
    public enum WebSocketEvent: Sendable, Equatable {
#if canImport(Network)
        case networkEvent(NetworkEventMonitor.NetworkEvent)
#else
        case networkEvent(NetworkEventMonitor.NIOEvent)
#endif
        case error(Error)
        case channelActive
        case channelInactive
        
        public static func == (
            lhs: WebSocketEvent,
            rhs: WebSocketEvent
        ) -> Bool {
            switch (lhs, rhs) {
            case (.channelActive, .channelActive),
                 (.channelInactive, .channelInactive):
                return true

            case let (.networkEvent(a), .networkEvent(b)):
#if canImport(Network)
                // NIOTS NetworkEvent associated values are not Equatable; compare descriptions.
                return String(describing: a) == String(describing: b)
#else
                return a == b
#endif

            case let (.error(errA), .error(errB)):
                return String(describing: errA) == String(describing: errB)
            default:
                return false
            }
        }
    }
    
    public var webSocketFrame: WebSocketOpcode?
    public var networkEvent: WebSocketEvent?
    public var messageStream: AsyncStream<WebSocketOpcode>?
    public var messageContinuation: AsyncStream<WebSocketOpcode>.Continuation?
    
    public var eventStream: AsyncStream<WebSocketEvent>?
    public var eventContinuation: AsyncStream<WebSocketEvent>.Continuation?
    
    private func makeMessageStream() {
        let pair = AsyncStream<WebSocketOpcode>.makeStream()
        messageStream = pair.stream
        messageContinuation = pair.continuation
    }
    
    private func makeEventStream() {
        let pair = AsyncStream<WebSocketEvent>.makeStream()
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    func prepareForConnection() {
        if messageStream == nil {
            makeMessageStream()
        }
        if eventStream == nil {
            makeEventStream()
        }
    }

    func finishStreams() {
        messageContinuation?.finish()
        eventContinuation?.finish()
        messageContinuation = nil
        eventContinuation = nil
        messageStream = nil
        eventStream = nil
    }

    /// Internal: updates observed state and emits to `messageStream`.
    public func setInboundMessage(_ message: WebSocketOpcode) {
        prepareForConnection()
        webSocketFrame = message
        messageContinuation?.yield(message)
    }
#if canImport(Network)
    /// Internal: updates observed state and emits a Network event to `eventStream`.
    public func setNetworkEvent(_ event: NetworkEventMonitor.NetworkEvent) {
        prepareForConnection()
        self.networkEvent = .networkEvent(event)
        eventContinuation?.yield(.networkEvent(event))
    }
#else
    /// Internal (Linux): updates observed state and emits an NIO event to `eventStream`.
    public func setNIOEvent(_ event: ConnectionManagerKit.NetworkEventMonitor.NIOEvent) {
        prepareForConnection()
        self.networkEvent = .networkEvent(event)
        eventContinuation?.yield(.networkEvent(event))
    }
#endif
    
    /// Internal: emits an error event to `eventStream`.
    public func setError(_ error: Error) {
        prepareForConnection()
        self.networkEvent = .error(error)
        eventContinuation?.yield(.error(error))
    }
    
    /// Internal: emits channel active to `eventStream`.
    public func setChannelActive() {
        prepareForConnection()
        self.networkEvent = .channelActive
        eventContinuation?.yield(.channelActive)
    }
    
    /// Internal: emits channel inactive to `eventStream`.
    public func setChannelInactive() {
        prepareForConnection()
        self.networkEvent = .channelInactive
        eventContinuation?.yield(.channelInactive)
    }
}

private final class WSConnectionDelegate: ConnectionDelegate, @unchecked Sendable {
    private weak var socketReceiver: SocketReceiver?
    private let errorTask = NIOLockedValueBox<Task<Void, Never>?>(nil)
    private let networkEventsTask = NIOLockedValueBox<Task<Void, Never>?>(nil)
    
    init(socketReceiver: SocketReceiver) {
        self.socketReceiver = socketReceiver
    }

    private func replaceTask(
        in box: NIOLockedValueBox<Task<Void, Never>?>,
        with task: Task<Void, Never>
    ) {
        let previous = box.withLockedValue { stored in
            let previous = stored
            stored = task
            return previous
        }
        previous?.cancel()
    }

    func invalidate() {
        let tasks = [errorTask, networkEventsTask].compactMap { box in
            box.withLockedValue { stored in
                defer { stored = nil }
                return stored
            }
        }
        tasks.forEach { $0.cancel() }
    }
    
#if canImport(Network)
    func handleError(_ stream: AsyncStream<NWError>, id: String) {
        let task = Task { [weak self] in
            for await error in stream {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.socketReceiver?.setError(error)
                }
            }
        }
        replaceTask(in: errorTask, with: task)
    }
    
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
        let task = Task { [weak self] in
            for await event in stream {
                await MainActor.run { [weak self] in
                       guard let self else { return }
                       self.socketReceiver?.setNetworkEvent(event)
                }
            }
        }
        replaceTask(in: networkEventsTask, with: task)
    }
#else
    func handleError(_ stream: AsyncStream<IOError>, id: String) {
        let task = Task { [weak self] in
            for await error in stream {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.socketReceiver?.setError(error)
                }
            }
        }
        replaceTask(in: errorTask, with: task)
    }
    
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NIOEvent>, id: String) async {
        let task = Task { [weak self] in
            for await event in stream {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.socketReceiver?.setNIOEvent(event)
                }
            }
        }
        replaceTask(in: networkEventsTask, with: task)
    }
#endif
    
    func initializedChildChannel<Outbound, Inbound>(_ context: ConnectionManagerKit.ChannelContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable {}
}

/// A high-level WebSocket client with automatic reconnection and main-actor event delivery.
///
/// - Thread-safety: `WebSocketClient` is an actor. All state, such as connection maps,
///   is protected by actor isolation.
/// - Events: Inbound frames and lifecycle events are forwarded to the `SocketReceiver`
///   on the main actor.
/// - Shutdown: `shutDown()` gracefully closes connections and finishes streams to
///   prevent leaks.
public actor WebSocketClient {
    
    @MainActor
    public static let shared = WebSocketClient(socketReceiver: .init())
    
    @MainActor
    public let socketReceiver: SocketReceiver
    
    private struct HeartbeatPolicy: Sendable {
        let enabled: Bool
        let interval: TimeInterval?
        let timeout: TimeInterval
    }

    private var nextPingTasks: [String: Task<Void, Never>] = [:]
    private var pongTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var awaitingPongRoutes: Set<String> = []
    private var heartbeatPolicies: [String: HeartbeatPolicy] = [:]
    
    public init(socketReceiver: SocketReceiver) {
        self.socketReceiver = socketReceiver
    }
    
    /// Errors thrown by the WebSocket client API.
    public enum Errors: Error {
        /// The provided URL is not a valid ws/wss URL.
        case invalidURL
        /// No connection exists for the requested route.
        case noConnectionForRoute(String)
        /// The outbound writer for the route is not yet available.
        case writerUnavailable(String)
    }
    
    private struct ConnectionBucket: Sendable {
        let manager: ConnectionManager<WebSocketFrame, WebSocketFrame>
        let contextDelegate: RouteContextDelegate
        let connectionDelegate: WSConnectionDelegate
    }
    private var connections: [String: ConnectionBucket] = [:]
    
    private func isValidWebSocketURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["ws", "wss"].contains(scheme),
              url.host != nil
        else {
            return false
        }
        if let port = url.port, !(1...65535).contains(port) {
            return false
        }
        return true
    }
    
    /// Connect using a WebSocket URL.
    /// - Parameters:
    ///   - url: WebSocket URL (ws:// or wss://). If nil, defaults to ws://localhost:8080/
    ///   - maxReconnectionAttempts: Maximum reconnection attempts per connection.
    ///   - timeout: Connection attempt timeout.
    ///   - tlsPreKeyed: Optional TLS configuration.
    ///   - retryStrategy: Retry policy for reconnection attempts.
    public func connect(
        url: URL? = nil,
        headers: HTTPHeaders = HTTPHeaders(),
        maxReconnectionAttempts: Int = 6,
        timeout: TimeAmount = .seconds(10),
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil,
        retryStrategy: RetryStrategy = .fixed(delay: .seconds(5)),
        autoPingPong: Bool = true,
        autoPingPongInterval: TimeInterval? = 60,
        autoPingTimeout: TimeInterval = 10
    ) async throws {
        let defaultURL = URL(string: "ws://localhost:8080/")
        
        guard
            let url = url ?? defaultURL,
            let scheme = url.scheme,
            let host = url.host
        else {
            throw Errors.invalidURL
        }
        
        if !isValidWebSocketURL(url) {
            throw Errors.invalidURL
        }
        
        let enableTLS = (scheme == "wss")
        let port = url.port ?? (enableTLS ? 443 : 80)
        let route = url.path.isEmpty ? "/" : url.path
        
        try await connect(
            host: host,
            port: port,
            enableTLS: enableTLS,
            route: route,
            headers: headers,
            maxReconnectionAttempts: maxReconnectionAttempts,
            timeout: timeout,
            tlsPreKeyed: tlsPreKeyed,
            retryStrategy: retryStrategy,
            autoPingPong: autoPingPong,
            autoPingPongInterval: autoPingPongInterval,
            autoPingTimeout: autoPingTimeout)
    }
    
    /// Connect using discrete parameters.
    /// - Parameters:
    ///   - host: Server hostname
    ///   - port: Server port
    ///   - enableTLS: Whether to use TLS (wss)
    ///   - route: Route/path component (e.g. "/chat") used as the connection key
    ///   - maxReconnectionAttempts: Maximum reconnection attempts per connection
    ///   - timeout: Connection timeout
    ///   - tlsPreKeyed: Optional TLS configuration
    ///   - retryStrategy: Retry policy for reconnection attempts
    ///
    /// Connecting is idempotent per route: if `route` is already connected this call
    /// returns immediately and leaves the live connection (and its headers, TLS, and
    /// heartbeat settings) untouched. Call `disconnect(_:)` first to reconnect with
    /// different parameters.
    public func connect(
        host: String = "localhost",
        port: Int = 8080,
        enableTLS: Bool = false,
        route: String = "/",
        headers: HTTPHeaders = HTTPHeaders(),
        maxReconnectionAttempts: Int = 6,
        timeout: TimeAmount = .seconds(10),
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil,
        retryStrategy: RetryStrategy = .fixed(delay: .seconds(5)),
        autoPingPong: Bool = true,
        autoPingPongInterval: TimeInterval? = 60,
        autoPingTimeout: TimeInterval = 10
    ) async throws {
        if connections[route] != nil { return }
        heartbeatPolicies[route] = HeartbeatPolicy(
            enabled: autoPingPong,
            interval: autoPingPongInterval,
            timeout: autoPingTimeout
        )
        await MainActor.run { [socketReceiver] in
            socketReceiver.prepareForConnection()
        }
        let manager = ConnectionManager<WebSocketFrame, WebSocketFrame>()
        manager.webSocketOptions = WebSocketOptions(uri: route, headers: headers)
        let connectionDelegate = WSConnectionDelegate(socketReceiver: socketReceiver)
        let routeDelegate = RouteContextDelegate(route: route, socket: self)
        let server = ServerLocation(
            host: host,
            port: port,
            enableTLS: enableTLS,
            cacheKey: "ws-\(route)",
            delegate: connectionDelegate,
            contextDelegate: routeDelegate)

        // Register the route before connecting so the writer-delivery event
        // (which starts the heartbeat) always finds its bucket.
        connections[route] = ConnectionBucket(
            manager: manager,
            contextDelegate: routeDelegate,
            connectionDelegate: connectionDelegate)
        do {
            try await manager.connectWebSocket(
                to: [server],
                maxReconnectionAttempts: maxReconnectionAttempts,
                timeout: timeout,
                tlsPreKeyed: tlsPreKeyed,
                retryStrategy: retryStrategy)
        } catch {
            connections.removeValue(forKey: route)
            heartbeatPolicies.removeValue(forKey: route)
            connectionDelegate.invalidate()
            await routeDelegate.invalidate()
            throw error
        }
    }

    /// The outbound writer for `route` is available; this is the event that starts the heartbeat.
    fileprivate func writerDidBecomeAvailable(for route: String) async {
        await startHeartbeatIfNeeded(for: route)
    }
    
    /// Gracefully shutdown all connections and finish streams.
    public func shutDown() async {
        // Cancel all per-route tasks
        for pingTask in nextPingTasks.values {
            pingTask.cancel()
        }
        for pingTimeoutTask in pongTimeoutTasks.values {
            pingTimeoutTask.cancel()
        }
        nextPingTasks.removeAll()
        pongTimeoutTasks.removeAll()
        awaitingPongRoutes.removeAll()
        for bucket in connections.values {
            bucket.connectionDelegate.invalidate()
            await bucket.contextDelegate.invalidate()
            await bucket.manager.gracefulShutdown()
        }
        connections.removeAll()
        heartbeatPolicies.removeAll()
        await MainActor.run { [socketReceiver] in
            socketReceiver.finishStreams()
        }
    }
    
    /// Disconnect a specific route, if connected.
    public func disconnect(_ route: String = "/") async {
        // Cancel per-route heartbeat and timeout
        await cancelHeartbeat(for: route)
        heartbeatPolicies.removeValue(forKey: route)
        guard let bucket = connections.removeValue(forKey: route) else { return }
        bucket.connectionDelegate.invalidate()
        await bucket.contextDelegate.invalidate()
        await bucket.manager.gracefulShutdown()
    }

    fileprivate func routeDidClose(_ route: String) async {
        await cancelHeartbeat(for: route)
        heartbeatPolicies.removeValue(forKey: route)
        guard let bucket = connections.removeValue(forKey: route) else { return }
        bucket.connectionDelegate.invalidate()
        await bucket.contextDelegate.invalidate()
    }
    
    /// Send a text frame to the specified route.
    public func sendText(_ text: String, to route: String = "/") async throws {
        let textFrame = WebSocketFrame(fin: true, opcode: .text, maskKey: maskKey, data: ByteBuffer(data: text.data(using: .utf8)!))
        guard let bucket = connections[route] else { throw Errors.noConnectionForRoute(route) }
        guard let writer = await bucket.contextDelegate.writer else { throw Errors.writerUnavailable(route) }
        try await writer.write(textFrame)
    }
    
    /// Send a binary frame to the specified route.
    public func sendBinary(_ data: Data, to route: String = "/") async throws {
        let bianryFrame = WebSocketFrame(fin: true, opcode: .binary, maskKey: maskKey, data: ByteBuffer(data: data))
        guard let bucket = connections[route] else { throw Errors.noConnectionForRoute(route) }
        guard let writer = await bucket.contextDelegate.writer else { throw Errors.writerUnavailable(route) }
        try await writer.write(bianryFrame)
    }
    
    /// Send a ping frame to the specified route.
    public func sendPing(_ data: any DataProtocol, to route: String = "/") async throws {
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        let pingFrame = WebSocketFrame(fin: true, opcode: .ping, maskKey: maskKey, data: buffer)
        guard let bucket = connections[route] else { throw Errors.noConnectionForRoute(route) }
        guard let writer = await bucket.contextDelegate.writer else { throw Errors.writerUnavailable(route) }
        try await writer.write(pingFrame)
    }
    
    /// Send a pong frame to the specified route.
    public func sendPong(_ data: any DataProtocol, to route: String = "/") async throws {
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        let pongFrame = WebSocketFrame(fin: true, opcode: .pong, maskKey: maskKey, data: buffer)
        guard let bucket = connections[route] else { throw Errors.noConnectionForRoute(route) }
        guard let writer = await bucket.contextDelegate.writer else { throw Errors.writerUnavailable(route) }
        try await writer.write(pongFrame)
    }
    
    fileprivate func handleInbound(_ frame: WebSocketFrame, route: String = "/") async {
        switch frame.opcode {
        case .binary:
            let data = frame.data.getData(at: 0, length: frame.data.readableBytes) ?? Data()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.socketReceiver.setInboundMessage(.binary(data))
            }
        case .ping:
            let payload = frame.data.getData(at: 0, length: frame.data.readableBytes) ?? Data()
            // Immediate pong per spec
            if heartbeatPolicies[route]?.enabled == true {
                do {
                    try await sendPong(payload, to: route)
                } catch {
                    
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.socketReceiver.setInboundMessage(.ping(payload))
            }
        case .pong:
            let payload = frame.data.getData(at: 0, length: frame.data.readableBytes) ?? Data()
            // Mark pong received and schedule next ping after interval
            awaitingPongRoutes.remove(route)
            if let t = pongTimeoutTasks.removeValue(forKey: route) { t.cancel() }
            if heartbeatPolicies[route]?.enabled == true {
                await scheduleNextPingAfterInterval(for: route)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.socketReceiver.setInboundMessage(.pong(payload))
            }
        case .text:
            let text = frame.data.getString(at: 0, length: frame.data.readableBytes) ?? ""
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.socketReceiver.setInboundMessage(.text(text))
            }
        case .continuation:
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.socketReceiver.setInboundMessage(.continuation)
            }
        case .connectionClose:
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.socketReceiver.setInboundMessage(.connectionClose)
            }
        default:
            break
        }
    }
    
    private var maskKey: WebSocketMaskingKey {
        var generator = SystemRandomNumberGenerator()
        return WebSocketMaskingKey.random(using: &generator)
    }
}

actor RouteContextDelegate: ChannelContextDelegate {
    let route: String
    weak var socket: WebSocketClient?
    var writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>?
    nonisolated private let activeTask = NIOLockedValueBox<Task<Void, Never>?>(nil)
    nonisolated private let inactiveTask = NIOLockedValueBox<Task<Void, Never>?>(nil)
    
    init(route: String, socket: WebSocketClient) {
        self.route = route
        self.socket = socket
    }
    
    func deliverWriter<Outbound, Inbound>(context: WriterContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable {
        guard Outbound.self == WebSocketFrame.self else { return }
        let writer = context.writer as! NIOAsyncChannelOutboundWriter<WebSocketFrame>
        self.writer = writer
        await socket?.writerDidBecomeAvailable(for: route)
    }
    
    func deliverInboundBuffer<Inbound, Outbound>(context: StreamContext<Inbound, Outbound>) async where Inbound : Sendable, Outbound : Sendable {
        guard let frame = context.inbound as? WebSocketFrame else { return }
        await socket?.handleInbound(frame, route: route)
    }
    
    nonisolated func channelActive(_ stream: AsyncStream<Void>, id: String) {
        let task = Task { [weak self] in
            guard let self else { return }
            for await _ in stream {
                await self.notifyChannelActive()
            }
        }
        replaceTask(in: activeTask, with: task)
    }
    
    nonisolated func channelInactive(_ stream: AsyncStream<Void>, id: String) {
        let task = Task { [weak self] in
            guard let self else { return }
            for await _ in stream {
                await self.notifyChannelInactive()
            }
        }
        replaceTask(in: inactiveTask, with: task)
    }

    nonisolated private func replaceTask(
        in box: NIOLockedValueBox<Task<Void, Never>?>,
        with task: Task<Void, Never>
    ) {
        let previous = box.withLockedValue { stored in
            let previous = stored
            stored = task
            return previous
        }
        previous?.cancel()
    }

    func invalidate() {
        writer = nil
        for box in [activeTask, inactiveTask] {
            let task = box.withLockedValue { stored in
                defer { stored = nil }
                return stored
            }
            task?.cancel()
        }
    }
    
    func reportChildChannel(error: any Error, id: String) async {
        await notifyError(error)
    }
    
    func didShutdownChildChannel() async {
        await notifyChannelInactive()
        await socket?.routeDidClose(route)
    }
    
    private func notifyChannelActive() async {
        guard let socket = socket else { return }
        await MainActor.run {
            socket.socketReceiver.setChannelActive()
        }
    }
    
    private func notifyChannelInactive() async {
        guard let socket = socket else { return }
        await MainActor.run {
            socket.socketReceiver.setChannelInactive()
        }
    }
    
    private func notifyError(_ error: Error) async {
        guard let socket = socket else { return }
        await MainActor.run {
            socket.socketReceiver.setError(error)
        }
    }
}

// MARK: - Heartbeat Management
extension WebSocketClient {
    private func startHeartbeatIfNeeded(for route: String) async {
        guard
            let policy = heartbeatPolicies[route],
            policy.enabled,
            policy.interval != nil,
            nextPingTasks[route] == nil,
            pongTimeoutTasks[route] == nil,
            !awaitingPongRoutes.contains(route)
        else {
            return
        }
        await sendPingAndArmTimeout(for: route)
    }
    
    private func scheduleNextPingAfterInterval(for route: String) async {
        guard
            let policy = heartbeatPolicies[route],
            policy.enabled,
            let interval = policy.interval
        else {
            return
        }
        if let t = nextPingTasks.removeValue(forKey: route) { t.cancel() }
        let t = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(until: .now + .seconds(interval))
            } catch { return }
            await self.sendPingAndArmTimeout(for: route)
        }
        nextPingTasks[route] = t
    }
    
    private func cancelHeartbeat(for route: String) async {
        if let t = nextPingTasks.removeValue(forKey: route) { t.cancel() }
        if let t = pongTimeoutTasks.removeValue(forKey: route) { t.cancel() }
        awaitingPongRoutes.remove(route)
    }
    
    private func sendPingAndArmTimeout(for route: String) async {
        guard
            connections[route] != nil,
            let policy = heartbeatPolicies[route],
            policy.enabled
        else {
            return
        }
        nextPingTasks.removeValue(forKey: route)
        // Mark before the suspension point so a concurrent start cannot double-ping.
        awaitingPongRoutes.insert(route)
        do {
            try await sendPing(Data(), to: route)
        } catch {
            // A failed write means the channel is dying; its close event tears the route down.
            awaitingPongRoutes.remove(route)
            return
        }
        if let t = pongTimeoutTasks.removeValue(forKey: route) { t.cancel() }
        let timeout = policy.timeout
        let watchdog = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(until: .now + .seconds(timeout))
            } catch { return }
            if await self.awaitingPongRoutes.contains(route) {
                await self.disconnect(route)
            }
        }
        pongTimeoutTasks[route] = watchdog
    }
}
