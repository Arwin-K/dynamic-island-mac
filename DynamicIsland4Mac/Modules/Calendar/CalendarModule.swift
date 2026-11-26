import AppKit
import EventKit
import Observation
import SwiftUI

/// Your next calendar event with a countdown. Opt-in: asks for calendar access when enabled.
///
/// No polling: it recomputes when EventKit says the store changed, at midnight, after wake,
/// and at the exact moments that matter (when the next event enters the lead window, its
/// reminder time, its start and its end) via a single scheduled wake-up.
@MainActor
@Observable
final class CalendarModule: IslandModule {
    let id = "calendar"
    let displayName = "Calendar"
    let symbolName = "calendar"
    let priority = 40
    let enabledByDefault = false
    let showsInExpandedWhenIdle = true

    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var location: String?
        var calendarName: String
        var color: Color
        var joinURL: URL?
    }

    @ObservationIgnored let context: ModuleContext
    @ObservationIgnored private let store = EKEventStore()
    private(set) var authorization: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    private(set) var upcoming: [Item] = []
    /// Bumped by the scheduled wake-up so `isActive` re-evaluates.
    private var tick = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var wakeUp: DispatchWorkItem?
    @ObservationIgnored private var alertedEventIDs: Set<String> = []

    init(context: ModuleContext) {
        self.context = context
    }

    var leadMinutes: Double { context.double("leadMinutes", default: 30) }
    var alertMinutes: Double { context.double("alertMinutes", default: 5) }
    var includeAllDay: Bool { context.bool("includeAllDay", default: false) }

    var isAuthorized: Bool { authorization == .fullAccess }

    /// The event the compact view shows: ongoing (until 10 min after start) or next within the lead time.
    var focus: Item? {
        _ = tick
        let now = Date()
        return upcoming.first { item in
            (item.start <= now && now < item.end && now.timeIntervalSince(item.start) < 600)
                || (item.start > now && item.start.timeIntervalSince(now) <= leadMinutes * 60)
        }
    }

    var isActive: Bool { focus != nil }

    func start() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        if authorization == .notDetermined { requestAccess() } else { reload() }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        wakeUp?.cancel()
        upcoming = []
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, error in
            DispatchQueue.main.async {
                if let error { Log.calendar.error("Calendar access: \(error.localizedDescription, privacy: .public)") }
                self?.authorization = EKEventStore.authorizationStatus(for: .event)
                self?.reload()
            }
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func reload() {
        authorization = EKEventStore.authorizationStatus(for: .event)
        guard isAuthorized else { upcoming = []; return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(36 * 3600), calendars: nil)
        upcoming = store.events(matching: predicate)
            .filter { $0.endDate > now && (includeAllDay || !$0.isAllDay) && !Self.isDeclined($0) }
            .sorted { $0.startDate < $1.startDate }
            .prefix(6)
            .map { event in
                Item(id: event.calendarItemIdentifier + "\(event.startDate.timeIntervalSince1970)",
                     title: event.title ?? "Untitled", start: event.startDate, end: event.endDate,
                     location: event.location, calendarName: event.calendar.title,
                     color: Color(nsColor: event.calendar.color ?? .systemBlue), joinURL: Self.meetingURL(event))
            }
        scheduleWakeUp()
    }

    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    /// A video-call link from the event URL, location or notes.
    static func meetingURL(_ event: EKEvent) -> URL? {
        if let url = event.url, url.scheme?.hasPrefix("http") == true { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "webex.com", "whereby.com", "facetime.apple.com"]
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let url = match.url, let host = url.host, hosts.contains(where: { host.hasSuffix($0) }) { return url }
        }
        return nil
    }

    /// One wake-up at the next moment something should change on screen.
    private func scheduleWakeUp() {
        wakeUp?.cancel()
        let now = Date()
        var moments: [Date] = []
        for item in upcoming {
            moments += [item.start.addingTimeInterval(-leadMinutes * 60), item.start.addingTimeInterval(-alertMinutes * 60),
                        item.start, item.start.addingTimeInterval(600), item.end]
        }
        guard let next = moments.filter({ $0 > now }).min() else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.tick += 1
            self.maybeAlert()
            self.reload()
        }
        wakeUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + next.timeIntervalSince(now) + 0.5, execute: work)
    }

    private func maybeAlert() {
        guard alertMinutes > 0 else { return }
        let now = Date()
        for item in upcoming where item.start > now && item.start.timeIntervalSince(now) <= alertMinutes * 60 + 1 && !alertedEventIDs.contains(item.id) {
            alertedEventIDs.insert(item.id)
            context.alert(feedback: .calendarSoon, duration: 6, coalescingKey: item.id) {
                CalendarAlertView(item: item)
            }
        }
    }

    // MARK: Views

    func compactLeading() -> some View {
        HStack(spacing: 4) {
            Circle().fill(focus?.color ?? .accentColor).frame(width: 6, height: 6)
            Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
        }
        .islandMatched("icon", module: id)
        .accessibilityHidden(true)
    }

    func compactTrailing() -> some View {
        Group {
            if let focus { CountdownText(start: focus.start, end: focus.end) }
        }
    }

    func expanded() -> some View {
        CalendarExpandedView(module: self)
    }

    func settingsView() -> AnyView {
        AnyView(CalendarSettingsView(module: self))
    }

    static func preview(context: ModuleContext) -> CalendarModule {
        let module = CalendarModule(context: context)
        let start = Date().addingTimeInterval(12 * 60)
        module.upcoming = [Item(id: "p", title: "Design review", start: start, end: start.addingTimeInterval(1800),
                                location: "Zoom", calendarName: "Work", color: .orange, joinURL: URL(string: "https://zoom.us/j/1"))]
        return module
    }
}

/// "in 12m", "now", "ends in 5m": refreshes every 30 s.
struct CountdownText: View {
    let start: Date
    let end: Date
    @Environment(\.islandTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Self.label(now: context.date, start: start, end: end))
                .font(theme.font(size: theme.typography.captionSize, weight: .semibold, monospacedDigits: true))
                .lineLimit(1)
        }
    }

    static func label(now: Date, start: Date, end: Date) -> String {
        if now >= start { return now < end ? "now" : "ended" }
        let minutes = Int(ceil(start.timeIntervalSince(now) / 60))
        return minutes >= 60 ? "in \(minutes / 60)h \(minutes % 60)m" : "in \(minutes)m"
    }
}

struct CalendarExpandedView: View {
    let module: CalendarModule
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        if !module.isAuthorized {
            VStack(spacing: 6) {
                Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 20))
                Text("Calendar access needed").font(theme.titleFont)
                Button("Grant Access") {
                    module.authorization == .notDetermined ? module.requestAccess() : CalendarModule.openPrivacySettings()
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if module.upcoming.isEmpty {
            Text("No more events today").font(theme.bodyFont).foregroundStyle(palette.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(module.upcoming.prefix(3)) { item in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 4, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(theme.font(size: theme.typography.bodySize, weight: theme.typography.titleWeight)).lineLimit(1)
                            Text("\(item.start.formatted(date: .omitted, time: .shortened))–\(item.end.formatted(date: .omitted, time: .shortened))\(item.location.map { " · \($0)" } ?? "")")
                                .font(theme.captionFont).foregroundStyle(palette.secondary).lineLimit(1)
                        }
                        Spacer()
                        CountdownText(start: item.start, end: item.end).foregroundStyle(palette.secondary)
                        if let url = item.joinURL {
                            Button("Join") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.plain)
                                .font(theme.font(size: theme.typography.captionSize, weight: .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(palette.accent))
                                .foregroundStyle(.white)
                                .accessibilityLabel("Join \(item.title)")
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct CalendarAlertView: View {
    let item: CalendarModule.Item
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar").font(.system(size: 16)).foregroundStyle(item.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(theme.titleFont).lineLimit(1)
                CountdownText(start: item.start, end: item.end).foregroundStyle(palette.secondary)
            }
            Spacer()
            if let url = item.joinURL {
                Button("Join") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(palette.accent))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CalendarSettingsView: View {
    let module: CalendarModule

    var body: some View {
        switch module.authorization {
        case .fullAccess:
            Label("Calendar access granted.", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .notDetermined:
            Button("Allow Calendar Access…") { module.requestAccess() }
        default:
            HStack {
                Label("Calendar access is off.", systemImage: "lock").foregroundStyle(.orange)
                Button("Open Privacy Settings") { CalendarModule.openPrivacySettings() }
            }
        }
        ValueSlider(title: "Show in the compact island this long before", value: module.context.doubleBinding("leadMinutes", default: 30), range: 5...120, step: 5, format: "%.0f min")
        ValueSlider(title: "Alert before start (0 = off)", value: module.context.doubleBinding("alertMinutes", default: 5), range: 0...30, step: 1, format: "%.0f min")
        Toggle("Include all-day events", isOn: module.context.boolBinding("includeAllDay", default: false))
    }
}
