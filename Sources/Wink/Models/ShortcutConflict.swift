import Foundation

struct ShortcutConflict: Identifiable, Equatable {
    let id = UUID()
    let existingShortcut: AppShortcut
    let attemptedShortcut: AppShortcut
}
