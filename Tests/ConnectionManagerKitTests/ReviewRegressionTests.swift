//
//  ReviewRegressionTests.swift
//  connection-manager-kit
//
//  Regression tests for the issues found in the ConnectionManagerKit review:
//  server accept-loop death, errored server connection leaks, unbounded cache
//  order growth, wildcard bind, WebSocket mode leaking across calls,
//  monitor streams never finishing, WebSocket Close handling, and
//  connectParallel metrics reporting.
//

import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import NIOConcurrencyHelpers
#if canImport(Network)
import Network
#endif
@testable import ConnectionManagerKit

// MARK: - Helpers

/// Polls `condition` until it is true or `timeout` elapses.
func waitUntil(
    timeout: Duration = .seconds(5),
    pollEvery: Duration = .milliseconds(25),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: pollEvery)
    }
    return await condition()
}

/// Runs `body` and returns `true` if it completed before `timeout`.
///
/// Uses an unstructured task so a body that is not cancellation-responsive
/// (e.g. one blocked on a never-completing future) cannot hang the test; it is
/// abandoned instead.
func completes(within timeout: Duration, _ body: @escaping @Sendable () async -> Void) async -> Bool {
    let done = NIOLockedValueBox(false)
    let task = Task {
        await body()
        done.withLockedValue { $0 = true }
    }
    let finished = await waitUntil(timeout: timeout) { done.withLockedValue { $0 } }
    if !finished { task.cancel() }
    return finished
}

/// Listener delegate for plain TCP servers: records the bound port and
/// installs caller-supplied child handlers.
final class TCPListenerDelegation: ListenerDelegate, @unchecked Sendable {
    nonisolated(unsafe) var boundPort: Int?
    private let handlers: @Sendable () -> [ChannelHandler]

    init(handlers: @escaping @Sendable () -> [ChannelHandler] = { [] }) {
        self.handlers = handlers
    }

    func retrieveChannelHandlers() -> [ChannelHandler] { handlers() }
    func retrieveSSLHandler() -> NIOSSLServerHandler? { nil }

    func didBindTCPServer<Inbound: Sendable, Outbound: Sendable>(
        channel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>
    ) async {
        boundPort = channel.channel.localAddress?.port
    }

    func waitForBoundPort(timeout: Duration = .seconds(5)) async -> Int? {
        _ = await waitUntil(timeout: timeout) { self.boundPort != nil }
        return boundPort
    }
}

/// Listener delegate for WebSocket servers: records the bound port.
final class WSListenerDelegation: ListenerDelegate, @unchecked Sendable {
    nonisolated(unsafe) var boundPort: Int?

    func retrieveChannelHandlers() -> [ChannelHandler] { [] }
    func retrieveSSLHandler() -> NIOSSLServerHandler? { nil }

    func didBindWebSocketServer<Inbound: Sendable, Outbound: Sendable>(
        channel: NIOAsyncChannel<EventLoopFuture<NIOAsyncChannel<Inbound, Outbound>>, Never>
    ) async {
        boundPort = channel.channel.localAddress?.port
    }

    func waitForBoundPort(timeout: Duration = .seconds(5)) async -> Int? {
        _ = await waitUntil(timeout: timeout) { self.boundPort != nil }
        return boundPort
    }
}

/// Context delegate that records lifecycle callbacks and keeps the raw
/// monitor streams so tests can assert they terminate.
final class RecordingContextDelegate: ChannelContextDelegate, @unchecked Sendable {
    nonisolated(unsafe) private(set) var shutdownCount = 0
    nonisolated(unsafe) private(set) var reportedErrors: [any Error] = []
    nonisolated(unsafe) private(set) var writerAny: Any?
    nonisolated(unsafe) private(set) var channelActiveStream: AsyncStream<Void>?
    nonisolated(unsafe) private(set) var channelInactiveStream: AsyncStream<Void>?
    nonisolated(unsafe) private(set) var inboundFrames: [WebSocketFrame] = []

    func reportChildChannel(error: any Error, id: String) async { reportedErrors.append(error) }
    func didShutdownChildChannel() async { shutdownCount += 1 }
    func channelActive(_ stream: AsyncStream<Void>, id: String) { channelActiveStream = stream }
    func channelInactive(_ stream: AsyncStream<Void>, id: String) { channelInactiveStream = stream }
    func deliverWriter<Outbound, Inbound>(context: WriterContext<Inbound, Outbound>) async {
        writerAny = context.writer
    }
    func deliverInboundBuffer<Inbound: Sendable, Outbound: Sendable>(context: StreamContext<Inbound, Outbound>) async {
        if let frame = context.inbound as? WebSocketFrame {
            inboundFrames.append(frame)
        }
    }

    func writer<O>(as: O.Type) -> NIOAsyncChannelOutboundWriter<O>? {
        writerAny as? NIOAsyncChannelOutboundWriter<O>
    }
}

/// Connection delegate that keeps the monitor event/error streams and wires a
/// server-side context delegate onto every accepted child channel.
final class RecordingConnectionDelegate<I: Sendable, O: Sendable>: ConnectionDelegate, @unchecked Sendable {
#if canImport(Network)
    nonisolated(unsafe) private(set) var eventStream: AsyncStream<NetworkEventMonitor.NetworkEvent>?
    nonisolated(unsafe) private(set) var errorStream: AsyncStream<NWError>?
    func handleError(_ stream: AsyncStream<NWError>, id: String) { errorStream = stream }
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async { eventStream = stream }
#else
    nonisolated(unsafe) private(set) var eventStream: AsyncStream<NetworkEventMonitor.NIOEvent>?
    nonisolated(unsafe) private(set) var errorStream: AsyncStream<IOError>?
    func handleError(_ stream: AsyncStream<IOError>, id: String) { errorStream = stream }
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NIOEvent>, id: String) async { eventStream = stream }
#endif

    let listener: ConnectionListener<I, O>?
    let serverContextDelegate: ChannelContextDelegate?
    nonisolated(unsafe) private(set) var initializedIDs: [String] = []

    init(listener: ConnectionListener<I, O>? = nil, serverContextDelegate: ChannelContextDelegate? = nil) {
        self.listener = listener
        self.serverContextDelegate = serverContextDelegate
    }

    func initializedChildChannel<Outbound, Inbound>(_ context: ChannelContext<Inbound, Outbound>) async where Outbound: Sendable, Inbound: Sendable {
        initializedIDs.append(context.id)
        if let serverContextDelegate {
            await listener?.setContextDelegate(serverContextDelegate, key: context.id)
        }
    }
}

struct PoisonError: Error {}

/// Passes bytes through until it sees 0xFF, then throws so the server's
/// inbound iterator fails while the TCP connection stays open.
final class PoisonDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes > 0 else { return .needMoreData }
        if buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) == 0xFF {
            throw PoisonError()
        }
        let slice = buffer.readSlice(length: buffer.readableBytes)!
        context.fireChannelRead(wrapInboundOut(slice))
        return .continue
    }
    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        .needMoreData
    }
}

/// Starts a TCP listener on an ephemeral port and returns the port plus the running task.
func startTCPListener<I: Sendable, O: Sendable>(
    _ listener: ConnectionListener<I, O>,
    delegate: ConnectionDelegate?,
    listenerDelegate: TCPListenerDelegation,
    host: String? = "127.0.0.1"
) async throws -> (port: Int, task: Task<Void, Error>) {
    let task = Task {
        let config = try await listener.resolveAddress(
            .init(group: MultiThreadedEventLoopGroup.singleton, host: host, port: 0))
        try await listener.listen(
            address: config.address!,
            configuration: config,
            delegate: delegate,
            listenerDelegate: listenerDelegate)
    }
    let port = try #require(await listenerDelegate.waitForBoundPort(), "listener must bind")
    return (port, task)
}

/// Starts a WebSocket listener on an ephemeral port and returns the port plus the running task.
func startWSListener(
    _ listener: ConnectionListener<WebSocketFrame, WebSocketFrame>,
    delegate: ConnectionDelegate?,
    listenerDelegate: WSListenerDelegation
) async throws -> (port: Int, task: Task<Void, Error>) {
    let task = Task {
        let config = try await listener.resolveAddress(
            .init(group: MultiThreadedEventLoopGroup.singleton, host: "127.0.0.1", port: 0))
        try await listener.listen(
            address: config.address!,
            websocketConfiguration: .init(),
            configuration: config,
            delegate: delegate,
            listenerDelegate: listenerDelegate)
    }
    let port = try #require(await listenerDelegate.waitForBoundPort(), "listener must bind")
    return (port, task)
}

func stopListener<I: Sendable, O: Sendable>(_ listener: ConnectionListener<I, O>, task: Task<Void, Error>) async {
    await listener.serviceGroup?.triggerGracefulShutdown()
    try? await listener.shutdown()
    task.cancel()
    _ = try? await task.value
}

/// Minimal in-memory `ChildChannelServiceDelegate` for cache-only tests.
final class NoopChildChannelServiceDelegate: ChildChannelServiceDelegate {
    func initializedChildChannel<Outbound: Sendable, Inbound: Sendable>(_ context: ChannelContext<Inbound, Outbound>) async {}
}

// MARK: - Tests

@Suite(.serialized)
struct ReviewRegressionTests {

    // MARK: S1 - WebSocket accept loop must survive bad handshakes

    @Test("WS listener keeps accepting after a client disconnects mid-handshake")
    func wsListenerSurvivesEarlyClose() async throws {
        let listener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
        let listenerDelegate = WSListenerDelegation()
        let serverContext = RecordingContextDelegate()
        let serverDelegate = RecordingConnectionDelegate(listener: listener, serverContextDelegate: serverContext)
        let (port, serverTask) = try await startWSListener(listener, delegate: serverDelegate, listenerDelegate: listenerDelegate)

        // A TCP client that connects and immediately goes away without upgrading.
        let raw = try await connectRaw(host: "127.0.0.1", port: port)
        try await raw.close()

        // A second raw client sends non-HTTP garbage.
        let garbage = try await connectRaw(host: "127.0.0.1", port: port)
        var junk = ByteBuffer()
        junk.writeString("\u{01}\u{02}this is not http\r\n\r\n")
        try? await garbage.writeAndFlush(junk)
        try? await garbage.close()

        // The listener must still be alive and able to complete a real upgrade.
        let manager = ConnectionManager<WebSocketFrame, WebSocketFrame>()
        let clientContext = RecordingContextDelegate()
        try await manager.connectWebSocket(
            to: [ServerLocation(host: "127.0.0.1", port: port, enableTLS: false, cacheKey: "ws-alive", contextDelegate: clientContext)],
            maxReconnectionAttempts: 1,
            timeout: .seconds(3))
        #expect(await waitUntil { clientContext.writerAny != nil }, "real WebSocket client must get a writer after bad peers")
        #expect(await waitUntil { serverDelegate.initializedIDs.count == 1 }, "server must initialize exactly one upgraded child channel")

        await manager.gracefulShutdown()
        await stopListener(listener, task: serverTask)
        #expect(await waitUntil { await listener.getMetrics().activeConnections == 0 })
    }

    @Test("WS listener rejects a plain HTTP request without crashing or dying")
    func wsListenerRejectsPlainHTTP() async throws {
        let listener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
        let listenerDelegate = WSListenerDelegation()
        let serverDelegate = RecordingConnectionDelegate<WebSocketFrame, WebSocketFrame>(listener: listener)
        let (port, serverTask) = try await startWSListener(listener, delegate: serverDelegate, listenerDelegate: listenerDelegate)

        let http = try await connectRaw(host: "127.0.0.1", port: port)
        var request = ByteBuffer()
        request.writeString("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        try await http.writeAndFlush(request)
        // The server should close the non-upgraded connection on its own.
        #expect(await completes(within: .seconds(5)) { try? await http.closeFuture.getAbandoningOnCancel() },
                "server must close a plain HTTP connection to a WebSocket listener")

        let manager = ConnectionManager<WebSocketFrame, WebSocketFrame>()
        let clientContext = RecordingContextDelegate()
        try await manager.connectWebSocket(
            to: [ServerLocation(host: "127.0.0.1", port: port, enableTLS: false, cacheKey: "ws-after-http", contextDelegate: clientContext)],
            maxReconnectionAttempts: 1,
            timeout: .seconds(3))
        #expect(await waitUntil { clientContext.writerAny != nil }, "listener must still upgrade real clients")
        #expect(serverDelegate.initializedIDs.count == 1, "plain HTTP must never be surfaced as a child channel")

        await manager.gracefulShutdown()
        await stopListener(listener, task: serverTask)
    }

    // MARK: S2 - Errored server connections must finish and release their slot

    @Test("Server connection whose inbound throws releases its slot and notifies shutdown")
    func serverErroredConnectionReleasesSlot() async throws {
        let listener = ConnectionListener<ByteBuffer, ByteBuffer>(
            configuration: ListenerConfiguration(maxConcurrentConnections: 1))
        let listenerDelegate = TCPListenerDelegation { [ByteToMessageHandler(PoisonDecoder())] }
        let serverContext = RecordingContextDelegate()
        let serverDelegate = RecordingConnectionDelegate(listener: listener, serverContextDelegate: serverContext)
        let (port, serverTask) = try await startTCPListener(listener, delegate: serverDelegate, listenerDelegate: listenerDelegate)

        let client = try await connectRaw(host: "127.0.0.1", port: port)
        #expect(await waitUntil { await listener.getMetrics().activeConnections == 1 })

        var poison = ByteBuffer()
        poison.writeInteger(UInt8(0xFF))
        try await client.writeAndFlush(poison)

        #expect(await waitUntil { serverContext.reportedErrors.contains { $0 is PoisonError } },
                "decoder error must be reported to the context delegate")
        #expect(await waitUntil { serverContext.shutdownCount == 1 },
                "didShutdownChildChannel must fire for an errored connection")
        #expect(await waitUntil { await listener.getMetrics().activeConnections == 0 },
                "errored connection must release its concurrency slot")
        #expect(await waitUntil { await listener.getMetrics().totalConnectionsClosed == 1 })
        #expect(await completes(within: .seconds(5)) { try? await client.closeFuture.getAbandoningOnCancel() },
                "server must close the errored connection")

        // The freed slot must be usable by a new client.
        let second = try await connectRaw(host: "127.0.0.1", port: port)
        #expect(await waitUntil { serverDelegate.initializedIDs.count == 2 }, "second client must be accepted after the first errored out")
        try? await second.close()

        await stopListener(listener, task: serverTask)
    }

    // MARK: S3 - Cache access order must stay bounded under churn

    @Test("ConnectionCache order bookkeeping stays bounded when keys churn below capacity")
    func cacheOrderStaysBoundedUnderChurn() async throws {
        let cache = ConnectionCache<ByteBuffer, ByteBuffer>(
            logger: .init(),
            configuration: .init(maxConnections: 100, enableLRU: true))
        let delegate = NoopChildChannelServiceDelegate()
        let location = ServerLocation(host: "h", port: 1, enableTLS: false, cacheKey: "churn")

        for _ in 0..<5_000 {
            let service = ChildChannelService<ByteBuffer, ByteBuffer>(
                logger: .init(), config: location, childChannel: nil, delegate: delegate)
            await cache.cacheConnection(service, for: "churn")
            _ = await cache.findConnection(cacheKey: "churn") // LRU hit appends an order entry
            try await cache.removeConnection("churn")
        }

        let entries = await cache.orderEntryCountForTesting
        #expect(entries < 1_024, "connectionOrder must be compacted; had \(entries) entries after churn")
        #expect(await cache.count == 0)
    }

    // MARK: S4 - Wildcard bind

    @Test("resolveAddress with a nil host binds to all IPv4 interfaces")
    func nilHostBindsWildcard() async throws {
        let listener = ConnectionListener<ByteBuffer, ByteBuffer>()
        let listenerDelegate = TCPListenerDelegation()
        let (port, serverTask) = try await startTCPListener(
            listener, delegate: nil, listenerDelegate: listenerDelegate, host: nil)

        let client = try await connectRaw(host: "127.0.0.1", port: port)
        #expect(client.isActive)
        try await client.close()

        await stopListener(listener, task: serverTask)
    }

    // MARK: S5 - Transport mode is per call, not per manager

    @Test("Plain connect after connectWebSocket on the same manager uses TCP")
    func plainConnectAfterWebSocketUsesTCP() async throws {
        // WebSocket server.
        let wsListener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
        let wsListenerDelegate = WSListenerDelegation()
        let (wsPort, wsTask) = try await startWSListener(wsListener, delegate: nil, listenerDelegate: wsListenerDelegate)

        // Silent plain TCP server (accepts, never writes).
        let tcpListener = ConnectionListener<ByteBuffer, ByteBuffer>()
        let tcpListenerDelegate = TCPListenerDelegation()
        let (tcpPort, tcpTask) = try await startTCPListener(tcpListener, delegate: nil, listenerDelegate: tcpListenerDelegate)

        let manager = ConnectionManager<WebSocketFrame, WebSocketFrame>()
        let wsContext = RecordingContextDelegate()
        try await manager.connectWebSocket(
            to: [ServerLocation(host: "127.0.0.1", port: wsPort, enableTLS: false, cacheKey: "ws", contextDelegate: wsContext)],
            maxReconnectionAttempts: 1)
        #expect(await waitUntil { wsContext.writerAny != nil })

        // A plain TCP connect on the same manager must not attempt an HTTP upgrade
        // (which would wait forever for a response the silent TCP server never sends).
        let tcpContext = RecordingContextDelegate()
        let connected = await completes(within: .seconds(5)) {
            try? await manager.connect(
                to: [ServerLocation(host: "127.0.0.1", port: tcpPort, enableTLS: false, cacheKey: "tcp", contextDelegate: tcpContext)],
                maxReconnectionAttempts: 1,
                timeout: .seconds(2))
        }
        #expect(connected, "plain TCP connect must not hang in a WebSocket upgrade")
        #expect(await waitUntil { tcpContext.writerAny != nil }, "plain TCP connect must deliver a writer without a WebSocket upgrade")

        await manager.gracefulShutdown()
        await stopListener(wsListener, task: wsTask)
        await stopListener(tcpListener, task: tcpTask)
    }

    // MARK: S6 - Monitor streams must finish when the channel goes away

    @Test("NetworkEventMonitor streams finish after the channel closes")
    func monitorStreamsFinishOnClose() async throws {
        let listener = ConnectionListener<ByteBuffer, ByteBuffer>()
        let listenerDelegate = TCPListenerDelegation()
        let (port, serverTask) = try await startTCPListener(listener, delegate: nil, listenerDelegate: listenerDelegate)

        let manager = ConnectionManager<ByteBuffer, ByteBuffer>()
        let connectionDelegate = RecordingConnectionDelegate<ByteBuffer, ByteBuffer>()
        let context = RecordingContextDelegate()
        try await manager.connect(to: [
            ServerLocation(host: "127.0.0.1", port: port, enableTLS: false, cacheKey: "streams",
                           delegate: connectionDelegate, contextDelegate: context)
        ])
        #expect(await waitUntil { context.writerAny != nil })
        let inactive = try #require(context.channelInactiveStream)
        let active = try #require(context.channelActiveStream)
        let events = try #require(connectionDelegate.eventStream)
        let errors = try #require(connectionDelegate.errorStream)

        // Peer closes.
        await stopListener(listener, task: serverTask)
        #expect(await waitUntil { context.shutdownCount == 1 })

        #expect(await completes(within: .seconds(3)) { for await _ in inactive {} }, "channelInactiveStream must finish")
        #expect(await completes(within: .seconds(3)) { for await _ in active {} }, "channelActiveStream must finish")
        #expect(await completes(within: .seconds(3)) { for await _ in events {} }, "eventStream must finish")
        #expect(await completes(within: .seconds(3)) { for await _ in errors {} }, "errorStream must finish")

        await manager.gracefulShutdown()
    }

    // MARK: S6b - Inline stream iteration in handleNetworkEvents must not stall connect

    @Test("connect returns even if the delegate iterates the event stream inline")
    func inlineNetworkEventIterationDoesNotStallConnect() async throws {
        final class InlineIteratingDelegate: ConnectionDelegate, @unchecked Sendable {
            nonisolated(unsafe) var eventCount = 0
            nonisolated(unsafe) var streamFinished = false
#if canImport(Network)
            func handleError(_ stream: AsyncStream<NWError>, id: String) {}
            func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
                for await _ in stream { eventCount += 1 }
                streamFinished = true
            }
#else
            func handleError(_ stream: AsyncStream<IOError>, id: String) {}
            func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NIOEvent>, id: String) async {
                for await _ in stream { eventCount += 1 }
                streamFinished = true
            }
#endif
            func initializedChildChannel<Outbound, Inbound>(_ context: ChannelContext<Inbound, Outbound>) async where Outbound: Sendable, Inbound: Sendable {}
        }

        let listener = ConnectionListener<ByteBuffer, ByteBuffer>()
        let listenerDelegate = TCPListenerDelegation()
        let (port, serverTask) = try await startTCPListener(listener, delegate: nil, listenerDelegate: listenerDelegate)

        let manager = ConnectionManager<ByteBuffer, ByteBuffer>()
        let delegate = InlineIteratingDelegate()
        let context = RecordingContextDelegate()
        let connected = await completes(within: .seconds(5)) {
            try? await manager.connect(to: [
                ServerLocation(host: "127.0.0.1", port: port, enableTLS: false, cacheKey: "inline",
                               delegate: delegate, contextDelegate: context)
            ], maxReconnectionAttempts: 1)
        }
        #expect(connected, "connect must not wait for the delegate to drain the event stream")
        #expect(await waitUntil { context.writerAny != nil }, "the connection must run")

        await manager.gracefulShutdown()
        #expect(await waitUntil { delegate.streamFinished }, "the delegate's inline loop must end once the channel closes")
        await stopListener(listener, task: serverTask)
    }

    // MARK: S7 - WebSocketClient honors a server Close frame

    @Test("WebSocketClient closes the connection when the server sends Close")
    func webSocketClientHonorsServerClose() async throws {
        let listener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
        let listenerDelegate = WSListenerDelegation()
        let serverContext = RecordingContextDelegate()
        let serverDelegate = RecordingConnectionDelegate(listener: listener, serverContextDelegate: serverContext)
        let (port, serverTask) = try await startWSListener(listener, delegate: serverDelegate, listenerDelegate: listenerDelegate)

        let client = await MainActor.run { WebSocketClient(socketReceiver: SocketReceiver()) }
        let events = try #require(await MainActor.run { client.socketReceiver.eventStream })
        try await client.connect(
            host: "127.0.0.1", port: port, enableTLS: false, route: "/close",
            maxReconnectionAttempts: 1, autoPingPong: false)
        let serverWriter = try #require(await waitUntil { serverContext.writerAny != nil } ? serverContext.writer(as: WebSocketFrame.self) : nil)

        var payload = ByteBuffer()
        payload.writeInteger(UInt16(1000)) // normal closure
        try await serverWriter.write(WebSocketFrame(fin: true, opcode: .connectionClose, data: payload))

        // Client must echo a Close frame back to the server...
        #expect(await waitUntil { serverContext.inboundFrames.contains { $0.opcode == .connectionClose } },
                "client must reply with a Close frame")
        // ...and tear the route down.
        #expect(await completes(within: .seconds(5)) {
            for await event in events where event == .channelInactive { return }
        }, "client must publish channelInactive after a server Close")
        await #expect(throws: WebSocketClient.Errors.self) {
            try await client.sendText("late", to: "/close")
        }

        await client.shutDown()
        await stopListener(listener, task: serverTask)
    }

    // MARK: S8 - connectParallel reports its summary even when connections fail

    @Test("connectParallel reports parallelConnectionDidComplete on failure (default strategy)")
    func connectParallelReportsSummaryOnFailureDefaultStrategy() async throws {
        let manager = ConnectionManager<ByteBuffer, ByteBuffer>()
        let metrics = MockConnectionManagerMetricsDelegate()
        await manager.setMetricsDelegate(metrics)
        let closedPort = try await reserveClosedPort()

        await #expect(throws: (any Error).self) {
            try await manager.connectParallel(
                to: [ServerLocation(host: "127.0.0.1", port: closedPort, enableTLS: false, cacheKey: "dead")],
                maxReconnectionAttempts: 1,
                timeout: .seconds(1))
        }
        #expect(metrics.parallelCompletions.count == 1)
        #expect(metrics.parallelCompletions.first?.failed == 1)
        #expect(metrics.parallelCompletions.first?.successful == 0)
        #expect(metrics.parallelCompletions.first?.totalAttempted == 1)
    }

    @Test("connectParallel reports parallelConnectionDidComplete (custom strategy)")
    func connectParallelReportsSummaryCustomStrategy() async throws {
        let manager = ConnectionManager<ByteBuffer, ByteBuffer>()
        let metrics = MockConnectionManagerMetricsDelegate()
        await manager.setMetricsDelegate(metrics)
        let closedPort = try await reserveClosedPort()

        await #expect(throws: (any Error).self) {
            try await manager.connectParallel(
                to: [ServerLocation(host: "127.0.0.1", port: closedPort, enableTLS: false, cacheKey: "dead")],
                maxReconnectionAttempts: 1,
                timeout: .seconds(1),
                retryStrategy: .fixed(delay: .milliseconds(10)))
        }
        #expect(metrics.parallelCompletions.count == 1)
        #expect(metrics.parallelCompletions.first?.failed == 1)
    }

    @Test("a cancelled future wait returns and closes a channel that connects later")
    func cancelledFutureWaitClosesALateChannel() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let promise = group.next().makePromise(of: Channel.self)
        let task = Task {
            try await CancellableFuture.resolveChannel(promise.futureResult)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        let server = try await bindRaw(host: "127.0.0.1", port: 0, group: group)
        let port = try #require(server.localAddress?.port)
        let client = try await connectRaw(host: "127.0.0.1", port: port, group: group)
        promise.succeed(client)

        #expect(await waitUntil(timeout: .seconds(2)) { !client.isActive })
        if client.isActive {
            try await client.close()
        }
        try await server.close()
    }

    /// Binds and immediately closes a listener so the port is known to be closed.
    private func reserveClosedPort() async throws -> Int {
        let server = try await bindRaw(host: "127.0.0.1", port: 0)
        let port = try #require(server.localAddress?.port)
        try await server.close()
        return port
    }
}
