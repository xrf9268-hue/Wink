import CryptoKit
import Foundation

/// **This file exists only to prove that CodeQL can produce an alert on this
/// repository, and it must never be merged.** See issue #442.
///
/// A zero-alert baseline is not evidence that scanning works: a scanner that
/// extracts nothing, or one whose query suite never loaded, reports zero
/// alerts too. The only way to tell a clean codebase from a vacuous gate is to
/// give the scanner something it is documented to flag and check that it does.
///
/// Each probe targets one query that the `default` suite actually ran against
/// `main` (confirmed in the CodeQL Setup run's query list):
///
/// - `swift/cleartext-storage-preferences` — CWE-312, storing a credential in
///   `UserDefaults` in the clear.
/// - `swift/weak-sensitive-data-hashing` — CWE-328, hashing a credential with
///   a broken digest.
///
/// Two independent probes rather than one, so a single query's heuristics
/// changing upstream cannot silently turn this proof back into a vacuous one.
///
/// Nothing here is called from Wink. The declarations exist so `swift build`
/// compiles them and the CodeQL extractor sees them.
enum CodeQLNonVacuityProbe {
    /// Expected alert: cleartext storage of sensitive information in the user
    /// defaults database.
    static func storeCredentialInPreferences(password: String) {
        UserDefaults.standard.set(password, forKey: "wink.codeql.probe.password")
    }

    /// Expected alert: use of a broken or weak cryptographic hashing algorithm
    /// on sensitive data.
    static func hashCredentialWeakly(password: String) -> String {
        Insecure.MD5
            .hash(data: Data(password.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
