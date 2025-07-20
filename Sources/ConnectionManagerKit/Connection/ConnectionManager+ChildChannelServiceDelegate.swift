//
//  ConnectionManager+ChildChannelServiceDelegate.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/27/24.
//

import NIOCore

extension ConnectionManager: ChildChannelServiceDelegate {
    func initializedChildChannel<MethodOutbound: Sendable, MethodInbound: Sendable>(_ context: ChannelContext<MethodInbound, MethodOutbound>) async {
        let foundConnection = await connectionCache.findConnection(cacheKey: context.id)
        await foundConnection?.config.delegate?.initializedChildChannel(context)
    }
}
