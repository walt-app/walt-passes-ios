import Foundation

/// The dispatchers' shared fail-fast for a missing kind-specific backend pair
/// (Android's `requireNotNull`): a programming error at the composition root,
/// never attacker-reachable — the arm and its backend come from one document.
func requiredBackend<T>(_ value: T?, _ message: @autoclosure () -> String) -> T {
    guard let value else { fatalError(message()) }
    return value
}
