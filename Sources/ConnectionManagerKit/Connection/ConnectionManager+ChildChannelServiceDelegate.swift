//
//  ConnectionManager+ChildChannelServiceDelegate.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/27/24.
//

import NIOCore

extension ConnectionManager: ChildChannelServiceDelelgate {
    func initializedChildChannel<Outbound, Inbound>(_ context: ChannelContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable {
        let foundConnection = try await connectionCache.findConnection(cacheKey: context.id)
        await foundConnection?.config.delegate.initializedChildChannel(context)
    }
}
