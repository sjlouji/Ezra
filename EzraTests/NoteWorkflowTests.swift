import AppKit
import Foundation
import SwiftUI
import SwiftData
import Testing
@testable import Ezra

/// Notes as part of the lists: where a note lives, and notes attached to to-dos.
@MainActor
struct NoteWorkflowTests {
    @Test func aNoteLivesInExactlyOnePlace() throws {
        let (workspace, _) = try makeWorkspace()
        let area = try workspace.addArea(name: "Work")
        let project = try workspace.addProject(name: "Checkout", area: area)
        let heading = try workspace.addHeading(title: "Reference", to: project)

        // A new note with nothing said goes to the Inbox.
        let note = try workspace.addNote(title: "Debug log")
        #expect(note.isInInbox && note.containerName == nil)

        // A heading brings its project; a project rules out an area.
        try workspace.move(note, to: nil, heading: heading)
        #expect(note.project == project && note.heading == heading && note.area == nil && !note.isInInbox)
        try workspace.move(note, to: project, area: area)
        #expect(note.project == project && note.heading == nil && note.area == nil)
        try workspace.move(note, to: nil, area: area)
        #expect(note.project == nil && note.area == area && (area.notes ?? []) == [note])
        try workspace.move(note, to: nil)
        #expect(note.isInInbox)

        // What the assistant remembers is a note too, but it is not waiting in the Inbox.
        try workspace.remember("Prefers mornings")
        let memory = try #require(try workspace.note(titled: Workspace.memoryTitle))
        #expect(!memory.isInInbox)
    }

    @Test func droppingANoteOnASidebarEntryFilesItThere() throws {
        let (workspace, _) = try makeWorkspace()
        let area = try workspace.addArea(name: "Home")
        let project = try workspace.addProject(name: "Kitchen")
        let heading = try workspace.addHeading(title: "Electrical", to: project)
        let note = try workspace.addNote(title: "Wattage")

        #expect(DragItem.note(note).accepts(.area(area)) && DragItem.note(note).accepts(.list(.inbox)) && !DragItem.note(note).accepts(.list(.today)))
        try workspace.file(.note(note), at: .heading(heading))
        #expect(note.project == project && note.heading == heading)
        try workspace.file(.note(note), at: .area(area))
        #expect(note.project == nil && note.heading == nil && note.area == area)
        try workspace.file(.note(note), at: .list(.inbox))
        #expect(note.isInInbox)
    }

    @Test func notesAreAttachedToToDosAndFoundFromBothSides() throws {
        let (workspace, _) = try makeWorkspace()
        let project = try workspace.addProject(name: "Checkout API v2")
        let log = try workspace.addNote(title: "Debug log", project: project)
        let decision = try workspace.addNote(title: "Retry design decision", project: project)
        let bug = try workspace.addToDo(title: "Fix payment retry bug", notes: "See [[retry design decision]].", project: project)
        let other = try workspace.addToDo(title: "Review pull request")

        // Attached by hand and linked in the text both count, each note once, attached ones first.
        try workspace.attach(log, to: bug)
        try workspace.attach(log, to: bug)
        try workspace.attach(decision, to: bug)
        #expect(bug.noteIDs.count == 2)
        #expect(try workspace.attachedNotes(of: bug) == [log, decision])
        #expect(try workspace.attachedNotes(of: other).isEmpty)

        // One note on several to-dos; the note lists them, open ones first.
        try workspace.attach(log, to: other)
        try workspace.setCompleted(bug, true)
        #expect(try workspace.todos(linking: log).map(\.title) == ["Review pull request", "Fix payment retry bug"])

        // Detaching takes off the attachment; the link written in the text stays.
        try workspace.detach(decision, from: bug)
        #expect(try workspace.attachedNotes(of: bug) == [log, decision])
        bug.notes = ""
        #expect(try workspace.attachedNotes(of: bug) == [log])
    }

    @Test func aToDoMadeFromANoteIsFiledWithItAndCarriesIt() throws {
        let (workspace, _) = try makeWorkspace()
        let project = try workspace.addProject(name: "Onboarding redesign")
        let heading = try workspace.addHeading(title: "Sprint 12", to: project)
        let review = try workspace.addNote(title: "Sprint review, 12 Nov", heading: heading)
        let made = try workspace.addToDo(for: review, title: "Send metrics to Priya")
        #expect(made.project == project && made.heading == heading && made.notes.isEmpty)
        #expect(try workspace.attachedNotes(of: made) == [review])

        // Deleting the note takes it off the to-dos it was on; the to-dos stay.
        try workspace.delete(review)
        #expect(made.noteIDs.isEmpty)
        #expect(try workspace.allToDos().count == 1)
        #expect(try workspace.notes().isEmpty)
    }

    @Test func theNotePickerNarrowsALongListByTitleOrProject() throws {
        let (workspace, _) = try makeWorkspace()
        let rome = try workspace.addProject(name: "Vacation in Rome")
        for number in 1...120 { try workspace.addNote(title: "Meeting \(number)") }
        let flights = try workspace.addNote(title: "Flight options", project: rome)
        let all = try workspace.notes()
        // Nothing typed: every note is offered (the list scrolls). Typing narrows it, by title or by where the note lives.
        #expect(NotePicker.matches(all, "  ").count == 121)
        #expect(NotePicker.matches(all, "meeting 12").map(\.title).sorted() == ["Meeting 12", "Meeting 120"])
        #expect(NotePicker.matches(all, "rome") == [flights] && NotePicker.matches(all, "zebra").isEmpty)
    }

    @Test func aNewNoteStartsWhereTheUserIs() throws {
        let (workspace, _) = try makeWorkspace()
        let app = AppModel()
        app.context = workspace.context
        let project = try workspace.addProject(name: "Kitchen")
        let area = try workspace.addArea(name: "Home")

        app.destination = .project(project)
        app.newNote()
        guard case .note(let inProject) = app.destination else { Issue.record("the new note was not opened"); return }
        #expect(inProject.project == project)

        app.destination = .area(area)
        app.newNote()
        guard case .note(let inArea) = app.destination else { Issue.record("the new note was not opened"); return }
        #expect(inArea.area == area && inArea.project == nil)

        app.destination = .list(.today)
        app.newNote()
        guard case .note(let loose) = app.destination else { Issue.record("the new note was not opened"); return }
        #expect(loose.isInInbox)
        // Back from the note returns to the list it was started from.
        #expect(app.canGoBack)
        app.goBack()
        #expect(app.destination == .list(.today))
    }
}

/// Sets up a developer's and a product owner's work with notes, and shows one screen of it. For the window snapshots.
@MainActor
func showNoteWorkflow(_ screen: String, app: AppModel, workspace: Workspace) throws {
    app.context = workspace.context
    let work = try workspace.area(named: "Work")
    let checkout = try workspace.addProject(name: "Checkout API v2", area: work)
    try workspace.setDetails(checkout, "Ship retries and idempotency before the December freeze.")
    let bug = try workspace.addToDo(
        title: "Fix payment retry bug", notes: "Third retry charges the card twice. Reported by support.",
        project: checkout, schedule: .on(.now), deadline: SmartList.day(3), tags: ["bug", "payments"]
    )
    let test = try workspace.addToDo(title: "Add test for the third retry", project: checkout, schedule: .on(.now), tags: ["tests"])
    try workspace.addToDo(title: "Review Arun's pull request", project: checkout, schedule: .on(.now))
    let log = try workspace.addNote(
        title: "Debug log: retry bug",
        body: """
            Reproduced on **staging** with a 504 from the gateway on attempt 2. The retry path runs three times with a growing delay, and the [gateway notes](https://example.com/gateway) say a 504 can still mean the charge went through, which is what happened here.
            > Support: "the card was charged twice" (ticket 4411)

            ## Cause
            `retry(3)` calls `charge()` *before* the idempotency key is saved.
            ```swift
            try saveKey(order)   // first
            try gateway.charge(order)
            ```
            ## Fix
            1. Write the key first
            2. Then call the gateway
              - only on 504 and 502
            - [x] Reproduce on staging
            - [ ] Add a test for the third retry
            ---
            | Attempt | Gateway | Charged |
            |---|---|---|
            | 1 | 504 | no |
            | 2 | 504 | **yes** |
            """,
        project: checkout
    )
    let decision = try workspace.addNote(title: "Retry design decision", body: "Exponential backoff, three attempts, one idempotency key per order.", project: checkout)
    let reference = try workspace.addHeading(title: "Reference", to: checkout)
    try workspace.addNote(title: "Gateway error codes", body: "504 is retryable; 402 is not.", heading: reference)
    try workspace.attach(log, to: bug)
    try workspace.attach(decision, to: bug)
    try workspace.attach(log, to: test)

    let onboarding = try workspace.addProject(name: "Onboarding redesign", area: work)
    let review = try workspace.addNote(
        title: "Sprint review, 12 Nov",
        body: "- Sign-up drop-off is 38% at the email step\n- Design wants empty states before the next sprint\n- Priya needs the metrics for the board deck",
        project: onboarding
    )
    let prd = try workspace.addNote(title: "PRD: onboarding v2", body: "# Problem\nNew users leave at the email step.", project: onboarding)
    let interviews = try workspace.addNote(title: "User interviews, Oct", body: "Five of eight could not find the skip button.", project: onboarding)
    try workspace.addToDo(for: review, title: "Follow up with design on empty states")
    try workspace.addToDo(for: review, title: "Send onboarding metrics to Priya")
    let write = try workspace.addToDo(for: review, title: "Write PRD for onboarding v2")
    try workspace.attach(prd, to: write)
    try workspace.attach(interviews, to: write)
    let brief = try workspace.addNote(
        title: "Onboarding v2 brief",
        body: """
            Where we are and what ships next. Each part below is its own cell.
            <!-- layout 2:1 -->
            ## Problem
            New users leave at the **email step**. Five of eight people in the October interviews could not find the skip button, and two thought the product was paid only.
            <!-- cell -->
            ### Numbers
            - 38% drop-off
            - 8 interviews
            - [ ] Re-measure in December
            <!-- /layout -->
            ## Options
            <!-- layout 1:1:1 -->
            ### A. Skip email
            Ask for it after the first project.
            <!-- cell -->
            ### B. Magic link
            One field, no password.
            <!-- cell -->
            ### C. Social sign-in
            Fast, but needs legal review.
            <!-- /layout -->
            ## Plan
            <!-- layout 1:1 -->
            **Design**
            1. Empty states
            2. New first screen
            <!-- cell -->
            **Engineering**
            - [x] Spike on magic links
            - [ ] Remove the password step
            <!-- cell -->
            **Research**
            > Re-run five interviews after launch
            <!-- cell -->
            **Launch**
            | Step | When |
            |---|---|
            | Beta | 2 Dec |
            | Everyone | 9 Dec |
            <!-- /layout -->
            """,
        project: onboarding
    )
    try workspace.addNote(title: "Ideas from the podcast", body: "Batch cooking, the two-list rule.")
    try workspace.addNote(title: "Meeting notes, 12 Nov", body: "Budget sign-off moved to Friday.")

    switch screen {
    case "notes-project", "notes-find": app.destination = .project(checkout)
    case "notes-todo":
        app.destination = .project(checkout)
        app.open(bug)
    case "notes-page": app.destination = .note(log)
    case "notes-layout": app.destination = .note(brief)
    case "notes-inbox": app.destination = .list(.inbox)
    case "notes-owner":
        app.destination = .project(onboarding)
        app.open(write)
    default: Issue.record("Unknown notes screen \(screen)")
    }
}
