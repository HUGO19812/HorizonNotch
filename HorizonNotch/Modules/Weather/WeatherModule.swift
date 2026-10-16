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
            return L("Kein Standortzugriff. Erlaube ihn in den Systemeinstellungen oder trag in den Einstellungen eine Stadt ein.",
                     "No location access. Allow it in System Settings or enter a city in the settings.")
        case .cityNotFound:
            return L("Stadt nicht gefunden. Prüfe die Eingabe in den Einstellungen.",
                     "City not found. Check the name in the settings.")
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

private struct HourRow: View {
    let hours: [WeatherService.Hour]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(hours) { hour in
                VStack(spacing: 4) {
                    Text(hour.time.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted))))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Image(systemName: WeatherCode.symbol(hour.code, isDay: hour.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 14))
                        .frame(height: 16)
                    Text(temperature(hour.temperature))
                        .font(.system(size: 11, weight: .semibold))
                }
            }
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
            Spacer(minLength: 0)
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
            Spacer(minLength: 0)
            HourRow(hours: hours)
        }
    }
}
