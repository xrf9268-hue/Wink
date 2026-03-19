import Foundation

struct ShortcutValidator {
    private let keyMatcher = KeyMatcher()

    func conflict(for candidate: AppShortcut, in shortcuts: [AppShortcut]) -> ShortcutConflict? {
        let candidateTrigger = keyMatcher.trigger(for: candidate)
        guard let existing = shortcuts.first(where: {
            $0.id != candidate.id && keyMatcher.trigger(for: $0) == candidateTrigger
        }) else {
            return nil
        }

        return ShortcutConflict(existingShortcut: existing, attemptedShortcut: candidate)
    }
}
