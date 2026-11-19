import AppKit
import CoreLocation
import os

/// Weather (R-13) from Open-Meteo (free, no key; data CC BY 4.0, attribution in Settings).
/// Location comes from macOS (approximate) and only coordinates rounded to 0.1° (~11 km) leave
/// the Mac. Refreshes every 30 min; nothing is requested while the module is off or the Mac sleeps.
final class WeatherModule: NSObject, Module, CLLocationManagerDelegate {
    let id = ModuleID.weather
    let actions: [ModuleAction] = []

    struct Report {
        let celsius: Double
        let code: Int
        let isDay: Bool
        let date: Date
    }

    enum Status { case idle, noLocation, failed }

    private(set) var report: Report?
    private(set) var status = Status.idle
    /// Called on the main thread when `report` or `status` change (the Touch Bar).
    var onChange: (() -> Void)?
    /// Posted with `onChange`, for other listeners (the menu bar item, R-30).
    static let didChangeNotification = Notification.Name("PenknifeWeatherDidChange")

    private let log = Logger(subsystem: "Penknife", category: "Weather")
    private var running = false
    private var location: CLLocationManager?
    private var coordinate: CLLocationCoordinate2D?
    private var session: URLSession?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard !running else { return }
        running = true
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        location = manager
        session = URLSession(configuration: .ephemeral)

        let center = NSWorkspace.shared.notificationCenter
        // Nothing is requested while the Mac or its screens sleep; on wake, refresh if stale.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            })
        }
        refresh()
    }

    func stop() {
        guard running else { return }
        running = false
        pause()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        location?.delegate = nil
        location = nil
        session?.invalidateAndCancel()
        session = nil
    }

    /// After waking: refresh if the report is stale (giving the network a moment), else wait for the rest.
    private func resume() {
        guard running, timer == nil, task == nil else { return }
        let age = report.map { Date().timeIntervalSince($0.date) } ?? .infinity
        schedule(after: WeatherTiming.afterWake(reportAge: age))
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
    }

    /// Refreshes now unless the last report is younger than `minAge` (a tap on the Touch Bar).
    func refresh(ifOlderThan minAge: TimeInterval = 0) {
        guard running, let location else { return }
        let age = report.map { Date().timeIntervalSince($0.date) }
        let step = WeatherRefresh.step(reportAge: age, minAge: minAge, status: status,
                                       authorization: location.authorizationStatus)
        if step == .nothing { return }
        if step == .openSettings { openLocationSettings(); return }
        pause()
        switch step {
        case .askPermission: location.requestWhenInUseAuthorization()
        case .locate: location.requestLocation()
        default: set(status: .noLocation)
        }
    }

    private func schedule(after seconds: TimeInterval) {
        guard running else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = WeatherTiming.tolerance(for: seconds)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func set(status: Status) {
        self.status = status
        onChange?()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Location

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard running else { return }
            switch authorization {
            case .authorized, .authorizedAlways: if report == nil { refresh() }
            case .denied, .restricted: set(status: .noLocation)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let rounded = WeatherRequest.rounded(last.coordinate)
        MainActor.assumeIsolated {
            coordinate = rounded
            fetch()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            log.error("Location: \(error.localizedDescription, privacy: .public)")
            // Use the last known place if there is one.
            if coordinate != nil { fetch() } else {
                set(status: WeatherRefresh.status(afterLocationError: error))
                schedule(after: WeatherTiming.retry)
            }
        }
    }

    // MARK: Open-Meteo

    private func fetch() {
        guard running, let coordinate, let session, let url = WeatherRequest.url(for: coordinate) else { return }
        task?.cancel()
        task = Task { [weak self] in
            do {
                let (data, response) = try await session.data(from: url)
                let report = try WeatherRequest.report(from: data, statusCode: (response as? HTTPURLResponse)?.statusCode,
                                                       date: Date())
                guard let self, !Task.isCancelled else { return }
                self.task = nil
                self.report = report
                self.set(status: .idle)
                self.schedule(after: WeatherTiming.interval)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.task = nil
                self.log.error("Open-Meteo: \(error.localizedDescription, privacy: .private)")
                self.set(status: .failed)
                self.schedule(after: WeatherTiming.retry)
            }
        }
    }
}

extension WeatherModule.Report {
    /// SF Symbol for the WMO weather code.
    var symbol: String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 65, 67, 82: "cloud.heavyrain.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    /// What VoiceOver and the menu say.
    var summary: String {
        switch code {
        case 0: String(localized: "Clear sky")
        case 1, 2: String(localized: "Partly cloudy")
        case 3: String(localized: "Cloudy")
        case 45, 48: String(localized: "Fog")
        case 51...57: String(localized: "Drizzle")
        case 61...67, 80...82: String(localized: "Rain")
        case 71...77, 85, 86: String(localized: "Snow")
        case 95...99: String(localized: "Thunderstorm")
        default: String(localized: "Cloudy")
        }
    }
}

/// When the weather is asked for again (WX-05, WX-06).
enum WeatherTiming {
    static let interval: TimeInterval = 30 * 60
    static let retry: TimeInterval = 2 * 60

    /// After a wake: what is left of the 30 min, but never sooner than 10 s (the network needs a moment).
    static func afterWake(reportAge: TimeInterval) -> TimeInterval { max(10, interval - reportAge) }

    static func tolerance(for seconds: TimeInterval) -> TimeInterval { min(seconds * 0.1, 60) }
}

/// What a refresh does (WX-03, WX-04, WX-07).
enum WeatherRefresh: Equatable {
    case nothing, openSettings, askPermission, locate, noLocation

    static func step(reportAge: TimeInterval?, minAge: TimeInterval, status: WeatherModule.Status,
                     authorization: CLAuthorizationStatus) -> WeatherRefresh {
        if let reportAge, reportAge < minAge { return .nothing }
        if status == .noLocation, authorization == .denied { return .openSettings }
        switch authorization {
        case .notDetermined: return .askPermission
        case .authorized, .authorizedAlways: return .locate
        default: return .noLocation
        }
    }
    /// The status when macOS can't give a place and none is known yet (WX-07).
    /// Only a refusal means "location not allowed"; anything else (no Wi-Fi, place unknown) is a failure.
    static func status(afterLocationError error: Error) -> WeatherModule.Status {
        (error as? CLError)?.code == .denied ? .noLocation : .failed
    }
}

/// What leaves the Mac and what comes back (WX-08, WX-09).
nonisolated enum WeatherRequest {
    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int
        }
        let current: Current
    }

    /// Coordinates rounded to 0.1° (about 11 km) before they leave the Mac.
    static func rounded(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (coordinate.latitude * 10).rounded() / 10,
                               longitude: (coordinate.longitude * 10).rounded() / 10)
    }

    static func url(for coordinate: CLLocationCoordinate2D) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.1f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.1f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
        ]
        return components.url
    }

    /// The report in an answer; throws unless the answer is a 200 with the three values.
    static func report(from data: Data, statusCode: Int?, date: Date) throws -> WeatherModule.Report {
        guard statusCode == 200 else { throw URLError(.badServerResponse) }
        let current = try JSONDecoder().decode(Response.self, from: data).current
        return WeatherModule.Report(celsius: current.temperature_2m, code: current.weather_code,
                                    isDay: current.is_day == 1, date: date)
    }
}
