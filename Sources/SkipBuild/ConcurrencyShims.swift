// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import TSCBasic

/// Concurrency-safe stdout stream owned by SkipBuild.
/// Avoids referencing `TSCBasic.stdoutStream`, which is a nonisolated mutable global
/// that Swift 6 strict concurrency flags on read from sendable contexts. The underlying
/// `ThreadSafeOutputByteStream` is internally synchronized, so an independent instance
/// pointing at the same file descriptor is safe.
nonisolated(unsafe) var skipBuildStdoutStream: ThreadSafeOutputByteStream = try! ThreadSafeOutputByteStream(LocalFileOutputByteStream(filePointer: stdout, closeOnDeinit: false))

/// Concurrency-safe stderr stream owned by SkipBuild. See `skipBuildStdoutStream`.
nonisolated(unsafe) var skipBuildStderrStream: ThreadSafeOutputByteStream = try! ThreadSafeOutputByteStream(LocalFileOutputByteStream(filePointer: stderr, closeOnDeinit: false))

/// Wraps an arbitrary value in an `@unchecked Sendable` container so it can be safely
/// captured into a `Task { }` whose body Swift 6 has marked `@Sendable`. The caller is
/// responsible for ensuring that the captured value is only used in ways that respect
/// its actual thread-safety guarantees.
final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
