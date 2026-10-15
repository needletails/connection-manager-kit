//
//  AcceptGate.swift
//  connection-manager-kit
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//  This file is part of the ConnectionManagerKit Project

import NIOConcurrencyHelpers
import NIOCore

/// Orders listener shutdown against children that are still being delivered.
///
/// `ServerBootstrap.bind(childChannelInitializer:)` runs the initializer on the child's event
/// loop and hops the result back to the server loop before yielding it to the accept loop. If
/// the listening socket closes in that gap, NIO's server-side `NIOAsyncChannelHandler` has
/// already finished its source and drops the result without closing it. For a child wrapped as
/// a `NIOAsyncChannel` that releases an unfinished `NIOAsyncWriter`, which traps once the child
/// becomes active ("Deinited NIOAsyncWriter without calling finish()"); for a WebSocket upgrade
/// future it leaks the upgraded connection.
///
/// The gate counts children between `beginDelivery()` (child loop, before wrapping) and
/// `endDelivery()` (accept loop, on receipt). `closeAndDrain()` rejects new deliveries and waits
/// until the count is zero, so the listening socket is only closed once every wrapped child is
/// owned by the accept loop.
final class AcceptGate: @unchecked Sendable {
    private let lock = NIOLock()
    private var isOpen = true
    private var inFlight = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// Longest `closeAndDrain()` waits for in-flight children before closing anyway.
    static let drainTimeout: Duration = .seconds(2)

    /// Reserves a delivery slot. Returns `false` once the listener is closing; the caller must
    /// then close the raw channel and fail the initializer without creating a writer.
    func beginDelivery() -> Bool {
        lock.withLock {
            guard isOpen else { return false }
            inFlight += 1
            return true
        }
    }

    /// Releases a slot reserved by `beginDelivery()`. Called by the accept loop as soon as it
    /// receives the element, or by an initializer that failed after reserving.
    func endDelivery() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            inFlight = max(0, inFlight - 1)
            guard inFlight == 0, !isOpen else { return [] }
            defer { drainWaiters.removeAll() }
            return drainWaiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Rejects further deliveries without waiting. Used when the accept loop itself has ended.
    func close() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = false
            guard inFlight == 0 else { return [] }
            defer { drainWaiters.removeAll() }
            return drainWaiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Closes the gate and waits until every reserved delivery has been received, or
    /// `drainTimeout` elapses. Returns `true` when fully drained.
    @discardableResult
    func closeAndDrain() async -> Bool {
        let mustWait: Bool = lock.withLock {
            isOpen = false
            return inFlight > 0
        }
        guard mustWait else { return true }

        let timedOut = NIOLockedValueBox(false)
        // `close()` resumes every waiter, so the timeout can end the wait below.
        let timeout = Task { [self] in
            try? await Task.sleep(for: Self.drainTimeout)
            timedOut.withLockedValue { $0 = true }
            close()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if inFlight == 0 { return true }
                drainWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        timeout.cancel()
        return !timedOut.withLockedValue { $0 }
    }
}
