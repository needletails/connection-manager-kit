//
//  TestPSKCredentials.swift
//  connection-manager-kit
//
//  Created by Cole M on 9/26/25.
//
import Foundation
import Crypto
#if canImport(Network)
import Network
#endif
@testable import ConnectionManagerKit

// MARK: - Test Helpers

struct TestPSKCredentials { let key: String; let hint: String }

func retrievePSKCredentials() -> TestPSKCredentials {
    // Fixed credentials for tests; could vary by clientIdentity if desired
    return TestPSKCredentials(key: "test-key", hint: "test-hint")
}

func makeTestTLSPreKeyedConfig() -> TLSPreKeyedConfiguration {
    
    let pskCredentials = retrievePSKCredentials()
    var tlsPreKeyed: TLSPreKeyedConfiguration
#if canImport(Network)
    let tlsOptions = NWProtocolTLS.Options()
    
    // Create the symmetric key from the PSK key
    guard let pskKeyData = pskCredentials.key.data(using: .utf8) else { fatalError() }
    let authenticationKey = SymmetricKey(data: pskKeyData)
    
    // Generate the HMAC for the PSK using the hint
    guard let hintData = pskCredentials.hint.data(using: .utf8) else { fatalError() }
    
    let authenticationCode = HMAC<SHA256>.authenticationCode(for: hintData, using: authenticationKey)
    
    // Convert the HMAC to DispatchData
    let authenticationDispatchData = authenticationCode.withUnsafeBytes {
        DispatchData(bytes: $0)
    }
    sec_protocol_options_set_min_tls_protocol_version(
        tlsOptions.securityProtocolOptions,
        .TLSv12
    )
    
    sec_protocol_options_set_max_tls_protocol_version(
        tlsOptions.securityProtocolOptions,
        .TLSv12
    )
    
    // Add the pre-shared key to the TLS options
    if let hintDispatchData = stringToDispatchData(pskCredentials.hint) {
        sec_protocol_options_add_pre_shared_key(tlsOptions.securityProtocolOptions,
                                                authenticationDispatchData as __DispatchData,
                                                hintDispatchData as __DispatchData) // Use the hint from PSKCredentials
        
    } else {
        print("Error: Unable to convert PSK hint to DispatchData.")
    }
    
    // Append the desired TLS cipher suite
    let cipherSuite = tls_ciphersuite_t(rawValue: TLS_ECDHE_PSK_WITH_AES_256_CBC_SHA)!
    sec_protocol_options_append_tls_ciphersuite(tlsOptions.securityProtocolOptions, cipherSuite)
    
    // Helper function to convert a string to DispatchData
    func stringToDispatchData(_ string: String) -> DispatchData? {
        guard let data = string.data(using: .utf8) else { return nil }
        let dispatchData = data.withUnsafeBytes {
            DispatchData(bytes: $0)
        }
        return dispatchData
    }
    tlsPreKeyed = TLSPreKeyedConfiguration(tlsOption: tlsOptions)
#else
    // Define the PSK client provider
    let pskClientProvider: NIOPSKClientIdentityProvider = { context in
        // Here you can evaluate the context to determine the appropriate PSK
        var psk = NIOSSLSecureBytes()
        
        guard let pskKeyData = pskCredentials.key.data(using: .utf8) else {
            fatalError("Error: Unable to convert PSK key to Data.")
        }
        
        guard let hintData = pskCredentials.hint.data(using: .utf8) else {
            fatalError("Error: Unable to convert PSK hint to Data.")
        }
        
        let authenticationKey = SymmetricKey(data: pskKeyData)
        
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: hintData, using: authenticationKey)
        
        
        let authenticationData = authenticationCode.withUnsafeBytes {
            Data($0)
        }
        
        psk.append(authenticationData)
        self.logger.log(level: .info, message: "CREDENTIALS - KEY \(psk.count)")
        return PSKClientIdentityResponse(key: psk, identity: "clientIdentity") // Set your client identity
    }
    
    // Create a TLS configuration for the client
    var tls = TLSConfiguration.makePreSharedKeyConfiguration()
    tls.cipherSuiteValues = [.TLS_ECDHE_PSK_WITH_AES_256_CBC_SHA]
    tls.maximumTLSVersion = .tlsv12
    tls.pskClientProvider = pskClientProvider
    tls.pskHint = pskCredentials.hint
    tlsPreKeyed = TLSPreKeyedConfiguration(tlsConfiguration: tls)
#endif
    return tlsPreKeyed
}


extension ByteToMessageHandler: @retroactive @unchecked Sendable {}
