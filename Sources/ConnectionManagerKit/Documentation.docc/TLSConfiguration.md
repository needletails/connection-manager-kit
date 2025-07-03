# TLS Configuration

Configure TLS for secure connections in ConnectionManagerKit with support for both client and server-side encryption.

## Overview

ConnectionManagerKit provides comprehensive TLS support across Apple platforms and Linux. The framework automatically handles TLS configuration based on your platform, using Network framework on Apple platforms and NIO SSL on Linux.

## Client-Side TLS

### Basic TLS Connection

```swift
let manager = ConnectionManager()
let connectionDelegate = MyConnectionDelegate()
let contextDelegate = MyChannelContextDelegate()

let servers = [
    ServerLocation(
        host: "api.example.com",
        port: 443,
        enableTLS: true,  // Enable TLS for this connection
        cacheKey: "secure-api",
        delegate: connectionDelegate,
        contextDelegate: contextDelegate
    )
]

try await manager.connect(
    to: servers,
    maxReconnectionAttempts: 5,
    timeout: .seconds(10)
)
```

### Custom TLS Configuration

#### Apple Platforms (Network Framework)

```swift
#if canImport(Network)
// Create custom TLS options
let tlsOptions = NWProtocolTLS.Options()

// Set minimum TLS version to 1.3
sec_protocol_options_set_min_tls_protocol_version(
    tlsOptions.securityProtocolOptions,
    .TLSv13
)

// Set maximum TLS version to 1.3
sec_protocol_options_set_max_tls_protocol_version(
    tlsOptions.securityProtocolOptions,
    .TLSv13
)

// Configure cipher suites
sec_protocol_options_set_tls_ciphersuite_allow_list(
    tlsOptions.securityProtocolOptions,
    [
        tls_ciphersuite_t(rawValue: UInt16(TLS_AES_256_GCM_SHA384))!,
        tls_ciphersuite_t(rawValue: UInt16(TLS_AES_128_GCM_SHA256))!
    ]
)

// Create pre-keyed configuration
let tlsConfig = TLSPreKeyedConfiguration(tlsOption: tlsOptions)

// Use custom TLS configuration
try await manager.connect(
    to: servers,
    maxReconnectionAttempts: 5,
    timeout: .seconds(10),
    tlsPreKeyed: tlsConfig
)
#endif
```

#### Linux (NIO SSL)

```swift
#if !canImport(Network)
// Create custom TLS configuration
var tlsConfig = TLSConfiguration.makeClientConfiguration()

// Set TLS version
tlsConfig?.minimumTLSVersion = .tlsv13
tlsConfig?.maximumTLSVersion = .tlsv13

// Configure cipher suites
tlsConfig?.cipherSuites = [
    .TLS_AES_256_GCM_SHA384,
    .TLS_AES_128_GCM_SHA256
]

// Configure certificate verification
tlsConfig?.certificateVerification = .fullVerification

// Create pre-keyed configuration
let preKeyedConfig = TLSPreKeyedConfiguration(tlsConfiguration: tlsConfig!)

// Use custom TLS configuration
try await manager.connect(
    to: servers,
    maxReconnectionAttempts: 5,
    timeout: .seconds(10),
    tlsPreKeyed: preKeyedConfig
)
#endif
```

### Certificate Pinning

#### Apple Platforms

```swift
#if canImport(Network)
let tlsOptions = NWProtocolTLS.Options()

// Add certificate pinning
let pinnedCertificates = [
    // Add your pinned certificates here
    // Example: loadCertificate(from: "pinned_cert.pem")
]

for certificate in pinnedCertificates {
    sec_protocol_options_add_tls_ca(
        tlsOptions.securityProtocolOptions,
        certificate
    )
}

// Disable default certificate validation
sec_protocol_options_set_verify_block(
    tlsOptions.securityProtocolOptions,
    { _, _, completion in
        // Custom verification logic
        completion(true)
    },
    nil
)

let tlsConfig = TLSPreKeyedConfiguration(tlsOption: tlsOptions)
#endif
```

#### Linux

```swift
#if !canImport(Network)
var tlsConfig = TLSConfiguration.makeClientConfiguration()

// Load pinned certificates
let pinnedCertificates = try loadPinnedCertificates()
tlsConfig?.trustRoots = .certificates(pinnedCertificates)

// Custom verification callback
tlsConfig?.certificateVerification = .custom { certs, hostname in
    // Custom verification logic
    return .certificateVerified
}
#endif
```

## Server-Side TLS

### Basic TLS Server

```swift
class MyTLSListenerDelegate: ListenerDelegate {
    func didBindServer<Inbound, Outbound>(channel: NIOAsyncChannel<NIOAsyncChannel<Inbound, Outbound>, Never>) async {
        print("TLS Server bound successfully")
    }
    
    func retrieveSSLHandler() -> NIOSSLServerHandler? {
        do {
            // Load server certificate and private key
            let certificate = try loadCertificate(from: "server_cert.pem")
            let privateKey = try loadPrivateKey(from: "server_key.pem")
            
            // Create TLS configuration
            let tlsConfig = TLSConfiguration.makeServerConfiguration(
                certificateChain: [.certificate(certificate)],
                privateKey: .privateKey(privateKey)
            )
            
            // Create SSL context
            let sslContext = try NIOSSLContext(configuration: tlsConfig)
            
            // Create SSL handler
            return try NIOSSLServerHandler(context: sslContext)
        } catch {
            print("Failed to create SSL handler: \(error)")
            return nil
        }
    }
    
    func retrieveChannelHandlers() -> [ChannelHandler] {
        return [
            LengthFieldPrepender(lengthFieldBitLength: .fourBytes),
            MyProtocolHandler()
        ]
    }
}
```

### Advanced Server TLS Configuration

```swift
func retrieveSSLHandler() -> NIOSSLServerHandler? {
    do {
        // Load certificates
        let certificate = try loadCertificate(from: "server_cert.pem")
        let privateKey = try loadPrivateKey(from: "server_key.pem")
        let caCertificates = try loadCACertificates(from: "ca_certs.pem")
        
        // Create advanced TLS configuration
        var tlsConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(privateKey)
        )
        
        // Configure TLS version
        tlsConfig.minimumTLSVersion = .tlsv13
        tlsConfig.maximumTLSVersion = .tlsv13
        
        // Configure cipher suites
        tlsConfig.cipherSuites = [
            .TLS_AES_256_GCM_SHA384,
            .TLS_AES_128_GCM_SHA256
        ]
        
        // Configure certificate verification
        tlsConfig.certificateVerification = .fullVerification
        tlsConfig.trustRoots = .certificates(caCertificates)
        
        // Configure session resumption
        tlsConfig.sessionResumption = .enabled
        
        // Create SSL context
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        
        return try NIOSSLServerHandler(context: sslContext)
    } catch {
        print("Failed to create SSL handler: \(error)")
        return nil
    }
}
```

### Certificate Loading Utilities

```swift
import Foundation
import NIOSSL

func loadCertificate(from path: String) throws -> NIOSSLCertificate {
    let certificateData = try Data(contentsOf: URL(fileURLWithPath: path))
    return try NIOSSLCertificate(bytes: certificateData, format: .pem)
}

func loadPrivateKey(from path: String) throws -> NIOSSLPrivateKey {
    let keyData = try Data(contentsOf: URL(fileURLWithPath: path))
    return try NIOSSLPrivateKey(bytes: keyData, format: .pem)
}

func loadCACertificates(from path: String) throws -> [NIOSSLCertificate] {
    let caData = try Data(contentsOf: URL(fileURLWithPath: path))
    return try NIOSSLCertificate.fromPEMBytes(caData)
}

#if canImport(Network)
import Network

func loadCertificate(from path: String) throws -> sec_certificate_t {
    let certificateData = try Data(contentsOf: URL(fileURLWithPath: path))
    return try sec_certificate_create_with_data(certificateData as CFData)
}

func loadPrivateKey(from path: String) throws -> sec_key_t {
    let keyData = try Data(contentsOf: URL(fileURLWithPath: path))
    return try sec_key_create_with_data(keyData as CFData)
}
#endif
```

## TLS Best Practices

### 1. Use Strong TLS Versions

```swift
// Always use TLS 1.3 when possible
#if canImport(Network)
sec_protocol_options_set_min_tls_protocol_version(
    tlsOptions.securityProtocolOptions,
    .TLSv13
)
#else
tlsConfig?.minimumTLSVersion = .tlsv13
#endif
```

### 2. Configure Secure Cipher Suites

```swift
// Use only strong cipher suites
let secureCipherSuites = [
    .TLS_AES_256_GCM_SHA384,
    .TLS_AES_128_GCM_SHA256,
    .TLS_CHACHA20_POLY1305_SHA256
]
```

### 3. Implement Certificate Pinning

```swift
// Pin certificates for additional security
let pinnedCertificates = loadPinnedCertificates()
// Use pinned certificates in TLS configuration
```

### 4. Handle TLS Errors Gracefully

```swift
class MyConnectionDelegate: ConnectionDelegate {
    func handleError(_ stream: AsyncStream<NWError>, id: String) {
        Task {
            for await error in stream {
                switch error {
                case .tls(let code):
                    switch code {
                    case .badCertificate:
                        print("TLS certificate error")
                    case .handshakeFailed:
                        print("TLS handshake failed")
                    default:
                        print("TLS error: \(code)")
                    }
                default:
                    print("Other error: \(error)")
                }
            }
        }
    }
}
```

### 5. Monitor TLS Connection State

```swift
func handleNetworkEvents(_ stream: AsyncStream<NetworkEventMonitor.NetworkEvent>, id: String) async {
    for await event in stream {
        switch event {
        case .viabilityChanged(let update):
            if update.isViable {
                print("TLS connection is viable")
            } else {
                print("TLS connection is not viable")
            }
        default:
            break
        }
    }
}
```

## Troubleshooting

### Common TLS Issues

1. **Certificate Errors**
   - Verify certificate chain is complete
   - Check certificate expiration dates
   - Ensure proper certificate format (PEM/DER)

2. **Handshake Failures**
   - Verify TLS version compatibility
   - Check cipher suite support
   - Ensure proper certificate validation

3. **Performance Issues**
   - Enable session resumption
   - Use appropriate cipher suites
   - Monitor connection pooling

### Debug TLS Connections

```swift
// Enable TLS debugging
#if canImport(Network)
let tlsOptions = NWProtocolTLS.Options()
sec_protocol_options_set_verify_block(
    tlsOptions.securityProtocolOptions,
    { metadata, trust, completion in
        print("TLS verification: \(metadata)")
        completion(true)
    },
    nil
)
#else
var tlsConfig = TLSConfiguration.makeClientConfiguration()
tlsConfig?.certificateVerification = .custom { certs, hostname in
    print("TLS verification: \(certs)")
    return .certificateVerified
}
#endif
```

## Platform-Specific Considerations

### Apple Platforms
- Uses Network framework for TLS
- Supports certificate pinning
- Automatic certificate validation
- Built-in security features

### Linux
- Uses NIO SSL for TLS
- Manual certificate management
- Custom verification callbacks
- Full control over TLS configuration

---

For more information about TLS configuration, see the [Basic Usage](BasicUsage) guide and [API Reference](Documentation). 