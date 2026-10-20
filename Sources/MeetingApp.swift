import AppKit
import EventKit
import SwiftUI

// MARK: - Services and link detection

enum Service: String, CaseIterable, Identifiable {
    case meet, teams, zoom, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .zoom: "Zoom"
        case .other: "Everything else"
        }
    }

    /// Hosts that identify this service (suffix match, so subdomains count).
    var hosts: [String] {
        switch self {
        case .meet: ["meet.google.com"]
        case .teams: ["teams.microsoft.com", "teams.live.com"]
        case .zoom: ["zoom.us"]
        case .other: []
        }
    }

    /// Custom scheme the desktop app registers, used to populate the app picker.
    var scheme: String? {
        switch self {
        case .teams: "msteams"
        case .zoom: "zoommtg"
        default: nil
        }
    }

    static func of(_ url: URL) -> Service {
        let host = url.host?.lowercased() ?? ""
        return allCases.first { s in s.hosts.contains { host == $0 || host.hasSuffix("." + $0) } } ?? .other
    }

    var prefKey: String { "app." + rawValue }
}

/// Host → how much it looks like a real meeting link. Higher wins, negative is never picked.
let hostRanks: [String: Int] = Service.allCases.flatMap(\.hosts)
    .reduce(into: [
        "webex.com": 3, "meet.jit.si": 3, "whereby.com": 3, "chime.aws": 3, "bluejeans.com": 3,
        "gather.town": 2, "around.co": 2, "tuple.app": 2, "pop.com": 2, "app.slack.com": 2,
        "tel.meet": -1,             // Meet's dial-in PIN page, not the meeting
        "support.google.com": -1,   // "Learn more about Meet", in every Google invite
        "aka.ms": -1,               // "Learn more about Teams"
    ]) { $0[$1] = 3 }

func hostRank(_ host: String) -> Int {
    hostRanks.filter { host == $0.key || host.hasSuffix("." + $0.key) }.map(\.value).max() ?? 0
}

/// Google Calendar rewrites links in descriptions as https://www.google.com/url?q=<real>,
/// which hides the real host. Unwrap before judging it.
func unwrapped(_ url: URL) -> URL {
    guard url.host?.lowercased().hasSuffix("google.com") == true, url.path == "/url",
          let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?
              .queryItems?.first(where: { $0.name == "q" })?.value,
          let real = URL(string: inner)
    else { return url }
    return real
}

/// Best meeting link across the given fields. Ranks every candidate instead of taking
/// the first hit, so an agenda link in the notes cannot beat the real conference link.
func meetingURL(in fields: [String?]) -> URL? {
    let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    var best: (score: Int, url: URL)?
    for (index, field) in fields.enumerated() {
        guard let field else { continue }
        let range = NSRange(location: 0, length: (field as NSString).length)
        for match in detector.matches(in: field, range: range) {
            guard let raw = match.url else { continue }
            let url = unwrapped(raw)
            guard url.scheme?.hasPrefix("http") == true, let host = url.host?.lowercased()
            else { continue }
            let rank = hostRank(host)
            guard rank >= 0 else { continue }
            let score = rank * 10 - index  // earlier fields win ties; notes come last
            if score > (best?.score ?? Int.min) { best = (score, url) }
        }
    }
    return best?.url
}

// MARK: - Opening

/// Teams desktop only follows its own scheme: https://teams.microsoft.com/l/... -> msteams:/l/...
func msteamsURL(_ url: URL) -> URL? {
    guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    c.scheme = "msteams"
    c.host = nil
    return c.url
}

func bundleID(_ app: URL) -> String {
    Bundle(url: app)?.bundleIdentifier?.lowercased() ?? ""
}

/// Apps the user can pick for a service: anything that handles meeting web links,
/// plus the service's own desktop app.
func candidateApps(for service: Service) -> [URL] {
    let ws = NSWorkspace.shared
    var apps = ws.urlsForApplications(toOpen: URL(string: "https://example.com")!)
    if let scheme = service.scheme, let url = URL(string: scheme + ":") {
        apps = ws.urlsForApplications(toOpen: url) + apps
    }
    var seen = Set<String>()
    return apps.filter { seen.insert($0.path).inserted }
}

func openMeeting(_ url: URL) {
    let service = Service.of(url)
    let path = UserDefaults.standard.string(forKey: service.prefKey) ?? ""
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
        NSWorkspace.shared.open(url)  // system default handler
        return
    }
    let app = URL(fileURLWithPath: path)
    var target = url
    if service == .teams, bundleID(app).contains("teams"), let deep = msteamsURL(url) { target = deep }
    NSWorkspace.shared.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
}

extension EKEvent {
    var joinURL: URL? { meetingURL(in: [location, url?.absoluteString, notes]) }
    var name: String { title?.isEmpty == false ? title! : "(no title)" }

    /// Stable row identity. Recurring instances share eventIdentifier, so the start
    /// time has to be part of it; an index is not identity and makes SwiftUI reuse rows.
    var rowID: String { "\(eventIdentifier ?? name)@\(startDate.timeIntervalSince1970)" }
}

// MARK: - Updates

@MainActor final class Updater: ObservableObject {
    static let shared = Updater()
    nonisolated static let repo = "markcipolla/meeting"
    nonisolated static let log = "/tmp/meetings-update.log"

    @Published var latest: String?  // set only when newer than what is running
    @Published var status = ""

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    private init() {
        Task { await check() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { await self.check() }
        }
    }

    func check() async {
        struct Release: Decodable { let tag_name: String }
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let tag = try? JSONDecoder().decode(Release.self, from: data).tag_name
        else { return }
        let new = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        // ponytail: numeric string compare, fine for x.y.z; use a real semver parse if pre-release tags appear
        latest = new.compare(current, options: .numeric) == .orderedDescending ? new : nil
    }

    /// Homebrew is the installer, so it is also the updater.
    func update() {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            NSWorkspace.shared.open(URL(string: "https://github.com/\(Self.repo)/releases/latest")!)
            return
        }
        status = "Updating…"
        let log = Self.log
        Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: brew)
            task.arguments = ["upgrade", "\(Self.repo)/meetings"]
            FileManager.default.createFile(atPath: log, contents: nil)
            let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: log))
            task.standardOutput = handle
            task.standardError = handle
            try? task.run()
            task.waitUntilExit()
            let ok = task.terminationStatus == 0
            await MainActor.run {
                if ok { relaunch() } else { self.status = "Update failed, see \(log)" }
            }
        }
    }
}

func relaunch() {
    // Prefer the /Applications symlink: the Cellar path dies with the old version.
    let linked = "/Applications/Meetings.app"
    let app = FileManager.default.fileExists(atPath: linked)
        ? URL(fileURLWithPath: linked) : Bundle.main.bundleURL
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: app, configuration: config) { _, _ in
        Task { @MainActor in NSApp.terminate(nil) }
    }
}

// MARK: - Calendar

@MainActor final class Cal: ObservableObject {
    static let shared = Cal()

    private let store = EKEventStore()
    @Published var events: [EKEvent] = []
    @Published var problem: String?
    private var timer: Timer?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { _ in Task { @MainActor in self.reload() } }

        Task {
            do {
                if try await store.requestFullAccessToEvents() == false {
                    problem = "Calendar access denied"
                }
            } catch { problem = error.localizedDescription }
            reload()
        }

        // One 30s tick refreshes both the countdown and the event list (local query, cheap).
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in self.reload() }
        }
    }

    func reload() {
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-4 * 3600),
            end: now.addingTimeInterval(8 * 86400),
            calendars: nil)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        objectWillChange.send()  // countdowns derive from Date(), not just from `events`
        autoJoinIfDue()
    }

    /// Opens the meeting by itself, n minutes ahead. Only real conferencing links,
    /// never a random link that happened to be the best candidate.
    private var opened = Set<String>()

    private func autoJoinIfDue() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "autoJoin") else { return }
        let lead = Double(max(0, defaults.integer(forKey: "autoJoinMinutes"))) * 60
        let now = Date()
        for event in events {
            guard let url = event.joinURL, Service.of(url) != .other,
                  now >= event.startDate.addingTimeInterval(-lead),
                  now < event.startDate.addingTimeInterval(5 * 60),  // don't drag you into a meeting half over
                  opened.insert(event.rowID).inserted
            else { continue }
            openMeeting(url)
        }
    }

    var next: EKEvent? { events.first { $0.endDate > Date() } }

    var today: [EKEvent] {
        events.filter { Calendar.current.isDateInToday($0.startDate) && $0.endDate > Date() }
    }

    var label: String {
        guard let e = next else { return "no meetings" }
        let mins = Int((e.startDate.timeIntervalSinceNow / 60).rounded(.up))
        let when = mins <= 0 ? "now" : mins < 60 ? "\(mins)m" : "\(mins / 60)h\(mins % 60)m"
        return "\(e.name.prefix(22)) · \(when)"
    }
}

// MARK: - Views

func timeRange(_ e: EKEvent) -> String {
    e.startDate.formatted(date: .omitted, time: .shortened) + "–"
        + e.endDate.formatted(date: .omitted, time: .shortened)
}

struct MenuContent: View {
    @ObservedObject var cal = Cal.shared
    @ObservedObject var updater = Updater.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let problem = cal.problem {
            Text(problem)
            Button("Open Privacy Settings…") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }
            Divider()
        }
        if let next = cal.next, let url = next.joinURL {
            Button("Join \(next.name)") { openMeeting(url) }.keyboardShortcut("j")
            Divider()
        }
        if cal.today.isEmpty {
            Text("Nothing left today")
        } else {
            ForEach(cal.today, id: \.rowID) { e in
                Button("\(e.startDate.formatted(date: .omitted, time: .shortened))  \(e.name)") {
                    if let url = e.joinURL { openMeeting(url) }
                }.disabled(e.joinURL == nil)
            }
        }
        Divider()
        if let v = updater.latest {
            Button("Update to \(v)") { updater.update() }
        } else if !updater.status.isEmpty {
            Text(updater.status)
        }
        Button("Next 7 days…") {
            openWindow(id: "week")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut("k")
        Button("Refresh") { cal.reload() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct WeekView: View {
    @ObservedObject var cal = Cal.shared

    var days: [(Date, [EKEvent])] {
        Dictionary(grouping: cal.events.filter { $0.endDate > Date() }) {
            Calendar.current.startOfDay(for: $0.startDate)
        }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        List {
            ForEach(days, id: \.0) { day, events in
                Section(day.formatted(.dateTime.weekday(.wide).day().month())) {
                    ForEach(events, id: \.rowID) { e in
                        Button {
                            if let url = e.joinURL { openMeeting(url) }
                        } label: {
                            HStack {
                                Circle().fill(Color(e.calendar.color)).frame(width: 8, height: 8)
                                Text(timeRange(e)).monospacedDigit().foregroundStyle(.secondary)
                                Text(e.name)
                                if e.joinURL != nil {
                                    Image(systemName: "video.fill").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(e.joinURL == nil)
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 420)
    }
}

struct SettingsView: View {
    @ObservedObject private var updater = Updater.shared
    @AppStorage("autoJoin") private var autoJoin = false
    @AppStorage("autoJoinMinutes") private var autoJoinMinutes = 1
    @AppStorage(Service.meet.prefKey) private var meet = ""
    @AppStorage(Service.teams.prefKey) private var teams = ""
    @AppStorage(Service.zoom.prefKey) private var zoom = ""
    @AppStorage(Service.other.prefKey) private var other = ""

    var body: some View {
        Form {
            picker(.meet, $meet)
            picker(.teams, $teams)
            picker(.zoom, $zoom)
            picker(.other, $other)
            Text("“System default” uses whatever macOS would open the link with.")
                .font(.caption).foregroundStyle(.secondary)
            Section {
                Toggle("Open meetings automatically", isOn: $autoJoin)
                if autoJoin {
                    Stepper(
                        "\(autoJoinMinutes) minute\(autoJoinMinutes == 1 ? "" : "s") beforehand",
                        value: $autoJoinMinutes, in: 0...30)
                }
                Text("Only Google Meet, Teams and Zoom links open automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Version \(updater.current)")
                    if let v = updater.latest {
                        Button("Update to \(v)") { updater.update() }
                    } else {
                        Button("Check for updates") { Task { await updater.check() } }
                    }
                    if !updater.status.isEmpty {
                        Text(updater.status).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy debug info") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(dumpText(), forType: .string)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    private func picker(_ service: Service, _ value: Binding<String>) -> some View {
        Picker(service.title, selection: value) {
            Text("System default").tag("")
            ForEach(candidateApps(for: service), id: \.path) { app in
                Text(FileManager.default.displayName(atPath: app.path)).tag(app.path)
            }
        }
    }
}

@main struct MeetingApp: App {
    @ObservedObject var cal = Cal.shared

    init() {
        if CommandLine.arguments.contains("--selftest") { selftest(); exit(0) }
        if CommandLine.arguments.contains("--dump") { print(dumpText()); exit(0) }
    }

    var body: some Scene {
        MenuBarExtra(cal.label) { MenuContent() }
        Window("Next 7 days", id: "week") { WeekView() }
        Settings { SettingsView() }
    }
}

/// What the link picker sees, for debugging a wrong join link.
func dumpText() -> String {
    let status = EKEventStore.authorizationStatus(for: .event)
    let store = EKEventStore()
    let now = Date()
    let predicate = store.predicateForEvents(
        withStart: now, end: now.addingTimeInterval(8 * 86400), calendars: nil)
    var out = "auth status: \(status.rawValue)\n"
    for e in store.events(matching: predicate).sorted(by: { $0.startDate < $1.startDate }) {
        guard !e.isAllDay else { continue }
        out += """
        — \(e.name)  [\(e.calendar.title)]
          location: \(e.location ?? "nil")
          url:      \(e.url?.absoluteString ?? "nil")
          notes:    \((e.notes ?? "nil").prefix(700).replacingOccurrences(of: "\n", with: " ⏎ "))
          PICKED:   \(e.joinURL?.absoluteString ?? "nil")

        """
    }
    return out
}

func selftest() {
    precondition(meetingURL(in: ["Join at https://acme.zoom.us/j/123"])?.host == "acme.zoom.us")
    precondition(meetingURL(in: [nil, "Room 3", "wiki https://wiki.corp/x then https://meet.google.com/a-b"])?
        .host == "meet.google.com")
    precondition(meetingURL(in: ["Boardroom 2"]) == nil)
    precondition(meetingURL(in: ["dial-in https://wiki.corp/page"])?.host == "wiki.corp")
    precondition(meetingURL(in: ["mailto:a@b.com"]) == nil)

    precondition(Service.of(URL(string: "https://meet.google.com/a-b-c")!) == .meet)
    precondition(Service.of(URL(string: "https://acme.zoom.us/j/1")!) == .zoom)
    precondition(Service.of(URL(string: "https://wiki.corp/x")!) == .other)

    let teams = URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting?context=%7b%22Tid%22%3a%221%22%7d")!
    precondition(Service.of(teams) == .teams)
    precondition(msteamsURL(teams)?.absoluteString
        == "msteams:/l/meetup-join/19%3ameeting?context=%7b%22Tid%22%3a%221%22%7d")
    // Google wraps description links, which used to hide the real host
    let wrapped = "https://www.google.com/url?q=https://meet.google.com/a-b-c&sa=D&source=calendar"
    precondition(unwrapped(URL(string: wrapped)!).host == "meet.google.com")

    // a conference link wins wherever it sits, and whatever it sits next to
    precondition(meetingURL(in: [nil, nil, "agenda https://docs.google.com/d/1 then https://meet.google.com/a-b-c"])?
        .host == "meet.google.com")
    precondition(meetingURL(in: [nil, nil,
        "https://www.google.com/url?q=https://docs.google.com/d/1&sa=D plus \(wrapped)"])?
        .host == "meet.google.com")
    precondition(meetingURL(in: ["https://meet.google.com/in-location", nil, "https://zoom.us/j/1"])?
        .path == "/in-location")  // field order breaks a tie between two real links

    // Google's own boilerplate is never the meeting
    precondition(meetingURL(in: ["https://tel.meet/a-b-c?pin=123"]) == nil)
    precondition(meetingURL(in: [nil, nil,
        "Join with Google Meet: https://meet.google.com/a-b-c ⏎ More phone numbers: https://tel.meet/a-b-c ⏎ Learn more at https://support.google.com/a/users/answer/9282720"])?
        .host == "meet.google.com")

    print("selftest ok")
}
