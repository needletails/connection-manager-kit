//
//  WebSocket.swift
//  connection-manager-kit
//
//  Created by Cole M on 8/16/25.
//

import Foundation
import Observation
import NIOFoundationCompat
#if canImport(Network)
import Network
#endif

/// A main-actor observable that surfaces inbound WebSocket messages and network events.
///
/// Consumers can observe the `messageStream` and `eventStream` to react to frames
/// and channel lifecycle updates. Streams are lazily created and explicitly
/// finished during `WebSocketClient.shutDown()` to avoid resource leaks.
@MainActor
@Observable
public final class SocketReceiver: Sendable {
    
    /// Inbound WebSocket message kinds delivered to `messageStream`.
    public enum WebSocketOpcode: Sendable, Equatable {
        case text(String)
        case message(String?)
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
        messageStream = AsyncStream<WebSocketOpcode> { [weak self] continuation in
            guard let self else { return }
            self.messageContinuation = continuation
        }
    }
    
    private func makeEventStream() {
        eventStream = AsyncStream<WebSocketEvent> { [weak self] continuation in
            guard let self else { return }
            self.eventContinuation = continuation
        }
    }
    
    /// Internal: updates observed state and emits to `messageStream`.
    public func setInboundMessage(_ message: WebSocketOpcode) {
        if messageStream == nil {
            makeMessageStream()
        }
        _ = withObservationTracking {
            self.webSocketFrame
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.messageContinuation?.yield(message)
            }
        }
        webSocketFrame = message
    }
#if canImport(Network)
    /// Internal: updates observed state and emits a Network event to `eventStream`.
    public func setNetworkEvent(_ event: NetworkEventMonitor.NetworkEvent) {
        if eventStream == nil {
            makeEventStream()
        }
        _ = withObservationTracking {
            self.networkEvent
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.eventContinuation?.yield(.networkEvent(event))
            }
        }
        self.networkEvent = .networkEvent(event)
    }
#else
    /// Internal (Linux): updates observed state and emits an NIO event to `eventStream`.
    public func setNIOEvent(_ event: ConnectionManagerKit.NetworkEventMonitor.NIOEvent) {
        if eventStream == nil {
            makeEventStream()
        }
        _ = withObservationTracking {
            self.networkEvent
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.eventContinuation?.yield(.networkEvent(event))
            }
        }
        self.networkEvent = .networkEvent(event)
    }
#endif
    
    /// Internal: emits an error event to `eventStream`.
    public func setError(_ error: Error) {
        if eventStream == nil {
            makeEventStream()
        }
        _ = withObservationTracking {
            self.networkEvent
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.eventContinuation?.yield(.error(error))
            }
        }
        self.networkEvent = .error(error)
    }
    
    /// Internal: emits channel active to `eventStream`.
    public func setChannelActive() {
        if eventStream == nil {
            makeEventStream()
        }
        _ = withObservationTracking {
            self.networkEvent
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.eventContinuation?.yield(.channelActive)
            }
        }
        self.networkEvent = .channelActive
    }
    
    /// Internal: emits channel inactive to `eventStream`.
    public func setChannelInactive() {
        if eventStream == nil {
            makeEventStream()
        }
        _ = withObservationTracking {
            self.networkEvent
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.eventContinuation?.yield(.channelInactive)
            }
        }
        self.networkEvent = .channelInactive
    }
}

private final class WSConnectionDelegate: ConnectionDelegate, @unchecked Sendable {
    private weak var socketReceiver: SocketReceiver?
    
    init(socketReceiver: SocketReceiver) {
        self.socketReceiver = socketReceiver
    }
    private var handleErrorTask: Task<Void, Never>?
    private var handleNetworkEventsTask: Task<Void, Never>?
    
#if canImport(Network)
    func handleError(_ stream: AsyncStream<NWError>, id: String) {
        if let handleErrorTask {
            handleErrorTask.cancel()
            self.handleErrorTask = nil
        }
        handleErrorTask = Task {
            for await error in stream {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.socketReceiver?.setError(error)
                }
            }
        }
    }
    
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
        if let handleNetworkEventsTask {
            handleNetworkEventsTask.cancel()
            self.handleNetworkEventsTask = nil
        }
        handleNetworkEventsTask = Task {
            for await event in stream {
                await MainActor.run { [weak self] in
                       guard let self else { return }
                       self.socketReceiver?.setNetworkEvent(event)
                }
            }
        }
    }
#else
    func handleError(_ stream: AsyncStream<IOError>, id: String) {
        if let handleErrorTask {
            handleErrorTask.cancel()
            self.handleErrorTask = nil
        }
        Task {
            for await error in stream {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.socketReceiver?.setError(error)
                }
            }
        }
    }
    
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NIOEvent>, id: String) async {
        if let handleNetworkEventsTask {
            handleNetworkEventsTask.cancel()
            self.handleNetworkEventsTask = nil
        }
        handleNetworkEventsTask = Task {
            for await event in stream {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.socketReceiver?.setNIOEvent(event)
                }
            }
        }
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
    
    init(socketReceiver: SocketReceiver) {
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
        maxReconnectionAttempts: Int = 6,
        timeout: TimeAmount = .seconds(10),
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil,
        retryStrategy: RetryStrategy = .fixed(delay: .seconds(5))
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
            maxReconnectionAttempts: maxReconnectionAttempts,
            timeout: timeout,
            tlsPreKeyed: tlsPreKeyed,
            retryStrategy: retryStrategy)
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
    public func connect(
        host: String = "localhost",
        port: Int = 8080,
        enableTLS: Bool = false,
        route: String = "/",
        maxReconnectionAttempts: Int = 6,
        timeout: TimeAmount = .seconds(10),
        tlsPreKeyed: TLSPreKeyedConfiguration? = nil,
        retryStrategy: RetryStrategy = .fixed(delay: .seconds(5))
    ) async throws {
        if connections[route] != nil { return }
        let manager = ConnectionManager<WebSocketFrame, WebSocketFrame>()
        manager.webSocketOptions = WebSocketOptions(uri: route)
        let connectionDelegate = WSConnectionDelegate(socketReceiver: socketReceiver)
        let routeDelegate = RouteContextDelegate(route: route, socket: self)
        let server = ServerLocation(
            host: host,
            port: port,
            enableTLS: enableTLS,
            cacheKey: "ws-\(route)",
            delegate: connectionDelegate,
            contextDelegate: routeDelegate)
        try await manager.connectWebSocket(
            to: [server],
            maxReconnectionAttempts: maxReconnectionAttempts,
            timeout: timeout,
            tlsPreKeyed: tlsPreKeyed,
            retryStrategy: retryStrategy)
        
        connections[route] = ConnectionBucket(
            manager: manager,
            contextDelegate: routeDelegate,
            connectionDelegate: connectionDelegate)
    }
    
    /// Gracefully shutdown all connections and finish streams.
    public func shutDown() async {
        for bucket in connections.values {
            await bucket.manager.gracefulShutdown()
        }
        connections.removeAll()
        await MainActor.run { [socketReceiver] in
            socketReceiver.messageContinuation?.finish()
            socketReceiver.eventContinuation?.finish()
            socketReceiver.messageContinuation = nil
            socketReceiver.eventContinuation = nil
        }
    }
    
    /// Disconnect a specific route, if connected.
    public func disconnect(_ route: String = "/") async {
        guard let bucket = connections.removeValue(forKey: route) else { return }
        await bucket.manager.gracefulShutdown()
    }
    
    /// Send a text frame to the specified route.
    public func sendText(_ text: String, to route: String = "/") async throws {
        let textFrame = WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(data: text.data(using: .utf8)!))
        guard let bucket = connections[route] else { throw Errors.noConnectionForRoute(route) }
        guard let writer = await bucket.contextDelegate.writer else { throw Errors.writerUnavailable(route) }
        try await writer.write(textFrame)
    }
    
    /// Send a binary frame to the specified route.
    public func sendBinary(_ data: Data, to route: String = "/") async throws {
        let bianryFrame = WebSocketFrame(fin: true, opcode: .binary, data: ByteBuffer(data: data))
        guard let bucket = connections[route] else { throw Errors.noConnectionForRoute(route) }
        guard let writer = await bucket.contextDelegate.writer else { throw Errors.writerUnavailable(route) }
        try await writer.write(bianryFrame)
    }
    
    /// Send a ping frame to the specified route.
    public func sendPing(_ data: Data, to route: String = "/") async throws {
        let pingFrame = WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer(data: data))
        guard let bucket = connections[route] else { throw Errors.noConnectionForRoute(route) }
        guard let writer = await bucket.contextDelegate.writer else { throw Errors.writerUnavailable(route) }
        try await writer.write(pingFrame)
    }
    
    /// Send a pong frame to the specified route.
    public func sendPong(_ data: Data, to route: String = "/") async throws {
        let pongFrame = WebSocketFrame(fin: true, opcode: .pong, data: ByteBuffer(data: data))
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
            let data = frame.data.getData(at: 0, length: frame.data.readableBytes) ?? Data()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.socketReceiver.setInboundMessage(.ping(data))
            }
        case .pong:
            let data = frame.data.getData(at: 0, length: frame.data.readableBytes) ?? Data()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.socketReceiver.setInboundMessage(.pong(data))
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
}

actor RouteContextDelegate: ChannelContextDelegate {
    let route: String
    weak var socket: WebSocketClient?
    var writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>?
    
    init(route: String, socket: WebSocketClient) {
        self.route = route
        self.socket = socket
    }
    
    func deliverWriter<Outbound, Inbound>(context: WriterContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable {
        guard Outbound.self == WebSocketFrame.self else { return }
        let writer = context.writer as! NIOAsyncChannelOutboundWriter<WebSocketFrame>
        self.writer = writer
    }
    
    func deliverInboundBuffer<Inbound, Outbound>(context: StreamContext<Inbound, Outbound>) async where Inbound : Sendable, Outbound : Sendable {
        guard let frame = context.inbound as? WebSocketFrame else { return }
        await socket?.handleInbound(frame, route: route)
    }
    
    nonisolated func channelActive(_ stream: AsyncStream<Void>, id: String) {
        Task { [weak self] in
            guard let self else { return }
            for await _ in stream {
                await self.notifyChannelActive()
            }
        }
    }
    
    nonisolated func channelInactive(_ stream: AsyncStream<Void>, id: String) {
        Task { [weak self] in
            guard let self else { return }
            for await _ in stream {
                await self.notifyChannelInactive()
            }
        }
    }
    
    func reportChildChannel(error: any Error, id: String) async {
        await notifyError(error)
    }
    
    func didShutdownChildChannel() async {
        await notifyChannelInactive()
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
