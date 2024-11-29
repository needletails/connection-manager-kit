//
//  ChannelService.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/27/24.
//
import NIOCore
#if canImport(Network)
import Network
#endif
import ServiceLifecycle

protocol ChildChannelServiceDelelgate: Sendable {
    func configureChildChannel() async
    func shutdownChildConfiguration() async
    func reportChildChannel(error: Error) async
    func deliverWriter<Outbound: Sendable>(writer: NIOAsyncChannelOutboundWriter<Outbound>) async
    func deliverInboundBuffer<Inbound: Sendable>(inbound: Inbound) async
}

extension ChildChannelServiceDelelgate {
    func configureChildChannel() async {}
    func shutdownChildConfiguration() async {}
}

actor ChildChannelService<Inbound: Sendable, Outbound: Sendable>: Service {
    
    let config: ServerLocation
    let childChannel: NIOAsyncChannel<Inbound, Outbound>?
    let delegate: ChildChannelServiceDelelgate
    var continuation: AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>.Continuation?
    var inboundContinuation: AsyncStream<NIOAsyncChannelInboundStream<Inbound>>.Continuation?
    
    
    init(
        config: ServerLocation,
        childChannel: NIOAsyncChannel<Inbound, Outbound>?,
        delegate: ChildChannelServiceDelelgate
    ) {
        self.config = config
        self.childChannel = childChannel
        self.delegate = delegate
    }
    
    func run() async throws {
        try await exectuteTask()
    }
    
    nonisolated private func exectuteTask() async throws {
        guard let childChannel = childChannel else { return }
        try await withThrowingDiscardingTaskGroup { group in
            try await childChannel.executeThenClose { [weak self] inbound, outbound in

                guard let self else { return }
                let (_inbound, _outbound) = await setUpStreams(
                    inbound: inbound,
                    outbound: outbound
                )
                
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.handleOutbound(
                        childChannel: childChannel,
                        _outbound: _outbound
                    )
                }

                for await stream in _inbound {
                    //We need to make sure that the sequence is canceled when we finish the stream
                    for try await inbound in stream.cancelOnGracefulShutdown() {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            await delegate.deliverInboundBuffer(inbound: inbound)
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
    
    private func handleOutbound(
        childChannel: NIOAsyncChannel<Inbound, Outbound>,
        _outbound: AsyncStream<NIOAsyncChannelOutboundWriter<Outbound>>
    ) async throws {
        for await writer in _outbound {
            await delegate.deliverWriter(writer: writer)
        }
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
