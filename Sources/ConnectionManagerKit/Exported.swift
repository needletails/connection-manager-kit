//
//  Exported.swift
//  connection-manager-kit
//
//  Created by Cole M on 8/16/25.
//
@_exported import NIOCore
@_exported import NIOPosix
@_exported import NIOWebSocket
@_exported import NIOSSL

// Re-export WebSocket types for testing
public typealias WebSocketEvent = ConnectionManagerKit.SocketReceiver.WebSocketEvent
