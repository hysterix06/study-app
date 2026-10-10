import SwiftUI
import AppKit
import StudyCore
import StudyAI

/// First launch, in four steps: welcome, your school, AI, done. Every step can be skipped, and quitting midway resumes
/// at the same step. By the end the course builder is laying out each course.
struct SetupFlow: View {
    @Environment(AppModel.self) var model
    var step: SetupStep

    var body: some View {
        let _ = model.revision
        VStack(spacing: 0) {
            progress.padding(.top, 28)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case .welcome: WelcomeStep()
                    case .school: SchoolStep()
                    case .ai: AIStep()
                    case .done: DoneStep()
                    }
                }
                .padding(32).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
            }
            Divider()
            footer.padding(.horizontal, 32).padding(.vertical, 14)
        }
        .background(Theme.canvas)
    }

    var progress: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases) { s in
                Capsule().fill(s == step ? Theme.textPrimary : index(s) < index(step) ? Theme.textTertiary : Theme.fillSubtle.opacity(3))
                    .frame(width: s == step ? 22 : 8, height: 8)
            }
        }
        .animation(.easeOut(duration: Theme.motionFast), value: step)
        .accessibilityLabel("Step \(index(step) + 1) of \(SetupStep.allCases.count)")
    }

    @ViewBuilder var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { model.go(.setup(SetupStep.allCases[max(index(step) - 1, 0)])) }.buttonStyle(QuietButtonStyle())
            }
            Spacer()
            switch step {
            case .welcome:
                EmptyView()
            case .done:
                Button("Go to Home") { finishSetup(model) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            default:
                Button("Skip") { model.go(.setup(next)) }.buttonStyle(.borderless).foregroundStyle(Theme.textSecondary)
                Button("Continue") { model.go(.setup(next)) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    var next: SetupStep { SetupStep.allCases[min(index(step) + 1, SetupStep.allCases.count - 1)] }
    func index(_ s: SetupStep) -> Int { SetupStep.allCases.firstIndex(of: s) ?? 0 }
}

/// Setup is done: Home, with every course getting its path.
@MainActor
func finishSetup(_ model: AppModel) {
    model.store.setBool("setup_completed", true)
    model.store.setSetting("setup_step", nil)
    model.go(.home, replace: true)
    model.jobs.prepareCourses()
    model.refresh()
}

private struct StepHeader: View {
    var title: String
    var detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.stTitle)
            Text(detail).font(.stBody).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomeStep: View {
    @Environment(AppModel.self) var model
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72).accessibilityHidden(true)
            StepHeader(title: "Welcome to Study Tracker",
                       detail: "First you write each course into a notebook, start to finish: the words and the pictures. Then you learn it topic by topic, in the best order, with every exam in time. Your files and deadlines sort themselves.")
            HStack {
                Button("Get started") { model.go(.setup(.school)) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                Button(loading ? "Loading…" : "Try sample data") {
                    loading = true
                    do {
                        try SampleData.load(model.store)
                        finishSetup(model)
                        model.show("A sample term with a built course was added. Remove it any time in Settings › Data and export.")
                    } catch { model.fail(error) }
                    loading = false
                }.buttonStyle(QuietButtonStyle())
            }
        }
    }
}

/// Moodle brings the term, the courses, their files and deadlines. Without it, courses are added by name.
private struct SchoolStep: View {
    @Environment(AppModel.self) var model
    @State private var creating = false
    @State private var newCourse = ""

    var body: some View {
        let unlinked = MoodleSync.unlinkedCurrentCourses(store: model.store)
        let courses = model.store.courses()
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "Your school", detail: "Connect Moodle and your courses, deadlines, grades and files come in on their own.")
            if model.moodle.isConnected && !unlinked.isEmpty {
                Panel {
                    Text("Moodle lists \(unlinked.count) current course\(unlinked.count == 1 ? "" : "s").").font(.stBodyStrong)
                    Text(unlinked.map { $0.shortname.isEmpty ? $0.fullname : $0.shortname }.joined(separator: " · ")).font(.stSmall).foregroundStyle(Theme.textSecondary)
                    Button(creating ? "Adding…" : "Add \(unlinked.count == 1 ? "this course" : "these courses")") {
                        creating = true
                        do {
                            let r = try MoodleSync.createCoursesAndTerm(store: model.store)
                            model.refresh()
                            model.show("Added \(r.courses) course\(r.courses == 1 ? "" : "s") from Moodle.")
                            Task { await model.moodle.sync(silent: true); creating = false }
                        } catch { model.fail(error); creating = false }
                    }.buttonStyle(PrimaryButtonStyle()).disabled(creating)
                }
            }
            MoodleSettings()
            Panel {
                SectionHeader(title: model.moodle.isConnected ? "Another course" : "No Moodle? Add your courses by name")
                HStack {
                    TextField("e.g. Revenue Management", text: $newCourse).textFieldStyle(.roundedBorder).onSubmit(add)
                    Button("Add", action: add).buttonStyle(QuietButtonStyle()).disabled(newCourse.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !courses.isEmpty {
                    Text(courses.map(\.displayName).joined(separator: " · ")).font(.stSmall).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    func add() {
        let name = newCourse.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let term = try model.store.ensureCurrentTerm()
            _ = try model.store.saveCourse(Course(termId: term.id, code: nil, name: name, color: model.store.nextCourseColor()))
            newCourse = ""
            model.refresh()
        } catch { model.fail(error) }
    }
}

/// Free AI is found and turned on; Claude is offered for building the courses.
private struct AIStep: View {
    @State private var consentFor: ProviderDescriptor?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "AI", detail: "Free AI sorts your files and reads your syllabi, on this Mac when it can. A course builder lays out each course the best way to learn it and writes its notebook guide; Claude does it best.")
            Panel { AISettingsSimple(askConsent: { consentFor = $0 }) }
        }
        .sheet(item: $consentFor) { d in ConsentSheet(provider: d) }
    }
}

private struct DoneStep: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let courses = model.store.courses()
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "You're set",
                       detail: courses.isEmpty ? "Add a course any time with + in the sidebar." :
                        "Each course gets its path now: an outline from your lectures straight away, then a full one as the course builder writes it. Your first task in each course is its notebook.")
            if !courses.isEmpty {
                Panel {
                    ForEach(courses) { c in
                        HStack(spacing: 10) {
                            CourseDot(color: c.color)
                            Text(c.displayName).font(.stBody)
                            Spacer()
                            Text("\(model.store.materials(courseId: c.id).count) files").font(.stSmall).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
        }
    }
}
