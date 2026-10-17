import SwiftUI
import StudyCore

/// The one-time step on Home that brings in the timetable. Shown until a timetable is added (or declined).
struct TimetableCard: View {
    @Environment(AppModel.self) var model
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add your timetable").font(.serif(22, weight: .semibold))
            Text("Paste your Outlook calendar's ICS link and your classes show under This week, kept up to date.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            OutlookSteps()
            TimetableLinkField()
            HStack(spacing: 16) {
                if CalendarAccess.available { Button("Use a calendar on this Mac instead") { picking = true }.buttonStyle(.link) }
                Button("Not now") { model.declineTimetable() }.buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
        .sheet(isPresented: $picking) { CalendarPicker().environment(model) }
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

    var body: some View {
        let _ = model.revision
        Section("Timetable") {
            switch model.timetableSource {
            case .link?:
                LabeledContent("Outlook link", value: model.timetableLink.flatMap { URL(string: $0)?.host } ?? "")
                LabeledContent("Updated") {
                    Text([model.store.timetableFetchedAt.map { Format.relative.localizedString(for: $0, relativeTo: Date()) },
                          model.store.setting("timetable_status")].compactMap { $0 }.joined(separator: " · "))
                }
                if let error = model.timetableError { Text(error).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Button("Refresh") { Task { await model.refreshTimetable(force: true) } }
                    Spacer()
                    Button("Remove", role: .destructive) { model.removeTimetable() }
                }
            case .calendar?:
                let names = model.calendar.calendars().filter { model.timetableCalendars.contains($0.id) }.map(\.title)
                LabeledContent("From Calendar", value: names.isEmpty ? "No calendars" : names.joined(separator: ", "))
                HStack {
                    Button("Choose calendars…") { picking = true }
                    Spacer()
                    Button("Remove", role: .destructive) { model.removeTimetable() }
                }
            case nil:
                OutlookSteps()
                TimetableLinkField()
                if CalendarAccess.available { Button("Use a calendar on this Mac instead") { picking = true } }
            }
        }
        .sheet(isPresented: $picking) { CalendarPicker().environment(model) }
        Section("Calendar") {
            Toggle("Copy deadlines to Apple Calendar", isOn: Binding(get: { model.mirrorsDeadlines }, set: { on in Task { await model.setMirror(on) } }))
                .disabled(!CalendarAccess.available)
            Text("Into a calendar called “\(CalendarMirror.calendarTitle)”, so your phone has them too. Work you hand in leaves it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = model.mirrorError { Text(error).font(.callout).foregroundStyle(.red) }
        }
    }
}
