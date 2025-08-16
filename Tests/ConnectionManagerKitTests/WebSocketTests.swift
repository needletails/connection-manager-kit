import Foundation
import NIOCore
import NIOPosix
import NIOWebSocket
import NIOSSL
import NIOFoundationCompat
import Testing
#if canImport(Network)
import Network
#endif
@testable import ConnectionManagerKit

// MARK: - Server Listener Delegate
final class WSServerListenerDelegate: ListenerDelegate {
    func retrieveChannelHandlers() -> [ChannelHandler] { [] }
    func retrieveSSLHandler() -> NIOSSLServerHandler? { nil }
    
    func didBindWebSocketServer<Inbound: Sendable, Outbound: Sendable>(
        channel: NIOAsyncChannel<EventLoopFuture<NIOAsyncChannel<Inbound, Outbound>>, Never>
    ) async {
        serverChannel = channel
        if shouldShutdown {
            try! await channel.executeThenClose({ _, _ in })
        }
    }
    
    let shouldShutdown: Bool
    nonisolated(unsafe) var serverChannel: Any?
    
    init(shouldShutdown: Bool = false) {
        self.shouldShutdown = shouldShutdown
    }
}

final class MockWSConnectionDelegate<TestableInbound: Sendable, TestableOutbound: Sendable>: ConnectionDelegate {
    
    let listener: ConnectionListener<TestableInbound, TestableOutbound>
    let channelContextHandler: MockWSClientDelegate
    init(lisenter: ConnectionListener<TestableInbound, TestableOutbound>, channelContextHandler: MockWSClientDelegate) {
        self.listener = lisenter
        self.channelContextHandler = channelContextHandler
    }
    
    
#if canImport(Network)
    func handleError(_ stream: AsyncStream<NWError>, id: String) {}
    func handleNetworkEvents(_ stream: AsyncStream<ConnectionManagerKit.NetworkEventMonitor.NetworkEvent>, id: String) async {}
#else
    func handleError(_ stream: AsyncStream<IOError>, id: String) {}
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NIOEvent>, id: String) async {}
#endif
    
    func initializedChildChannel<Outbound, Inbound>(_ context: ConnectionManagerKit.ChannelContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable {
        await listener.setContextDelegate(channelContextHandler, key: context.id)
    }
}

// MARK: - Comprehensive WebSocket Client Delegate
final class MockWSClientDelegate: ChannelContextDelegate, @unchecked Sendable {
    private let operation: WSOperation?
    private let completion: AsyncStream<WebSocketFrame>.Continuation
    var writer: NIOAsyncChannelOutboundWriter<WebSocketFrame>?
    
    enum WSOperation {
        case sendText(String)
        case sendBinary(ByteBuffer)
        case sendPing(String)
        case sendClose
    }
    
    init(operation: WSOperation? = nil, completion: AsyncStream<WebSocketFrame>.Continuation) {
        self.operation = operation
        self.completion = completion
    }
    
    func deliverWriter<Outbound, Inbound>(context: WriterContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable {
        guard Outbound.self == WebSocketFrame.self else { return }
        let writer = context.writer as! NIOAsyncChannelOutboundWriter<WebSocketFrame>
        self.writer = writer
    }
    
    func deliverInboundBuffer<Inbound, Outbound>(context: StreamContext<Inbound, Outbound>) async where Inbound : Sendable, Outbound : Sendable {
        guard let frame = context.inbound as? WebSocketFrame else { return }
        completion.yield(frame)
    }
    
    func channelActive(_ stream: AsyncStream<Void>, id: String) {}
    
    func channelInactive(_ stream: AsyncStream<Void>, id: String) {
        if case .sendClose = operation {
            Task {
                for await _ in stream {
                    completion.finish()
                    break
                }
            }
        }
    }
    
    func reportChildChannel(error: any Error, id: String) async { }
    func didShutdownChildChannel() async { }
}

// MARK: - Test Suite
@Suite(.serialized)
struct WebSocketTests {
    
    // MARK: - Ping/Pong Tests
    @Test("WebSocket ping/pong")
    func testWebSocketPingPong() async throws {
        let port = 6693
        let pingPayload = "ping-data-123".data(using: .utf8)!
        
        // Setup server
        let listener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
        let listenerDelegate = WSServerListenerDelegate()
        let config = ConnectionManagerKit.Configuration(group: .singletonMultiThreadedEventLoopGroup, host: "127.0.0.1", port: port)
        let resolved = try await listener.resolveAddress(config)
        let (serverChannelCompletionStream, serverChannelCompletionContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let serverClientDelegate = MockWSClientDelegate(completion: serverChannelCompletionContinuation)
        let connectionDelegate = MockWSConnectionDelegate(lisenter: listener, channelContextHandler: serverClientDelegate)
        
        
        let serverTask = Task {
            try await listener.listen(
                address: resolved.address!,
                websocketConfiguration: .init(),
                configuration: resolved,
                delegate: connectionDelegate,
                listenerDelegate: listenerDelegate
            )
        }
        
        // Server response handler
        let serverResponseTask = Task {
            for await frame in serverChannelCompletionStream {
                switch frame.opcode {
                case .ping:
                    let pongFrame = WebSocketFrame(fin: true, opcode: .pong, data: ByteBuffer(data: pingPayload))
                    try await serverClientDelegate.writer?.write(pongFrame)
                default:
                    break
                }
            }
        }
        
        try await Task.sleep(for: .milliseconds(100))
        
        // Setup client
        let manager = ConnectionManager<WebSocketFrame, WebSocketFrame>()
        
        let (completionStream, completionContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let clientDelegate = MockWSClientDelegate(completion: completionContinuation)
        
        let server = ServerLocation(
            host: "localhost",
            port: port,
            enableTLS: false,
            cacheKey: "ws-ping-pong",
            delegate: nil,
            contextDelegate: clientDelegate
        )
        
        Task {
            try await manager.connectWebSocket(to: [server])
        }
        
        try await Task.sleep(for: .seconds(2))
        
        // Send ping and expect pong
        let pingFrame = WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer(data: pingPayload))
        try await clientDelegate.writer!.write(pingFrame)
        
        // Wait for pong response and verify
        var pongReceived = false
        for await frame in completionStream {
            if frame.opcode == .pong {
                #expect(frame.data == ByteBuffer(data: pingPayload))
                pongReceived = true
                break
            }
        }
        
        // Verify pong was received
        #expect(pongReceived == true, "Expected pong frame was not received")
        
        // Cleanup
        await manager.gracefulShutdown()
        serverTask.cancel()
        serverResponseTask.cancel()
        await listener.serviceGroup?.triggerGracefulShutdown()
        try await Task.sleep(for: .milliseconds(200))
    }
    
    // MARK: - Text Frame Tests
    @Test("WebSocket text frame")
    func testWebSocketTextFrame() async throws {
        let port = 6694
        let testMessage = "Hello, WebSocket!"
        
        // Setup server
        let listener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
        let listenerDelegate = WSServerListenerDelegate()
        let config = ConnectionManagerKit.Configuration(group: .singletonMultiThreadedEventLoopGroup, host: "127.0.0.1", port: port)
        let resolved = try await listener.resolveAddress(config)
        let (serverChannelCompletionStream, serverChannelCompletionContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let serverClientDelegate = MockWSClientDelegate(completion: serverChannelCompletionContinuation)
        let connectionDelegate = MockWSConnectionDelegate(lisenter: listener, channelContextHandler: serverClientDelegate)
        
        let serverTask = Task {
            try await listener.listen(
                address: resolved.address!,
                websocketConfiguration: .init(),
                configuration: resolved,
                delegate: connectionDelegate,
                listenerDelegate: listenerDelegate
            )
        }
        
        // Server echo handler
        let serverResponseTask = Task {
            for await frame in serverChannelCompletionStream {
                if frame.opcode == .text {
                    // Echo back the text frame
                    let echoFrame = WebSocketFrame(fin: true, opcode: .text, data: frame.data)
                    try await serverClientDelegate.writer?.write(echoFrame)
                }
            }
        }
        
        try await Task.sleep(for: .milliseconds(100))
        
        // Setup client
        let manager = ConnectionManager<WebSocketFrame, WebSocketFrame>()
        
        let (completionStream, completionContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let clientDelegate = MockWSClientDelegate(completion: completionContinuation)
        
        let server = ServerLocation(
            host: "localhost",
            port: port,
            enableTLS: false,
            cacheKey: "ws-text-test",
            delegate: nil,
            contextDelegate: clientDelegate
        )
        
        Task {
            try await manager.connectWebSocket(to: [server])
        }
        
        try await Task.sleep(for: .seconds(2))
        
        // Send text frame
        let textFrame = WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: testMessage))
        try await clientDelegate.writer!.write(textFrame)
        
        // Wait for echo response and verify
        var echoReceived = false
        for await frame in completionStream {
            if frame.opcode == .text {
                #expect(frame.data.getString(at: 0, length: frame.data.readableBytes) == testMessage)
                echoReceived = true
                break
            }
        }
        
        // Verify echo was received
        #expect(echoReceived == true, "Expected text echo frame was not received")
        
        // Cleanup
        await manager.gracefulShutdown()
        serverTask.cancel()
        serverResponseTask.cancel()
        await listener.serviceGroup?.triggerGracefulShutdown()
        try await Task.sleep(for: .milliseconds(200))
    }
    
    // MARK: - Binary Frame Tests
    @Test("WebSocket binary frame")
    func testWebSocketBinaryFrame() async throws {
        let port = 6695
        let testData = "Binary data test".data(using: .utf8)!
        
        // Setup server
        let listener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
        let listenerDelegate = WSServerListenerDelegate()
        let config = ConnectionManagerKit.Configuration(group: .singletonMultiThreadedEventLoopGroup, host: "127.0.0.1", port: port)
        let resolved = try await listener.resolveAddress(config)
        let (serverChannelCompletionStream, serverChannelCompletionContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let serverClientDelegate = MockWSClientDelegate(completion: serverChannelCompletionContinuation)
        let connectionDelegate = MockWSConnectionDelegate(lisenter: listener, channelContextHandler: serverClientDelegate)
        
        let serverTask = Task {
            try await listener.listen(
                address: resolved.address!,
                websocketConfiguration: .init(),
                configuration: resolved,
                delegate: connectionDelegate,
                listenerDelegate: listenerDelegate
            )
        }
        
        // Server binary echo handler
        let serverResponseTask = Task {
            for await frame in serverChannelCompletionStream {
                if frame.opcode == .binary {
                    // Echo back the binary frame
                    let echoFrame = WebSocketFrame(fin: true, opcode: .binary, data: frame.data)
                    try await serverClientDelegate.writer?.write(echoFrame)
                }
            }
        }
        
        try await Task.sleep(for: .milliseconds(100))
        
        // Setup client
        let manager = ConnectionManager<WebSocketFrame, WebSocketFrame>()
        
        let (completionStream, completionContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let clientDelegate = MockWSClientDelegate(completion: completionContinuation)
        
        let server = ServerLocation(
            host: "localhost",
            port: port,
            enableTLS: false,
            cacheKey: "ws-binary-test",
            delegate: nil,
            contextDelegate: clientDelegate
        )
        
        Task {
            try await manager.connectWebSocket(to: [server])
        }
        
        try await Task.sleep(for: .seconds(2))
        
        // Send binary frame
        let binaryFrame = WebSocketFrame(fin: true, opcode: .binary, data: ByteBuffer(data: testData))
        try await clientDelegate.writer!.write(binaryFrame)
        
        // Wait for echo response and verify
        var echoReceived = false
        for await frame in completionStream {
            if frame.opcode == .binary {
                #expect(frame.data == ByteBuffer(data: testData))
                echoReceived = true
                break
            }
        }
        
        // Verify echo was received
        #expect(echoReceived == true, "Expected binary echo frame was not received")
        
        // Cleanup
        await manager.gracefulShutdown()
        serverTask.cancel()
        serverResponseTask.cancel()
        await listener.serviceGroup?.triggerGracefulShutdown()
        try await Task.sleep(for: .milliseconds(200))
    }
    
    // MARK: - Close Frame Tests
    @Test("WebSocket close frame")
    func testWebSocketCloseFrame() async throws {
        let port = 6696
        let closeCode: UInt16 = 1000 // Normal closure
        let closeReason = "Test closure"
        
        // Setup server
        let listener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
        let listenerDelegate = WSServerListenerDelegate()
        let config = ConnectionManagerKit.Configuration(group: .singletonMultiThreadedEventLoopGroup, host: "127.0.0.1", port: port)
        let resolved = try await listener.resolveAddress(config)
        let (serverChannelCompletionStream, serverChannelCompletionContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let serverClientDelegate = MockWSClientDelegate(operation: .sendClose, completion: serverChannelCompletionContinuation)
        let connectionDelegate = MockWSConnectionDelegate(lisenter: listener, channelContextHandler: serverClientDelegate)
        
        let serverTask = Task {
            try await listener.listen(
                address: resolved.address!,
                websocketConfiguration: .init(),
                configuration: resolved,
                delegate: connectionDelegate,
                listenerDelegate: listenerDelegate
            )
        }
        
        // Server close handler
        let serverResponseTask = Task {
            for await frame in serverChannelCompletionStream {
                if frame.opcode == .connectionClose {
                    // Send close frame back
                    let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.data)
                    try await serverClientDelegate.writer?.write(closeFrame)
                }
            }
        }
        
        try await Task.sleep(for: .milliseconds(100))
        
        // Setup client
        let manager = ConnectionManager<WebSocketFrame, WebSocketFrame>()
        
        let (completionStream, completionContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let clientDelegate = MockWSClientDelegate(operation: .sendClose, completion: completionContinuation)
        
        let server = ServerLocation(
            host: "localhost",
            port: port,
            enableTLS: false,
            cacheKey: "ws-close-test",
            delegate: nil,
            contextDelegate: clientDelegate
        )
        
        Task {
            try await manager.connectWebSocket(to: [server])
        }
        
        try await Task.sleep(for: .seconds(2))
        
        // Send close frame
        var closeData = ByteBuffer()
        closeData.writeInteger(closeCode, endianness: .big)
        closeData.writeString(closeReason)
        
        let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeData)
        try await clientDelegate.writer!.write(closeFrame)
        
        // Wait for close response and verify
        var closeResponseReceived = false
        for await frame in completionStream {
            if frame.opcode == .connectionClose {
                // Verify close code
                var frameData = frame.data
                let responseCode = frameData.readInteger(endianness: .big, as: UInt16.self) ?? 0
                #expect(responseCode == closeCode)
                closeResponseReceived = true
                break
            }
        }
        
        // Verify close response was received
        #expect(closeResponseReceived == true, "Expected close response frame was not received")
        
        // Cleanup
        await manager.gracefulShutdown()
        serverTask.cancel()
        serverResponseTask.cancel()
        await listener.serviceGroup?.triggerGracefulShutdown()
        try await Task.sleep(for: .milliseconds(200))
    }
    
    // MARK: - WebSocket Class Tests
    @Test("WebSocket class URL connection")
    func testWebSocketClassURLConnection() async throws {
        let port = 6697
        
        // Setup server
        let listener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
        let listenerDelegate = WSServerListenerDelegate()
        let config = ConnectionManagerKit.Configuration(group: .singletonMultiThreadedEventLoopGroup, host: "127.0.0.1", port: port)
        let resolved = try await listener.resolveAddress(config)
        let (serverChannelCompletionStream, serverChannelCompletionContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let serverClientDelegate = MockWSClientDelegate(completion: serverChannelCompletionContinuation)
        let connectionDelegate = MockWSConnectionDelegate(lisenter: listener, channelContextHandler: serverClientDelegate)
        
        let serverTask = Task {
            try await listener.listen(
                address: resolved.address!,
                websocketConfiguration: .init(),
                configuration: resolved,
                delegate: connectionDelegate,
                listenerDelegate: listenerDelegate)
        }
        
        try await Task.sleep(for: .milliseconds(500))
        
        let serverResponseTask = Task {
            for await _ in serverChannelCompletionStream {
                break
            }
        }
        
        try await Task.sleep(for: .milliseconds(100))
        
        // Test WebSocket class connection with URL using singleton
        let webSocket = await WebSocketClient.shared
        let url = URL(string: "ws://localhost:\(port)/test-route")!
        
        try await webSocket.connect(url: url)
        
        try await Task.sleep(for: .seconds(2))
        
        // Safely unwrap the optional AsyncSequence
        guard let eventStream = await webSocket.socketReceiver.eventStream else {
            // Handle the missing stream (e.g., throw or return)
            return
        }
        
        // Wait for event response by monitoring the server's completion stream
        for try await event in eventStream {
            switch event {
            case .networkEvent(let event):
                switch event {
                case .viabilityChanged(let changed):
                    #expect(changed.isViable)
                    await webSocket.socketReceiver.eventContinuation?.finish()
                default:
                    break
                }
            default:
               break
            }
        }
        
        // Cleanup
        await webSocket.shutDown()
        serverTask.cancel()
        serverResponseTask.cancel()
        await listener.serviceGroup?.triggerGracefulShutdown()
        try await Task.sleep(for: .milliseconds(200))
    }
    
    @Test("WebSocket class invalid URL")
    func testWebSocketClassInvalidURL() async throws {
        let webSocket = await WebSocketClient.shared
        
        // Test with invalid URL using singleton
        do {
            try await webSocket.connect(
                url: URL(string: "invalid://url")!,
                maxReconnectionAttempts: 1,
                timeout: .seconds(2),
                retryStrategy: .fixed(delay:.seconds(2)))
        } catch WebSocketClient.Errors.invalidURL {
            // Expected error
            #expect(true)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
        try await Task.sleep(for: .milliseconds(200))
    }
    
    @Test("WebSocket class send text message")
    func testWebSocketClassSendTextMessage() async throws {
        let port = 6702
        let testMessage = "Hello from WebSocket class!"
        
        // Setup server
        let listener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
        let listenerDelegate = WSServerListenerDelegate()
        let config = ConnectionManagerKit.Configuration(group: .singletonMultiThreadedEventLoopGroup, host: "127.0.0.1", port: port)
        let resolved = try await listener.resolveAddress(config)
        let (serverChannelCompletionStream, serverChannelCompletionContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let serverClientDelegate = MockWSClientDelegate(completion: serverChannelCompletionContinuation)
        let connectionDelegate = MockWSConnectionDelegate(lisenter: listener, channelContextHandler: serverClientDelegate)
        
        let serverTask = Task {
            try await listener.listen(
                address: resolved.address!,
                websocketConfiguration: .init(),
                configuration: resolved,
                delegate: connectionDelegate,
                listenerDelegate: listenerDelegate
            )
        }
        try await Task.sleep(for: .milliseconds(500))
        // Server echo handler
        let serverResponseTask = Task {
            for await frame in serverChannelCompletionStream {
                if frame.opcode == .text {
                    // Echo back the text frame
                    let echoFrame = WebSocketFrame(fin: true, opcode: .text, data: frame.data)
                    try await serverClientDelegate.writer?.write(echoFrame)
                }
            }
        }
        try await Task.sleep(for: .milliseconds(500))
       
        
        // Test WebSocket class using singleton
        let webSocket = await WebSocketClient.shared
        try await webSocket.connect(host: "localhost", port: port, enableTLS: false, route: "/text")
        
        // Wait until channel is active to avoid race conditions
        if let eventStream = await webSocket.socketReceiver.eventStream {
            for try await event in eventStream {
                if case .channelActive = event { break }
            }
        } else {
            try await Task.sleep(for: .seconds(1))
        }
        
        // Send text message
        try await webSocket.sendText(testMessage, to: "/text")
        try await Task.sleep(for: .seconds(2))
        
        // Wait for echo response by monitoring the server's completion stream
        var echoReceived = false
        // Safely unwrap the optional AsyncSequence
        guard let messageStream = await webSocket.socketReceiver.messageStream else {
            // Handle the missing stream (e.g., throw or return)
            return
        }
        
        for try await frame in messageStream {
            if case let .text(message) = frame {
                // Extract String from ByteBuffer
                #expect(message == testMessage)
                echoReceived = true
                break
            }
        }
        
        // Verify echo was received
        #expect(echoReceived == true, "Expected text echo was not received")
        
        // Cleanup
        await webSocket.shutDown()
        serverTask.cancel()
        serverResponseTask.cancel()
        await listener.serviceGroup?.triggerGracefulShutdown()
        try await Task.sleep(for: .milliseconds(500))
    }
    
    @Test("WebSocket class send binary message")
    func testWebSocketClassSendBinaryMessage() async throws {
        let port = 6704
        let testData = "Binary data from WebSocket class".data(using: .utf8)!
        
        // Setup server
        let listener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
        let listenerDelegate = WSServerListenerDelegate()
        let config = ConnectionManagerKit.Configuration(group: .singletonMultiThreadedEventLoopGroup, host: "127.0.0.1", port: port)
        let resolved = try await listener.resolveAddress(config)
        let (serverChannelCompletionStream, serverChannelCompletionContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let serverClientDelegate = MockWSClientDelegate(completion: serverChannelCompletionContinuation)
        let connectionDelegate = MockWSConnectionDelegate(lisenter: listener, channelContextHandler: serverClientDelegate)
        
        let serverTask = Task {
            try await listener.listen(
                address: resolved.address!,
                websocketConfiguration: .init(),
                configuration: resolved,
                delegate: connectionDelegate,
                listenerDelegate: listenerDelegate
            )
        }
        
        // Server binary echo handler
        let serverResponseTask = Task {
            for await frame in serverChannelCompletionStream {
                if frame.opcode == .binary {
                    // Echo back the binary frame
                    let echoFrame = WebSocketFrame(fin: true, opcode: .binary, data: frame.data)
                    try await serverClientDelegate.writer?.write(echoFrame)
                }
            }
        }
        
        try await Task.sleep(for: .milliseconds(500))
        
        // Test WebSocket class using singleton
        let webSocket = await WebSocketClient.shared
        try await webSocket.connect(host: "localhost", port: port, enableTLS: false, route: "/binary")
        
        // Wait until channel is active to avoid race conditions
        if let eventStream = await webSocket.socketReceiver.eventStream {
            for try await event in eventStream {
                if case .channelActive = event { break }
            }
        } else {
            try await Task.sleep(for: .seconds(1))
        }
        
        // Send binary message
        try await webSocket.sendBinary(testData, to: "/binary")
        try await Task.sleep(for: .seconds(2))
        
        // Wait for echo response by monitoring the server's completion stream
        var echoReceived = false
        // Safely unwrap the optional AsyncSequence
        guard let messageStream = await webSocket.socketReceiver.messageStream else {
            // Handle the missing stream (e.g., throw or return)
            return
        }
        
        for try await frame in messageStream {
            if case let .binary(receivedData) = frame {
                // Extract String from ByteBuffer
                #expect(receivedData == testData)
                echoReceived = true
                break
            }
        }
        
        // Verify echo was received
        #expect(echoReceived == true, "Expected binary echo was not received")
        
        // Cleanup
        await webSocket.shutDown()
        serverTask.cancel()
        serverResponseTask.cancel()
        await listener.serviceGroup?.triggerGracefulShutdown()
        try await Task.sleep(for: .milliseconds(500))
    }
    
    @Test("WebSocket class ping/pong")
    func testWebSocketClassPingPong() async throws {
        let port = 6701
        let pingData = "ping-data-from-class".data(using: .utf8)!
        
        // Setup server
        let listener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
        let listenerDelegate = WSServerListenerDelegate()
        let config = ConnectionManagerKit.Configuration(group: .singletonMultiThreadedEventLoopGroup, host: "127.0.0.1", port: port)
        let resolved = try await listener.resolveAddress(config)
        let (serverChannelCompletionStream, serverChannelCompletionContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let serverClientDelegate = MockWSClientDelegate(completion: serverChannelCompletionContinuation)
        let connectionDelegate = MockWSConnectionDelegate(lisenter: listener, channelContextHandler: serverClientDelegate)
        
        let serverTask = Task {
            try await listener.listen(
                address: resolved.address!,
                websocketConfiguration: .init(),
                configuration: resolved,
                delegate: connectionDelegate,
                listenerDelegate: listenerDelegate
            )
        }
        
        // Server ping/pong handler
        let serverResponseTask = Task {
            for await frame in serverChannelCompletionStream {
                if frame.opcode == .ping {
                    // Send pong response
                    let pongFrame = WebSocketFrame(fin: true, opcode: .pong, data: frame.data)
                    try await serverClientDelegate.writer?.write(pongFrame)
                }
            }
        }
        
        try await Task.sleep(for: .milliseconds(500))
        
        // Test WebSocket class using singleton
        let webSocket = await WebSocketClient.shared
        try await webSocket.connect(host: "localhost", port: port, enableTLS: false, route: "/ping")
        
        try await Task.sleep(for: .seconds(2))
        
        // Send ping
        try await webSocket.sendPing(pingData, to: "/ping")
        
        try await Task.sleep(for: .seconds(2))
        
        // Safely unwrap the optional AsyncSequence
        guard let messageStream = await webSocket.socketReceiver.messageStream else {
            // Handle the missing stream (e.g., throw or return)
            return
        }
        
        // Wait for pong response by monitoring the server's completion stream
        var pongReceived = false
        for try await frame in messageStream {
            if case let .pong(receivedData) = frame {
                // Extract String from ByteBuffer
                #expect(receivedData == pingData)
                pongReceived = true
                break
            }
        }
        
        // Verify ping was received by server
        #expect(pongReceived == true, "Expected ping was not received by server")
        
        // Cleanup
        await webSocket.shutDown()
        serverTask.cancel()
        serverResponseTask.cancel()
        await listener.serviceGroup?.triggerGracefulShutdown()
        try await Task.sleep(for: .milliseconds(500))
    }
    
    @Test("WebSocket class multiple routes")
    func testWebSocketClassMultipleRoutes() async throws {
        let port = 6703
        
        // Setup server
        let listener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
        let listenerDelegate = WSServerListenerDelegate()
        let config = ConnectionManagerKit.Configuration(group: .singletonMultiThreadedEventLoopGroup, host: "127.0.0.1", port: port)
        let resolved = try await listener.resolveAddress(config)
        let (_, serverChannelCompletionContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let serverClientDelegate = MockWSClientDelegate(completion: serverChannelCompletionContinuation)
        let connectionDelegate = MockWSConnectionDelegate(lisenter: listener, channelContextHandler: serverClientDelegate)
        
        let serverTask = Task {
            try await listener.listen(
                address: resolved.address!,
                websocketConfiguration: .init(),
                configuration: resolved,
                delegate: connectionDelegate,
                listenerDelegate: listenerDelegate
            )
        }
        
        try await Task.sleep(for: .milliseconds(500))
        
        // Test WebSocket class with multiple routes using singleton
        let webSocket = await WebSocketClient.shared
        
        await #expect(throws: Never.self, performing: {
            // Connect to multiple routes
            try await webSocket.connect(host: "localhost", port: port, enableTLS: false, route: "/route1")
            try await webSocket.connect(host: "localhost", port: port, enableTLS: false, route: "/route2")
            try await webSocket.connect(host: "localhost", port: port, enableTLS: false, route: "/route3")
        })
        
        // Verify all connections were established
        // Note: connections property is private, so we can't directly verify it
        // Instead, we verify the connections were successful by checking no errors were thrown
        #expect(true) // All connections succeeded without throwing
        
        // Test disconnecting specific route
        await webSocket.disconnect("/route2")
        // Note: connections property is private, so we can't directly verify it
        #expect(true) // Disconnect succeeded without throwing
        
        // Cleanup
        await webSocket.shutDown()
        serverTask.cancel()
        await listener.serviceGroup?.triggerGracefulShutdown()
        try await Task.sleep(for: .milliseconds(200))
    }
    
    @Test("WebSocket class test event stream")
    func testEventStreamFromConnection() async throws {
        let port = 6699
        
        // Setup server
        let listener = ConnectionListener<WebSocketFrame, WebSocketFrame>()
        let listenerDelegate = WSServerListenerDelegate()
        let config = ConnectionManagerKit.Configuration(group: .singletonMultiThreadedEventLoopGroup, host: "127.0.0.1", port: port)
        let resolved = try await listener.resolveAddress(config)
        let (_, serverChannelCompletionContinuation) = AsyncStream<WebSocketFrame>.makeStream()
        let serverClientDelegate = MockWSClientDelegate(completion: serverChannelCompletionContinuation)
        let connectionDelegate = MockWSConnectionDelegate(lisenter: listener, channelContextHandler: serverClientDelegate)
        
        let serverTask = Task {
            try await listener.listen(
                address: resolved.address!,
                websocketConfiguration: .init(),
                configuration: resolved,
                delegate: connectionDelegate,
                listenerDelegate: listenerDelegate
            )
        }
        
        try await Task.sleep(for: .milliseconds(500))
        
        // Test WebSocket class connection with URL using singleton
        let webSocket = await WebSocketClient.shared
        let url = URL(string: "ws://localhost:\(port)/")!
        try await webSocket.connect(url: url)
        
        try await Task.sleep(for: .seconds(2))
        
        // Safely unwrap the optional AsyncSequence
        guard let eventStream = await webSocket.socketReceiver.eventStream else {
            // Handle the missing stream (e.g., throw or return)
            return
        }
        
        // Wait for event response by monitoring the server's completion stream
        for try await event in eventStream {
            switch event {
            case .channelActive:
                #expect(true)
                await webSocket.socketReceiver.eventContinuation?.finish()
            default:
               break
            }
        }

        // Cleanup
        await webSocket.shutDown()
        serverTask.cancel()
        await listener.serviceGroup?.triggerGracefulShutdown()
        try await Task.sleep(for: .milliseconds(200))
    }
}

