# WebSocket Quick Start

Learn how to use `WebSocketClient` to connect, send messages, and handle events.

## Overview

`WebSocketClient` is an actor-based, high-level client for WebSocket communication. It forwards inbound messages and lifecycle events to the main actor via `SocketReceiver`. It supports custom HTTP headers, TLS, retry strategies, and automatic ping/pong heartbeats.

## Connect by URL

```swift
import ConnectionManagerKit

let client = await WebSocketClient.shared
let url = URL(string: "wss://example.com/chat")!
try await client.connect(
    url: url,
    headers: ["Authorization": "Bearer <token>"]
)

// Optionally, wait until channel is active before sending (useful in tests)
if let events = await client.socketReceiver.eventStream {
    for await event in events {
        if case .channelActive = event { break }
    }
}
```

## Connect by parameters

```swift
try await client.connect(
    host: "example.com",
    port: 443,
    enableTLS: true,
    route: "/chat",
    headers: ["Sec-WebSocket-Protocol": "chat.v1"],
    retryStrategy: .exponential(initialDelay: .seconds(1), maxDelay: .seconds(30))
)
```

## Send messages

```swift
try await client.sendText("hello", to: "/chat")
try await client.sendBinary(Data([0x01, 0x02]), to: "/chat")
try await client.sendPing(Data("ping".utf8), to: "/chat")
```

## Receive messages

```swift
if let messages = await client.socketReceiver.messageStream {
    Task {
        for await message in messages {
            switch message {
            case .text(let string):
                print("text: \(string)")
            case .binary(let data):
                print("binary: \(data?.count ?? 0) bytes")
            case .ping(let data):
                print("ping: \(data?.count ?? 0) bytes")
            case .pong(let data):
                print("pong: \(data?.count ?? 0) bytes")
            case .continuation:
                print("continuation")
            case .connectionClose:
                print("connection closed")
            }
        }
    }
}
```

## Handle events

```swift
if let events = await client.socketReceiver.eventStream {
    Task {
        for await event in events {
            switch event {
            case .channelActive:
                print("connected")
            case .channelInactive:
                print("disconnected")
            case .error(let error):
                print("error: \(error)")
            default:
                break
            }
        }
    }
}
```

## Headers and TLS

- Provide HTTP headers via the `headers` parameter on `connect(...)`. Useful for `Authorization`, `Sec-WebSocket-Protocol`, and custom headers.
- Use `wss://` or `enableTLS: true` for TLS. For advanced cases, supply `tlsPreKeyed`.

## Heartbeats (Auto Ping/Pong)

`WebSocketClient` can automatically manage ping/pong heartbeats:

- `autoPingPong` (default true)
- `autoPingPongInterval` (default 60s)
- `autoPingTimeout` (default 10s, disconnects route on missing pong)

## Shutdown

```swift
await client.shutDown()
```

## Notes

- Use distinct routes per logical connection (e.g. `/chat`, `/presence`).
- Prefer waiting for `.channelActive` before sending messages to avoid races in tests.
- Streams are finished automatically on `shutDown()` to prevent leaks.


