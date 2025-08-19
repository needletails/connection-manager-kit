//
//  ConnectionManager+ChildChannelServiceDelegate.swift
//  connection-manager-kit
//
//  Created by Cole M on 11/27/24.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//  This file is part of the ConnectionManagerKit Project

import NIOCore

extension ConnectionManager: ChildChannelServiceDelegate {
    func initializedChildChannel<MethodOutbound: Sendable, MethodInbound: Sendable>(_ context: ChannelContext<MethodInbound, MethodOutbound>) async {
        let foundConnection = await connectionCache.findConnection(cacheKey: context.id)
        await foundConnection?.config.delegate?.initializedChildChannel(context)
    }
}
