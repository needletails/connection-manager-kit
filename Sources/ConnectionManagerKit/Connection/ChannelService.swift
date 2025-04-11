//
//  ChannelService.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/27/24.
//
import Foundation
import NIOCore
#if canImport(Network)
import Network
#endif
import ServiceLifecycle

public actor ChildChannelService<Inbound: Sendable, Outbound: Sendable>: Service {

    public var config: ServerLocation
    let childChannel: NIOAsyncChannel<Inbound, Outbound>?
    let delegate: ChildChannelServiceDelelgate
    private var connectionDelegate: ConnectionDelegate?
    private var contextDelegate: ChannelContextDelegate?
    var continuation: AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.Continuation?
    var inboundContinuation: AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.Continuation?
    
    public func setConfig(_ config: ServerLocation) async {
        self.config = config
        self.contextDelegate = config.contextDelegate
        self.connectionDelegate = config.delegate
    }
    
    init(
        config: ServerLocation,
        childChannel: NIOAsyncChannel<Inbound, Outbound>?,
        delegate: ChildChannelServiceDelelgate
    ) {
        self.config = config
        self.childChannel = childChannel
        self.delegate = delegate
        self.connectionDelegate = config.delegate
        self.contextDelegate = config.contextDelegate
    }
    
    public
    func run() async throws {
        try await exectuteTask()
    }
    
    nonisolated private func exectuteTask() async throws {
        guard let childChannel = childChannel else { return }
        try await withThrowingDiscardingTaskGroup { group in
            try await childChannel.executeThenClose { [weak self] inbound, outbound in
                guard let self else { return }
                
                let channelId = await config.cacheKey
                let channelContext = ChannelContext<Inbound, Outbound>(
                    id: channelId,
                    channel: childChannel
                )
                
                await delegate.initializedChildChannel(channelContext)
                
                let (_inbound, _outbound) = await setUpStreams(
                    inbound: inbound,
                    outbound: outbound
                )
                
                group.addTask { [weak self] in
                    guard let self else { return }
                    for await writer in _outbound {
                        let writerContext = WriterContext(
                            id: channelId,
                            channel: childChannel,
                            writer: writer)
                        await contextDelegate?.deliverWriter(context: writerContext)
                    }
                }
                
                for await stream in _inbound {
                    //We need to make sure that the sequence is canceled when we finish the stream
                    for try await inbound in stream.cancelOnGracefulShutdown() {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            let streamContext = StreamContext<Inbound, Outbound>(
                                id: channelId,
                                channel: childChannel,
                                inbound: inbound
                            )
                            await contextDelegate?.deliverInboundBuffer(context: streamContext)
                        }
                    }
                }
            }
        }
    }
    
    private func setUpStreams(
        inbound: NIOAsyncChannelInboundStream<Inbound>,
        outbound: NIOAsyncChannelOutboundWriter<Outbound>
    ) -> (AsyncStream<NIOAsyncChannelInboundStream<Inbound>>, AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>) {
        // set up async streams and handle data
        let _outbound = AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>> { continuation in
            continuation.yield(outbound)
            self.continuation = continuation
            
            continuation.onTermination = { status in
#if DEBUG
                print("Writer Stream Terminated with status: \(status)")
#endif
            }
        }
        
        let _inbound = AsyncStream<NIOAsyncChannelInboundStream<Inbound>> { continuation in
            continuation.yield(inbound)
            self.inboundContinuation = continuation
            
            continuation.onTermination = { status in
#if DEBUG
                print("Inbound Stream Terminated with status: \(status)")
#endif
            }
        }
        return (_inbound, _outbound)
    }
    
    func shutdown() async throws {
        if let inboundContinuation, let continuation {
            inboundContinuation.finish()
            continuation.finish()
        } else {
            try await childChannel?.executeThenClose { inbound, outbound in
                outbound.finish()
            }
        }
    }
}
