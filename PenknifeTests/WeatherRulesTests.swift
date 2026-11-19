import CoreLocation
import Foundation
import Testing
@testable import Penknife

/// Weather rules (docs/requirements/weather.md). Each test names the rule it checks. Nothing here
/// asks for the location, opens a connection, opens System Settings or writes the user's settings.
@MainActor
@Suite("Weather rules")
struct WeatherRulesTests {

    static func report(_ code: Int, day: Bool = true) -> WeatherModule.Report {
        WeatherModule.Report(celsius: 18, code: code, isDay: day, date: Date())
    }

    @Test("WX-01 module on by default with its symbol, no actions")
    func module() {
        #expect(ModuleID.weather.symbol == "cloud.sun" && ModuleID.weather.defaultOn)
        #expect(!ModuleID.weather.needsTouchBar)
        let module = WeatherModule()
        #expect(module.actions.isEmpty && !module.needsAccessibility)
        #expect(module.report == nil && module.status == .idle)
    }

    // MARK: Refresh

    @Test("WX-03 a young report is kept; otherwise the permission decides")
    func refreshStep() {
        let allowed = CLAuthorizationStatus.authorizedAlways
        #expect(WeatherRefresh.step(reportAge: 30, minAge: 60, status: .idle, authorization: allowed) == .nothing)
        #expect(WeatherRefresh.step(reportAge: 61, minAge: 60, status: .idle, authorization: allowed) == .locate)
        #expect(WeatherRefresh.step(reportAge: nil, minAge: 60, status: .idle, authorization: allowed) == .locate)
        #expect(WeatherRefresh.step(reportAge: 0, minAge: 0, status: .idle, authorization: allowed) == .locate)
        #expect(WeatherRefresh.step(reportAge: nil, minAge: 0, status: .idle, authorization: .notDetermined) == .askPermission)
        #expect(WeatherRefresh.step(reportAge: nil, minAge: 0, status: .idle, authorization: .restricted) == .noLocation)
    }

    @Test("WX-04 denied: the first refresh says so, the next opens Location settings")
    func refreshDenied() {
        #expect(WeatherRefresh.step(reportAge: nil, minAge: 0, status: .idle, authorization: .denied) == .noLocation)
        #expect(WeatherRefresh.step(reportAge: nil, minAge: 0, status: .noLocation, authorization: .denied) == .openSettings)
        #expect(WeatherRefresh.step(reportAge: nil, minAge: 0, status: .noLocation, authorization: .restricted) == .noLocation)
        #expect(WeatherRefresh.step(reportAge: 10, minAge: 60, status: .noLocation, authorization: .denied) == .nothing)
    }

    @Test("WX-07 B-20 a place macOS can't find is not a refused permission")
    func locationError() {
        #expect(WeatherRefresh.status(afterLocationError: CLError(.denied)) == .noLocation)
        #expect(WeatherRefresh.status(afterLocationError: CLError(.locationUnknown)) == .failed)
        #expect(WeatherRefresh.status(afterLocationError: CLError(.network)) == .failed)
        #expect(WeatherRefresh.status(afterLocationError: URLError(.notConnectedToInternet)) == .failed)
    }

    // MARK: Timing

    @Test("WX-05 WX-06 every 30 min, retry in 2 min, after a wake what is left but at least 10 s")
    func timing() {
        #expect(WeatherTiming.interval == 1800 && WeatherTiming.retry == 120)
        #expect(WeatherTiming.afterWake(reportAge: .infinity) == 10)
        #expect(WeatherTiming.afterWake(reportAge: 3600) == 10)
        #expect(WeatherTiming.afterWake(reportAge: 1795) == 10)
        #expect(WeatherTiming.afterWake(reportAge: 600) == 1200)
        #expect(WeatherTiming.tolerance(for: 1800) == 60)
        #expect(WeatherTiming.tolerance(for: 120) == 12)
        #expect(WeatherTiming.tolerance(for: 10) == 1)
        // O-27: a report older than 2 h is dropped at the next failure.
        #expect(WeatherTiming.keeps(reportAge: 7199))
        #expect(!WeatherTiming.keeps(reportAge: 7200))
    }

    // MARK: Request

    @Test("WX-08 only rounded coordinates leave the Mac")
    func request() throws {
        let place = WeatherRequest.rounded(CLLocationCoordinate2D(latitude: 4.6534, longitude: -74.0836))
        #expect(place.latitude == 4.7 && place.longitude == -74.1)
        let url = try #require(WeatherRequest.url(for: place))
        #expect(url.absoluteString == "https://api.open-meteo.com/v1/forecast?latitude=4.7&longitude=-74.1&current=temperature_2m,weather_code,is_day")
        let precise = try #require(WeatherRequest.url(for: CLLocationCoordinate2D(latitude: 4.6534, longitude: -74.0836)))
        #expect(precise.absoluteString.contains("latitude=4.7&longitude=-74.1&"))
    }

    @Test("WX-09 an answer is a 200 with temperature, code and day")
    func answer() throws {
        let body = Data(#"{"latitude":4.7,"current":{"time":"2026-11-19T10:00","temperature_2m":17.6,"weather_code":61,"is_day":0}}"#.utf8)
        let date = Date(timeIntervalSince1970: 1000)
        let report = try WeatherRequest.report(from: body, statusCode: 200, date: date)
        #expect(report.celsius == 17.6 && report.code == 61 && !report.isDay && report.date == date)
        #expect(throws: (any Error).self) { try WeatherRequest.report(from: body, statusCode: 429, date: date) }
        #expect(throws: (any Error).self) { try WeatherRequest.report(from: body, statusCode: nil, date: date) }
        let missing = Data(#"{"current":{"temperature_2m":17.6,"is_day":1}}"#.utf8)
        #expect(throws: (any Error).self) { try WeatherRequest.report(from: missing, statusCode: 200, date: date) }
    }

    // MARK: Look

    @Test("WX-10 WMO code → symbol and words")
    func conditions() {
        let table: [(Int, Bool, String, String)] = [
            (0, true, "sun.max.fill", "Clear sky"), (0, false, "moon.stars.fill", "Clear sky"),
            (1, true, "cloud.sun.fill", "Partly cloudy"), (2, false, "cloud.moon.fill", "Partly cloudy"),
            (3, true, "cloud.fill", "Cloudy"), (45, true, "cloud.fog.fill", "Fog"), (48, true, "cloud.fog.fill", "Fog"),
            (51, true, "cloud.drizzle.fill", "Drizzle"), (57, true, "cloud.drizzle.fill", "Drizzle"),
            (61, true, "cloud.rain.fill", "Rain"), (63, true, "cloud.rain.fill", "Rain"), (66, true, "cloud.rain.fill", "Rain"),
            (80, true, "cloud.rain.fill", "Rain"), (81, true, "cloud.rain.fill", "Rain"),
            (65, true, "cloud.heavyrain.fill", "Rain"), (67, true, "cloud.heavyrain.fill", "Rain"),
            (82, true, "cloud.heavyrain.fill", "Rain"),
            (71, true, "cloud.snow.fill", "Snow"), (77, true, "cloud.snow.fill", "Snow"),
            (85, true, "cloud.snow.fill", "Snow"), (86, true, "cloud.snow.fill", "Snow"),
            (95, true, "cloud.bolt.rain.fill", "Thunderstorm"), (99, true, "cloud.bolt.rain.fill", "Thunderstorm"),
            (4, true, "cloud.fill", "Cloudy"), (100, true, "cloud.fill", "Cloudy"),
        ]
        for (code, day, symbol, words) in table {
            let report = Self.report(code, day: day)
            #expect(report.symbol == symbol, "code \(code)")
            #expect(report.summary == String(localized: String.LocalizationValue(words)), "code \(code)")
        }
    }
}
