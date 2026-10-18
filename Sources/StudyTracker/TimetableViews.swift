import AppKit
import SwiftUI
import UniformTypeIdentifiers
import StudyCore

/// The one-time step on Home that brings in the timetable. Shown until a timetable is added (or declined).
struct TimetableCard: View {
    @Environment(AppModel.self) var model
    @State private var picture: URL?
    @State private var showLink = false
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add your timetable").font(.serif(22, weight: .semibold))
            Text("Choose a screenshot or photo of your timetable. Claude reads it, and your classes show under This week.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Choose a picture…") { picture = TimetablePicture.choose() }
                    .buttonStyle(PillButtonStyle(prominent: true))
                Text("Or drop it here.").font(.callout).foregroundStyle(.secondary)
            }
            if showLink {
                OutlookSteps()
                TimetableLinkField()
            }
            HStack(spacing: 16) {
                if !showLink { Button("Use a calendar link instead") { showLink = true }.buttonStyle(.link) }
                if CalendarAccess.available { Button("Use a calendar on this Mac") { picking = true }.buttonStyle(.link) }
                Button("Not now") { model.declineTimetable() }.buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
        .dropDestination(for: URL.self) { urls, _ in
            picture = urls.first { TimetablePicture.accepts($0) }
            return picture != nil
        }
        .sheet(item: $picture) { url in TimetablePictureSheet(url: url).environment(model) }
        .sheet(isPresented: $picking) { CalendarPicker().environment(model) }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

enum TimetablePicture {
    static let types: [UTType] = [.image, .pdf]

    static func accepts(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return types.contains { type.conforms(to: $0) }
    }

    @MainActor static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.message = "Choose a screenshot, photo or PDF of your timetable."
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Claude reads the picture, then the student checks the week it found and starts using it.
struct TimetablePictureSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var schedule: TimetableReader.Schedule?
    @State private var problem: String?
    @State private var group = ""
    @State private var copy = true
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let schedule { confirm(schedule) }
            else if let problem { failed(problem) }
            else { reading }
        }
        .padding(24)
        .frame(width: 560, height: 580, alignment: .topLeading)
        .task { await read() }
    }

    func read() async {
        do {
            let s = try await model.readTimetablePicture(url)
            group = s.groups.first ?? ""
            copy = CalendarAccess.available
            schedule = s
        } catch {
            problem = error.localizedDescription
        }
    }

    var reading: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
            Text("Claude is reading your timetable…").font(.serif(20, weight: .semibold))
            Text("This takes up to a minute.").foregroundStyle(.secondary)
            Spacer()
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .frame(maxWidth: .infinity)
    }

    func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Couldn't read that timetable").font(.serif(20, weight: .semibold))
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    func confirm(_ s: TimetableReader.Schedule) -> some View {
        let slots = TimetableReader.classes(s, group: group.isEmpty ? nil : group)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Your week").font(.serif(22, weight: .semibold))
            Text(summary(s, slots)).foregroundStyle(.secondary)
            if s.groups.count > 1 {
                Picker("Your group", selection: $group) { ForEach(s.groups, id: \.self) { Text($0).tag($0) } }
                    .frame(maxWidth: 260)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows(slots), id: \.0) { label, items in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(label).font(.callout.weight(.medium)).frame(width: 90, alignment: .leading)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(items.enumerated()), id: \.offset) { _, slot in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text("\(slot.start)–\(slot.end)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                                        Text(slot.title)
                                        if let loc = slot.location { Text(loc).font(.callout).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
            if !s.note.isEmpty { Text(s.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if CalendarAccess.available {
                Toggle("Also put these classes in Calendar, for your iPhone", isOn: $copy)
            }
            HStack {
                Text("If something's wrong, try a clearer picture.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use this timetable") {
                    saving = true
                    Task {
                        await model.useTimetablePicture(s, group: group.isEmpty ? nil : group, copyToCalendar: copy)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(slots.isEmpty || saving)
            }
        }
    }

    /// "12 classes a week · 7 Sep – 18 Dec"
    func summary(_ s: TimetableReader.Schedule, _ slots: [TimetableReader.Slot]) -> String {
        let weekly = slots.filter { $0.date == nil }.count, dated = slots.count - weekly
        var parts: [String] = []
        if weekly > 0 { parts.append("\(weekly) class\(weekly == 1 ? "" : "es") a week") }
        if dated > 0 { parts.append("\(dated) on set dates") }
        if let a = s.termStart, let b = s.termEnd { parts.append("\(Self.short(a)) – \(Self.short(b))") }
        return parts.joined(separator: " · ")
    }

    static func short(_ d: LocalDate) -> String { d.at(LocalTime(hour: 12, minute: 0), tz: .current).formatted(.dateTime.day().month(.abbreviated)) }

    /// Weekly classes by weekday, then classes on set dates by date.
    func rows(_ slots: [TimetableReader.Slot]) -> [(String, [TimetableReader.Slot])] {
        let names = Calendar.current.weekdaySymbols // Sunday first
        var out: [(String, [TimetableReader.Slot])] = (1...7).compactMap { wd in
            let items = slots.filter { $0.date == nil && $0.weekday == wd }.sorted { $0.start < $1.start }
            return items.isEmpty ? nil : (names[wd % 7], items)
        }
        let dated = Dictionary(grouping: slots.filter { $0.date != nil }, by: { $0.date! })
        for date in dated.keys.sorted() { out.append((Self.short(date), dated[date]!.sorted { $0.start < $1.start })) }
        return out
    }
}

struct OutlookSteps: View {
    var body: some View {
        Text("In Outlook on the web, open Settings › Calendar › Shared calendars. Under Publish a calendar, choose your calendar and “Can view all details”, press Publish, then copy the ICS link.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A field for the calendar link, checked by downloading it before it's kept.
struct TimetableLinkField: View {
    @Environment(AppModel.self) var model
    @State private var link = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField("https://outlook.office365.com/owa/calendar/…/calendar.ics", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 460)
                    .onSubmit(add)
                if checking { ProgressView().controlSize(.small) }
                Button("Add", action: add).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }

    func add() {
        guard !checking else { return }
        checking = true
        error = nil
        Task {
            error = await model.setTimetableLink(link)
            checking = false
        }
    }
}

/// Choosing the calendars on this Mac that hold the timetable.
struct CalendarPicker: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) private var dismiss
    @State private var calendars: [CalendarAccess.CalendarInfo] = []
    @State private var chosen: Set<String> = []
    @State private var denied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Calendars with your classes").font(.serif(20, weight: .semibold))
            if denied {
                Text("Study Tracker isn't allowed to use Calendar. Allow it in System Settings › Privacy & Security › Calendars, then try again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                List {
                    ForEach(Dictionary(grouping: calendars, by: \.account).sorted { $0.key < $1.key }, id: \.key) { account, cals in
                        Section(account) {
                            ForEach(cals) { c in
                                Toggle(c.title, isOn: Binding(get: { chosen.contains(c.id) },
                                                              set: { if $0 { chosen.insert(c.id) } else { chosen.remove(c.id) } }))
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use these") {
                    model.useCalendars(calendars.map(\.id).filter(chosen.contains))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440, height: 440)
        .task {
            guard await model.calendar.requestAccess() else { denied = true; return }
            calendars = model.calendar.calendars()
            chosen = Set(model.timetableCalendars)
        }
    }
}

/// Settings › Timetable and Settings › Calendar.
struct TimetableSettings: View {
    @Environment(AppModel.self) var model
    @State private var picking = false
    @State private var picture: URL?

    var body: some View {
        let _ = model.revision
        Section("Timetable") {
            switch model.timetableSource {
            case .picture?:
                LabeledContent("From a picture", value: model.store.setting("timetable_status") ?? "")
                HStack {
                    Button("Choose a new picture…") { picture = TimetablePicture.choose() }
                    Spacer()
                    Button("Remove", role: .destructive) { model.removeTimetable() }
                }
            case .link?:
                LabeledContent("Calendar link", value: model.timetableLink.flatMap { URL(string: $0)?.host } ?? "")
                LabeledContent("Updated") {
                    Text([model.store.timetableFetchedAt.map { Format.relative.localizedString(for: $0, relativeTo: Date()) },
                          model.store.setting("timetable_status")].compactMap { $0 }.joined(separator: " · "))
                }
                if let error = model.timetableError { Text(error).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Button("Refresh") { Task { await model.refreshTimetable(force: true) } }
                    Button("Use a picture instead…") { picture = TimetablePicture.choose() }
                    Spacer()
                    Button("Remove", role: .destructive) { model.removeTimetable() }
                }
            case .calendar?:
                let names = model.calendar.calendars().filter { model.timetableCalendars.contains($0.id) }.map(\.title)
                LabeledContent("From Calendar", value: names.isEmpty ? "No calendars" : names.joined(separator: ", "))
                HStack {
                    Button("Choose calendars…") { picking = true }
                    Button("Use a picture instead…") { picture = TimetablePicture.choose() }
                    Spacer()
                    Button("Remove", role: .destructive) { model.removeTimetable() }
                }
            case nil:
                Button("Choose a picture of your timetable…") { picture = TimetablePicture.choose() }
                OutlookSteps()
                TimetableLinkField()
                if CalendarAccess.available { Button("Use a calendar on this Mac instead") { picking = true } }
            }
        }
        .sheet(isPresented: $picking) { CalendarPicker().environment(model) }
        .sheet(item: $picture) { url in TimetablePictureSheet(url: url).environment(model) }
        Section("Calendar") {
            Toggle("Copy classes to Apple Calendar", isOn: Binding(get: { model.mirrorsClasses }, set: { on in Task { await model.setClassMirror(on) } }))
                .disabled(!CalendarAccess.available || model.timetableSource == .calendar)
            Toggle("Copy deadlines to Apple Calendar", isOn: Binding(get: { model.mirrorsDeadlines }, set: { on in Task { await model.setMirror(on) } }))
                .disabled(!CalendarAccess.available)
            Text("Into calendars called “\(CalendarMirror.classesCalendarTitle)” and “\(CalendarMirror.calendarTitle)”, so your iPhone has them too. Work you hand in leaves the deadlines calendar.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = model.mirrorError { Text(error).font(.callout).foregroundStyle(.red) }
        }
    }
}
