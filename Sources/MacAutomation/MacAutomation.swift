/// MacAutomation — Swift package for macOS app integrations.
///
/// Provides clean async Swift APIs for interacting with macOS apps
/// like Apple Notes, Reminders, Calendar, Safari, Chrome, and more.
///
/// All operations use AppleScript or native frameworks (EventKit, Contacts)
/// under the hood. No private APIs, no SQLite hacks.
///
/// Usage:
///     let result = await AppleNotesManager.createNote(title: "Hello", body: "World")
///     let search = await AppleNotesManager.searchNotes(query: "shopping")
public enum MacAutomation {
    public static let version = "0.1.0"
}
