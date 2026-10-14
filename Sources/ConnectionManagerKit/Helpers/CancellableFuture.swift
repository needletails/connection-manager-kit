//
//  CancellableFuture.swift
//  connection-manager-kit
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//  This file is part of the ConnectionManagerKit Project

import Foundation
import NIOCore

/// Set when a wait is cancelled before its value exists, so a late success can still be discarded.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Values produced while a bootstrap initializer runs.
///
/// Happy Eyeballs can invoke the initializer once per address. The winning channel is the one
/// the connect future returns, so products are stored by channel and only that one is taken.
final class ChannelProducts<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ObjectIdentifier: Value] = [:]

    func store(_ value: Value, on channel: Channel) {
        let id = ObjectIdentifier(channel)
        lock.lock()
        values[id] = value
        lock.unlock()
    }

    func take(from channel: Channel) -> Value? {
        let id = ObjectIdentifier(channel)
        lock.lock()
        defer { lock.unlock() }
        return values.removeValue(forKey: id)
    }
}

/// Cancellation-aware waits for `EventLoopFuture`.
///
/// `EventLoopFuture.get()` ignores task cancellation and does not return until the future
/// completes. These waits return `CancellationError` immediately. A connect that finishes
/// afterward is closed, matching HTTPConnectionKit.
enum CancellableFuture {
    static func discard(_ channel: Channel) {
        channel.close(promise: nil)
    }

    /// Waits for a connect future and closes the channel if the task is cancelled first.
    static func resolveChannel(_ future: EventLoopFuture<Channel>) async throws -> Channel {
        try await resolve(future, onLateSuccess: discard)
    }

    /// Waits for `future`. `onLateSuccess` runs when a value arrives after cancellation, or wins the race with it.
    static func resolve<Value: Sendable>(
        _ future: EventLoopFuture<Value>,
        onLateSuccess: @escaping @Sendable (Value) -> Void
    ) async throws -> Value {
        let flag = CancelFlag()
        future.whenComplete { result in
            guard case .success(let value) = result, flag.isCancelled else {
                return
            }
            onLateSuccess(value)
        }
        return try await withTaskCancellationHandler {
            let value = try await future.getAbandoningOnCancel()
            if flag.isCancelled {
                onLateSuccess(value)
                throw CancellationError()
            }
            return value
        } onCancel: {
            flag.cancel()
        }
    }

    /// Waits for a future and runs `onCancel` when the task stops waiting.
    ///
    /// Use this when the resource already exists, such as a channel waiting on an upgrade.
    static func resolve<Value: Sendable>(
        _ future: EventLoopFuture<Value>,
        onCancel: @escaping @Sendable () -> Void
    ) async throws -> Value {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            let value = try await future.getAbandoningOnCancel()
            if flag.isCancelled {
                onCancel()
                throw CancellationError()
            }
            return value
        } onCancel: {
            flag.cancel()
            onCancel()
        }
    }
}
