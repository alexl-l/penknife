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

    private let log = Logger(subsystem: "Penknife", category: "Weather")
    private static let interval: TimeInterval = 30 * 60
    private static let retry: TimeInterval = 2 * 60
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
        schedule(after: max(10, Self.interval - age))
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
    }

    /// Refreshes now unless the last report is younger than `minAge` (a tap on the Touch Bar).
    func refresh(ifOlderThan minAge: TimeInterval = 0) {
        guard running else { return }
        if let report, Date().timeIntervalSince(report.date) < minAge { return }
        if status == .noLocation, location?.authorizationStatus == .denied {
            openLocationSettings()
            return
        }
        pause()
        switch location?.authorizationStatus {
        case .notDetermined:
            location?.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            location?.requestLocation()
        default:
            set(status: .noLocation)
        }
    }

    private func schedule(after seconds: TimeInterval) {
        guard running else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = min(seconds * 0.1, 60)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func set(status: Status) {
        self.status = status
        onChange?()
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
        let rounded = CLLocationCoordinate2D(latitude: (last.coordinate.latitude * 10).rounded() / 10,
                                             longitude: (last.coordinate.longitude * 10).rounded() / 10)
        MainActor.assumeIsolated {
            coordinate = rounded
            fetch()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            log.error("Location: \(error.localizedDescription, privacy: .public)")
            // Use the last known place if there is one.
            if coordinate != nil { fetch() } else { set(status: .noLocation); schedule(after: Self.retry) }
        }
    }

    // MARK: Open-Meteo

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int
        }
        let current: Current
    }

    private func fetch() {
        guard running, let coordinate, let session else { return }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.1f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.1f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
        ]
        guard let url = components.url else { return }
        task?.cancel()
        task = Task { [weak self] in
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let current = try JSONDecoder().decode(Response.self, from: data).current
                guard let self, !Task.isCancelled else { return }
                self.task = nil
                self.report = Report(celsius: current.temperature_2m, code: current.weather_code,
                                     isDay: current.is_day == 1, date: Date())
                self.set(status: .idle)
                self.schedule(after: Self.interval)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.task = nil
                self.log.error("Open-Meteo: \(error.localizedDescription, privacy: .private)")
                self.set(status: .failed)
                self.schedule(after: Self.retry)
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
        case 0: String(localized: "Clear")
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
