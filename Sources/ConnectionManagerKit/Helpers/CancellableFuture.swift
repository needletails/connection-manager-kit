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
///
/// Every other product is passed to `discard`: on `take`, when it is stored after `take`, or
/// when the container goes away because the connect failed or was cancelled. A product that
/// wraps a `NIOAsyncChannel` must be finished rather than dropped (see `CancellableFuture.wrap`).
final class ChannelProducts<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ObjectIdentifier: Value] = [:]
    private var taken = false
    private let discard: @Sendable (Value) -> Void

    init(discard: @escaping @Sendable (Value) -> Void) {
        self.discard = discard
    }

    deinit {
        for value in values.values {
            discard(value)
        }
    }

    func store(_ value: Value, on channel: Channel) {
        let id = ObjectIdentifier(channel)
        lock.lock()
        if taken {
            lock.unlock()
            discard(value)
            return
        }
        values[id] = value
        lock.unlock()
    }

    func take(from channel: Channel) -> Value? {
        let id = ObjectIdentifier(channel)
        lock.lock()
        taken = true
        let value = values.removeValue(forKey: id)
        let losers = Array(values.values)
        values.removeAll()
        lock.unlock()
        for loser in losers {
            discard(loser)
        }
        return value
    }
}

/// Cancellation-aware waits for `EventLoopFuture`.
///
/// `EventLoopFuture.get()` ignores task cancellation and does not return until the future
/// completes. These waits return `CancellationError` immediately. A connect that finishes
/// afterward is closed, matching HTTPConnectionKit.
enum CancellableFuture {
    /// Wraps `channel` in a `NIOAsyncChannel`.
    ///
    /// The result owns an unfinished `NIOAsyncWriter`. Releasing it without `executeThenClose`
    /// (or finishing the writer) traps with "Deinited NIOAsyncWriter without calling finish()",
    /// so every caller must hand the value to an owner or discard it through `executeThenClose`.
    /// A channel that closed before it was wrapped is safe: the closed sink finishes the writer.
    static func wrap<Inbound: Sendable, Outbound: Sendable>(
        _ channel: Channel,
        configuration: NIOAsyncChannel<Inbound, Outbound>.Configuration = .init()
    ) throws -> NIOAsyncChannel<Inbound, Outbound> {
        try NIOAsyncChannel(wrappingChannelSynchronously: channel, configuration: configuration)
    }

    static func discard(_ channel: Channel) {
        channel.close(promise: nil)
    }

    /// Finishes the writer and closes a wrapped channel nobody will use.
    static func discard<Inbound: Sendable, Outbound: Sendable>(_ channel: NIOAsyncChannel<Inbound, Outbound>) {
        Task {
            try? await channel.executeThenClose { _, _ in }
        }
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
