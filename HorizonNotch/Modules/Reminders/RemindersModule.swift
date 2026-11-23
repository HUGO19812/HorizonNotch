import AppKit
import EventKit
import SwiftUI

/// Open reminders from the Reminders app on their own page: grouped into
/// overdue, today, upcoming and no date, ticked off with a tap, and added
/// with a line at the bottom (list and day pickable). Updates come from
/// EKEventStoreChanged – no polling.
final class RemindersModule: NotchModule {
    let id = "reminders"
    var title: String { L("Erinnerungen", "Reminders") }
    let symbol = "checklist"
    let priority = ModulePriority.calendar
    let hasExpandedContent = true
    var isActive: Bool { false }

    enum Group: CaseIterable {
        case overdue, today, upcoming, undated

        var title: String {
            switch self {
            case .overdue: return L("Überfällig", "Overdue")
            case .today: return L("Heute", "Today")
            case .upcoming: return L("Demnächst", "Upcoming")
            case .undated: return L("Ohne Datum", "No date")
            }
        }
    }

    /// When a new reminder is due.
    enum Due: CaseIterable {
        case today, tomorrow, none

        var title: String {
            switch self {
            case .today: return L("Heute", "Today")
            case .tomorrow: return L("Morgen", "Tomorrow")
            case .none: return L("Ohne Datum", "No date")
            }
        }
    }

    @Published private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    /// Open reminders, sorted by due date (undated last).
    @Published private(set) var reminders: [EKReminder] = []
    @Published private(set) var lists: [EKCalendar] = []

    private let store = EKEventStore()
    private var observers: [NSObjectProtocol] = []

    var hasAccess: Bool { access == .fullAccess }

    /// Overdue and today's reminders as a badge on the tab.
    var headerInfo: HeaderInfo? {
        let count = reminders.filter { [.overdue, .today].contains(group(of: $0)) }.count
        return count > 0 ? .badge(count) : nil
    }

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                                queue: .main) { [weak self] _ in self?.reload() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in self?.reload() })
        reload()
    }

    func requestAccess() {
        store.requestFullAccessToReminders { [weak self] _, _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    func reload() {
        access = EKEventStore.authorizationStatus(for: .reminder)
        guard hasAccess else {
            reminders = []
            lists = []
            return
        }
        lists = store.calendars(for: .reminder).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] found in
            let sorted = (found ?? []).sorted { a, b in
                let da = Self.dueDate(of: a) ?? .distantFuture
                let db = Self.dueDate(of: b) ?? .distantFuture
                return da != db ? da < db : (a.creationDate ?? .distantPast) < (b.creationDate ?? .distantPast)
            }
            DispatchQueue.main.async { self?.reminders = sorted }
        }
    }

    static func dueDate(of reminder: EKReminder) -> Date? {
        reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
    }

    func group(of reminder: EKReminder) -> Group {
        guard let due = Self.dueDate(of: reminder) else { return .undated }
        let calendar = Calendar.current
        if calendar.isDateInToday(due) {
            // A timed reminder earlier today is overdue already.
            let timed = reminder.dueDateComponents?.hour != nil
            return timed && due < Date() ? .overdue : .today
        }
        return due < calendar.startOfDay(for: Date()) ? .overdue : .upcoming
    }

    func reminders(in group: Group) -> [EKReminder] {
        reminders.filter { self.group(of: $0) == group }
    }

    var defaultList: EKCalendar? { store.defaultCalendarForNewReminders() }

    func complete(_ reminder: EKReminder) {
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        reminders.removeAll { $0.calendarItemIdentifier == reminder.calendarItemIdentifier }
    }

    func add(_ title: String, list: EKCalendar?, due: Due) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, hasAccess, let list = list ?? defaultList else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = list
        let calendar = Calendar.current
        switch due {
        case .today: reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day], from: Date())
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
            reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        case .none: break
        }
        try? store.save(reminder, commit: true)
        reload()
    }

    func list(withID id: String?) -> EKCalendar? {
        lists.first { $0.calendarIdentifier == id }
    }

    func openRemindersApp() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.open(app)
        }
    }

    func compactLeading() -> AnyView { AnyView(EmptyView()) }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }
    func expandedView() -> AnyView { AnyView(RemindersPage(module: self)) }
}

// MARK: - Page

private struct RemindersPage: View {
    @ObservedObject var module: RemindersModule

    var body: some View {
        if !module.hasAccess {
            RemindersAccessView(module: module)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                header
                if module.reminders.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 26, weight: .light))
                        Text(L("Alles erledigt", "All done"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(RemindersModule.Group.allCases, id: \.self) { group in
                                let items = module.reminders(in: group)
                                if !items.isEmpty { section(group, items) }
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                NewReminderField(module: module)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L("Erinnerungen", "Reminders"))
                .font(.system(size: 16, weight: .bold))
            Text(L("\(module.reminders.count) offen", "\(module.reminders.count) open"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 8)
            Button { module.openRemindersApp() } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(L("In Erinnerungen öffnen", "Open in Reminders"))
        }
    }

    private func section(_ group: RemindersModule.Group, _ items: [EKReminder]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(group.title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(group == .overdue ? Color.red.opacity(0.85) : .white.opacity(0.45))
                Text("\(items.count)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.3))
            }
            // Two columns so more fits in the wide, short island.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                      alignment: .leading, spacing: 4) {
                ForEach(items, id: \.calendarItemIdentifier) { reminder in
                    ReminderRow(module: module, reminder: reminder, group: group)
                }
            }
        }
    }
}

private struct ReminderRow: View {
    @ObservedObject var module: RemindersModule
    let reminder: EKReminder
    let group: RemindersModule.Group
    @State private var ticked = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { ticked = true }
            // Let the tick show a moment before the row goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation { module.complete(reminder) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ticked ? Color.green : Color(cgColor: reminder.calendar.cgColor))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(reminder.title ?? "")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(ticked ? 0.4 : 0.92))
                        .strikethrough(ticked)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(group == .overdue ? Color.red.opacity(0.8) : .white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if reminder.priority > 0 && reminder.priority <= 4 {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Due day/time and the list's name.
    private var detail: String? {
        var parts: [String] = []
        if let due = RemindersModule.dueDate(of: reminder) {
            let timed = reminder.dueDateComponents?.hour != nil
            switch group {
            case .today:
                if timed { parts.append(due.formatted(.dateTime.hour().minute().locale(appLocale))) }
            default:
                var text = due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(appLocale))
                if timed { text += ", " + due.formatted(.dateTime.hour().minute().locale(appLocale)) }
                parts.append(text)
            }
        }
        if module.lists.count > 1 { parts.append(reminder.calendar.title) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// "+ New reminder" with the day and the list beside it.
private struct NewReminderField: View {
    @ObservedObject var module: RemindersModule
    @State private var text = ""
    @State private var due: RemindersModule.Due = .today
    @AppStorage("remindersListID") private var listID = ""
    @FocusState private var typing: Bool

    private var list: EKCalendar? { module.list(withID: listID) ?? module.defaultList }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(cgColor: list?.cgColor ?? NSColor.systemBlue.cgColor))
            TextField(L("Neue Erinnerung", "New reminder"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($typing)
                .onSubmit {
                    module.add(text, list: list, due: due)
                    text = ""
                }
                .onTapGesture {
                    // The island panel only takes typing when asked to.
                    NotificationCenter.default.post(name: .islandWantsKeyboard, object: nil)
                    typing = true
                }
            Menu {
                ForEach(RemindersModule.Due.allCases, id: \.self) { option in
                    Button(option.title) { due = option }
                }
            } label: {
                chip(due.title, symbol: "calendar")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            Menu {
                ForEach(module.lists, id: \.calendarIdentifier) { calendar in
                    Button(calendar.title) { listID = calendar.calendarIdentifier }
                }
            } label: {
                chip(list?.title ?? L("Liste", "List"), symbol: "list.bullet")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func chip(_ title: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

private struct RemindersAccessView: View {
    @ObservedObject var module: RemindersModule

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 72, height: 72)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Zugriff auf Erinnerungen nötig", "Reminders access needed"))
                    .font(.system(size: 14, weight: .semibold))
                if module.access == .notDetermined {
                    Button(L("Zugriff erlauben", "Allow access")) { module.requestAccess() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Text(L("In den Systemeinstellungen unter Datenschutz → Erinnerungen freigeben.",
                           "Allow it in System Settings → Privacy → Reminders."))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer()
        }
    }
}
