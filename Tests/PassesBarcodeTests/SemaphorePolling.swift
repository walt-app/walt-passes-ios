import Foundation

/// Non-blocking poll. Wrapped in a sync function only because the compiler bans the call in async
/// contexts; with a `.now()` deadline it never actually blocks.
func tryTake(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now()) == .success
}

/// Waits for up to `count` signals, giving up after `seconds` and returning how many arrived.
///
/// Bounded so a regression fails rather than hanging the suite. Yields rather than blocking: a
/// blocking poll holds a cooperative-pool thread and starves the tasks being waited for.
func awaitSignals(_ semaphore: DispatchSemaphore, upTo count: Int, seconds: Double) async -> Int {
    let deadline = Date().addingTimeInterval(seconds)
    var seen = 0
    while seen < count, Date() < deadline {
        if tryTake(semaphore) {
            seen += 1
        } else {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    return seen
}
