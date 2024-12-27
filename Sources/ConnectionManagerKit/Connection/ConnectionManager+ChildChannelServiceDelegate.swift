//
//  ConnectionManager+ChildChannelServiceDelegate.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/27/24.
//

import NIOCore

extension ConnectionManager: ChildChannelServiceDelelgate {
    func initializedChildChannel<Outbound, Inbound>(_ context: ChannelContext<Inbound, Outbound>) async where Outbound : Sendable, Inbound : Sendable {
        let foundConnection = await connectionCache.findConnection(cacheKey: context.id)
        await foundConnection?.config.delegate.initializedChildChannel(context)
    }
    
    nonisolated func shutdown(location: ServerLocation) {
        Task { [weak self] in
            guard let self else { return }
            await self.shutdown(cacheKey: location.cacheKey)
        }
    }
}
