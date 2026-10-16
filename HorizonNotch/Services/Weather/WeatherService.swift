import AppKit
import Combine
import CoreLocation

/// Current weather and the next hours from Open-Meteo (no API key).
/// The location comes from CoreLocation, or from a city typed in the
/// settings. Asks for location only once the weather page is first shown.
final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Hour: Identifiable, Equatable {
        let time: Date
        let temperature: Double
        let code: Int
        let isDay: Bool
        var rainChance: Int = 0
        var id: Date { time }
    }

    /// Forecast for one day of the date strip.
    struct Day: Identifiable, Equatable {
        let date: Date
        let code: Int
        let high: Double
        let low: Double
        let rainChance: Int
        let windMax: Double
        let sunrise: Date?
        let sunset: Date?
        var id: Date { date }
    }

    static let forecastDays = 10

    struct Report: Equatable {
        var temperature: Double
        var apparent: Double
        var code: Int
        var isDay: Bool
        var high: Double
        var low: Double
        var windSpeed: Double
        var precipitationChance: Int
        /// The next sunrise or sunset still ahead.
        var sunEvent: (isSunrise: Bool, time: Date)?
        var hours: [Hour]
        /// Every forecast hour (all days), for the other days' previews.
        var allHours: [Hour]
        var days: [Day]
        var fetched: Date

        /// Every hour of the given day, for the scrollable hour row.
        func hours(on day: Date) -> [Hour] {
            allHours.filter { Calendar.current.isDate($0.time, inSameDayAs: day) }
        }

        static func == (a: Report, b: Report) -> Bool {
            a.fetched == b.fetched && a.temperature == b.temperature && a.code == b.code
        }
    }

    enum Problem: Equatable {
        case locationDenied, cityNotFound, network
    }

    @Published private(set) var report: Report?
    @Published private(set) var placeName = ""
    @Published private(set) var problem: Problem?
    @Published private(set) var loading = false

    private let settings = AppSettings.shared
    private let locationManager = CLLocationManager()
    private var coordinate: CLLocationCoordinate2D?
    private var refreshTimer: Timer?
    private var activated = false
    private var subscriptions = Set<AnyCancellable>()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.refreshIfStale() }
            .store(in: &subscriptions)
        // Picking a place sets both; one lookup is enough.
        settings.$weatherCity.dropFirst().map { _ in () }
            .merge(with: settings.$weatherCoordinate.dropFirst().map { _ in () })
            .debounce(for: .seconds(0.3), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.resolveLocation() }
            .store(in: &subscriptions)
        settings.$weatherUsesLocation.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.resolveLocation() } }
            .store(in: &subscriptions)
        settings.$useFahrenheit.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.fetch() } }
            .store(in: &subscriptions)
    }

    /// Called when the weather page appears.
    func activate() {
        if !activated {
            activated = true
            resolveLocation()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.fetch() }
            refreshTimer?.tolerance = 120
        } else {
            refreshIfStale()
        }
    }

    private func refreshIfStale() {
        guard activated else { return }
        if let report, Date().timeIntervalSince(report.fetched) < 15 * 60 { return }
        fetch()
    }

    // MARK: - Location

    private func resolveLocation() {
        guard activated else { return }
        problem = nil
        if settings.weatherUsesLocation {
            switch locationManager.authorizationStatus {
            case .notDetermined:
                locationManager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                problem = .locationDenied
            default:
                locationManager.requestLocation()
            }
        } else if let picked = settings.weatherCoordinate {
            placeName = settings.weatherCity
            coordinate = CLLocationCoordinate2D(latitude: picked[0], longitude: picked[1])
            fetch()
        } else {
            geocode(city: settings.weatherCity)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard activated, settings.weatherUsesLocation else { return }
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways: manager.requestLocation()
        case .denied, .restricted: problem = .locationDenied
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        coordinate = location.coordinate
        fetch()
        CLGeocoder().reverseGeocodeLocation(location) { [weak self] marks, _ in
            DispatchQueue.main.async {
                self?.placeName = marks?.first?.locality ?? marks?.first?.name ?? ""
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[HorizonNotch] location: \(error.localizedDescription)")
        if coordinate == nil { problem = .network }
    }

    /// One hit of the place search in the settings.
    struct Place: Decodable, Identifiable, Hashable {
        let id: Int
        let name: String
        let latitude: Double
        let longitude: Double
        let admin1: String?
        let country: String?

        /// "Tyrol, Austria" – tells apart places with the same name.
        var region: String {
            [admin1, country].compactMap { $0 }.filter { !$0.isEmpty && $0 != name }.joined(separator: ", ")
        }
    }

    /// Places matching a name, from Open-Meteo's geocoding (no account).
    static func searchPlaces(_ query: String, german: Bool) async -> [Place] {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard name.count >= 2 else { return [] }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: german ? "de" : "en"),
        ]
        struct Result: Decodable { let results: [Place]? }
        guard let response = try? await URLSession.shared.data(from: components.url!),
              let result = try? JSONDecoder().decode(Result.self, from: response.0) else { return [] }
        return result.results ?? []
    }

    private func geocode(city: String) {
        let name = city.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            problem = .cityNotFound
            return
        }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: settings.isGerman ? "de" : "en"),
        ]
        URLSession.shared.dataTask(with: components.url!) { [weak self] data, _, _ in
            struct Result: Decodable { let results: [Place]? }
            struct Place: Decodable { let name: String; let latitude: Double; let longitude: Double }
            let place = data.flatMap { try? JSONDecoder().decode(Result.self, from: $0) }?.results?.first
            DispatchQueue.main.async {
                guard let self else { return }
                guard let place else {
                    self.problem = data == nil ? .network : .cityNotFound
                    return
                }
                self.placeName = place.name
                self.coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
                self.fetch()
            }
        }.resume()
    }

    // MARK: - Forecast

    func fetch() {
        guard let coordinate else { return }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day,precipitation_probability"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,precipitation_probability_max,wind_speed_10m_max"),
            URLQueryItem(name: "wind_speed_unit", value: settings.useFahrenheit ? "mph" : "kmh"),
            URLQueryItem(name: "forecast_days", value: String(Self.forecastDays)),
            // A week back, so the strip reads like the calendar's.
            URLQueryItem(name: "past_days", value: "7"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "temperature_unit", value: settings.useFahrenheit ? "fahrenheit" : "celsius"),
        ]
        loading = true
        URLSession.shared.dataTask(with: components.url!) { [weak self] data, _, _ in
            let report = data.flatMap(Self.parse)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                if let report {
                    self.report = report
                    self.problem = nil
                } else if self.report == nil {
                    self.problem = .network
                }
            }
        }.resume()
    }

    private static func parse(_ data: Data) -> Report? {
        struct Response: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let apparent_temperature: Double
                let weather_code: Int
                let is_day: Int
                let wind_speed_10m: Double?
            }
            struct Hourly: Decodable {
                let time: [Double]
                let temperature_2m: [Double]
                let weather_code: [Int]
                let is_day: [Int]
                let precipitation_probability: [Int?]?
            }
            struct Daily: Decodable {
                let time: [Double]
                let weather_code: [Int]?
                let temperature_2m_max: [Double]
                let temperature_2m_min: [Double]
                let sunrise: [Double]?
                let sunset: [Double]?
                let precipitation_probability_max: [Int?]?
                let wind_speed_10m_max: [Double?]?
            }
            let current: Current
            let hourly: Hourly
            let daily: Daily
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let now = Date()
        let hourly = response.hourly
        let count = min(hourly.time.count, hourly.temperature_2m.count, hourly.weather_code.count, hourly.is_day.count)
        let allHours = (0..<count)
            .map { Hour(time: Date(timeIntervalSince1970: hourly.time[$0]), temperature: hourly.temperature_2m[$0],
                        code: hourly.weather_code[$0], isDay: hourly.is_day[$0] == 1,
                        rainChance: (hourly.precipitation_probability?[$0] ?? 0) ?? 0) }
        // The next day's worth; the row scrolls sideways.
        let hours = allHours.filter { $0.time > now }.prefix(24)
        let daily = response.daily
        let days = daily.time.indices.map { i in
            Day(date: Date(timeIntervalSince1970: daily.time[i]),
                code: daily.weather_code?[i] ?? 3,
                high: daily.temperature_2m_max[i],
                low: daily.temperature_2m_min[i],
                rainChance: (daily.precipitation_probability_max?[i] ?? 0) ?? 0,
                windMax: (daily.wind_speed_10m_max?[i] ?? 0) ?? 0,
                sunrise: daily.sunrise.map { Date(timeIntervalSince1970: $0[i]) },
                sunset: daily.sunset.map { Date(timeIntervalSince1970: $0[i]) })
        }
        // Chance of rain for the hour we are in.
        let currentHour = hourly.time.lastIndex { Date(timeIntervalSince1970: $0) <= now }
        let rain = currentHour.flatMap { hourly.precipitation_probability?[$0] } ?? 0
        let suns = (response.daily.sunrise ?? []).map { (true, Date(timeIntervalSince1970: $0)) }
            + (response.daily.sunset ?? []).map { (false, Date(timeIntervalSince1970: $0)) }
        let nextSun = suns.filter { $0.1 > now }.min { $0.1 < $1.1 }
        // The data starts a week back; today's row is not the first one.
        let today = days.first { Calendar.current.isDateInToday($0.date) }
        return Report(temperature: response.current.temperature_2m,
                      apparent: response.current.apparent_temperature,
                      code: response.current.weather_code,
                      isDay: response.current.is_day == 1,
                      high: today?.high ?? response.current.temperature_2m,
                      low: today?.low ?? response.current.temperature_2m,
                      windSpeed: response.current.wind_speed_10m ?? 0,
                      precipitationChance: rain ?? 0,
                      sunEvent: nextSun.map { (isSunrise: $0.0, time: $0.1) },
                      hours: Array(hours),
                      allHours: allHours,
                      days: days,
                      fetched: now)
    }
}

/// WMO weather interpretation codes as used by Open-Meteo.
enum WeatherCode {
    static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 61, 63, 66, 67, 80, 81: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func text(_ code: Int) -> String {
        switch code {
        case 0: return L("Klar", "Clear")
        case 1: return L("Überwiegend klar", "Mostly clear")
        case 2: return L("Teils bewölkt", "Partly cloudy")
        case 3: return L("Bewölkt", "Overcast")
        case 45, 48: return L("Nebel", "Fog")
        case 51, 53, 55, 56, 57: return L("Nieselregen", "Drizzle")
        case 61, 63, 80, 81: return L("Regen", "Rain")
        case 65, 82: return L("Starker Regen", "Heavy rain")
        case 66, 67: return L("Gefrierender Regen", "Freezing rain")
        case 71, 73, 75, 77, 85, 86: return L("Schnee", "Snow")
        case 95, 96, 99: return L("Gewitter", "Thunderstorm")
        default: return ""
        }
    }
}
