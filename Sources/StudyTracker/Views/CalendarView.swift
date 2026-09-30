import SwiftUI
import StudyCore

struct CalendarLayers {
    var classes = true, deadlines = true, blocks = true, busy = true, canceled = true
}

struct CalendarScreen: View {
    @Environment(AppModel.self) var model
    @AppStorage("layer.classes") var showClasses = true
    @AppStorage("layer.deadlines") var showDeadlines = true
    @AppStorage("layer.blocks") var showBlocks = true
    @AppStorage("layer.busy") var showBusy = true
    @AppStorage("layer.canceled") var showCanceled = true

    var layers: CalendarLayers { CalendarLayers(classes: showClasses, deadlines: showDeadlines, blocks: showBlocks, busy: showBusy, canceled: showCanceled) }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.stHeading).monospacedDigit()
                Spacer()
                Button { model.planStudy() } label: { Label("Plan study", systemImage: "wand.and.stars") }.buttonStyle(QuietButtonStyle())
                    .help("Propose study blocks for the next three weeks around your classes and busy time")
                Menu {
                    Toggle("Classes and events", isOn: $showClasses)
                    Toggle("Assignments and exams", isOn: $showDeadlines)
                    Toggle("Study blocks", isOn: $showBlocks)
                    Toggle("Busy time (work, personal)", isOn: $showBusy)
                    Toggle("Canceled classes", isOn: $showCanceled)
                } label: { Label("Layers", systemImage: "square.3.layers.3d") }
                .menuStyle(.borderlessButton).fixedSize()
                Picker("View", selection: $model.calendarMode) { ForEach(CalendarMode.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                HStack(spacing: 2) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: [])
                        .accessibilityLabel("Previous")
                    Button("Today") { model.calendarDate = LocalDate.today(tz: model.tz) }.keyboardShortcut("t", modifiers: [])
                    Button { step(1) } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow, modifiers: [])
                        .accessibilityLabel("Next")
                }.buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            switch model.calendarMode {
            case .week: WeekView(start: model.calendarDate.startOfWeek(weekStartsOn: model.store.weekStartsOn), layers: layers)
            case .month: MonthView(month: model.calendarDate.firstOfMonth, layers: layers)
            case .agenda: AgendaView(from: model.calendarDate, layers: layers)
            }
        }
    }

    var title: String {
        let d = model.calendarDate.at(LocalTime(hour: 12, minute: 0), tz: model.tz)
        switch model.calendarMode {
        case .week:
            let s = model.calendarDate.startOfWeek(weekStartsOn: model.store.weekStartsOn)
            return "\(Formatters.day(s.at(LocalTime(hour: 12, minute: 0), tz: model.tz), tz: model.tz)) – \(Formatters.day(s.adding(days: 6).at(LocalTime(hour: 12, minute: 0), tz: model.tz), tz: model.tz))"
        case .month: return Formatters.monthYear(d, tz: model.tz)
        case .agenda: return "From \(Formatters.day(d, tz: model.tz))"
        }
    }

    func step(_ n: Int) {
        switch model.calendarMode {
        case .week: model.calendarDate = model.calendarDate.adding(days: 7 * n)
        case .month: model.calendarDate = model.calendarDate.firstOfMonth.adding(months: n)
        case .agenda: model.calendarDate = model.calendarDate.adding(days: 14 * n)
        }
    }
}

// MARK: - Shared data for a range

struct CalendarData {
    var occurrences: [Occurrence]
    var deadlines: [Assignment]
    var blocks: [StudyBlock]
    var courses: [Int: Course]

    @MainActor
    init(model: AppModel, from: LocalDate, to: LocalDate, layers: CalendarLayers) {
        let tz = model.tz
        let store = model.store
        courses = store.courseMap()
        occurrences = store.occurrences(from: from, to: to).filter { o in
            if o.kind == "busy" { return layers.busy }
            if o.status == .canceled && !layers.canceled { return false }
            return layers.classes
        }
        let start = from.at(LocalTime(hour: 0, minute: 0), tz: tz), end = to.adding(days: 1).at(LocalTime(hour: 0, minute: 0), tz: tz)
        deadlines = layers.deadlines ? store.assignments(AssignmentFilter(dueFrom: start, dueTo: end)) : []
        blocks = layers.blocks ? store.studyBlocks(from: start, to: end, statuses: ["proposed", "planned", "done"]) : []
    }
}

// MARK: - Week

struct WeekView: View {
    @Environment(AppModel.self) var model
    var start: LocalDate
    var layers: CalendarLayers
    let hourHeight: CGFloat = 46
    let gutter: CGFloat = 52

    @State private var pendingEdit: PendingEdit?
    @State private var quickAddSlot: QuickSlot?

    var days: [LocalDate] { (0..<7).map { start.adding(days: $0) } }

    var body: some View {
        let _ = model.revision
        let tz = model.tz
        let data = CalendarData(model: model, from: start, to: start.adding(days: 6), layers: layers)
        let today = LocalDate.today(tz: tz)
        VStack(spacing: 0) {
            // Day headers and all-day row.
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: gutter, height: 1)
                ForEach(days, id: \.self) { d in
                    VStack(spacing: 2) {
                        Text(weekdayName(d)).font(.stSmall).foregroundStyle(Theme.textTertiary)
                        Text("\(d.day)").font(.system(size: 18, weight: d == today ? .bold : .regular)).monospacedDigit()
                            .foregroundStyle(d == today ? Theme.attention : Theme.textPrimary)
                        let allDay = data.occurrences.filter { $0.allDay && LocalDate($0.start, tz: tz) == d }
                        ForEach(allDay) { o in
                            Text(o.title).font(.stSmall).lineLimit(1).padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: Theme.corner(3)).fill(Theme.fillSubtle))
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.calendarDate = d; model.calendarMode = .agenda }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { h in Color.clear.frame(height: hourHeight).id(h) }
                    }
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .topLeading) {
                        GeometryReader { geo in
                            let colW = (geo.size.width - gutter) / 7
                            ZStack(alignment: .topLeading) {
                                grid(colW: colW, today: today)
                                ForEach(Array(days.enumerated()), id: \.element) { i, d in
                                    dayColumn(d, index: i, colW: colW, data: data, today: today)
                                }
                            }
                        }
                    }
                }
                .onAppear { DispatchQueue.main.async { proxy.scrollTo(7, anchor: .top) } }
            }
        }
        .sheet(item: $pendingEdit) { p in ScopeDialog(edit: p) }
        .popover(item: $quickAddSlot) { slot in SlotQuickAdd(slot: slot) }
    }

    func weekdayName(_ d: LocalDate) -> String {
        let f = DateFormatter(); f.timeZone = model.tz; f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: d.at(LocalTime(hour: 12, minute: 0), tz: model.tz))
    }

    func grid(colW: CGFloat, today: LocalDate) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<24, id: \.self) { h in
                Text(String(format: "%02d:00", h)).font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.textTertiary)
                    .frame(width: gutter - 8, alignment: .trailing).offset(x: 0, y: CGFloat(h) * hourHeight - 6)
                Rectangle().fill(Theme.hairline).frame(height: 1).offset(x: gutter, y: CGFloat(h) * hourHeight)
            }
            ForEach(0..<8, id: \.self) { i in
                Rectangle().fill(Theme.hairline).frame(width: 1, height: hourHeight * 24).offset(x: gutter + CGFloat(i) * colW)
            }
            // Study window shading.
            let ps = model.store.plannerSettings
            Rectangle().fill(Theme.textPrimary.opacity(0.018)).frame(height: CGFloat(ps.windowStart.minutes) / 60 * hourHeight).offset(x: gutter)
        }
    }

    func y(_ date: Date, on d: LocalDate) -> CGFloat {
        let startOfDay = d.at(LocalTime(hour: 0, minute: 0), tz: model.tz)
        return CGFloat(date.timeIntervalSince(startOfDay) / 3600) * hourHeight
    }

    struct Placed: Identifiable { let id: String; let top: CGFloat; let height: CGFloat; let lane: Int; let lanes: Int }

    /// Greedy lane assignment so overlapping items sit side by side.
    func layout(_ items: [(id: String, start: Date, end: Date)], on d: LocalDate) -> [String: Placed] {
        let sorted = items.sorted { $0.start < $1.start }
        var lanesEnd: [Date] = []
        var laneOf: [String: Int] = [:]
        var cluster: [String] = []
        var clusterEnd = Date.distantPast
        var out: [String: Placed] = [:]
        func flush() {
            let n = max(1, (cluster.compactMap { laneOf[$0] }.max() ?? 0) + 1)
            for id in cluster {
                let it = sorted.first { $0.id == id }!
                let top = y(it.start, on: d)
                out[id] = Placed(id: id, top: top, height: max(18, y(it.end, on: d) - top), lane: laneOf[id]!, lanes: n)
            }
            cluster = []; lanesEnd = []
        }
        for it in sorted {
            if it.start >= clusterEnd && !cluster.isEmpty { flush() }
            if let free = lanesEnd.firstIndex(where: { $0 <= it.start }) { laneOf[it.id] = free; lanesEnd[free] = it.end }
            else { laneOf[it.id] = lanesEnd.count; lanesEnd.append(it.end) }
            cluster.append(it.id)
            clusterEnd = max(clusterEnd, it.end)
        }
        if !cluster.isEmpty { flush() }
        return out
    }

    @ViewBuilder
    func dayColumn(_ d: LocalDate, index i: Int, colW: CGFloat, data: CalendarData, today: LocalDate) -> some View {
        let tz = model.tz
        let occ = data.occurrences.filter { !$0.allDay && LocalDate($0.start, tz: tz) == d }
        let blocks = data.blocks.filter { LocalDate($0.plannedStart, tz: tz) == d }
        let deadlines = data.deadlines.filter { $0.dueAt.map { LocalDate($0, tz: tz) == d } ?? false }
        let items = occ.map { (id: "o" + $0.key, start: $0.start, end: $0.end) } + blocks.map { (id: "b\($0.id)", start: $0.plannedStart, end: $0.end) }
        let placed = layout(items, on: d)
        let x0 = gutter + CGFloat(i) * colW

        // Empty-slot tap → quick add at that time.
        Color.clear.contentShape(Rectangle())
            .frame(width: colW, height: hourHeight * 24)
            .offset(x: x0)
            .onTapGesture(coordinateSpace: .local) { p in
                let minutes = Int((p.y / hourHeight * 60 / 30).rounded(.down)) * 30
                quickAddSlot = QuickSlot(date: d, time: LocalTime(minutes: min(minutes, 23 * 60 + 30)))
            }

        ForEach(occ) { o in
            if let p = placed["o" + o.key] {
                let w = (colW - 4) / CGFloat(p.lanes)
                OccurrenceBlock(occ: o, course: o.courseId.flatMap { data.courses[$0] }, height: p.height, hourHeight: hourHeight, colW: colW) { newStart, newEnd in
                    requestMove(o, newStart: newStart, newEnd: newEnd)
                }
                .frame(width: w - 2, height: p.height)
                .offset(x: x0 + 2 + CGFloat(p.lane) * w, y: p.top)
            }
        }
        ForEach(blocks) { b in
            if let p = placed["b\(b.id)"] {
                let w = (colW - 4) / CGFloat(p.lanes)
                StudyBlockView(block: b, course: b.courseId.flatMap { data.courses[$0] })
                    .frame(width: w - 2, height: p.height)
                    .offset(x: x0 + 2 + CGFloat(p.lane) * w, y: p.top)
            }
        }
        ForEach(deadlines) { a in
            DeadlineMarker(a: a, course: a.courseId.flatMap { data.courses[$0] })
                .frame(width: colW - 6)
                .offset(x: x0 + 3, y: y(a.dueAt!, on: d) - (a.kind == .exam ? 22 : 16))
        }
        if d == today {
            let ny = y(Date(), on: d)
            Rectangle().fill(Theme.attention).frame(width: colW, height: 1.5).offset(x: x0, y: ny)
            Circle().fill(Theme.attention).frame(width: 7, height: 7).offset(x: x0 - 3.5, y: ny - 3)
        }
    }

    func requestMove(_ o: Occurrence, newStart: Date, newEnd: Date) {
        let tz = model.tz
        let change = ScheduleChange(newDate: LocalDate(newStart, tz: tz) == LocalDate(o.start, tz: tz) ? nil : LocalDate(newStart, tz: tz),
                                    newStart: LocalTime(newStart, tz: tz), newEnd: LocalTime(newEnd, tz: tz))
        if o.patternId != nil { pendingEdit = PendingEdit(occurrence: o, change: change) }
        else { model.applyScheduleEdit(o, scope: .this, change: change) }
    }
}

struct QuickSlot: Identifiable { var id: String { date.string + time.string }; var date: LocalDate; var time: LocalTime }
struct PendingEdit: Identifiable { let id = UUID(); var occurrence: Occurrence; var change: ScheduleChange }

struct OccurrenceBlock: View {
    @Environment(AppModel.self) var model
    var occ: Occurrence
    var course: Course?
    var height: CGFloat
    var hourHeight: CGFloat
    var colW: CGFloat
    var onMove: (Date, Date) -> Void
    @State private var drag: CGSize = .zero
    @State private var resize: CGFloat = 0
    @State private var showPopover = false

    var body: some View {
        let canceled = occ.status == .canceled
        let busy = occ.kind == "busy"
        let color = busy ? Theme.textTertiary : Theme.course(course?.color)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.corner(5)).fill(busy ? Theme.textPrimary.opacity(0.05) : color.opacity(0.16))
            Rectangle().fill(color.opacity(busy ? 0.35 : 0.9)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(course?.displayName ?? occ.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    if occ.status == .modified { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 8)).accessibilityLabel("Changed") }
                }
                if height > 30 {
                    Text(timeText).font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.textSecondary)
                }
                if height > 46, let loc = occ.location { Text(loc).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).lineLimit(1) }
            }
            .strikethrough(canceled)
            .padding(.leading, 6).padding(.top, 3)
        }
        .opacity(canceled ? 0.45 : 1)
        .overlay(alignment: .bottom) {
            if !busy && !canceled {
                Rectangle().fill(Color.clear).frame(height: 6).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 2).onChanged { resize = $0.translation.height }.onEnded { v in
                        let minutes = Int((v.translation.height / hourHeight * 60 / 15).rounded()) * 15
                        resize = 0
                        if minutes != 0 { onMove(occ.start, max(occ.end.adding(minutes: minutes), occ.start.adding(minutes: 15))) }
                    })
            }
        }
        .frame(height: max(18, height + resize), alignment: .top)
        .offset(drag)
        .zIndex(drag == .zero ? 0 : 10)
        .gesture(busy ? nil : DragGesture(minimumDistance: 4).onChanged { drag = $0.translation }.onEnded { v in
            let minutes = Int((v.translation.height / hourHeight * 60 / 15).rounded()) * 15
            let days = Int((v.translation.width / colW).rounded())
            drag = .zero
            if minutes != 0 || days != 0 {
                let delta = TimeInterval(minutes * 60 + days * 86400)
                onMove(occ.start.addingTimeInterval(delta), occ.end.addingTimeInterval(delta))
            }
        })
        .onTapGesture { showPopover = true }
        .popover(isPresented: $showPopover, arrowEdge: .trailing) { OccurrencePopover(occ: occ, course: course) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(occ.title), \(timeText)\(canceled ? ", canceled" : "")\(occ.location.map { ", \($0)" } ?? "")")
        .accessibilityAddTraits(.isButton)
    }

    var timeText: String { "\(Formatters.time(occ.start, tz: model.tz))–\(Formatters.time(occ.end, tz: model.tz))" }
}

struct OccurrencePopover: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var occ: Occurrence
    var course: Course?
    @State private var editing = false
    @State private var date = Date()
    @State private var startTime = Date()
    @State private var endTime = Date()
    @State private var location = ""
    @State private var pending: PendingEdit?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(occ.title).font(.stBodyStrong)
            Text("\(Formatters.day(occ.start, tz: model.tz)), \(Formatters.time(occ.start, tz: model.tz))–\(Formatters.time(occ.end, tz: model.tz))")
                .font(.stBody).foregroundStyle(Theme.textSecondary).monospacedDigit()
            if let loc = occ.location { Label(loc, systemImage: "mappin.and.ellipse").font(.stBody) }
            if occ.status == .canceled { Chip(text: "Canceled") }
            if let note = occ.note { Text(note).font(.stSmall).foregroundStyle(Theme.textSecondary) }
            if editing {
                Form {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    DatePicker("Starts", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: $endTime, displayedComponents: .hourAndMinute)
                    TextField("Room", text: $location)
                }.formStyle(.columns).environment(\.timeZone, model.tz)
                HStack {
                    Button("Cancel") { editing = false }
                    Spacer()
                    Button("Save") { save() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            } else if occ.kind != "busy" {
                HStack {
                    Button("Edit") { begin() }
                    if occ.status == .canceled {
                        Button("Restore") { restore() }
                    } else {
                        Button(occ.isClass ? "Cancel this class" : "Cancel event") { cancel() }
                    }
                    if let c = course { Button("Details") { dismiss(); model.openCourse(c.id) } }
                }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(16).frame(width: 320)
        .sheet(item: $pending) { p in ScopeDialog(edit: p) }
    }

    func begin() {
        date = occ.start; startTime = occ.start; endTime = occ.end; location = occ.location ?? ""; editing = true
    }

    func save() {
        let tz = model.tz
        let d = LocalDate(date, tz: tz)
        let change = ScheduleChange(newDate: d == LocalDate(occ.start, tz: tz) ? nil : d, newStart: LocalTime(startTime, tz: tz),
                                    newEnd: LocalTime(endTime, tz: tz), newLocation: location)
        editing = false
        if occ.patternId != nil { pending = PendingEdit(occurrence: occ, change: change) }
        else { model.applyScheduleEdit(occ, scope: .this, change: change); dismiss() }
    }

    func cancel() {
        // "Cancel this class" is always this occurrence only (Flow C).
        model.applyScheduleEdit(occ, scope: .this, change: ScheduleChange(cancel: true))
        dismiss()
    }

    func restore() {
        if let pid = occ.patternId, let od = occ.originalDate,
           let ex = model.store.exceptions().first(where: { $0.patternId == pid && $0.originalDate == od }) {
            model.run("Restored \(occ.title).") { try model.store.apply(EditPlan(mutations: [.deleteException(id: ex.id)], warnings: []), label: "Restore") }
        } else if let eid = occ.eventId, var e = model.store.events().first(where: { $0.id == eid }) {
            e.canceled = false
            model.run("Restored \(occ.title).") { try model.store.apply(EditPlan(mutations: [.updateEvent(e)], warnings: []), label: "Restore") }
        }
        dismiss()
    }
}

/// Three options like Apple Calendar, default "This class only", with an affected-count preview (§5.2).
struct ScopeDialog: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var edit: PendingEdit
    @State private var scope: EditScope = .this

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change \(edit.occurrence.title)").font(.stHeading)
            Text(describe(edit.change)).font(.stBody).foregroundStyle(Theme.textSecondary)
            Picker("Apply to", selection: $scope) {
                ForEach(EditScope.allCases) { s in Text(s.label).tag(s) }
            }
            .pickerStyle(.radioGroup)
            if scope != .this {
                let n = EditPlanner.affectedCount(occurrence: edit.occurrence, scope: scope, patterns: model.store.patterns(), breaks: model.store.breaks())
                Text("This changes \(n) class\(n == 1 ? "" : "es").").font(.stBodyStrong)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { model.applyScheduleEdit(edit.occurrence, scope: scope, change: edit.change); dismiss() }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 420)
    }

    func describe(_ c: ScheduleChange) -> String {
        let tz = model.tz
        var parts: [String] = []
        if let d = c.newDate { parts.append("move to \(Formatters.day(d.at(LocalTime(hour: 12, minute: 0), tz: tz), tz: tz))") }
        if let s = c.newStart, let e = c.newEnd { parts.append("\(s.string)–\(e.string)") }
        if let l = c.newLocation, l != (edit.occurrence.location ?? "") { parts.append(l.isEmpty ? "no room" : "room \(l)") }
        return parts.isEmpty ? "No change." : parts.joined(separator: ", ").capitalizedFirst + "."
    }
}

struct StudyBlockView: View {
    @Environment(AppModel.self) var model
    var block: StudyBlock
    var course: Course?
    @State private var show = false

    var body: some View {
        let proposed = block.status == "proposed"
        let color = Theme.course(course?.color)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.corner(5))
                .fill(proposed ? Theme.clear : color.opacity(block.status == "done" ? 0.08 : 0.12))
            RoundedRectangle(cornerRadius: Theme.corner(5))
                .strokeBorder(color.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: proposed ? [4, 3] : []))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Image(systemName: block.status == "done" ? "checkmark" : "book").font(.system(size: 9))
                    Text(block.focus ?? "Study").font(.system(size: 11, weight: .medium)).lineLimit(2)
                }
                Text(proposed ? "Proposed · \(block.plannedMinutes) min" : "\(block.plannedMinutes) min").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }.padding(4)
        }
        .onTapGesture { show = true }
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 10) {
                Text(block.focus ?? "Study block").font(.stBodyStrong)
                Text("\(Formatters.dayTime(block.plannedStart, tz: model.tz)) · \(block.plannedMinutes) min").font(.stBody).foregroundStyle(Theme.textSecondary)
                if block.createdBy == "claude" { Chip(text: "Proposed by Claude") }
                HStack {
                    if proposed {
                        Button("Accept") { set("planned") }.buttonStyle(PrimaryButtonStyle())
                        Button("Dismiss") { set("dismissed") }.buttonStyle(QuietButtonStyle())
                    } else if block.status == "planned" {
                        Button("Done") { set("done") }.buttonStyle(PrimaryButtonStyle())
                        Button("Skipped") { set("skipped") }.buttonStyle(QuietButtonStyle())
                        Button("Remove") { set("dismissed") }.buttonStyle(QuietButtonStyle())
                    } else {
                        Button("Undo done") { set("planned") }.buttonStyle(QuietButtonStyle())
                    }
                }
            }.padding(16).frame(width: 300)
        }
        .accessibilityLabel("Study block \(block.focus ?? ""), \(block.plannedMinutes) minutes, \(block.status)")
    }

    func set(_ s: String) { show = false; model.run { try model.store.setBlockStatus(block.id, s); return nil } }
}

struct DeadlineMarker: View {
    @Environment(AppModel.self) var model
    var a: Assignment
    var course: Course?
    var body: some View {
        let exam = a.kind == .exam
        let urgent = a.isOverdue(now: Date()) || (a.isOpen && (a.dueAt.map { $0.timeIntervalSinceNow < 48 * 3600 && $0 > Date() } ?? false))
        Button { model.openAssignment(a.id) } label: {
            HStack(spacing: 4) {
                Image(systemName: exam ? "exclamationmark.square.fill" : "flag.fill").font(.system(size: exam ? 11 : 9))
                Text(a.title).font(.system(size: exam ? 11 : 10, weight: exam ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 5).frame(height: exam ? 20 : 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(urgent ? Theme.attention : Theme.textPrimary)
            .background(RoundedRectangle(cornerRadius: Theme.corner(4)).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner(4)).strokeBorder(urgent ? Theme.attention.opacity(0.6) : Theme.course(course?.color).opacity(0.7)))
            .opacity(a.isOpen ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .help("\(a.title) · due \(a.dueAt.map { Formatters.dayTime($0, tz: model.tz) } ?? "")")
        .accessibilityLabel("\(exam ? "Exam" : "Due"): \(a.title)")
    }
}

struct SlotQuickAdd: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var slot: QuickSlot
    @State private var text = ""
    @State private var asEvent = false
    @State private var courseId: Int?

    var body: some View {
        let tz = model.tz
        let start = slot.date.at(slot.time, tz: tz)
        VStack(alignment: .leading, spacing: 10) {
            Text(Formatters.dayTime(start, tz: tz)).font(.stSmall).foregroundStyle(Theme.textSecondary)
            Picker("", selection: $asEvent) { Text("Assignment due").tag(false); Text("Event").tag(true) }.pickerStyle(.segmented).labelsHidden()
            TextField(asEvent ? "Event title" : "What's due?", text: $text).textFieldStyle(.roundedBorder).onSubmit(save)
            Picker("Course", selection: $courseId) {
                Text("No course").tag(Int?.none)
                ForEach(model.store.courses()) { c in Text(c.displayName).tag(Int?.some(c.id)) }
            }
            HStack { Spacer(); Button("Add", action: save).buttonStyle(PrimaryButtonStyle()).disabled(text.isEmpty || (!asEvent && courseId == nil)) }
        }
        .padding(14).frame(width: 300)
    }

    func save() {
        guard !text.isEmpty else { return }
        let start = slot.date.at(slot.time, tz: model.tz)
        if asEvent {
            model.run("Added \(text).") { _ = try model.store.saveEvent(Event(courseId: courseId, title: text, kind: courseId == nil ? "event" : "class", start: start, end: start.adding(minutes: 60))); return nil }
        } else {
            guard let courseId else { return }
            let p = QuickAddParser(courses: model.store.courses(), tz: model.tz).parse(text)
            model.run("Added \(p.title).") {
                _ = try model.store.saveAssignment(Assignment(courseId: courseId, title: p.title, kind: p.kind, dueAt: start, weightPct: p.weightPct, estHours: p.estHours))
                return nil
            }
        }
        dismiss()
    }
}

// MARK: - Month

struct MonthView: View {
    @Environment(AppModel.self) var model
    var month: LocalDate
    var layers: CalendarLayers

    var body: some View {
        let _ = model.revision
        let tz = model.tz
        let first = month.startOfWeek(weekStartsOn: model.store.weekStartsOn)
        let days = (0..<42).map { first.adding(days: $0) }
        let data = CalendarData(model: model, from: days.first!, to: days.last!, layers: layers)
        let today = LocalDate.today(tz: tz)
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                let d = first.adding(days: i)
                Text(Formatters.weekdayShort(d.at(LocalTime(hour: 12, minute: 0), tz: tz), tz: tz))
                    .font(.stSmall).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
        }
        GeometryReader { geo in
            let rowH = geo.size.height / 6
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { d in
                    let occ = data.occurrences.filter { LocalDate($0.start, tz: tz) == d && $0.kind != "busy" }
                    let dl = data.deadlines.filter { $0.dueAt.map { LocalDate($0, tz: tz) == d } ?? false }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(d.day)").font(.system(size: 12, weight: d == today ? .bold : .regular)).monospacedDigit()
                            .foregroundStyle(d == today ? Theme.attention : (d.month == month.month ? Theme.textPrimary : Theme.textTertiary))
                        ForEach(dl.prefix(2)) { a in
                            HStack(spacing: 3) {
                                Image(systemName: a.kind == .exam ? "exclamationmark.square.fill" : "flag.fill").font(.system(size: 8))
                                Text(a.title).font(.system(size: 10, weight: a.kind == .exam ? .semibold : .regular)).lineLimit(1)
                            }
                        }
                        ForEach(occ.prefix(max(0, 3 - dl.count))) { o in
                            HStack(spacing: 3) {
                                CourseDot(color: o.courseId.flatMap { data.courses[$0]?.color }, size: 5)
                                Text(o.allDay ? o.title : "\(Formatters.time(o.start, tz: tz)) \(o.courseId.flatMap { data.courses[$0]?.displayName } ?? o.title)")
                                    .font(.system(size: 10)).lineLimit(1).strikethrough(o.status == .canceled)
                            }
                        }
                        let more = occ.count + dl.count - 3
                        if more > 0 { Text("+\(more) more").font(.system(size: 10)).foregroundStyle(Theme.textTertiary) }
                        Spacer(minLength: 0)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, minHeight: rowH, maxHeight: rowH, alignment: .topLeading)
                    .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .contentShape(Rectangle())
                    .onTapGesture { model.calendarDate = d; model.calendarMode = .week }
                }
            }
        }
    }
}

// MARK: - Agenda

struct AgendaView: View {
    @Environment(AppModel.self) var model
    var from: LocalDate
    var layers: CalendarLayers

    var body: some View {
        let _ = model.revision
        let tz = model.tz
        let to = from.adding(days: 30)
        let data = CalendarData(model: model, from: from, to: to, layers: layers)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(LocalDate.range(from, to), id: \.self) { d in
                    let occ = data.occurrences.filter { LocalDate($0.start, tz: tz) == d }
                    let dl = data.deadlines.filter { $0.dueAt.map { LocalDate($0, tz: tz) == d } ?? false }
                    let bl = data.blocks.filter { LocalDate($0.plannedStart, tz: tz) == d }
                    if !(occ.isEmpty && dl.isEmpty && bl.isEmpty) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(Formatters.longDay(d.at(LocalTime(hour: 12, minute: 0), tz: tz), tz: tz)).font(.stBodyStrong)
                            ForEach(dl) { a in AssignmentLine(a: a, courses: data.courses) .onTapGesture { model.openAssignment(a.id) } }
                            ForEach(occ) { o in
                                HStack(spacing: 10) {
                                    Text(o.allDay ? "All day" : "\(Formatters.time(o.start, tz: tz))–\(Formatters.time(o.end, tz: tz))")
                                        .font(.stSmall).monospacedDigit().foregroundStyle(Theme.textSecondary).frame(width: 96, alignment: .leading)
                                    CourseDot(color: o.courseId.flatMap { data.courses[$0]?.color })
                                    Text(o.title).font(.stBody).strikethrough(o.status == .canceled)
                                        .foregroundStyle(o.kind == "busy" || o.status == .canceled ? Theme.textSecondary : Theme.textPrimary)
                                    if let l = o.location { Text(l).font(.stSmall).foregroundStyle(Theme.textTertiary) }
                                    if o.status == .modified { Chip(text: "changed") }
                                }
                            }
                            ForEach(bl) { b in
                                HStack(spacing: 10) {
                                    Text(Formatters.time(b.plannedStart, tz: tz)).font(.stSmall).monospacedDigit().foregroundStyle(Theme.textSecondary).frame(width: 96, alignment: .leading)
                                    Image(systemName: "book").font(.stSmall)
                                    Text("\(b.focus ?? "Study") · \(b.plannedMinutes) min").font(.stBody)
                                    if b.status == "proposed" { Chip(text: "proposed") }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24).contentWidth()
        }
    }
}
