import Foundation

/// Runs `operation` with a hard ceiling on how long it may take, returning nil
/// if the ceiling is hit.
///
/// The per-request timeout is not enough on its own: a refresh that issues one
/// request per model multiplies that timeout by the size of the model library.
/// This bounds the *whole* refresh, so a slow server delays the overlay by a
/// known amount rather than an unbounded one.
///
/// On expiry the operation is cancelled — including every request still in
/// flight underneath it — and callers keep whatever they were already showing.
@MainActor
func withDeadline<T>(
    _ duration: Duration,
    operation: @escaping @MainActor () async -> T
) async -> T? {
    let work = Task { @MainActor in await operation() }
    let timer = Task {
        try? await Task.sleep(for: duration)
        work.cancel()
    }
    defer { timer.cancel() }
    let result = await work.value
    return Task.isCancelled || work.isCancelled ? nil : result
}
