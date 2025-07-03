//
//  NetworkEventMonitor.swift
//  connection-manager-kit
//
//  Created by Cole M on 12/2/24.
//
import NIOCore
import NIOConcurrencyHelpers
#if os(Linux)
import Glibc
#else
import System
#endif
import Atomics
#if canImport(Network)
import Network
import NIOTransportServices
#endif

/// A channel handler that monitors network events and connection state changes.
///
/// `NetworkEventMonitor` is responsible for detecting and reporting network-related
/// events such as connection errors, network viability changes, path changes, and
/// channel lifecycle events. It provides async streams for these events, allowing
/// applications to respond to network conditions in real-time.
///
/// ## Key Features
/// - **Network Event Monitoring**: Detects network viability, path changes, and connectivity issues
/// - **Error Detection**: Monitors for connection errors and network failures
/// - **Channel Lifecycle**: Tracks channel active/inactive state changes
/// - **Cross-Platform Support**: Works on Apple platforms and Linux with appropriate event types
/// - **Async Streams**: Provides async streams for continuous event monitoring
///
/// ## Usage Example
/// ```swift
/// // The monitor is automatically added to the channel pipeline
/// let monitor = NetworkEventMonitor(connectionIdentifier: "my-connection")
/// 
/// // Monitor network events
/// if let eventStream = monitor.eventStream {
///     for await event in eventStream {
///         switch event {
///         case .viabilityChanged(let update):
///             print("Network viability: \(update.isViable)")
///         case .betterPathAvailable(let path):
///             print("Better path available")
///         case .waitingForConnectivity(let error):
///             print("Waiting for connectivity: \(error)")
///         default:
///             break
///         }
///     }
/// }
/// 
/// // Monitor errors
/// if let errorStream = monitor.errorStream {
///     for await error in errorStream {
///         print("Network error: \(error)")
///     }
/// }
/// ```
///
/// - Note: This class is designed to be added to the NIO channel pipeline and will
///   automatically start monitoring events when the channel becomes active.
/// - Note: The monitor uses atomic operations to ensure thread safety when setting
///   error states to prevent duplicate error reporting.
public final class NetworkEventMonitor: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    
    /// A unique identifier for the connection being monitored.
    public let connectionIdentifier: String
    
    /// An atomic flag to prevent duplicate error reporting.
    private let didSetError = ManagedAtomic(false)
    
    /// A lock for synchronizing access to async stream continuations.
    private let lock = NIOLock()
    
#if canImport(Network)
    /// The async stream for network errors on Apple platforms.
    var errorStream: AsyncStream<NWError>?
    
    /// The continuation for the error stream on Apple platforms.
    private var errorContinuation: AsyncStream<NWError>.Continuation?
    
    /// The async stream for network events on Apple platforms.
    var eventStream: AsyncStream<NetworkEvent>?
    
    /// The continuation for the network event stream on Apple platforms.
    private var eventContinuation: AsyncStream<NetworkEvent>.Continuation?
#else
    /// The async stream for I/O errors on non-Apple platforms.
    var errorStream: AsyncStream<IOError>?
    
    /// The continuation for the error stream on non-Apple platforms.
    private var errorContinuation: AsyncStream<IOError>.Continuation?
    
    /// The async stream for NIO events on non-Apple platforms.
    var eventStream: AsyncStream<NIOEvent>?
    
    /// The continuation for the NIO event stream on non-Apple platforms.
    private var eventContinuation: AsyncStream<NIOEvent>.Continuation?
#endif
    
    /// The async stream for channel active events.
    var channelActiveStream: AsyncStream<Void>?
    
    /// The continuation for the channel active stream.
    private var channelActiveContinuation: AsyncStream<Void>.Continuation?
    
    /// The async stream for channel inactive events.
    var channelInactiveStream: AsyncStream<Void>?
    
    /// The continuation for the channel inactive stream.
    private var channelInactiveContinuation: AsyncStream<Void>.Continuation?

    /// Creates a new network event monitor.
    ///
    /// - Parameter connectionIdentifier: A unique identifier for the connection being monitored.
    ///
    /// ## Example
    /// ```swift
    /// let monitor = NetworkEventMonitor(connectionIdentifier: "api-server-1")
    /// ```
    init(connectionIdentifier: String) {
        self.connectionIdentifier = connectionIdentifier
#if canImport(Network)
        errorStream = AsyncStream<NWError>(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            guard let self else { return }
            self.errorContinuation = continuation
        }
        
        eventStream = AsyncStream<NetworkEvent>(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            guard let self else { return }
            self.eventContinuation = continuation
        }
#else
        errorStream = AsyncStream<IOError>(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            guard let self else { return }
            self.errorContinuation = continuation
        }
        
        eventStream = AsyncStream<NIOEvent>(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            guard let self else { return }
            self.eventContinuation = continuation
        }
#endif
        channelActiveStream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            guard let self else { return }
            self.channelActiveContinuation = continuation
        }
        channelInactiveStream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            guard let self else { return }
            self.channelInactiveContinuation = continuation
        }
    }
    
    /// Handles errors caught by the channel pipeline.
    ///
    /// This method is called when the channel encounters an error. It filters for
    /// specific network-related errors and reports them through the error stream.
    ///
    /// - Parameters:
    ///   - context: The channel handler context.
    ///   - error: The error that occurred.
    ///
    /// ## Example
    /// ```swift
    /// // Errors are automatically handled and reported through errorStream
    /// if let errorStream = monitor.errorStream {
    ///     for await error in errorStream {
    ///         switch error {
    ///         case .posix(.ECONNREFUSED):
    ///             print("Connection refused")
    ///         case .posix(.ENETDOWN):
    ///             print("Network is down")
    ///         case .dns(let code):
    ///             print("DNS error: \(code)")
    ///         default:
    ///             print("Other error: \(error)")
    ///         }
    ///     }
    /// }
    /// ```
    public func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.fireErrorCaught(error)
#if canImport(Network)
        let nwError = error as? NWError
        if nwError == .posix(.ENETDOWN) || nwError == .posix(.ENOTCONN), !didSetError.load(ordering: .acquiring) {
            didSetError.store(true, ordering: .relaxed)
            if let nwError = nwError {
                lock.withLock { [weak self] in
                    guard let self else { return }
                    self.errorContinuation?.yield(nwError)
                }
            } 
        }
#else 
    let error = error as? IOError
    if error?.errnoCode == ENETDOWN || error?.errnoCode == ENOTCONN, !didSetError.load(ordering: .acquiring) {
        didSetError.store(true, ordering: .relaxed)
        if let error: IOError = error {
            lock.withLock { [weak self] in
                guard let self else { return }
                self.errorContinuation?.yield(error)
            }
            }
    }
#endif
    }
    
#if canImport(Network)
    /// Network events that can occur on Apple platforms.
    ///
    /// These events provide information about network state changes, path availability,
    /// and connectivity status.
    public enum NetworkEvent: Sendable {
        /// A better network path has become available.
        case betterPathAvailable(NIOTSNetworkEvents.BetterPathAvailable)
        
        /// A previously available better network path is no longer available.
        case betterPathUnavailable
        
        /// The network viability has changed (e.g., network became available/unavailable).
        case viabilityChanged(NIOTSNetworkEvents.ViabilityUpdate)
        
        /// The system is attempting to connect to a Network framework endpoint.
        case connectToNWEndpoint(NIOTSNetworkEvents.ConnectToNWEndpoint)
        
        /// The system is attempting to bind to a Network framework endpoint.
        case bindToNWEndpoint(NIOTSNetworkEvents.BindToNWEndpoint)
        
        /// The system is waiting for connectivity to become available.
        case waitingForConnectivity(NIOTSNetworkEvents.WaitingForConnectivity)
        
        /// The network path has changed (e.g., switching from WiFi to cellular).
        case pathChanged(NIOTSNetworkEvents.PathChanged)
    }
#else
    /// NIO-specific events that can occur on non-Apple platforms.
    ///
    /// This enum provides a wrapper for NIO-specific events that may occur
    /// during network operations.
    public enum NIOEvent: @unchecked Sendable {
        /// A generic NIO event.
        case event(Any)
    }
#endif
    
    /// Handles user inbound events triggered by the channel.
    ///
    /// This method is called when the channel receives user-defined events,
    /// particularly network events on Apple platforms. It processes these events
    /// and reports them through the event stream.
    ///
    /// - Parameters:
    ///   - context: The channel handler context.
    ///   - event: The user inbound event that occurred.
    ///
    /// ## Example
    /// ```swift
    /// // Network events are automatically handled and reported through eventStream
    /// if let eventStream = monitor.eventStream {
    ///     for await event in eventStream {
    ///         switch event {
    ///         case .viabilityChanged(let update):
    ///             if update.isViable {
    ///                 print("Network is viable")
    ///             } else {
    ///                 print("Network is not viable")
    ///             }
    ///         case .betterPathAvailable(let path):
    ///             print("Better network path available")
    ///         case .waitingForConnectivity(let error):
    ///             print("Waiting for connectivity: \(error)")
    ///         case .pathChanged(let path):
    ///             print("Network path changed")
    ///         default:
    ///             break
    ///         }
    ///     }
    /// }
    /// ```
    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        context.fireUserInboundEventTriggered(event)
#if canImport(Network)
        guard let networkEvent = event as? any NIOTSNetworkEvent else {
            return
        }
        let eventType: NetworkEvent?
        switch networkEvent {
        case let event as NIOTSNetworkEvents.BetterPathAvailable:
            eventType = .betterPathAvailable(event)
        case is NIOTSNetworkEvents.BetterPathUnavailable:
            eventType = .betterPathUnavailable
        case let event as NIOTSNetworkEvents.ViabilityUpdate:
            eventType = .viabilityChanged(event)
        case let event as NIOTSNetworkEvents.ConnectToNWEndpoint:
            eventType = .connectToNWEndpoint(event)
        case let event as NIOTSNetworkEvents.BindToNWEndpoint:
            eventType = .bindToNWEndpoint(event)
        case let event as NIOTSNetworkEvents.WaitingForConnectivity:
            eventType = .waitingForConnectivity(event)
        case let event as NIOTSNetworkEvents.PathChanged:
            eventType = .pathChanged(event)
        default:
            eventType = nil
        }
       
        if let eventType = eventType {
            lock.withLock { [weak self] in
                guard let self else { return }
                self.eventContinuation?.yield(eventType)
            }
        }
#else
        lock.withLock { [weak self] in
            guard let self else { return }
            self.eventContinuation?.yield(NIOEvent.event(event))
        }
#endif
    }

    /// Called when the channel becomes active and ready for communication.
    ///
    /// This method is called when the channel transitions to an active state.
    /// It reports this event through the channel active stream.
    ///
    /// - Parameter context: The channel handler context.
    ///
    /// ## Example
    /// ```swift
    /// // Channel active events are automatically reported
    /// if let channelActiveStream = monitor.channelActiveStream {
    ///     for await _ in channelActiveStream {
    ///         print("Channel \(monitor.connectionIdentifier) is now active")
    ///     }
    /// }
    /// ```
    public func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        lock.withLock { [weak self] in
            guard let self else { return }
            self.channelActiveContinuation?.yield()
        }
    }

    /// Called when the channel becomes inactive and is no longer available for communication.
    ///
    /// This method is called when the channel transitions to an inactive state,
    /// typically due to disconnection or shutdown.
    ///
    /// - Parameter context: The channel handler context.
    ///
    /// ## Example
    /// ```swift
    /// // Channel inactive events are automatically reported
    /// if let channelInactiveStream = monitor.channelInactiveStream {
    ///     for await _ in channelInactiveStream {
    ///         print("Channel \(monitor.connectionIdentifier) is now inactive")
    ///     }
    /// }
    /// ```
    public func channelInactive(context: ChannelHandlerContext) {
        context.fireChannelInactive()
        lock.withLock { [weak self] in
            guard let self else { return }
            self.channelInactiveContinuation?.yield()
        }
    }
}
