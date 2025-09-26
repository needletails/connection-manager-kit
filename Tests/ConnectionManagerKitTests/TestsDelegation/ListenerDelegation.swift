import Crypto
//
//  ListenerDelegation.swift
//  connection-manager-kit
//
//  Created by Cole M on 9/26/25.
//
import Foundation
import NIOCore
import NIOExtras
import NIOPosix
import NIOSSL

@testable import ConnectionManagerKit

final class ListenerDelegation: ListenerDelegate {
    func retrieveChannelHandlers() -> [any NIOCore.ChannelHandler] {
        [
            LengthFieldPrepender(lengthFieldBitLength: .threeBytes),
            ByteToMessageHandler(
                LengthFieldBasedFrameDecoder(lengthFieldBitLength: .threeBytes),
                maximumBufferSize: 16_777_216),
        ]
    }

    func retrieveSSLHandler() -> NIOSSL.NIOSSLServerHandler? {
        #if !os(Linux) || !os(Android)
            let pskServerProvider: NIOPSKServerIdentityProvider = { context in

                // Get the PSK credentials for the client
                let pskCredentials = retrievePSKCredentials()
                // Create the PSK from the retrieved credentials
                var psk = NIOSSLSecureBytes()

                guard let pskKeyData = pskCredentials.key.data(using: .utf8) else {
                    fatalError("Error: Unable to convert PSK key to Data.")
                }

                guard let hintData = pskCredentials.hint.data(using: .utf8) else {
                    fatalError("Error: Unable to convert PSK hint to Data.")
                }
                let authenticationKey = SymmetricKey(data: pskKeyData)

                let authenticationCode = HMAC<SHA256>.authenticationCode(
                    for: hintData, using: authenticationKey)

                let authenticationData = authenticationCode.withUnsafeBytes {
                    Data($0)
                }
                psk.append(authenticationData)
                return PSKServerIdentityResponse(key: psk)
            }

            // Create a TLS configuration for PSK
            var tls = TLSConfiguration.makePreSharedKeyConfiguration()
            tls.cipherSuiteValues = [.TLS_ECDHE_PSK_WITH_AES_256_CBC_SHA]
            tls.maximumTLSVersion = .tlsv12
            // Log the PSK hint being used
            let pskHint = retrievePSKCredentials().hint
            tls.pskHint = pskHint

            // Set the PSK server provider
            tls.pskServerProvider = pskServerProvider

            // Create the SSL context
            do {
                let sslContext = try NIOSSLContext(configuration: tls)

                // Return the SSL server handler
                return NIOSSLServerHandler(context: sslContext)
            } catch {
                fatalError(error.localizedDescription)
            }
        #else
            return nil
        #endif
    }

    func didBindTCPServer<Inbound: Sendable, Outbound: Sendable>(
        channel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>
    ) async {
        serverChannelAny = channel
        if shouldShutdown {
            try! await channel.executeThenClose({ _, _ in })
        }
    }

    let shouldShutdown: Bool
    nonisolated(unsafe) var serverChannelAny: Any?

    init(shouldShutdown: Bool) {
        self.shouldShutdown = shouldShutdown
    }
}
