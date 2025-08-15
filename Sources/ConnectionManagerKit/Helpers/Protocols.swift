//
//  Protocols.swift
//  connection-manager-kit
//
//  Created by Cole M on 12/2/24.
//
import Foundation
import NIOCore
import NIOSSL
#if canImport(Network)
import Network
#endif

/// A protocol for handling child channel service lifecycle events.
///
/// This protocol defines the interface for objects that need to be notified when
/// child channels are initialized. It's used internally by the connection manager
/// to coordinate channel lifecycle events.
///
/// ## Usage Example
/// ```swift
/// class MyChildChannelServiceDelegate: ChildChannelServiceDelegate {
///     func initializedChildChannel<Outbound, Inbound>(_ context: ChannelContext<Inbound, Outbound>) async {
///         // Handle the newly initialized child channel
///         print("Child channel initialized with ID: \(context.id)")
///     }
/// }
/// ```
protocol ChildChannelServiceDelegate: Sendable {
    /// Called when a child channel has been initialized and is ready for use.
    ///
    /// - Parameter context: The channel context containing the initialized channel and its metadata.
    func initializedChildChannel<Outbound: Sendable, Inbound: Sendable>(_ context: ChannelContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable
}

/// A protocol for handling connection-level events and network state changes.
///
/// This protocol defines the interface for objects that need to respond to connection
/// events, network state changes, and errors. It's the primary interface for
/// implementing custom connection behavior.
///
/// ## Usage Example
/// ```swift
/// class MyConnectionDelegate: ConnectionDelegate {
///     func handleError(_ stream: AsyncStream<NWError>, id: String) {
///         Task {
///             for await error in stream {
///                 print("Connection error for \(id): \(error)")
///             }
///         }
///     }
///     
///     func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
///         for await event in stream {
///             switch event {
///             case .viabilityChanged(let update):
///                 print("Network viability changed: \(update.isViable)")
///             case .betterPathAvailable(let path):
///                 print("Better network path available")
///             default:
///                 break
///             }
///         }
///     }
///     
///     func initializedChildChannel<Outbound, Inbound>(_ context: ChannelContext<Inbound, Outbound>) async {
///         print("Child channel initialized: \(context.id)")
///     }
/// }
/// ```
public protocol ConnectionDelegate: AnyObject, Sendable {
    #if canImport(Network)
    /// Handles network errors that occur on the connection.
    ///
    /// This method is called when network errors are detected. The errors are provided
    /// as an async stream, allowing for continuous monitoring of error conditions.
    ///
    /// - Parameters:
    ///   - stream: An async stream of `NWError` instances representing network errors.
    ///   - id: The unique identifier of the connection that experienced the error.
    func handleError(_ stream: AsyncStream<NWError>, id: String)
    
    /// Handles network events and state changes.
    ///
    /// This method is called when network events occur, such as path changes,
    /// viability updates, or connectivity changes. The events are provided as an
    /// async stream for continuous monitoring.
    ///
    /// - Parameters:
    ///   - stream: An async stream of `NetworkEventMonitor.NetworkEvent` instances.
    ///   - id: The unique identifier of the connection that generated the event.
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async
    #else
    /// Handles I/O errors that occur on the connection.
    ///
    /// This method is called when I/O errors are detected on non-Apple platforms.
    /// The errors are provided as an async stream for continuous monitoring.
    ///
    /// - Parameters:
    ///   - stream: An async stream of `IOError` instances representing I/O errors.
    ///   - id: The unique identifier of the connection that experienced the error.
    func handleError(_ stream: AsyncStream<IOError>, id: String)
    
    /// Handles NIO-specific network events.
    ///
    /// This method is called when NIO-specific events occur on non-Apple platforms.
    /// The events are provided as an async stream for continuous monitoring.
    ///
    /// - Parameters:
    ///   - stream: An async stream of `NetworkEventMonitor.NIOEvent` instances.
    ///   - id: The unique identifier of the connection that generated the event.
    func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NIOEvent>, id: String) async
    #endif
    
    /// Called when a child channel has been initialized and is ready for use.
    ///
    /// This method is called when a new child channel is created and initialized.
    /// It provides an opportunity to set up any channel-specific handlers or
    /// perform initialization tasks.
    ///
    /// - Parameter context: The channel context containing the initialized channel and its metadata.
    func initializedChildChannel<Outbound, Inbound>(_ context: ChannelContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable
}

/// A protocol for handling channel context events and data flow.
///
/// This protocol defines the interface for objects that need to respond to channel
/// lifecycle events, data reception, and channel state changes. It's used for
/// implementing custom data processing and channel management logic.
///
/// ## Usage Example
/// ```swift
/// class MyChannelContextDelegate: ChannelContextDelegate {
///     func channelActive(_ stream: AsyncStream<Void>, id: String) {
///         Task {
///             for await _ in stream {
///                 print("Channel \(id) became active")
///             }
///         }
///     }
///     
///     func channelInactive(_ stream: AsyncStream<Void>, id: String) {
///         Task {
///             for await _ in stream {
///                 print("Channel \(id) became inactive")
///             }
///         }
///     }
///     
///     func deliverWriter<Outbound, Inbound>(context: WriterContext<Inbound, Outbound>) async {
///         // Store the writer for later use
///         writers[context.id] = context.writer
///     }
///     
///     func deliverInboundBuffer<Inbound, Outbound>(context: StreamContext<Inbound, Outbound>) async {
///         // Process the received data
///         await processData(context.inbound, from: context.id)
///     }
/// }
/// ```
public protocol ChannelContextDelegate: AnyObject, Sendable {
    /// Called when a channel becomes active and ready for communication.
    ///
    /// This method is called when a channel transitions to an active state and
    /// is ready to send and receive data. The event is provided as an async stream
    /// for continuous monitoring.
    ///
    /// - Parameters:
    ///   - stream: An async stream that yields when the channel becomes active.
    ///   - id: The unique identifier of the channel that became active.
    func channelActive(_ stream: AsyncStream<Void>, id: String)
    
    /// Called when a channel becomes inactive and is no longer available for communication.
    ///
    /// This method is called when a channel transitions to an inactive state,
    /// typically due to disconnection or shutdown. The event is provided as an
    /// async stream for continuous monitoring.
    ///
    /// - Parameters:
    ///   - stream: An async stream that yields when the channel becomes inactive.
    ///   - id: The unique identifier of the channel that became inactive.
    func channelInactive(_ stream: AsyncStream<Void>, id: String)
    
    /// Called when an error occurs on a child channel.
    ///
    /// This method is called when an error is detected on a child channel,
    /// providing an opportunity to handle the error appropriately.
    ///
    /// - Parameters:
    ///   - error: The error that occurred on the child channel.
    ///   - id: The unique identifier of the channel that experienced the error.
    func reportChildChannel(error: any Error, id: String) async
    
    /// Called when a child channel has been shut down.
    ///
    /// This method is called when a child channel has been completely shut down
    /// and is no longer available for use.
    func didShutdownChildChannel() async
    
    /// Delivers a writer context for sending data through a channel.
    ///
    /// This method is called when a writer becomes available for a channel,
    /// providing an opportunity to store or use the writer for sending data.
    ///
    /// - Parameter context: The writer context containing the channel and its writer.
    func deliverWriter<Outbound, Inbound>(context: WriterContext<Inbound, Outbound>) async
    
    /// Delivers inbound data received through a channel.
    ///
    /// This method is called when data is received through a channel,
    /// providing an opportunity to process the received data.
    ///
    /// - Parameter context: The stream context containing the received data and channel information.
    func deliverInboundBuffer<Inbound: Sendable, Outbound: Sendable>(context: StreamContext<Inbound, Outbound>) async
}

// MARK: - Server Side Protocols

/// A protocol for handling server-side listener events and configuration.
///
/// This protocol defines the interface for objects that need to respond to server
/// binding events and provide server-specific configuration. It's used for
/// implementing custom server behavior.
///
/// ## Usage Example
/// ```swift
/// class MyListenerDelegate: ListenerDelegate {
///     func didBindServer<Inbound, Outbound>(channel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>) async {
///         print("Server successfully bound and is listening for connections")
///     }
///     
///     func retrieveSSLHandler() -> NIOSSLServerHandler? {
///         // Return SSL handler for secure connections
///         return try? NIOSSLServerHandler(context: sslContext)
///     }
///     
///     func retrieveChannelHandlers() -> [ChannelHandler] {
///         return [MyCustomHandler()]
///     }
/// }
/// ```
public protocol ListenerDelegate: AnyObject, Sendable, TCPListenerDelegate, WebSocketListenerDelegate {
    /// Called when the server has successfully bound to its address and is listening for connections.
    ///
    /// This method is called when the server has been successfully set up and is
    /// ready to accept incoming connections.
    ///
    /// - Parameter channel: The server channel that is now listening for connections.
    @available(*, deprecated, renamed: "didBindTCPServer")
    func didBindServer<Inbound: Sendable, Outbound: Sendable>(channel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>) async
    
    /// Retrieves an SSL handler for secure connections.
    ///
    /// This method should return an SSL handler if the server should support
    /// secure connections. Return `nil` if SSL is not required.
    ///
    /// - Returns: An SSL handler for secure connections, or `nil` if SSL is not required.
    nonisolated func retrieveSSLHandler() -> NIOSSLServerHandler?
    
    /// Retrieves custom channel handlers for the server.
    ///
    /// This method should return any custom channel handlers that should be
    /// added to the server's channel pipeline.
    ///
    /// - Returns: An array of channel handlers to add to the server pipeline.
    nonisolated func retrieveChannelHandlers() -> [ChannelHandler]
}

// TCP-specific delegate
public protocol TCPListenerDelegate {
    func didBindTCPServer<Inbound: Sendable, Outbound: Sendable>(
        channel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>
    ) async
}

// WebSocket-specific delegate
public protocol WebSocketListenerDelegate {
    func didBindWebSocketServer<Inbound: Sendable, Outbound: Sendable>(
        channel: NIOAsyncChannel<EventLoopFuture<NIOAsyncChannel<Inbound, Outbound>>, Never>
    ) async
}

extension TCPListenerDelegate{
    func didBindTCPServer<Inbound: Sendable, Outbound: Sendable>(
        channel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>
    ) async {}
}
extension WebSocketListenerDelegate{
    func didBindWebSocketServer<Inbound: Sendable, Outbound: Sendable>(
        channel: NIOAsyncChannel<EventLoopFuture<NIOAsyncChannel<Inbound, Outbound>>, Never>
    ) async {}
}
extension ListenerDelegate {
    func didBindServer<Inbound: Sendable, Outbound: Sendable>(channel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>) async {}
}

/// A protocol for handling service listener events and configuration.
///
/// This protocol is used internally by the server service to coordinate
/// listener events and configuration. It's similar to `ListenerDelegate`
/// but is used in a different context.
///
/// ## Usage Example
/// ```swift
/// class MyServiceListenerDelegate: ServiceListenerDelegate {
///     func retrieveSSLHandler() -> NIOSSLServerHandler? {
///         return try? NIOSSLServerHandler(context: sslContext)
///     }
///     
///     func retrieveChannelHandlers() -> [ChannelHandler] {
///         return [MyCustomHandler()]
///     }
/// }
/// ```
protocol ServiceListenerDelegate: AnyObject {
    /// Retrieves an SSL handler for secure connections.
    ///
    /// - Returns: An SSL handler for secure connections, or `nil` if SSL is not required.
    func retrieveSSLHandler() -> NIOSSLServerHandler?
    
    /// Retrieves custom channel handlers for the service.
    ///
    /// - Returns: An array of channel handlers to add to the service pipeline.
    func retrieveChannelHandlers() -> [ChannelHandler]
}
