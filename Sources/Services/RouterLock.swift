// RouterLock.swift
// DataHawk
//
// Global mutex around every conversation with the router. Exactly one flow
// talks to the device at a time, app-wide.
//
// Router firmware copes badly with concurrent clients, and two hazards are
// unfixable inside a provider:
//
//   - The CSRF token rotates on every model.json response. Two writes that
//     each read their own token invalidate one another — GET₁ GET₂ POST₁
//     POST₂ leaves POST₂ holding a dead token and the router rejects it.
//   - A read issued while a write is in flight describes the pre-write world.
//
// Both need the *whole* block — auth read plus the write, or auth read plus
// the metrics read — to be atomic. Guarding individual requests would not
// help: it still permits the interleaving above. So the lock is taken at
// provider entry points, never inside the HTTP helpers they call.
//
// Nesting deadlocks: a guarded block must not call another guarded block.
//
// Cancellation is not special-cased. A task cancelled while queued keeps its
// place, then runs a body that fails fast (URLSession throws immediately and
// the callers check `Task.isCancelled`), and `defer` still releases the lock.

import os

/// A FIFO async mutex.
///
/// `acquire()` suspends until the lock is free; `release()` is deliberately
/// synchronous so that call sites can pair the two with `defer`, which an
/// actor-based lock could not offer (`defer` cannot await).
final class RouterLock: Sendable {
    static let shared = RouterLock()

    private struct State {
        var isHeld = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    /// `OSAllocatedUnfairLock`'s scoped `withLock` is the async-safe way to
    /// hold a lock — unlike `NSLock.lock()`, it cannot be left held across a
    /// suspension point. Critical sections here are a few instructions long.
    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    // MARK: - Public API

    /// Suspends until the caller owns the lock.
    ///
    /// Every arrival passes through exactly one critical section, which both
    /// decides the outcome and enqueues the waiter. Splitting that into an
    /// uncontended fast path plus a slow path would cost strict ordering: a
    /// later arrival could enqueue ahead of one that had already failed its
    /// first check.
    func acquire() async {
        await withCheckedContinuation { continuation in
            let claimed = state.withLock { state -> Bool in
                guard state.isHeld else {
                    state.isHeld = true

                    return true
                }

                state.waiters.append(continuation)

                return false
            }

            if claimed { continuation.resume() }
        }
    }

    /// Hands the lock to the longest-waiting caller, or frees it.
    ///
    /// Ownership passes directly to the next waiter — `isHeld` deliberately
    /// stays `true` — so a newcomer cannot barge in front of the queue.
    func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.isHeld = false

                return nil
            }

            return state.waiters.removeFirst()
        }

        // Resumed outside the critical section: the woken task must not have
        // to contend with a lock this one still holds.
        next?.resume()
    }
}
