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
        let ahead = calendar.date(byAdding: .day, value: max(1, settings.calendarDaysAhead), to: today)!
        // The week view always needs the whole current week.
        let weekEnd = calendar.dateInterval(of: .weekOfYear, for: today)?.end ?? ahead
        let end = max(ahead, weekEnd)
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

    /// Shows the event in Calendar (or at least opens Calendar).
    func openInCalendar() {
        let id = calendarItemExternalIdentifier ?? ""
        if let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"),
           NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open(app)
        }
    }

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

/// Two views, switched top right: Week – seven columns with each day's
/// events, today highlighted with a line for "now" – and Day – today in
/// detail on an hour timeline, with the to-dos beside it.
private struct CalendarPage: View {
    @ObservedObject var module: CalendarModule
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("calendarMode") private var mode = "week"

    var body: some View {
        if !module.hasAccess {
            AccessView(module: module)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    ModeSwitch(mode: $mode)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
                }
                ZStack {
                    if mode == "day" {
                        HStack(alignment: .top, spacing: 12) {
                            DayTimeline(module: module)
                                .frame(maxWidth: .infinity)
                            if settings.calendarShowReminders {
                                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                                TodoColumn(module: module, day: Calendar.current.startOfDay(for: Date()))
                                    .frame(width: 170)
                            }
                        }
                        .transition(.opacity)
                    } else {
                        WeekGrid(module: module)
                            .transition(.opacity)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .animation(.easeInOut(duration: 0.2), value: mode)
            }
        }
    }

    private var title: some View {
        let calendar = Calendar.current
        let now = Date()
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if mode == "day" {
                Text(now.formatted(.dateTime.weekday(.wide).locale(appLocale)))
                    .font(.system(size: 16, weight: .bold))
                Text(now.formatted(.dateTime.day().month(.wide).locale(appLocale)))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                let week = calendar.component(.weekOfYear, from: now)
                Text(L("KW \(week)", "Week \(week)"))
                    .font(.system(size: 16, weight: .bold))
                if let interval = calendar.dateInterval(of: .weekOfYear, for: now) {
                    let last = interval.end.addingTimeInterval(-1)
                    Text(interval.start.formatted(.dateTime.day().month(.abbreviated).locale(appLocale)) + " – "
                         + last.formatted(.dateTime.day().month(.abbreviated).locale(appLocale)))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }
}

/// "Day | Week" in a small capsule.
private struct ModeSwitch: View {
    @Binding var mode: String
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            item("day", L("Tag", "Day"))
            item("week", L("Woche", "Week"))
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func item(_ value: String, _ label: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { mode = value }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(mode == value ? 1 : 0.5))
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background {
                    if mode == value {
                        Capsule().fill(Color.white.opacity(0.16)).matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Week

private struct WeekGrid: View {
    @ObservedObject var module: CalendarModule

    var body: some View {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? calendar.startOfDay(for: Date())
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(alignment: .top, spacing: 5) {
                ForEach(days, id: \.self) { day in
                    WeekColumn(day: day, events: module.events(on: day), now: context.date)
                }
            }
        }
    }
}

private struct WeekColumn: View {
    let day: Date
    let events: [EKEvent]
    let now: Date

    var body: some View {
        let calendar = Calendar.current
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let isPast = day < calendar.startOfDay(for: now)
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text(day.formatted(.dateTime.weekday(.abbreviated).locale(appLocale)).uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(isToday ? Color.red : .white.opacity(isPast ? 0.35 : 0.55))
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(isPast ? .white.opacity(0.4) : .white)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Circle().fill(isToday ? Color.red : .clear))
            }
            .lineLimit(1)
            GeometryReader { proxy in
                let allDay = events.filter(\.isAllDay)
                let timed = events.filter { !$0.isAllDay }
                // As many cards as fit; the rest as "+N".
                let room = proxy.size.height - CGFloat(allDay.prefix(1).count) * 21
                let fits = max(0, Int((room + 4) / 40))
                let shown = timed.count > fits ? Array(timed.prefix(max(0, fits - 1))) : timed
                let hidden = timed.count - shown.count
                VStack(spacing: 4) {
                    ForEach(allDay.prefix(1), id: \.calendarItemIdentifier) { event in
                        Text(event.title ?? "")
                            .font(.system(size: 9.5, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(event.tint.opacity(0.45)))
                            .onTapGesture { event.openInCalendar() }
                    }
                    if timed.isEmpty && allDay.isEmpty {
                        Text(L("Frei", "Free"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.top, 10)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.calendarItemIdentifier) { index, event in
                        if isToday && event.startDate > now && (index == 0 || shown[index - 1].startDate <= now) {
                            NowLine()
                        }
                        WeekCard(event: event, now: now)
                    }
                    if isToday, let last = shown.last, last.startDate <= now { NowLine() }
                    if hidden > 0 {
                        Text("+\(hidden)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(isToday ? 3 : 0)
            .background {
                if isToday {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WeekCard: View {
    let event: EKEvent
    let now: Date

    var body: some View {
        let past = event.endDate < now
        HStack(spacing: 4) {
            Capsule().fill(event.tint).frame(width: 2.5).padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title ?? "")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                Text(event.startDate.formatted(.dateTime.hour().minute().locale(appLocale)))
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(event.tint.opacity(0.3)))
        .opacity(past ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { event.openInCalendar() }
        .help(event.title ?? "")
    }
}

/// A red dot and line: now.
private struct NowLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
            Rectangle().fill(Color.red).frame(height: 1.5)
        }
        .frame(height: 6)
    }
}

// MARK: Day

/// Today on an hour timeline: every event as a block at its time and as
/// long as it lasts, all-day ones on top, a red line at the current time.
/// Opens scrolled to now.
private struct DayTimeline: View {
    @ObservedObject var module: CalendarModule
    private let hourHeight: CGFloat = 34

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let events = module.events(on: today)
        let allDay = events.filter(\.isAllDay)
        let timed = events.filter { !$0.isAllDay }
        VStack(alignment: .leading, spacing: 4) {
            if !allDay.isEmpty {
                HStack(spacing: 4) {
                    ForEach(allDay, id: \.calendarItemIdentifier) { event in
                        Text(event.title ?? "")
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(event.tint.opacity(0.45)))
                            .onTapGesture { event.openInCalendar() }
                    }
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                ForEach(0..<24, id: \.self) { hour in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text(String(format: "%02d", hour))
                                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                                            .foregroundStyle(.white.opacity(0.35))
                                            .frame(width: 16, alignment: .trailing)
                                            .offset(y: -5)
                                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                                    }
                                    .frame(height: hourHeight, alignment: .top)
                                    .id(hour)
                                }
                            }
                            ForEach(layout(timed, day: today), id: \.event.calendarItemIdentifier) { item in
                                block(item, now: context.date)
                            }
                            let minutes = context.date.timeIntervalSince(today) / 60
                            NowLine()
                                .padding(.leading, 19)
                                .offset(y: CGFloat(minutes / 60) * hourHeight - 3)
                        }
                        .padding(.top, 5)
                    }
                }
                .onAppear {
                    let hour = max(0, calendar.component(.hour, from: Date()) - 1)
                    proxy.scrollTo(hour, anchor: .top)
                }
            }
            if events.isEmpty {
                Text(L("Heute keine Termine – genieß deine freie Zeit!", "No events today – enjoy your free time!"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private struct Placed {
        let event: EKEvent
        let column: Int
        let columns: Int
    }

    /// Overlapping events sit side by side.
    private func layout(_ events: [EKEvent], day: Date) -> [Placed] {
        var placed: [Placed] = []
        var group: [(EKEvent, Int)] = []
        var groupEnd = Date.distantPast
        func flush() {
            let count = (group.map(\.1).max() ?? 0) + 1
            placed += group.map { Placed(event: $0.0, column: $0.1, columns: count) }
            group = []
        }
        for event in events.sorted(by: { $0.startDate < $1.startDate }) {
            if event.startDate >= groupEnd { flush() }
            let used = Set(group.filter { $0.0.endDate > event.startDate }.map(\.1))
            let column = (0...).first { !used.contains($0) }!
            group.append((event, column))
            groupEnd = max(groupEnd, event.endDate)
        }
        flush()
        return placed
    }

    private func block(_ item: Placed, now: Date) -> some View {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = start.addingTimeInterval(86_400)
        let from = max(item.event.startDate, start), to = min(item.event.endDate, end)
        let top = CGFloat(from.timeIntervalSince(start) / 3600) * hourHeight
        let height = max(18, CGFloat(to.timeIntervalSince(from) / 3600) * hourHeight - 2)
        let past = item.event.endDate < now
        return GeometryReader { proxy in
            let width = (proxy.size.width - 24) / CGFloat(item.columns)
            HStack(alignment: .top, spacing: 5) {
                Capsule().fill(item.event.tint).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.event.title ?? "")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(height > 40 ? 2 : 1)
                    if height > 28 {
                        Text(item.event.startDate.formatted(.dateTime.hour().minute().locale(appLocale)) + " – "
                             + item.event.endDate.formatted(.dateTime.hour().minute().locale(appLocale))
                             + (item.event.location.map { $0.isEmpty ? "" : " · " + $0 } ?? ""))
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let link = item.event.meetingURL, !past, height > 24 {
                    Button { NSWorkspace.shared.open(link) } label: {
                        Image(systemName: "video.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 22, height: 16)
                            .background(Capsule().fill(item.event.tint))
                    }
                    .buttonStyle(PressScaleStyle())
                    .help(L("Beitreten", "Join"))
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .frame(width: width - 2, height: height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(item.event.tint.opacity(0.3)))
            .opacity(past ? 0.5 : 1)
            .contentShape(Rectangle())
            .onTapGesture { item.event.openInCalendar() }
            .offset(x: 24 + CGFloat(item.column) * width, y: top)
        }
        .frame(height: 24 * hourHeight)
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
