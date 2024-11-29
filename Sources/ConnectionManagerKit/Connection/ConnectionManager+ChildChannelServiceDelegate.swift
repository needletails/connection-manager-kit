//
//  ConnectionManager+ChildChannelServiceDelegate.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/27/24.
//

import NIOCore

extension ConnectionManager: ChildChannelServiceDelelgate {
    func reportChildChannel(error: any Error) async {
        await delegate?.reportChildChannel(error: error)
    }
    
    func deliverWriter<Outbound>(writer: NIOCore.NIOAsyncChannelOutboundWriter<Outbound>) async where Outbound : Sendable {
        await delegate?.deliverWriter(writer: writer)
    }
    
    func deliverInboundBuffer<Inbound>(inbound: Inbound) async where Inbound : Sendable {
        await delegate?.deliverInboundBuffer(inbound: inbound)
    }
    
    
}
