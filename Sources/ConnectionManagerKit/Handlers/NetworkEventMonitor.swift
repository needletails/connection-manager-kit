//
//  NetworkEventMonitor.swift
//  connection-manager-kit
//
//  Created by Cole M on 12/2/24.
//
import NIOCore
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

public final class NetworkEventMonitor: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    
    private let didSetError = ManagedAtomic(false)
#if canImport(Network)
    var errorStream: AsyncStream<NWError>?
    private var errorContinuation: AsyncStream<NWError>.Continuation?
    var eventStream: AsyncStream<NetworkEvent>?
    private var eventContinuation: AsyncStream<NetworkEvent>.Continuation?
#else
    var errorStream: AsyncStream<IOError>?
    private var errorContinuation: AsyncStream<IOError>.Continuation?
    var eventStream: AsyncStream<NIOEvent>?
    private var eventContinuation: AsyncStream<NIOEvent>.Continuation?
#endif
    var channelActiveStream: AsyncStream<Void>?
    private var channelActiveContinuation: AsyncStream<Void>.Continuation?
    var channelInActiveStream: AsyncStream<Void>?
    private var channelInActiveContinuation: AsyncStream<Void>.Continuation?

    
    init() {
#if canImport(Network)
        errorStream = AsyncStream<NWError>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.errorContinuation = continuation
        }
        
        eventStream = AsyncStream<NetworkEvent>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.eventContinuation = continuation
        }
#else
        errorStream = AsyncStream<IOError>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.errorContinuation = continuation
        }
        
        eventStream = AsyncStream<NIOEvent>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.eventContinuation = continuation
        }
#endif
        channelActiveStream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.channelActiveContinuation = continuation
        }
        channelInActiveStream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.channelInActiveContinuation = continuation
        }
    }
    
    public func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.fireErrorCaught(error)
#if canImport(Network)
        let nwError = error as? NWError
        if nwError == .posix(.ENETDOWN) || nwError == .posix(.ENOTCONN), !didSetError.load(ordering: .acquiring) {
            didSetError.store(true, ordering: .relaxed)
            if let nwError = nwError {
                errorContinuation?.yield(nwError)
            } 
        }
#else 
    let error = error as? IOError
    if error?.errnoCode == ENETDOWN || error?.errnoCode == ENOTCONN, !didSetError.load(ordering: .acquiring) {
        didSetError.store(true, ordering: .relaxed)
        if let error: IOError = error {
                errorContinuation?.yield(error)
            } 
    }
#endif
    }
    
#if canImport(Network)
    public enum NetworkEvent: Sendable {
        case betterPathAvailable(NIOTSNetworkEvents.BetterPathAvailable)
        case betterPathUnavailable
        case viabilityChanged(NIOTSNetworkEvents.ViabilityUpdate)
        case connectToNWEndpoint(NIOTSNetworkEvents.ConnectToNWEndpoint)
        case bindToNWEndpoint(NIOTSNetworkEvents.BindToNWEndpoint)
        case waitingForConnectivity(NIOTSNetworkEvents.WaitingForConnectivity)
        case pathChanged(NIOTSNetworkEvents.PathChanged)
    }
#else
    public enum NIOEvent: @unchecked Sendable {
        case event(Any)
    }
#endif
    
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
            eventContinuation?.yield(eventType)
        }
#else
        eventContinuation?.yield(NIOEvent.event(event))
#endif
    }

    public func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        channelActiveContinuation?.yield()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        context.fireChannelInactive()
        channelInActiveContinuation?.yield()
    }
}
