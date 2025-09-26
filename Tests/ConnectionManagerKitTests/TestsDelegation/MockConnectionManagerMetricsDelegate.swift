//
//  MockConnectionManagerMetricsDelegate.swift
//  connection-manager-kit
//
//  Created by Cole M on 9/26/25.
//
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOExtras
@testable import ConnectionManagerKit

final class MockConnectionManagerMetricsDelegate: ConnectionManagerMetricsDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _totalConnections: Int = 0
    private var _activeConnections: Int = 0
    private var _failedConnections: Int = 0
    private var _averageConnectionTime: TimeAmount = .seconds(0)
    private var _connectionFailures: [(serverLocation: String, error: Error, attemptNumber: Int)] = []
    private var _connectionSuccesses: [(serverLocation: String, connectionTime: TimeAmount)] = []
    private var _parallelCompletions: [(totalAttempted: Int, successful: Int, failed: Int)] = []
    
    var totalConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return _totalConnections
    }
    
    var activeConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return _activeConnections
    }
    
    var failedConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return _failedConnections
    }
    
    var averageConnectionTime: TimeAmount {
        lock.lock()
        defer { lock.unlock() }
        return _averageConnectionTime
    }
    
    var connectionFailures: [(serverLocation: String, error: Error, attemptNumber: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return _connectionFailures
    }
    
    var connectionSuccesses: [(serverLocation: String, connectionTime: TimeAmount)] {
        lock.lock()
        defer { lock.unlock() }
        return _connectionSuccesses
    }
    
    var parallelCompletions: [(totalAttempted: Int, successful: Int, failed: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return _parallelCompletions
    }
    
    func connectionManagerMetricsDidUpdate(totalConnections: Int, activeConnections: Int, failedConnections: Int, averageConnectionTime: TimeAmount) {
        lock.lock()
        defer { lock.unlock() }
        _totalConnections = totalConnections
        _activeConnections = activeConnections
        _failedConnections = failedConnections
        _averageConnectionTime = averageConnectionTime
    }
    
    func connectionDidFail(serverLocation: String, error: Error, attemptNumber: Int) {
        lock.lock()
        defer { lock.unlock() }
        _connectionFailures.append((serverLocation: serverLocation, error: error, attemptNumber: attemptNumber))
    }
    
    func connectionDidSucceed(serverLocation: String, connectionTime: TimeAmount) {
        lock.lock()
        defer { lock.unlock() }
        _connectionSuccesses.append((serverLocation: serverLocation, connectionTime: connectionTime))
    }
    
    func parallelConnectionDidComplete(totalAttempted: Int, successful: Int, failed: Int) {
        lock.lock()
        defer { lock.unlock() }
        _parallelCompletions.append((totalAttempted: totalAttempted, successful: successful, failed: failed))
    }
}
