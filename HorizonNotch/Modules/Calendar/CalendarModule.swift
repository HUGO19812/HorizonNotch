import AppKit
import Combine
import EventKit
import SwiftUI

/// Appointments via EventKit: month header, a snapping strip of days and
/// the events of the chosen day, plus a countdown next to the notch shortly before a
/// meeting. Updates come from EKEventStoreChanged plus one work item for the
/// next moment the display has to change – no polling.
final class CalendarModule: NotchModule {
    let id = "calendar"
    var title: String { L("Kalender", "Calendar") }
    let symbol = "calendar"
    let priority = ModulePriority.calendar
    let hasExpandedContent = true
    let compactWingWidth: CGFloat = 64

    static let graceAfterStart: TimeInterval = 2 * 60
    /// Days before today in the date strip.
    static let daysBack = 7

    @Published private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    /// Events from a week ago over the configured number of days ahead.
    @Published private(set) var events: [EKEvent] = []
    /// The meeting that is about to start or just started.
    @Published private(set) var imminent: EKEvent?
    /// Open reminders (to-dos) with or without a due date.
    @Published private(set) var reminders: [EKReminder] = []
    @Published private(set) var reminderAccess: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)

    private let store = EKEventStore()
    private let settings = AppSettings.shared
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var nextUpdate: DispatchWorkItem?

    var isActive: Bool { imminent != nil }

    /// Today's day of the month.
    var headerInfo: HeaderInfo? { .text("\(Calendar.current.component(.day, from: Date()))") }
    var hasAccess: Bool { access == .fullAccess }
    private var leadTime: TimeInterval { TimeInterval(max(1, settings.calendarLeadMinutes) * 60) }

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                                queue: .main) { [weak self] _ in self?.reload() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in self?.reload() })
        Publishers.Merge4(settings.$calendarDaysAhead.map { _ in () }, settings.$calendarShowAllDay.map { _ in () },
                          settings.$calendarCountdown.map { _ in () }, settings.$calendarLeadMinutes.map { _ in () })
            .dropFirst(4)
            .sink { [weak self] in DispatchQueue.main.async { self?.reload() } }
            .store(in: &subscriptions)
        settings.$calendarShowReminders.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reloadReminders() } }
            .store(in: &subscriptions)
        reload()
    }

    // MARK: - Reminders

    var hasReminderAccess: Bool { reminderAccess == .fullAccess }

    func requestReminderAccess() {
        store.requestFullAccessToReminders { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
                self?.reloadReminders()
            }
        }
    }

    func reloadReminders() {
        reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
        guard settings.calendarShowReminders, hasReminderAccess else {
            reminders = []
            return
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] found in
            let sorted = (found ?? []).sorted { a, b in
                let da = a.dueDateComponents?.date ?? .distantFuture
                let db = b.dueDateComponents?.date ?? .distantFuture
                return da != db ? da < db : (a.creationDate ?? .distantPast) < (b.creationDate ?? .distantPast)
            }
            DispatchQueue.main.async { self?.reminders = sorted }
        }
    }

    /// To-dos for a day: due that day, plus (on today) overdue and undated ones.
    func reminders(on day: Date) -> [EKReminder] {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day)
        return reminders.filter { reminder in
            guard let due = reminder.dueDateComponents.flatMap({ calendar.date(from: $0) }) else { return isToday }
            if calendar.isDate(due, inSameDayAs: day) { return true }
            return isToday && due < calendar.startOfDay(for: day)
        }
    }

    func complete(_ reminder: EKReminder) {
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        reminders.removeAll { $0.calendarItemIdentifier == reminder.calendarItemIdentifier }
    }

    func addReminder(_ title: String, on day: Date) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, hasReminderAccess, let list = store.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = list
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: day)
        try? store.save(reminder, commit: true)
        reloadReminders()
    }

    #if DEBUG
    /// Fills the module with made-up events so the page can be checked
    /// without calendar access.
    func debugDemo() {
        access = .fullAccess
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func make(_ title: String, day: Int, hour: Int, minutes: Int, location: String? = nil, allDay: Bool = false) -> EKEvent {
            let event = EKEvent(eventStore: store)
            event.title = title
            event.location = location
            event.isAllDay = allDay
            event.startDate = calendar.date(byAdding: .minute, value: (day * 24 + hour) * 60, to: today)!
            event.endDate = event.startDate.addingTimeInterval(TimeInterval(minutes * 60))
            return event
        }
        events = [
            make("Schularbeit Mathematik", day: 0, hour: 8, minutes: 100, location: "Raum 2.14"),
            make("Projektbesprechung", day: 0, hour: 13, minutes: 45, location: "https://zoom.us/j/123"),
            make("Training", day: 0, hour: 18, minutes: 90, location: "Sporthalle"),
            make("Geburtstag Lena", day: 1, hour: 0, minutes: 1440, allDay: true),
            make("Zahnarzt", day: 2, hour: 10, minutes: 30),
        ]
    }
    #endif

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.access = EKEventStore.authorizationStatus(for: .event)
                self?.reload()
            }
        }
    }

    func reload() {
        reloadReminders()
        access = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else {
            events = []
            imminent = nil
            return
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -Self.daysBack, to: today)!
        let end = calendar.date(byAdding: .day, value: max(1, settings.calendarDaysAhead), to: today)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.status != .canceled && (settings.calendarShowAllDay || !$0.isAllDay) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
        evaluate()
    }

    func events(on day: Date) -> [EKEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return events.filter { $0.startDate < end && $0.endDate > start }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
    }

    /// The next timed event that has not ended yet.
    var nextEvent: EKEvent? {
        let now = Date()
        return events.filter { !$0.isAllDay && $0.endDate > now }.min { $0.startDate < $1.startDate }
    }

    private func evaluate() {
        let now = Date()
        let timed = events.filter { !$0.isAllDay }
        imminent = settings.calendarCountdown ? timed.first { event in
            event.startDate.timeIntervalSince(now) <= leadTime
                && now.timeIntervalSince(event.startDate) <= Self.graceAfterStart
                && event.endDate > now
        } : nil
        // Next moment something visible changes.
        let moments = timed.flatMap { [$0.startDate.addingTimeInterval(-leadTime),
                                       $0.startDate.addingTimeInterval(Self.graceAfterStart),
                                       $0.endDate] }
            .filter { $0 > now }
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
        let next = (moments + [midnight]).min()!
        nextUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        nextUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + next.timeIntervalSince(now) + 0.5, execute: work)
    }

    func compactLeading() -> AnyView { AnyView(CalendarCompactLeading(module: self)) }
    func compactTrailing() -> AnyView { AnyView(CalendarCompactTrailing(module: self)) }
    func expandedView() -> AnyView { AnyView(CalendarPage(module: self)) }
}

extension EKEvent {
    var tint: Color { Color(nsColor: calendar?.color ?? .systemBlue) }

    /// A video call link from the URL, location or notes, if any.
    var meetingURL: URL? {
        if let url, ["zoom", "teams", "meet.google", "webex", "facetime"].contains(where: { url.absoluteString.contains($0) }) {
            return url
        }
        let text = [location, notes].compactMap { $0 }.joined(separator: " ")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.url).first { link in
            ["zoom.us", "teams.microsoft", "meet.google", "webex", "facetime"].contains { link.absoluteString.contains($0) }
        }
    }
}


// MARK: - Compact

private struct CalendarCompactLeading: View {
    @ObservedObject var module: CalendarModule
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar")
                .foregroundStyle(theme.tint(module.imminent?.tint ?? .white))
            Text(module.imminent?.title ?? "")
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.85))
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
    }
}

private struct CalendarCompactTrailing: View {
    @ObservedObject var module: CalendarModule
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Group {
            if let event = module.imminent {
                if event.startDate > Date() {
                    Text(timerInterval: Date()...event.startDate, countsDown: true)
                        .foregroundStyle(theme.tint(event.tint))
                } else {
                    Text(L("Jetzt", "Now")).foregroundStyle(theme.tint(event.tint))
                }
            }
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 10)
    }
}

// MARK: - Page

/// Month header, a snapping strip of days (one week back, the configured
/// number of days ahead) and the chosen day's events below.
private struct CalendarPage: View {
    @ObservedObject var module: CalendarModule
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedDay: Date? = Calendar.current.startOfDay(for: Date())

    var body: some View {
        if !module.hasAccess {
            AccessView(module: module)
        } else {
            let day = selectedDay ?? Calendar.current.startOfDay(for: Date())
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(day.formatted(.dateTime.month(.abbreviated).locale(appLocale)))
                            .font(.title3.weight(.semibold))
                        Text(day.formatted(.dateTime.year()))
                            .font(.title3.weight(.light))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .frame(width: 58, alignment: .leading)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: day)
                    DayStrip(days: days, selected: $selectedDay) { day, isSelected in
                        DayCell(day: day, isSelected: isSelected)
                    }
                }
                .frame(height: 50)
                HStack(alignment: .top, spacing: 12) {
                    // Events and to-dos share the width equally.
                    DayEvents(module: module, day: day)
                        .frame(maxWidth: .infinity)
                    if settings.calendarShowReminders {
                        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                        TodoColumn(module: module, day: day)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var days: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (-CalendarModule.daysBack..<max(1, settings.calendarDaysAhead))
            .compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }
}

private struct DayCell: View {
    let day: Date
    let isSelected: Bool

    var body: some View {
        let isToday = Calendar.current.isDateInToday(day)
        VStack(spacing: 4) {
            Text(day.formatted(.dateTime.weekday(.abbreviated).locale(appLocale)))
                .font(.caption)
                .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                .lineLimit(1)
            Text(day.formatted(.dateTime.day()))
                .font(.body.weight(.medium).monospacedDigit())
                .foregroundStyle(isToday ? .white : (isSelected ? .white : .white.opacity(0.6)))
                .frame(width: 24, height: 24)
                .background(Circle().fill(isToday ? Color.accentColor : .clear))
        }
        .modifier(DayCellBackground(isSelected: isSelected, isToday: isToday))
    }
}

/// The day's to-dos from Reminders beside the events: a circle to tick
/// one off, and a line to add a new one for that day.
private struct TodoColumn: View {
    @ObservedObject var module: CalendarModule
    let day: Date
    @State private var newTitle = ""
    @State private var done: Set<String> = []
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L("To-dos", "To-dos"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                let count = module.reminders(on: day).count
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            if !module.hasReminderAccess {
                Button(L("Erinnerungen erlauben", "Allow Reminders")) { module.requestReminderAccess() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(module.reminders(on: day), id: \.calendarItemIdentifier) { reminder in
                            row(reminder)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                    TextField(L("Neues To-do", "New to-do"), text: $newTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .focused($typing)
                        .onSubmit {
                            module.addReminder(newTitle, on: day)
                            newTitle = ""
                        }
                        .onTapGesture {
                            // The island panel only takes typing when asked to.
                            NotificationCenter.default.post(name: .islandWantsKeyboard, object: nil)
                            typing = true
                        }
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07)))
            }
        }
    }

    private func row(_ reminder: EKReminder) -> some View {
        let id = reminder.calendarItemIdentifier
        let ticked = done.contains(id)
        let overdue = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            .map { $0 < Calendar.current.startOfDay(for: Date()) } ?? false
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { _ = done.insert(id) }
            // Let the tick show a moment before the row goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation { module.complete(reminder) }
                done.remove(id)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ticked ? Color.green : Color(cgColor: reminder.calendar.cgColor).opacity(0.9))
                    .contentTransition(.symbolEffect(.replace))
                Text(reminder.title ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(ticked ? 0.4 : 0.9))
                    .strikethrough(ticked)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if overdue {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(overdue ? L("Überfällig", "Overdue") : "")
    }
}

private struct DayEvents: View {
    @ObservedObject var module: CalendarModule
    let day: Date

    var body: some View {
        let events = module.events(on: day)
        if events.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.45))
                VStack(alignment: .leading, spacing: 1) {
                    Text(Calendar.current.isDateInToday(day) ? L("Heute keine Termine", "No events today")
                                                             : L("Keine Termine", "No events"))
                        .font(.subheadline.weight(.medium))
                    Text(L("Genieß deine freie Zeit!", "Enjoy your free time!"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.element.calendarItemIdentifier) { index, event in
                            if index > 0 { Divider().overlay(Color.white.opacity(0.2)) }
                            EventRow(event: event).id(event.calendarItemIdentifier)
                        }
                    }
                }
                .onAppear { scrollToFocus(events, proxy) }
                .onChange(of: day) { _, _ in scrollToFocus(module.events(on: day), proxy) }
            }
        }
    }

    /// First upcoming timed event, else the first all-day one, else the last.
    private func scrollToFocus(_ events: [EKEvent], _ proxy: ScrollViewProxy) {
        let now = Date()
        let target = events.first { !$0.isAllDay && $0.endDate > now } ?? events.first(where: \.isAllDay) ?? events.last
        if let target { proxy.scrollTo(target.calendarItemIdentifier, anchor: .top) }
    }
}

private struct EventRow: View {
    let event: EKEvent

    var body: some View {
        let isPast = !event.isAllDay && event.endDate < Date()
        HStack(alignment: .center, spacing: 8) {
            Capsule().fill(event.tint).frame(width: 3)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "")
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let link = event.meetingURL, !isPast {
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 20)
                        .background(Capsule().fill(event.tint))
                }
                .buttonStyle(PressScaleStyle())
                .help(L("Beitreten", "Join"))
            }
            VStack(alignment: .trailing, spacing: 1) {
                if event.isAllDay {
                    Text(L("Ganztägig", "All-day"))
                } else {
                    Text(time(event.startDate))
                    Text(time(event.endDate)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .font(.caption.monospacedDigit())
        }
        .padding(.vertical, 5)
        .opacity(isPast ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { openInCalendar() }
    }

    private func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(appLocale))
    }

    private func openInCalendar() {
        let id = event.calendarItemExternalIdentifier ?? ""
        if let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"),
           NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open(app)
        }
    }
}

private struct AccessView: View {
    @ObservedObject var module: CalendarModule
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 72, height: 72)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Kalenderzugriff nötig", "Calendar access needed"))
                    .font(.system(size: 14, weight: .semibold))
                if module.access == .notDetermined {
                    Button(L("Zugriff erlauben", "Allow access")) { module.requestAccess() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Text(L("In den Systemeinstellungen unter Datenschutz → Kalender freigeben.",
                           "Allow it in System Settings → Privacy → Calendars."))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer()
        }
    }
}
