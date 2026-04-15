import EventKit
import Foundation

/// A reminder returned by the RemindersManager.
public struct ReminderItem: Sendable {
    public let id: String
    public let title: String
    public let notes: String?
    public let dueDate: Date?
    public let isCompleted: Bool
    public let completionDate: Date?
    public let priority: ReminderPriority
    public let isRecurring: Bool
    public let listName: String?
    public let listId: String?
    public let openURL: String

    /// URL scheme that opens this reminder in Reminders.app.
    public static func openURL(forId id: String) -> String {
        "x-apple-reminderkit://REMCDReminder/\(id)"
    }
}

/// Priority levels matching Apple's EKReminderPriority values.
public enum ReminderPriority: Int, Sendable {
    case none = 0
    case high = 1
    case medium = 5
    case low = 9

    public init(fromString string: String?) {
        switch string?.lowercased() {
        case "high": self = .high
        case "medium": self = .medium
        case "low": self = .low
        default: self = .none
        }
    }

    public var displayString: String {
        switch self {
        case .none: return ""
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        }
    }
}

/// A reminder list (calendar) returned by the RemindersManager.
public struct ReminderList: Sendable {
    public let id: String
    public let title: String
    public let isDefault: Bool
}

/// Recurrence configuration for creating/updating reminders.
public struct ReminderRecurrence: Sendable {
    public let frequency: Frequency
    public let interval: Int
    public let endDate: Date?

    public enum Frequency: String, Sendable {
        case daily
        case weekdays
        case weekends
        case weekly
        case monthly
        case yearly
    }

    public init(frequency: Frequency, interval: Int = 1, endDate: Date? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.endDate = endDate
    }
}

/// Parameters for creating a new reminder.
public struct NewReminder: Sendable {
    public let title: String
    public let notes: String?
    public let dueDate: Date?
    public let dueDateHasTime: Bool
    public let priority: ReminderPriority
    public let listId: String?
    public let recurrence: ReminderRecurrence?
    public let address: String?
    public let proximity: LocationProximity?

    public enum LocationProximity: String, Sendable {
        case enter
        case leave
    }

    public init(
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        dueDateHasTime: Bool = false,
        priority: ReminderPriority = .none,
        listId: String? = nil,
        recurrence: ReminderRecurrence? = nil,
        address: String? = nil,
        proximity: LocationProximity? = nil
    ) {
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.dueDateHasTime = dueDateHasTime
        self.priority = priority
        self.listId = listId
        self.recurrence = recurrence
        self.address = address
        self.proximity = proximity
    }
}
