import Foundation
import PassesCore

/// Encrypted, device-only storage surface for parsed passes.
///
/// Production implementation will encrypt at rest using a Secure-Enclave-
/// wrapped key (mirrors `passes-android` SQLCipher + Android Keystore) and
/// exclude its files from iCloud backup. Built in the Passes feature epic.
public protocol PassStorage: Sendable {
    func save(_ pass: Pass) async throws
    func load(id: String) async throws -> Pass?
    func all() async throws -> [Pass]
    func delete(id: String) async throws
}
