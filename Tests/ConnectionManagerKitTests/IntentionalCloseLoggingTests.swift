//
//  IntentionalCloseLoggingTests.swift
//  connection-manager-kit
//
//  Regression: when the listener closes a TLS child itself (`shutdownChildChannel`,
//  the server's QUIT / keepalive-deadline path), the peer often answers the
//  close_notify with a bare TCP FIN. NIOSSL then raises `uncleanShutdown` after the
//  context delegate has already been removed, and the listener logged both
//  "No context delegate for child channel; dropping error" and
//  "Child channel … failed: uncleanShutdown" at error level for an expected close.
//  Those lines are now debug; a peer-initiated drop still reports as before.
//

import Testing
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import NIOConcurrencyHelpers
import NeedleTailLogger
import Crypto
@testable import ConnectionManagerKit

// MARK: - Helpers

/// swift-log backend that keeps every line so a test can assert on levels.
private final class LogRecorder: @unchecked Sendable {
    struct Entry: Sendable {
        let level: Logger.Level
        let message: String
    }
    private let entries = NIOLockedValueBox<[Entry]>([])

    func record(_ level: Logger.Level, _ message: String) {
        entries.withLockedValue { $0.append(Entry(level: level, message: message)) }
    }

    var all: [Entry] { entries.withLockedValue { $0 } }

    func entries(atLeast level: Logger.Level) -> [Entry] {
        all.filter { $0.level >= level }
    }

    /// `NeedleTailLogger` wraps long lines at 80 columns; compare on unwrapped text.
    func contains(_ fragment: String) -> Bool {
        all.contains { $0.message.replacingOccurrences(of: "\n", with: " ").contains(fragment) }
    }

    func waitFor(_ fragment: String, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !contains(fragment) {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return contains(fragment)
    }

    func makeNeedleTailLogger() -> NeedleTailLogger {
        let logger = Logger(label: "[test.listener]") { _ in RecordingLogHandler(recorder: self) }
        return NeedleTailLogger(logger, level: .trace)
    }
}

private struct RecordingLogHandler: LogHandler {
    let recorder: LogRecorder
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        recorder.record(level, message.description)
    }
}

/// Server-side context delegate that remembers the child id and reported errors.
private final class ObservingContextDelegate: ChannelContextDelegate, @unchecked Sendable {
    private let state = NIOLockedValueBox<(id: String?, inbound: Int, errors: [String], didShutdown: Bool)>(
        (nil, 0, [], false))

    var childId: String? { state.withLockedValue { $0.id } }
    var reportedErrors: [String] { state.withLockedValue { $0.errors } }
    var didShutdown: Bool { state.withLockedValue { $0.didShutdown } }

    func reportChildChannel(error: any Error, id: String) async {
        state.withLockedValue { $0.errors.append(String(describing: error)) }
    }
    func didShutdownChildChannel() async {
        state.withLockedValue { $0.didShutdown = true }
    }
    func channelActive(_ stream: AsyncStream<Void>, id: String) {}
    func channelInactive(_ stream: AsyncStream<Void>, id: String) {}
    func deliverWriter<Outbound, Inbound>(context: WriterContext<Inbound, Outbound>) async {
        state.withLockedValue { $0.id = context.id }
    }
    func deliverInboundBuffer<Inbound: Sendable, Outbound: Sendable>(context: StreamContext<Inbound, Outbound>) async {
        state.withLockedValue { $0.inbound += 1 }
    }

    /// The first decrypted frame proves the TLS handshake finished on both sides.
    func waitForInbound(timeout: Duration = .seconds(10)) async -> String? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let (id, inbound) = state.withLockedValue { ($0.id, $0.inbound) }
            if let id, inbound > 0 { return id }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    func waitForShutdown(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !didShutdown {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return didShutdown
    }

    func waitForReportedError(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, reportedErrors.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return !reportedErrors.isEmpty
    }
}

/// Sits in front of the client's `NIOSSLClientHandler`. Once armed, the next bytes
/// from the server (its close_notify) close the raw socket without a TLS reply, which
/// is what a backgrounded iOS client does. `closeNow` drops the socket on demand.
private final class AbruptCloser: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let armed = NIOLockedValueBox(false)

    func arm() { armed.withLockedValue { $0 = true } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if armed.withLockedValue({ $0 }) {
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(data)
    }

    static func closeNow(_ channel: Channel) {
        channel.pipeline.context(handlerType: AbruptCloser.self).whenSuccess { context in
            context.close(promise: nil)
        }
    }
}

private func makePSKClientSSLHandler() throws -> NIOSSLClientHandler {
    let credentials = retrievePSKCredentials()
    var tls = TLSConfiguration.makePreSharedKeyConfiguration()
    tls.cipherSuiteValues = [.TLS_ECDHE_PSK_WITH_AES_256_CBC_SHA]
    tls.maximumTLSVersion = .tlsv12
    tls.pskHint = credentials.hint
    tls.pskClientProvider = { _ in
        var psk = NIOSSLSecureBytes()
        let key = SymmetricKey(data: Data(credentials.key.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(credentials.hint.utf8), using: key)
        psk.append(code.withUnsafeBytes { Data($0) })
        return PSKClientIdentityResponse(key: psk, identity: "clientIdentity")
    }
    let context = try NIOSSLContext(configuration: tls)
    return try NIOSSLClientHandler(context: context, serverHostname: nil)
}

/// One three-byte length-prefixed frame, matching `ListenerDelegation.retrieveChannelHandlers()`.
private func lengthPrefixedFrame(_ text: String) -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count + 3)
    buffer.writeInteger(UInt8(0))
    buffer.writeInteger(UInt16(text.utf8.count))
    buffer.writeString(text)
    return buffer
}

private struct TLSListenerFixture {
    let recorder: LogRecorder
    let listener: ConnectionListener<ByteBuffer, ByteBuffer>
    let listenerDelegation: ListenerDelegation
    let context: ObservingContextDelegate
    let serverTask: Task<Void, any Error>
    let port: Int
    let client: Channel
    let closer: AbruptCloser
    let childId: String

    static func start() async throws -> TLSListenerFixture {
        let recorder = LogRecorder()
        let listener = ConnectionListener<ByteBuffer, ByteBuffer>(logger: recorder.makeNeedleTailLogger())
        let listenerDelegation = ListenerDelegation(shouldShutdown: false)
        let context = ObservingContextDelegate()
        let serverConformer = MockConnectionDelegate<ByteBuffer, ByteBuffer>(
            listener: listener,
            serverClientContextDelegate: context,
            listenerDelegation: listenerDelegation)
        let serverTask = Task {
            let config = try await listener.resolveAddress(
                .init(group: MultiThreadedEventLoopGroup.singleton, host: "localhost", port: 0))
            try await listener.listen(
                address: config.address!,
                configuration: config,
                delegate: serverConformer,
                listenerDelegate: listenerDelegation)
        }
        let port = try #require(await listenerDelegation.waitForBoundPort())

        let closer = AbruptCloser()
        let client = try await connectRaw(host: "localhost", port: port) { [closer] in
            // Only throws on a broken test setup (fixed PSK credentials).
            [closer, try! makePSKClientSSLHandler()]
        }
        try await client.writeAndFlush(lengthPrefixedFrame("hello")).get()
        let childId = try #require(await context.waitForInbound(), "TLS handshake and first frame must reach the server")

        return TLSListenerFixture(
            recorder: recorder, listener: listener, listenerDelegation: listenerDelegation,
            context: context, serverTask: serverTask, port: port, client: client,
            closer: closer, childId: childId)
    }

    func stop() async {
        _ = try? await client.close().get()
        try? await listener.shutdown()
        await listener.serviceGroup?.triggerGracefulShutdown()
        serverTask.cancel()
    }
}

// MARK: - Tests

@Suite(.serialized)
struct IntentionalCloseLoggingTests {

    @Test("Listener-initiated close answered by a bare FIN logs nothing at error level")
    func listenerInitiatedCloseIsQuiet() async throws {
        let fixture = try await TLSListenerFixture.start()
        defer { Task { await fixture.stop() } }

        // The peer will answer our close_notify by dropping the socket (no TLS reply).
        fixture.closer.arm()
        await fixture.listener.shutdownChildChannel(id: fixture.childId)

        // `shutdownChildChannel` removed the delegate, so it hears nothing more; the run
        // loop's exit is only visible in the listener log.
        let ended = await fixture.recorder.waitFor("ended after listener-initiated close")
        #expect(ended, "the unclean TLS shutdown is recorded, at debug: \(fixture.recorder.all.map { "\($0.level) \($0.message)" })")

        let loud = fixture.recorder.entries(atLeast: .warning)
        #expect(loud.isEmpty, "unexpected warning/error lines: \(loud.map(\.message))")
        #expect(!fixture.recorder.contains("failed: uncleanShutdown"))
        #expect(fixture.context.reportedErrors.isEmpty, "the removed delegate is not reported to")
        let serviceErrors = fixture.recorder.all.filter { $0.message.contains("No context delegate") }
        #expect(serviceErrors.allSatisfy { $0.level == .debug }, "\(serviceErrors)")
    }

    @Test("Peer-initiated drop still reports the error to the delegate")
    func peerInitiatedDropStillReports() async throws {
        let fixture = try await TLSListenerFixture.start()
        defer { Task { await fixture.stop() } }

        // Nobody asked the listener to close; the peer vanishes mid-session.
        AbruptCloser.closeNow(fixture.client)

        #expect(await fixture.context.waitForReportedError(), "delegate must hear about the drop")
        #expect(fixture.context.reportedErrors.contains { $0.contains("uncleanShutdown") })
        #expect(await fixture.context.waitForShutdown())
        #expect(await fixture.recorder.waitFor("failed: uncleanShutdown"),
                "a drop the listener did not initiate keeps its error-level line")
        #expect(!fixture.recorder.contains("ended after listener-initiated close"))
    }
}
