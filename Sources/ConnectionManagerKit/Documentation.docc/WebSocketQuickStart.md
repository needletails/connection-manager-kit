# WebSocket Quick Start

Learn how to use `WebSocketClient` to connect, send messages, and handle events.

## Overview

`WebSocketClient` is an actor-based, high-level client for WebSocket communication. It forwards inbound messages and lifecycle events to the main actor via `SocketReceiver`.

## Connect by URL

```swift
import ConnectionManagerKit

let client = await WebSocketClient.shared
let url = URL(string: "ws://localhost:8080/chat")!
try await client.connect(url: url)

// Optionally, wait for channel to become active before sending
if let events = await client.socketReceiver.eventStream {
    for try await event in events {
        if case .channelActive = event { break }
    }
}
```

## Connect by parameters

```swift
try await client.connect(host: "localhost", port: 8080, enableTLS: false, route: "/chat")
```

## Send messages

```swift
try await client.sendText("hello", to: "/chat")
try await client.sendBinary(Data([0x01, 0x02]), to: "/chat")
try await client.sendPing(Data("ping".utf8), to: "/chat")
```

## Receive messages

```swift
guard let messages = await client.socketReceiver.messageStream else { return }
for try await message in messages {
    switch message {
    case .text(let string):
        print("text: \(string)")
    case .binary(let data):
        print("binary: \(data?.count ?? 0) bytes")
    default:
        break
    }
}
```

## Handle events

```swift
guard let events = await client.socketReceiver.eventStream else { return }
for try await event in events {
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
```

## Shutdown

```swift
await client.shutDown()
```

## Notes

- Use distinct routes per logical connection (e.g. `/chat`, `/presence`).
- Prefer waiting for `.channelActive` before sending messages to avoid races in tests.
- Streams are finished automatically on `shutDown()` to prevent leaks.


