# Weather — requirements (current behavior)

Source of truth for what the Weather module (current weather from Open-Meteo at the Mac's approximate location) must do TODAY (main after e82e0bf, with B-20 fixed). The history behind each rule stays in `docs/REQUIREMENTS.md` (R-13; R-30 for the menu bar item; R-11, R-15, R-19 for cost, modules and accessibility) and `docs/DECISIONS.md` (Weather: Open-Meteo, Weather, No paid Apple Developer account, Menu bar readings).

**How to use it.** Before changing anything that touches the weather, read the rules of the parts you change. After the change, run `scripts/test.sh` and check EVERY affected rule by its Verify line, not only the new behavior. A new or changed wish → change the rule here, and keep the story in REQUIREMENTS.md.

Code abbreviations: WM = `Modules/WeatherModule.swift` (WeatherModule, Report, WeatherTiming, WeatherRefresh, WeatherRequest), MO = `Core/Module.swift`, SV = `Settings/SettingsView.swift`, BL = `TouchBar/BarLooks.swift`, TM = `TouchBar/TouchBarModule.swift`, SM = `App/StatusMenu.swift`, MR = `App/MenuBarReadings.swift`, TT = `TemperatureText` in `Modules/CPUTemperatureModule.swift`.

**Tests:** `PenknifeTests/WeatherRulesTests.swift` (8 tests; WX-01, 03, 04, 05, 06, 07, 08, 09, 10); the Touch Bar look is in `TouchBarRulesTests` (TB-25). A test must never call `start()`, `refresh()` or `stop()` on a `WeatherModule` (they ask for the location, open connections, open System Settings), never open a URL, never write `UserDefaults.standard`.

## 1. Rules

### A. The module

- **WX-01** Module "Weather" / "Tiempo" (symbol `cloud.sun`, cyan in Settings), on by default, no actions, no shortcuts, no Accessibility. Description: "Shows the current weather on the Touch Bar and in the menu, using your approximate location." / "Muestra el tiempo actual en la Touch Bar y en el menú, según tu ubicación aproximada." Starts with no report and status idle.
  Source: R-13, R-15 · Code: MO:title, summary, symbol, defaultOn; SV:tint; WM:actions · Verify: **auto** — `ModuleID.weather` symbol, `defaultOn`, not `needsTouchBar`; a new `WeatherModule` has no actions, no report, status idle.
- **WX-02** Settings › Weather: "Show in the menu bar" (R-30, `menuBar.show.weather`), then the caption "Only an approximate location (about 11 km) is sent. [Weather data by Open-Meteo.com](https://open-meteo.com/) (CC BY 4.0)." / "Solo se envía una ubicación aproximada (unos 11 km). [Datos meteorológicos de Open-Meteo.com](https://open-meteo.com/) (CC BY 4.0)." The link opens open-meteo.com (attribution required by CC BY 4.0).
  Source: R-13 "Show the data attribution"; D: Weather: Open-Meteo · Code: SV:case .weather · Verify: manual — Settings › Weather: the toggle and the caption; the link opens the site.

### B. When a report is asked for

- **WX-03** A refresh does nothing when the last report is younger than its minimum age: 60 s for a Touch Bar tap (TB-25), 0 for everything else (start, timer, "Update Now", "Allow Location…"). Otherwise the location permission decides: not asked yet → macOS asks (when the user allows, a report is asked for at once if there is none, WX-04); allowed → one location request (`requestLocation`, then WX-08); restricted (by a profile) → status "no location", nothing opens. Any waiting timer or request is cancelled first.
  Source: R-13; TB-25 · Code: WM:refresh, WeatherRefresh.step · Verify: **auto** (S3) — `WeatherRefresh.step`: age 30 / min 60 → nothing; age 61 → locate; no report → locate; not determined → ask; restricted → no location.
- **WX-04** Location refused: the first refresh sets "no location" (the Touch Bar shows `location.slash`, the menu bar item offers "Allow Location…" / "Permitir ubicación…"); a refresh while it already says so opens System Settings › Privacy & Security › Location Services (`x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices`) and changes nothing else. When the permission changes while the module runs: allowed and no report yet → refresh; refused or restricted → "no location". Turning Location Services off for the whole Mac counts as refused.
  Source: R-13; R-30 "opens Location settings if denied"; TB-25 · Code: WM:refresh, locationManagerDidChangeAuthorization, openLocationSettings · Verify: **auto** (S3) — `WeatherRefresh.step`: denied + idle → no location; denied + no location → open settings; restricted + no location → no location; a young report still wins; manual — refuse the permission, tap the weather button twice: the second tap opens Location Services.
- **WX-05** Timing: a new report 30 min after the last one; 2 min after a failure (network, bad answer, or a place macOS can't find); one one-shot timer at a time, tolerance 10 % of the wait, at most 60 s. No timer at all while "no location" from a refusal (the permission change wakes it, WX-04).
  Source: R-13 "Refresh ~30 min"; R-11; D: Weather · Code: WM:schedule, WeatherTiming · Verify: **auto** (S2) — `WeatherTiming.interval` 1800, `retry` 120, `tolerance` 60 for 1800, 12 for 120, 1 for 10.
- **WX-06** Sleep: when the Mac or its screens go to sleep, the timer and any request in flight are cancelled. On wake (Mac or screens), if nothing is waiting: a new report after what is left of the 30 min since the last one, never sooner than 10 s (the network needs a moment); no report yet → 10 s.
  Source: R-13 "no request while … the Mac sleeps"; D: Weather · Code: WM:start (observers), pause, resume, WeatherTiming.afterWake · Verify: **auto** (S2) — `afterWake`: no report → 10; 1 h old → 10; 10 min old → 1200; manual — sleep the Mac, wake it: Console (category Weather) has no request during the sleep; the weather updates within a few seconds when the last one was over 30 min old.
- **WX-07** Location failure: if a place was found earlier, it is reused and the report is asked for; if none, the status is "no location" only when macOS refused the permission (`CLError.denied`), otherwise "failed" (no data yet, `cloud`; menu bar item "Update Now"), and a new try comes in 2 min. Each failure is logged (category Weather).
  Source: R-13; B-20 · Code: WM:locationManager(_:didFailWithError:), WeatherRefresh.status(afterLocationError:) · Verify: **auto** (S3) — denied → no location; place unknown, network error → failed; manual — permission allowed, Wi-Fi off, quit and open Penknife: the weather button shows `cloud` ("no data yet"), not `location.slash`.

### C. What leaves the Mac and what comes back

- **WX-08** Privacy: location at reduced accuracy (`kCLLocationAccuracyReduced`), rounded to 0.1° (about 11 km) before anything else sees it; the only request is `https://api.open-meteo.com/v1/forecast?latitude=<0.1°>&longitude=<0.1°>&current=temperature_2m,weather_code,is_day` on an ephemeral session (no cookies, no cache on disk); no key, no account. Open-Meteo errors are logged as private.
  Source: R-13 "only rounded coordinates are sent"; D: Weather: Open-Meteo; D: Weather · Code: WM:start, didUpdateLocations, fetch, WeatherRequest.rounded, url · Verify: **auto** (S4) — 4.6534, −74.0836 → 4.7, −74.1; the URL text exactly; an unrounded place still gives one decimal.
- **WX-09** An answer counts only when it is HTTP 200 with `current.temperature_2m`, `weather_code` and `is_day`; the report keeps them with the time it arrived. Anything else → status "failed", the previous report stays shown (O-27), new try in 2 min. A report → status idle, next one in 30 min.
  Source: R-13 · Code: WM:fetch, WeatherRequest.report · Verify: **auto** (S4) — a 200 body decodes (17.6, 61, night); 429, no status, missing code → throws.
- **WX-10** Condition (WMO code) → symbol and words, shown everywhere the report is: 0 `sun.max.fill` / `moon.stars.fill` at night, "Clear sky" / "Despejado"; 1–2 `cloud.sun.fill` / `cloud.moon.fill`, "Partly cloudy" / "Poco nuboso"; 3 `cloud.fill`, "Cloudy" / "Nublado"; 45, 48 `cloud.fog.fill`, "Fog" / "Niebla"; 51–57 `cloud.drizzle.fill`, "Drizzle" / "Llovizna"; 65, 67, 82 `cloud.heavyrain.fill` and other 61–67, 80–82 `cloud.rain.fill`, all "Rain" / "Lluvia"; 71–77, 85, 86 `cloud.snow.fill`, "Snow" / "Nieve"; 95–99 `cloud.bolt.rain.fill`, "Thunderstorm" / "Tormenta"; any other code `cloud.fill`, "Cloudy". Temperature: whole degrees in the system's unit, "18°" short, in words for VoiceOver (TT).
  Source: R-13 · Code: WM:Report.symbol, summary; TT · Verify: **auto** — the whole table, day and night for 0–2, plus unknown codes 4 and 100.

### D. Where it shows

- **WX-11** Every change of report or status redraws, on the main thread: the Touch Bar button (TB-25, through `onChange`), the menu bar item (R-30, through `didChangeNotification`). The main menu shows "Weather: <condition>, 18°" / "Tiempo: <condición>, 18°" with the condition symbol only while the module is on and a report exists (R-19). The menu bar item's own menu: the reading (if any), then "Allow Location…" while "no location", else "Update Now" / "Actualizar ahora"; both refresh with minimum age 0 (WX-03, WX-04).
  Source: R-13, R-19, R-30 · Code: WM:set(status:); TM:updateWeather, tap; SM:readings; MR:drawWeather, menuNeedsUpdate, refreshWeather · Verify: manual — open the main menu: the weather line; menu bar item › Update Now: the item redraws.
- **WX-12** Off: switching the module off cancels the timer and request, removes the sleep/wake observers, forgets the location manager and the session; nothing more is asked until it is on again (then a fresh refresh). The last report stays in memory but the main menu stops showing it.
  Source: R-13 "no request while the module is off"; R-15 · Code: WM:stop, start; SM:isEnabled · Verify: manual — switch Weather off: Console (category Weather) stays quiet; the menu has no weather line; on again: a new report within seconds.

## 2. Open questions and known bugs

Decided, not built yet (user, 2026-11-19: "okay, hay que hacer eso entonces cuando lleguemos a esas tareas" = yes to the recommendation, build it when we get to it):
- **O-27 An old report stays forever without saying so.** When every refresh fails (no internet for hours, Open-Meteo down), the Touch Bar, the menu and the menu bar item keep showing the last report as if it were current, even a day later. [After 2 hours without a new report, show "no data yet" (`cloud`) instead of the old temperature; the next good answer brings it back.]

Not measured (check live; nothing to decide yet):
- A location request still in flight when the Mac sleeps is not cancelled (CoreLocation's `requestLocation` has no cancel): its answer could start one request right after sleep begins.
- Whether "restricted" (a managed Mac's profile) ever happens on the work Mac; the tap then does nothing and says nothing.

Fixed:
- **B-20 (fixed 2026-11-19)** A place macOS can't find (Wi-Fi off, unknown place) with the permission ALLOWED set "no location": the Touch Bar said "location not allowed. Tap to open the settings." and the menu bar item offered "Allow Location…". Now only a refusal says so (WX-07); the rest shows "no data yet" and retries in 2 min. Broke TB-25 ("location not allowed → `location.slash`"), fixed under the routine-work rule; test `WX-07 B-20` seen to fail before the fix.

Doc conflicts (code wins; marked in DECISIONS.md on 2026-11-19):
- D: Weather "refresh 10 s after wake" → WX-06 (only when the last report is 30 min old or there is none; else what is left of the 30 min).

## 3. Rejected / out of scope (do not rebuild)

- Apple's WeatherKit (D: No paid Apple Developer account).
- Precise location or sending the exact place (R-13).
- A forecast, a city name or more readings (not asked).

## 4. Test plan (step B)

**Done 2026-11-19** (autonomous routine work): as-is tests + S2–S4 in `PenknifeTests/WeatherRulesTests.swift`, 212 pass in all; each rule broken on purpose made its test fail (mutation run: WX-04, 05, 06, 08, 09, 10); no behavior change besides B-20. Each seam is a pure type in WM that the module calls with the same values as before.

- **Testable as-is:** `ModuleID.weather` (WX-01); `Report.symbol`, `summary` (WX-10); the Touch Bar look (TB-25, in TouchBarRulesTests).
- **S2 Timing** (WM). `WeatherTiming.interval`, `retry`, `afterWake(reportAge:)`, `tolerance(for:)`. Covers WX-05, WX-06.
- **S3 Refresh steps** (WM). `WeatherRefresh.step(reportAge:minAge:status:authorization:)` used by `refresh`; `status(afterLocationError:)`. Covers WX-03, WX-04, WX-07.
- **S4 Request** (WM, `nonisolated`: the location delegate calls it off the main actor). `WeatherRequest.rounded`, `url(for:)`, `report(from:statusCode:date:)`. Covers WX-08, WX-09.

Manual only (no seam worth it): WX-02, WX-06 (observers), WX-11, WX-12.
