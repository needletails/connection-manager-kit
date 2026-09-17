# Connection Caching

Keep one live connection per cache key with bounded FIFO or LRU eviction.

## Overview

ConnectionManagerKit provides a keyed connection cache. It does not provide multi-checkout
pooling or acquire/return semantics. A successful connection is cached using the
`ServerLocation.cacheKey`. Connecting again with the same key opens a new connection and
replaces the cached entry; the previous connection for that key is shut down. Use
`setDelegates(connectionDelegate:contextDelegate:cacheKey:)` to update an existing entry
without reconnecting.

Configure the cache when creating a manager:

```swift
let manager = ConnectionManager<ByteBuffer, ByteBuffer>(
    cacheConfiguration: CacheConfiguration(
        maxConnections: 50,
        ttl: .seconds(300),
        enableLRU: true
    )
)
```

`maxConnections` is always enforced:

- With `enableLRU: true`, successful lookups update access order and the least-recently-used
  connection is evicted.
- With `enableLRU: false`, insertion order is retained and the oldest connection is evicted.

When `ttl` is set, a lookup closes and removes an expired connection before returning `nil`.
Elapsed time uses a monotonic clock, so wall-clock changes do not alter expiration.

## Cache Keys

Use stable, unique keys for independent destinations:

```swift
let servers = [
    ServerLocation(
        host: "api.example.com",
        port: 443,
        enableTLS: true,
        cacheKey: "primary-api",
        delegate: connectionDelegate,
        contextDelegate: contextDelegate
    ),
    ServerLocation(
        host: "events.example.com",
        port: 443,
        enableTLS: true,
        cacheKey: "events",
        delegate: eventConnectionDelegate,
        contextDelegate: eventContextDelegate
    )
]

try await manager.connectParallel(to: servers)
```

Replacing or evicting an entry closes the old channel service. Calling
`gracefulShutdown()` closes every cached connection and clears the cache.

> Note: `ConnectionPoolConfiguration` remains temporarily available for source compatibility,
> but it is deprecated and is not used by `ConnectionManager`.

## See Also

- <doc:BasicUsage>
- <doc:ParallelConnections>
- <doc:RetryStrategies>
