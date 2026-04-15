import AppKit
import CoreLocation
import EventKit
import Foundation

/// Swift interface for Apple Reminders via EventKit.
/// No AppleScript — uses the native framework directly.
/// Requires the `NSRemindersUsageDescription` key in Info.plist.
public final class RemindersManager: @unchecked Sendable {

    private let eventStore = EKEventStore()

    public init() {}

    // MARK: - Authorization

    /// Requests access to Reminders. Returns true if granted.
    /// On macOS 14+ uses `requestFullAccessToReminders()`, falls back to older API.
    public func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            return (try? await eventStore.requestFullAccessToReminders()) ?? false
        } else {
            return await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .reminder) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    // MARK: - Lists

    /// Returns all reminder lists (calendars).
    public func getLists() async -> [ReminderList] {
        guard await requestAccess() else { return [] }

        let defaultCalendar = eventStore.defaultCalendarForNewReminders()
        return eventStore.calendars(for: .reminder).map { calendar in
            ReminderList(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                isDefault: calendar.calendarIdentifier == defaultCalendar?.calendarIdentifier
            )
        }
    }

    // MARK: - Fetch

    /// Fetches all incomplete reminders, optionally filtered to a specific list.
    /// - Parameter listId: Optional calendar identifier to filter by.
    /// - Returns: Up to 1000 incomplete reminders sorted by due date.
    public func getIncompleteReminders(listId: String? = nil) async -> [ReminderItem] {
        guard await requestAccess() else { return [] }

        let calendars = resolveCalendars(listId: listId)
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )

        let ekReminders = await fetchReminders(matching: predicate)
        return Array(ekReminders.map { convertToReminderItem($0) }.prefix(1000))
    }

    /// Fetches completed reminders, optionally filtered to a specific list.
    /// - Parameter listId: Optional calendar identifier to filter by.
    /// - Returns: Up to 1000 completed reminders sorted by completion date.
    public func getCompletedReminders(listId: String? = nil) async -> [ReminderItem] {
        guard await requestAccess() else { return [] }

        let calendars = resolveCalendars(listId: listId)
        let predicate = eventStore.predicateForCompletedReminders(
            withCompletionDateStarting: nil,
            ending: nil,
            calendars: calendars
        )

        let ekReminders = await fetchReminders(matching: predicate)
        return Array(ekReminders.map { convertToReminderItem($0) }.prefix(1000))
    }

    // MARK: - Create

    /// Creates a new reminder.
    /// - Parameter newReminder: The reminder configuration.
    /// - Returns: The created `ReminderItem`, or nil on failure.
    @discardableResult
    public func createReminder(_ newReminder: NewReminder) async -> ReminderItem? {
        guard await requestAccess() else { return nil }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = newReminder.title
        reminder.notes = newReminder.notes
        reminder.priority = newReminder.priority.rawValue

        // Calendar (list)
        if let listId = newReminder.listId,
           let calendar = eventStore.calendars(for: .reminder).first(where: { $0.calendarIdentifier == listId }) {
            reminder.calendar = calendar
        } else {
            reminder.calendar = eventStore.defaultCalendarForNewReminders()
        }

        // Due date
        if let dueDate = newReminder.dueDate {
            if newReminder.dueDateHasTime {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: dueDate
                )
                reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
            } else {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day],
                    from: dueDate
                )
            }
        }

        // Recurrence
        if let recurrence = newReminder.recurrence {
            if let rule = buildRecurrenceRule(recurrence) {
                reminder.addRecurrenceRule(rule)
            }
        }

        // Location-based alarm
        if let address = newReminder.address, !address.isEmpty {
            await addLocationAlarm(
                to: reminder,
                address: address,
                proximity: newReminder.proximity ?? .enter
            )
        }

        do {
            try eventStore.save(reminder, commit: true)
            return convertToReminderItem(reminder)
        } catch {
            print("⚠️ RemindersManager: failed to create reminder: \(error)")
            return nil
        }
    }

    // MARK: - Update

    /// Toggles a reminder's completion status.
    /// - Parameter reminderId: The `calendarItemIdentifier` of the reminder.
    /// - Returns: True if toggled successfully.
    @discardableResult
    public func toggleCompletion(reminderId: String) async -> Bool {
        guard await requestAccess(),
              let reminder = eventStore.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return false
        }

        reminder.isCompleted = !reminder.isCompleted

        do {
            try eventStore.save(reminder, commit: true)
            return true
        } catch {
            print("⚠️ RemindersManager: failed to toggle completion: \(error)")
            return false
        }
    }

    /// Updates a reminder's title and/or notes.
    /// - Parameters:
    ///   - reminderId: The `calendarItemIdentifier` of the reminder.
    ///   - title: New title, or nil to keep existing.
    ///   - notes: New notes, or nil to keep existing.
    /// - Returns: True if updated successfully.
    @discardableResult
    public func updateTitleAndNotes(
        reminderId: String,
        title: String? = nil,
        notes: String? = nil
    ) async -> Bool {
        guard await requestAccess(),
              let reminder = eventStore.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return false
        }

        if let title { reminder.title = title }
        if let notes { reminder.notes = notes }

        do {
            try eventStore.save(reminder, commit: true)
            return true
        } catch {
            print("⚠️ RemindersManager: failed to update title/notes: \(error)")
            return false
        }
    }

    /// Updates a reminder's due date. Removes all existing alarms and re-adds if needed.
    /// Pass nil to clear the due date.
    /// - Parameters:
    ///   - reminderId: The `calendarItemIdentifier` of the reminder.
    ///   - dueDate: New due date, or nil to clear.
    ///   - hasTime: Whether the date includes a time component.
    /// - Returns: True if updated successfully.
    @discardableResult
    public func updateDueDate(
        reminderId: String,
        dueDate: Date?,
        hasTime: Bool = false
    ) async -> Bool {
        guard await requestAccess(),
              let reminder = eventStore.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return false
        }

        // Remove all existing alarms before changing due date
        // (required for overdue reminders to update properly in Reminders.app)
        if let alarms = reminder.alarms {
            for alarm in alarms {
                reminder.removeAlarm(alarm)
            }
        }

        if let dueDate {
            if hasTime {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: dueDate
                )
                reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
            } else {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day],
                    from: dueDate
                )
            }
        } else {
            reminder.dueDateComponents = nil
        }

        do {
            try eventStore.save(reminder, commit: true)
            return true
        } catch {
            print("⚠️ RemindersManager: failed to update due date: \(error)")
            return false
        }
    }

    /// Updates a reminder's priority.
    /// - Parameters:
    ///   - reminderId: The `calendarItemIdentifier` of the reminder.
    ///   - priority: The new priority level.
    /// - Returns: True if updated successfully.
    @discardableResult
    public func updatePriority(
        reminderId: String,
        priority: ReminderPriority
    ) async -> Bool {
        guard await requestAccess(),
              let reminder = eventStore.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return false
        }

        reminder.priority = priority.rawValue

        do {
            try eventStore.save(reminder, commit: true)
            return true
        } catch {
            print("⚠️ RemindersManager: failed to update priority: \(error)")
            return false
        }
    }

    /// Moves a reminder to a different list.
    /// - Parameters:
    ///   - reminderId: The `calendarItemIdentifier` of the reminder.
    ///   - listId: The target calendar identifier.
    /// - Returns: True if moved successfully.
    @discardableResult
    public func moveToList(
        reminderId: String,
        listId: String
    ) async -> Bool {
        guard await requestAccess(),
              let reminder = eventStore.calendarItem(withIdentifier: reminderId) as? EKReminder,
              let newCalendar = eventStore.calendars(for: .reminder).first(where: { $0.calendarIdentifier == listId }) else {
            return false
        }

        reminder.calendar = newCalendar

        do {
            try eventStore.save(reminder, commit: true)
            return true
        } catch {
            print("⚠️ RemindersManager: failed to move reminder: \(error)")
            return false
        }
    }

    /// Sets a recurrence rule on a reminder. Pass nil to remove recurrence.
    /// - Parameters:
    ///   - reminderId: The `calendarItemIdentifier` of the reminder.
    ///   - recurrence: The new recurrence configuration, or nil to clear.
    /// - Returns: True if updated successfully.
    @discardableResult
    public func updateRecurrence(
        reminderId: String,
        recurrence: ReminderRecurrence?
    ) async -> Bool {
        guard await requestAccess(),
              let reminder = eventStore.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return false
        }

        // Remove existing recurrence rules
        if let existingRules = reminder.recurrenceRules {
            for rule in existingRules {
                reminder.removeRecurrenceRule(rule)
            }
        }

        // Add new rule if provided
        if let recurrence, let rule = buildRecurrenceRule(recurrence) {
            reminder.addRecurrenceRule(rule)
        }

        do {
            try eventStore.save(reminder, commit: true)
            return true
        } catch {
            print("⚠️ RemindersManager: failed to update recurrence: \(error)")
            return false
        }
    }

    // MARK: - Delete

    /// Deletes a reminder.
    /// - Parameter reminderId: The `calendarItemIdentifier` of the reminder.
    /// - Returns: True if deleted successfully.
    @discardableResult
    public func deleteReminder(reminderId: String) async -> Bool {
        guard await requestAccess(),
              let reminder = eventStore.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return false
        }

        do {
            try eventStore.remove(reminder, commit: true)
            return true
        } catch {
            print("⚠️ RemindersManager: failed to delete reminder: \(error)")
            return false
        }
    }

    // MARK: - Open

    /// Opens a reminder in Reminders.app.
    /// - Parameter reminderId: The `calendarItemIdentifier` of the reminder.
    public func openReminder(reminderId: String) {
        let urlString = ReminderItem.openURL(forId: reminderId)
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private Helpers

    private func resolveCalendars(listId: String?) -> [EKCalendar]? {
        guard let listId else { return nil }
        if let calendar = eventStore.calendar(withIdentifier: listId) {
            return [calendar]
        }
        return nil
    }

    private func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                nonisolated(unsafe) let result = reminders ?? []
                continuation.resume(returning: result)
            }
        }
    }

    private func convertToReminderItem(_ reminder: EKReminder) -> ReminderItem {
        let priorityValue = ReminderPriority(rawValue: reminder.priority) ?? .none

        return ReminderItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes,
            dueDate: reminder.dueDateComponents?.date,
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            priority: priorityValue,
            isRecurring: reminder.hasRecurrenceRules,
            listName: reminder.calendar?.title,
            listId: reminder.calendar?.calendarIdentifier,
            openURL: ReminderItem.openURL(forId: reminder.calendarItemIdentifier)
        )
    }

    private func buildRecurrenceRule(_ recurrence: ReminderRecurrence) -> EKRecurrenceRule? {
        let frequency: EKRecurrenceFrequency
        var daysOfTheWeek: [EKRecurrenceDayOfWeek]?

        switch recurrence.frequency {
        case .daily:
            frequency = .daily
        case .weekdays:
            frequency = .weekly
            daysOfTheWeek = [
                EKRecurrenceDayOfWeek(.monday),
                EKRecurrenceDayOfWeek(.tuesday),
                EKRecurrenceDayOfWeek(.wednesday),
                EKRecurrenceDayOfWeek(.thursday),
                EKRecurrenceDayOfWeek(.friday),
            ]
        case .weekends:
            frequency = .weekly
            daysOfTheWeek = [
                EKRecurrenceDayOfWeek(.saturday),
                EKRecurrenceDayOfWeek(.sunday),
            ]
        case .weekly:
            frequency = .weekly
        case .monthly:
            frequency = .monthly
        case .yearly:
            frequency = .yearly
        }

        let end: EKRecurrenceEnd? = recurrence.endDate.map { EKRecurrenceEnd(end: $0) }

        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: recurrence.interval,
            daysOfTheWeek: daysOfTheWeek,
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: end
        )
    }

    private func addLocationAlarm(
        to reminder: EKReminder,
        address: String,
        proximity: NewReminder.LocationProximity
    ) async {
        do {
            let placemarks = try await CLGeocoder().geocodeAddressString(address)
            guard let placemark = placemarks.first,
                  let location = placemark.location else { return }

            let structuredLocation = EKStructuredLocation(title: placemark.name ?? address)
            structuredLocation.geoLocation = location
            structuredLocation.radius = 100

            let alarm = EKAlarm()
            alarm.structuredLocation = structuredLocation
            alarm.proximity = proximity == .enter ? .enter : .leave

            reminder.addAlarm(alarm)
        } catch {
            print("⚠️ RemindersManager: geocoding failed for \"\(address)\": \(error)")
        }
    }
}
