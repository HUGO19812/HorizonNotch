import AppKit
import EventKit
import SwiftUI

/// Open reminders from the Reminders app on their own page, like Apple's
/// app: four smart lists on the left (Today, Scheduled, All, Important)
/// with a ring for what's done today, the chosen list on the right, and a
/// form for new reminders with date, time, repeat, list, priority and an
/// alert. Updates come from EKEventStoreChanged – no polling.
final class RemindersModule: NotchModule {
    let id = "reminders"
    var title: String { L("Erinnerungen", "Reminders") }
    let symbol = "checklist"
    let priority = ModulePriority.calendar
    let hasExpandedContent = true
    var isActive: Bool { false }

    /// The smart lists. ("Flagged" isn't readable through EventKit, so
    /// "Important" shows reminders with a priority.)
    enum Smart: String, CaseIterable {
        case today, scheduled, all, important

        var title: String {
            switch self {
            case .today: return L("Heute", "Today")
            case .scheduled: return L("Geplant", "Scheduled")
            case .all: return L("Alle", "All")
            case .important: return L("Wichtig", "Important")
            }
        }

        var symbol: String {
            switch self {
            case .today: return "calendar"
            case .scheduled: return "calendar.badge.clock"
            case .all: return "tray.fill"
            case .important: return "exclamationmark"
            }
        }

        var color: Color {
            switch self {
            case .today: return .blue
            case .scheduled: return .red
            case .all: return Color(white: 0.6)
            case .important: return .orange
            }
        }
    }

    enum Repeat: String, CaseIterable {
        case never, daily, weekly, monthly, yearly

        var title: String {
            switch self {
            case .never: return L("Nie", "Never")
            case .daily: return L("Täglich", "Daily")
            case .weekly: return L("Wöchentlich", "Weekly")
            case .monthly: return L("Monatlich", "Monthly")
            case .yearly: return L("Jährlich", "Yearly")
            }
        }

        var rule: EKRecurrenceRule? {
            let frequency: EKRecurrenceFrequency
            switch self {
            case .never: return nil
            case .daily: frequency = .daily
            case .weekly: frequency = .weekly
            case .monthly: frequency = .monthly
            case .yearly: frequency = .yearly
            }
            return EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: nil)
        }
    }

    /// Apple's priority values: 0 none, 9 low, 5 medium, 1 high.
    enum Priority: Int, CaseIterable {
        case none = 0, low = 9, medium = 5, high = 1

        var title: String {
            switch self {
            case .none: return L("Keine", "None")
            case .low: return L("Niedrig", "Low")
            case .medium: return L("Mittel", "Medium")
            case .high: return L("Hoch", "High")
            }
        }
    }

    /// Everything the form collects.
    struct Draft {
        var title = ""
        var notes = ""
        var hasDate = true
        var hasTime = false
        var date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        var repeats: Repeat = .never
        var listID = ""
        var priority: Priority = .none
        var alert = true
    }

    @Published private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    /// Open reminders, sorted by due date (undated last).
    @Published private(set) var reminders: [EKReminder] = []
    @Published private(set) var lists: [EKCalendar] = []
    /// Ticked off today, for the ring.
    @Published private(set) var doneToday = 0

    private let store = EKEventStore()
    private var observers: [NSObjectProtocol] = []

    var hasAccess: Bool { access == .fullAccess }

    /// Today's and overdue reminders as a badge on the tab.
    var headerInfo: HeaderInfo? {
        let count = items(in: .today).count
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
        let open = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: open) { [weak self] found in
            let sorted = (found ?? []).sorted { a, b in
                let da = Self.dueDate(of: a) ?? .distantFuture
                let db = Self.dueDate(of: b) ?? .distantFuture
                return da != db ? da < db : (a.creationDate ?? .distantPast) < (b.creationDate ?? .distantPast)
            }
            DispatchQueue.main.async { self?.reminders = sorted }
        }
        let start = Calendar.current.startOfDay(for: Date())
        let done = store.predicateForCompletedReminders(withCompletionDateStarting: start, ending: Date(), calendars: nil)
        store.fetchReminders(matching: done) { [weak self] found in
            let count = found?.count ?? 0
            DispatchQueue.main.async { self?.doneToday = count }
        }
    }

    static func dueDate(of reminder: EKReminder) -> Date? {
        reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
    }

    static func hasTime(_ reminder: EKReminder) -> Bool { reminder.dueDateComponents?.hour != nil }

    static func isOverdue(_ reminder: EKReminder) -> Bool {
        guard let due = dueDate(of: reminder) else { return false }
        return hasTime(reminder) ? due < Date() : due < Calendar.current.startOfDay(for: Date())
    }

    func items(in smart: Smart) -> [EKReminder] {
        let calendar = Calendar.current
        switch smart {
        case .today:
            return reminders.filter { reminder in
                guard let due = Self.dueDate(of: reminder) else { return false }
                return calendar.isDateInToday(due) || Self.isOverdue(reminder)
            }
        case .scheduled: return reminders.filter { $0.dueDateComponents != nil }
        case .all: return reminders
        case .important: return reminders.filter { $0.priority > 0 }
        }
    }

    var defaultList: EKCalendar? { store.defaultCalendarForNewReminders() }

    func list(withID id: String?) -> EKCalendar? {
        lists.first { $0.calendarIdentifier == id }
    }

    func complete(_ reminder: EKReminder) {
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        reminders.removeAll { $0.calendarItemIdentifier == reminder.calendarItemIdentifier }
        doneToday += 1
    }

    @discardableResult
    func add(_ draft: Draft) -> Bool {
        let text = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, hasAccess, let list = list(withID: draft.listID) ?? defaultList else { return false }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = list
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { reminder.notes = notes }
        reminder.priority = draft.priority.rawValue
        if draft.hasDate {
            let parts: Set<Calendar.Component> = draft.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: draft.date)
            if let rule = draft.repeats.rule { reminder.addRecurrenceRule(rule) }
            if draft.alert {
                // Without a time Apple's app reminds at 9:00.
                let at = draft.hasTime ? draft.date
                    : Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: draft.date) ?? draft.date
                reminder.addAlarm(EKAlarm(absoluteDate: at))
            }
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            NSLog("[HorizonNotch] saving reminder failed: %@", error.localizedDescription)
            return false
        }
        reload()
        return true
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
    @AppStorage("remindersSmartList") private var selectedRaw = RemindersModule.Smart.today.rawValue
    @State private var creating = false

    private var selected: RemindersModule.Smart { RemindersModule.Smart(rawValue: selectedRaw) ?? .today }

    var body: some View {
        if !module.hasAccess {
            RemindersAccessView(module: module)
        } else if creating {
            NewReminderForm(module: module) { withAnimation(.easeInOut(duration: 0.2)) { creating = false } }
        } else {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(RemindersModule.Smart.allCases, id: \.self) { smart in tile(smart) }
                    }
                }
                .frame(width: 196)
                listCard
            }
        }
    }

    /// Ring with what's done today, title and count.
    private var header: some View {
        let open = module.items(in: .today).count
        let total = open + module.doneToday
        return HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: total > 0 ? CGFloat(module.doneToday) / CGFloat(total) : 0)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Erinnerungen", "Reminders")).font(.system(size: 13.5, weight: .bold))
                Text(L("\(module.doneToday) von \(total) erledigt", "\(module.doneToday) of \(total) done"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
    }

    private func tile(_ smart: RemindersModule.Smart) -> some View {
        let active = smart == selected
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { selectedRaw = smart.rawValue }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: smart.symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(smart.color)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(smart.color.opacity(0.18)))
                Text(smart.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(active ? 1 : 0.6))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(module.items(in: smart).count)")
                    .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
            }
            .padding(.horizontal, 7)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? Color.blue.opacity(0.26) : Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(active ? Color.blue.opacity(0.55) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var listCard: some View {
        let items = module.items(in: selected)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(selected.title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(selected.color)
                Text("\(items.count)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()
                Button { module.openRemindersApp() } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help(L("In Erinnerungen öffnen", "Open in Reminders"))
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { creating = true }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 9.5, weight: .heavy))
                        Text(L("Neu", "New")).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.blue)
                    .padding(.horizontal, 9)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.blue.opacity(0.18)))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScaleStyle())
                .help(L("Neue Erinnerung", "New reminder"))
            }
            if items.isEmpty {
                Text(L("Alles erledigt", "All done"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(items, id: \.calendarItemIdentifier) { reminder in
                            ReminderRow(module: module, reminder: reminder)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

private struct ReminderRow: View {
    @ObservedObject var module: RemindersModule
    let reminder: EKReminder
    @State private var ticked = false

    var body: some View {
        let overdue = RemindersModule.isOverdue(reminder)
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { ticked = true }
            // Let the tick show a moment before the row goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation { module.complete(reminder) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ticked ? Color.green : Color(cgColor: reminder.calendar.cgColor))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 0) {
                    Text(reminder.title ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(ticked ? 0.4 : 0.95))
                        .strikethrough(ticked)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(overdue ? Color.red.opacity(0.9) : .white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if reminder.priority > 0 {
                    Text(reminder.priority <= 4 ? "!!!" : (reminder.priority == 5 ? "!!" : "!"))
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "overdue · 09:00 · Private".
    private var detail: String? {
        var parts: [String] = []
        if RemindersModule.isOverdue(reminder) { parts.append(L("überfällig", "overdue")) }
        if let due = RemindersModule.dueDate(of: reminder) {
            let timed = RemindersModule.hasTime(reminder)
            if Calendar.current.isDateInToday(due) {
                if timed { parts.append(due.formatted(.dateTime.hour().minute().locale(appLocale))) }
            } else {
                var text = due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(appLocale))
                if timed { text += ", " + due.formatted(.dateTime.hour().minute().locale(appLocale)) }
                parts.append(text)
            }
        }
        if module.lists.count > 1 { parts.append(reminder.calendar.title) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - New reminder

/// Like Apple's: title and notes, then date, time and repeat on the left,
/// list, priority and the alert on the right.
private struct NewReminderForm: View {
    @ObservedObject var module: RemindersModule
    let close: () -> Void
    @State private var draft = RemindersModule.Draft()
    @AppStorage("remindersListID") private var lastListID = ""
    @FocusState private var focus: Field?

    private enum Field { case title, notes }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Button(L("Abbrechen", "Cancel"), action: close)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                VStack(spacing: 0) {
                    TextField(L("Neue Erinnerung", "New reminder"), text: $draft.title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .focused($focus, equals: .title)
                        .onSubmit(save)
                    TextField(L("Notizen", "Notes"), text: $draft.notes)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .focused($focus, equals: .notes)
                        .onSubmit(save)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
                .onTapGesture { askForKeyboard(.title) }
                Button(L("Hinzufügen", "Add"), action: save)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Color.blue.opacity(draft.title.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1))
            }
            HStack(alignment: .top, spacing: 8) {
                block {
                    row("calendar", .red, L("Datum", "Date")) {
                        if draft.hasDate {
                            DatePicker("", selection: $draft.date, displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.field)
                                .controlSize(.small)
                                .fixedSize()
                                .onTapGesture { askForKeyboard(nil) }
                        }
                        Toggle("", isOn: $draft.hasDate.animation()).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    divider
                    row("clock.fill", .blue, L("Uhrzeit", "Time")) {
                        if draft.hasTime {
                            DatePicker("", selection: $draft.date, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .datePickerStyle(.field)
                                .controlSize(.small)
                                .fixedSize()
                                .onTapGesture { askForKeyboard(nil) }
                        }
                        Toggle("", isOn: Binding(get: { draft.hasTime }, set: { on in
                            withAnimation { draft.hasTime = on; if on { draft.hasDate = true } }
                        }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    divider
                    row("repeat", Color(white: 0.6), L("Wiederholen", "Repeat")) {
                        picker(draft.repeats.title) {
                            ForEach(RemindersModule.Repeat.allCases, id: \.self) { option in
                                Button(option.title) { draft.repeats = option; if option != .never { draft.hasDate = true } }
                            }
                        }
                    }
                }
                block {
                    row("list.bullet", .orange, L("Liste", "List")) {
                        let list = module.list(withID: draft.listID) ?? module.defaultList
                        picker(list?.title ?? "–", dot: list.map { Color(cgColor: $0.cgColor) }) {
                            ForEach(module.lists, id: \.calendarIdentifier) { calendar in
                                Button(calendar.title) { draft.listID = calendar.calendarIdentifier }
                            }
                        }
                    }
                    divider
                    row("exclamationmark", .red, L("Priorität", "Priority")) {
                        picker(draft.priority.title) {
                            ForEach(RemindersModule.Priority.allCases, id: \.self) { option in
                                Button(option.title) { draft.priority = option }
                            }
                        }
                    }
                    divider
                    row("bell.fill", .orange, L("Benachrichtigen", "Alert")) {
                        Toggle("", isOn: $draft.alert).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            .disabled(!draft.hasDate)
                    }
                }
            }
            if draft.hasDate {
                // Apple's quick picks for the day.
                HStack(spacing: 6) {
                    chip(L("Heute", "Today"), Calendar.current.isDateInToday(draft.date)) { setDay(0) }
                    chip(L("Morgen", "Tomorrow"), Calendar.current.isDateInTomorrow(draft.date)) { setDay(1) }
                    chip(L("Wochenende", "Weekend"), isWeekend) { setWeekend() }
                    chip(L("Nächste Woche", "Next week"), isNextWeek) { setDay(7) }
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            draft.listID = module.list(withID: lastListID) != nil ? lastListID : (module.defaultList?.calendarIdentifier ?? "")
            askForKeyboard(.title)
        }
    }

    private func chip(_ title: String, _ active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? Color.black : .white.opacity(0.75))
                .padding(.horizontal, 8)
                .frame(height: 19)
                .background(Capsule().fill(active ? Color.white : Color.white.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var isWeekend: Bool {
        let day = Calendar.current.component(.weekday, from: draft.date)
        return (day == 7 || day == 1) && draft.date.timeIntervalSinceNow < 7 * 86_400
    }

    private var isNextWeek: Bool {
        Calendar.current.isDate(draft.date, inSameDayAs: Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date())
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.leading, 30)
    }

    private func block<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
            .frame(maxWidth: .infinity)
    }

    private func row<Trailing: View>(_ symbol: String, _ color: Color, _ title: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 19, height: 19)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.16)))
            Text(title).font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 7)
        .frame(height: 21)
    }

    private func picker<Items: View>(_ title: String, dot: Color? = nil, @ViewBuilder items: () -> Items) -> some View {
        Menu { items() } label: {
            HStack(spacing: 4) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func setDay(_ offset: Int) {
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute], from: draft.date)
        let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Date())) ?? Date()
        draft.date = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
    }

    private func setWeekend() {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: Date()) // 1 = Sunday, 7 = Saturday
        setDay(weekday == 7 ? 7 : 7 - weekday)
    }

    private func askForKeyboard(_ field: Field?) {
        // The island panel only takes typing when asked to.
        NotificationCenter.default.post(name: .islandWantsKeyboard, object: nil)
        if let field { focus = field }
    }

    private func save() {
        guard module.add(draft) else { return }
        lastListID = draft.listID
        close()
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
