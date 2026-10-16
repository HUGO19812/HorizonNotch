import AppKit
import Combine
import SwiftUI

/// Weather page in the expanded island.
final class WeatherModule: NotchModule {
    let id = "weather"
    var title: String { L("Wetter", "Weather") }
    let symbol = "cloud.sun.fill"
    let priority = ModulePriority.media - 20
    let hasExpandedContent = true

    let service = WeatherService()
    private var subscription: AnyCancellable?

    init() {
        subscription = service.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var isActive: Bool { false }

    func compactLeading() -> AnyView { AnyView(EmptyView()) }
    func compactTrailing() -> AnyView { AnyView(EmptyView()) }
    func expandedView() -> AnyView { AnyView(WeatherPage(service: service)) }
}

/// A strip of days like the calendar; below it the chosen day: right now
/// for today, the day's forecast otherwise.
private struct WeatherPage: View {
    @ObservedObject var service: WeatherService
    @State private var selectedDay: Date? = Calendar.current.startOfDay(for: Date())

    var body: some View {
        Group {
            if let report = service.report {
                let day = selectedDay ?? Calendar.current.startOfDay(for: Date())
                VStack(spacing: 6) {
                    DayStrip(days: report.days.map(\.date), selected: $selectedDay, cellWidth: 40) { date, isSelected in
                        WeatherDayCell(day: report.days.first { $0.date == date }, date: date, isSelected: isSelected)
                    }
                    .frame(height: 54)
                    if Calendar.current.isDateInToday(day) {
                        TodayDetail(report: report, place: service.placeName)
                    } else if let forecast = report.days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) {
                        DayDetail(day: forecast, hours: report.hours(on: day), place: service.placeName)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: day)
            } else if let problem = service.problem {
                message(symbol: "location.slash", text: text(for: problem))
            } else {
                message(symbol: "cloud.sun", text: L("Wetter wird geladen …", "Loading weather …"))
            }
        }
        .onAppear { service.activate() }
    }

    private func text(for problem: WeatherService.Problem) -> String {
        switch problem {
        case .locationDenied:
            return L("Kein Standortzugriff. Erlaube ihn in den Systemeinstellungen oder such in den Einstellungen einen Ort.",
                     "No location access. Allow it in System Settings or search for a place in the settings.")
        case .cityNotFound:
            return L("Ort nicht gefunden. Such ihn in den Einstellungen und klick ihn an.",
                     "Place not found. Search for it in the settings and click it.")
        case .network:
            return L("Wetter gerade nicht erreichbar.", "Weather is unavailable right now.")
        }
    }

    private func message(symbol: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 56)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
        }
    }
}

private func temperature(_ value: Double) -> String { "\(Int(value.rounded()))°" }

private struct WeatherDayCell: View {
    let day: WeatherService.Day?
    let date: Date
    let isSelected: Bool

    var body: some View {
        let isToday = Calendar.current.isDateInToday(date)
        VStack(spacing: 3) {
            Text(isToday ? L("Heute", "Today") : date.formatted(.dateTime.weekday(.abbreviated).locale(appLocale)))
                .font(.caption2.weight(.medium))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                .lineLimit(1)
            Image(systemName: WeatherCode.symbol(day?.code ?? 3, isDay: true))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 13))
                .frame(height: 15)
            Text(day.map { temperature($0.high) } ?? "–")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
        }
        .modifier(DayCellBackground(isSelected: isSelected, isToday: isToday))
    }
}

private struct Detail: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 10))
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
    }
}

/// Hours side by side, scrollable with the trackpad or mouse wheel. Edges
/// fade out so it is clear there is more. Other days start at 8 am.
private struct HourRow: View {
    let hours: [WeatherService.Hour]
    var startHour: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(hours) { hour in
                        HourCell(hour: hour)
                            .id(hour.id)
                    }
                }
                .padding(.horizontal, 8)
            }
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                       .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .onAppear { scrollToStart(proxy) }
            .onChange(of: hours.first?.id) { _, _ in scrollToStart(proxy) }
        }
        .frame(maxWidth: .infinity)
        .background(HorizontalWheelScroll())
    }

    private func scrollToStart(_ proxy: ScrollViewProxy) {
        guard let startHour,
              let hour = hours.first(where: { Calendar.current.component(.hour, from: $0.time) == startHour })
        else { return }
        proxy.scrollTo(hour.id, anchor: .leading)
    }
}

private struct HourCell: View {
    let hour: WeatherService.Hour

    var body: some View {
        VStack(spacing: 3) {
            Text(hour.time.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted))))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Image(systemName: WeatherCode.symbol(hour.code, isDay: hour.isDay))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 14))
                .frame(height: 16)
            Text(temperature(hour.temperature))
                .font(.system(size: 11, weight: .semibold))
            Text(hour.rainChance >= 20 ? "\(hour.rainChance) %" : " ")
                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.cyan.opacity(0.85))
        }
        .frame(width: 32)
    }
}

/// A plain mouse wheel only scrolls vertically; this turns vertical wheel
/// movement over the hour row into sideways scrolling. Trackpads already
/// scroll sideways and are left alone.
private struct HorizontalWheelScroll: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WheelView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WheelView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !event.hasPreciseScrollingDeltas,
                      event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      let cgEvent = event.cgEvent?.copy() else { return event }
                // Move the vertical deltas to the horizontal axis, like
                // holding Shift does.
                let pairs: [(CGEventField, CGEventField)] = [
                    (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
                    (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
                ]
                for (vertical, horizontal) in pairs {
                    cgEvent.setIntegerValueField(horizontal, value: cgEvent.getIntegerValueField(vertical))
                    cgEvent.setIntegerValueField(vertical, value: 0)
                }
                cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2,
                                            value: cgEvent.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
                cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
                return NSEvent(cgEvent: cgEvent) ?? event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

private var windUnit: String { AppSettings.shared.useFahrenheit ? "mph" : "km/h" }

/// Today: the current conditions.
private struct TodayDetail: View {
    let report: WeatherService.Report
    let place: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: WeatherCode.symbol(report.code, isDay: report.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 30))
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(temperature(report.temperature))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text(WeatherCode.text(report.code))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Text("\(place.isEmpty ? "" : place + " · ")↑\(temperature(report.high)) ↓\(temperature(report.low))")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .frame(width: 176, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Detail(symbol: "thermometer.medium", text: L("Gefühlt ", "Feels ") + temperature(report.apparent))
                Detail(symbol: "wind", text: "\(Int(report.windSpeed.rounded())) \(windUnit)")
                Detail(symbol: "umbrella.fill", text: "\(report.precipitationChance) %")
                if let sun = report.sunEvent {
                    Detail(symbol: sun.isSunrise ? "sunrise.fill" : "sunset.fill",
                           text: sun.time.formatted(date: .omitted, time: .shortened))
                }
            }
            .frame(width: 100, alignment: .leading)
            HourRow(hours: report.hours)
        }
    }
}

/// Another day: its forecast and four times of day.
private struct DayDetail: View {
    let day: WeatherService.Day
    let hours: [WeatherService.Hour]
    let place: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: WeatherCode.symbol(day.code, isDay: true))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 30))
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(temperature(day.high)) / \(temperature(day.low))")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(WeatherCode.text(day.code))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(appLocale)))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .frame(width: 176, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Detail(symbol: "umbrella.fill", text: "\(day.rainChance) %")
                Detail(symbol: "wind", text: "\(Int(day.windMax.rounded())) \(windUnit)")
                if let sunrise = day.sunrise {
                    Detail(symbol: "sunrise.fill", text: sunrise.formatted(date: .omitted, time: .shortened))
                }
                if let sunset = day.sunset {
                    Detail(symbol: "sunset.fill", text: sunset.formatted(date: .omitted, time: .shortened))
                }
            }
            .frame(width: 100, alignment: .leading)
            HourRow(hours: hours, startHour: 8)
        }
    }
}
