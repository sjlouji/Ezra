import Foundation

/// The demo content, with every date written as a day offset from today. All of it is fictional.
enum Fixtures {
    struct Event: Identifiable {
        let id = UUID()
        let day: Int
        /// Minutes after midnight; nil for an all-day event.
        let minutes: Int?
        let title: String
        let bucket: Bucket
        var note = ""
    }

    struct ProjectSpec {
        let name: String
        var notes = ""
        var headings: [String] = []
    }

    enum Place {
        case inbox, anytime, someday
        case day(Int, evening: Bool = false)
        /// Completed this many days ago.
        case done(Int)
    }

    struct ToDoSpec {
        let title: String
        let place: Place
        var project: String?
        var heading: String?
        var area: String?
        var notes = ""
        var checklist: [String] = []
        var tags: [String] = []
        var deadline: Int?
    }

    static let looseProjects = [ProjectSpec(name: "Plan Kitchen Remodel", notes: "Budget first, then quotes from three contractors.")]

    static let areas: [(name: String, projects: [ProjectSpec])] = [
        ("Family", [
            ProjectSpec(name: "Vacation in Rome", notes: "Five days in May. Keep the mornings free.", headings: ["Before we go", "In Rome"]),
            ProjectSpec(name: "Buy a New Bike"),
            ProjectSpec(name: "Throw Party for Eve", notes: "Surprise party on Saturday at 6.", headings: ["Invites", "Food & drinks", "Decorations"]),
        ]),
        ("Work", [
            ProjectSpec(name: "Prepare Presentation", notes: "Twenty minutes plus questions.", headings: ["Slides and notes", "Preparation"]),
            ProjectSpec(name: "Onboard Julia"),
            ProjectSpec(name: "Q4 Budget Review"),
        ]),
        ("Health", [ProjectSpec(name: "Run a Marathon"), ProjectSpec(name: "Learn Basic Italian")]),
        ("Home", [
            ProjectSpec(name: "Move to the New Flat", notes: "Keys on the 1st. Movers booked for the first Saturday.",
                        headings: ["Paperwork", "Packing", "After the move"]),
            ProjectSpec(name: "Spring Clean"),
        ]),
        ("Money", [
            ProjectSpec(name: "File Taxes", notes: "Everything the accountant asked for is in the checklist of the first to-do.",
                        headings: ["Collect", "Submit"]),
            ProjectSpec(name: "Cut Monthly Costs"),
        ]),
        ("Side Projects", [
            ProjectSpec(name: "Launch the Recipe Blog", notes: "Ten recipes at launch, one new post a week after that.",
                        headings: ["Writing", "Site", "Launch"]),
            ProjectSpec(name: "Read 12 Books This Year"),
        ]),
    ]

    static let events: [Event] = [
        Event(day: 0, minutes: nil, title: "Ben's birthday", bucket: .fire),
        Event(day: 0, minutes: 7 * 60, title: "Hit the gym with Lucas", bucket: .growth),
        Event(day: 0, minutes: 8 * 60 + 30, title: "Coffee with Emma", bucket: .extra),
        Event(day: 0, minutes: 11 * 60, title: "Team meeting", bucket: .fire, note: "Agenda\n• Launch date\n• Who covers support next week"),
        Event(day: 0, minutes: 15 * 60 + 30, title: "Budget review", bucket: .growth),
        Event(day: 1, minutes: 9 * 60, title: "Design review", bucket: .extra),
        Event(day: 1, minutes: 18 * 60, title: "Dinner with Mia and Noah", bucket: .fire),
        Event(day: 2, minutes: 12 * 60 + 30, title: "Lunch with Julia", bucket: .growth),
        Event(day: 4, minutes: 10 * 60, title: "Dentist", bucket: .growth),
        Event(day: 5, minutes: nil, title: "Eve's party", bucket: .fire),
        Event(day: 6, minutes: 8 * 60, title: "Long run", bucket: .growth),
        Event(day: 1, minutes: 13 * 60, title: "Call with the accountant", bucket: .fire, note: "Bring\n• Last year's return\n• Rental income figures"),
        Event(day: 2, minutes: 17 * 60 + 30, title: "Flat viewing: meter readings", bucket: .extra),
        Event(day: 3, minutes: 9 * 60 + 30, title: "Sprint planning", bucket: .growth),
        Event(day: 3, minutes: 19 * 60, title: "Book club", bucket: .extra),
        Event(day: 4, minutes: 14 * 60, title: "1:1 with Daniel", bucket: .growth),
        Event(day: 7, minutes: nil, title: "Moving day", bucket: .fire),
        Event(day: 8, minutes: 11 * 60, title: "Internet installation", bucket: .fire),
        Event(day: 9, minutes: 16 * 60, title: "Quarterly all-hands", bucket: .growth),
        Event(day: 12, minutes: 10 * 60, title: "Presentation day", bucket: .fire),
        Event(day: 13, minutes: 12 * 60, title: "Lunch with Mom", bucket: .extra),
        Event(day: -1, minutes: 10 * 60, title: "Stand-up", bucket: .extra),
        Event(day: -2, minutes: 18 * 60 + 30, title: "Yoga class", bucket: .growth),
    ]

    private static func t(
        _ title: String, _ place: Place, in project: String? = nil, under heading: String? = nil, area: String? = nil,
        notes: String = "", checklist: [String] = [], tags: [String] = [], due deadline: Int? = nil
    ) -> ToDoSpec {
        ToDoSpec(title: title, place: place, project: project, heading: heading, area: area,
                 notes: notes, checklist: checklist, tags: tags, deadline: deadline)
    }

    static let todos: [ToDoSpec] = [
        // Inbox
        t("Look into standing desks", .inbox),
        t("Reply to Oliver about the cabin weekend", .inbox),
        t("Renew library card", .inbox, tags: ["Errand"]),
        t("Idea: photo book for Grandma", .inbox, notes: "Maybe the summer photos from the lake."),
        t("Cancel unused streaming trial", .inbox),

        // Today
        t("Buy party decorations", .day(0), in: "Throw Party for Eve", under: "Decorations",
          notes: "The party shop on Elm Street closes at 6.", checklist: ["Balloons", "Party hats", "Streamers"],
          tags: ["Errand"], due: 0),
        t("Send invitations", .day(0), in: "Throw Party for Eve", under: "Invites", tags: ["Important"]),
        t("Finish slide outline", .day(0), in: "Prepare Presentation", under: "Slides and notes", due: 4),
        t("Book flights to Rome", .day(0), in: "Vacation in Rome", under: "Before we go", notes: "Compare the morning departures."),
        t("Pick up dry cleaning", .day(0), area: "Family", tags: ["Errand"]),
        t("Review Julia's first-week plan", .day(0), in: "Onboard Julia"),
        t("Easy 5 km run", .day(0), in: "Run a Marathon"),
        t("Pay electricity bill", .day(-1), tags: ["Home"], due: 0),
        // This Evening
        t("Call Mom", .day(0, evening: true), area: "Family"),
        t("Italian lesson 4", .day(0, evening: true), in: "Learn Basic Italian"),
        t("Order the birthday cake", .day(0, evening: true), in: "Throw Party for Eve", under: "Food & drinks", due: 2),
        t("Water the plants", .day(0, evening: true), tags: ["Home"]),

        // Upcoming: the next week
        t("Confirm guest list", .day(1), in: "Throw Party for Eve", under: "Invites"),
        t("Draft budget summary", .day(1), in: "Q4 Budget Review", due: 6),
        t("Test ride two bikes", .day(2), in: "Buy a New Bike", tags: ["Errand"]),
        t("Rehearse the opening", .day(2), in: "Prepare Presentation", under: "Preparation"),
        t("Buy drinks and snacks", .day(3), in: "Throw Party for Eve", under: "Food & drinks", checklist: ["Lemonade", "Sparkling water", "Crisps"]),
        t("Set up Julia's accounts", .day(3), in: "Onboard Julia"),
        t("Tempo run, 8 km", .day(4), in: "Run a Marathon"),
        t("Hang the decorations", .day(5), in: "Throw Party for Eve", under: "Decorations"),
        t("Measure the kitchen", .day(5), in: "Plan Kitchen Remodel"),
        t("Send slides to Daniel for review", .day(6), in: "Prepare Presentation", under: "Slides and notes", due: 7),
        t("Renew passport", .day(7), in: "Vacation in Rome", under: "Before we go", due: 20),
        // Upcoming: later
        t("Collect quotes from contractors", .day(10), in: "Plan Kitchen Remodel"),
        t("Give the presentation", .day(12), in: "Prepare Presentation", under: "Preparation", tags: ["Important"]),
        t("Book the Colosseum tour", .day(14), in: "Vacation in Rome", under: "In Rome"),
        t("Long run, 18 km", .day(16), in: "Run a Marathon"),
        t("Julia's 30-day check-in", .day(19), in: "Onboard Julia"),
        t("Submit the final budget", .day(21), in: "Q4 Budget Review", due: 24),
        t("Schedule the car service", .day(24), tags: ["Errand"]),

        // Anytime
        t("Compare travel insurance", .anytime, in: "Vacation in Rome", under: "Before we go"),
        t("Find a cat sitter", .anytime, in: "Vacation in Rome", under: "Before we go"),
        t("Make a list of trattorias", .anytime, in: "Vacation in Rome", under: "In Rome"),
        t("Decide on a budget", .anytime, in: "Buy a New Bike"),
        t("Read reviews of gravel bikes", .anytime, in: "Buy a New Bike"),
        t("Make a party playlist", .anytime, in: "Throw Party for Eve"),
        t("Collect speaker notes", .anytime, in: "Prepare Presentation", under: "Slides and notes"),
        t("Check the projector adapter", .anytime, in: "Prepare Presentation", under: "Preparation"),
        t("Write the team introduction email", .anytime, in: "Onboard Julia"),
        t("Gather last year's figures", .anytime, in: "Q4 Budget Review"),
        t("Buy new running shoes", .anytime, in: "Run a Marathon", tags: ["Errand"]),
        t("Sign up for the spring race", .anytime, in: "Run a Marathon", due: 18),
        t("Practise ordering coffee", .anytime, in: "Learn Basic Italian"),
        t("Choose cabinet colours", .anytime, in: "Plan Kitchen Remodel"),
        t("Sort the family photos", .anytime, area: "Family"),
        t("Tidy the shared drive", .anytime, area: "Work"),
        t("Book a check-up", .anytime, area: "Health"),

        // Someday
        t("Learn to make fresh pasta", .someday),
        t("Plan a hiking trip to the Dolomites", .someday, area: "Family"),
        t("Build a bookshelf", .someday),
        t("Watch Italian films without subtitles", .someday, in: "Learn Basic Italian"),
        t("Write a talk proposal", .someday, area: "Work"),
        t("Try a triathlon", .someday, area: "Health"),
        t("Repaint the hallway", .someday, in: "Plan Kitchen Remodel"),

        // Logbook: the last 11 days
        t("Book the venue", .done(0), in: "Throw Party for Eve"),
        t("Morning stretches", .done(0), area: "Health"),
        t("Draft the guest list", .done(1), in: "Throw Party for Eve", under: "Invites"),
        t("Send Julia her welcome pack", .done(1), in: "Onboard Julia"),
        t("Interval session", .done(2), in: "Run a Marathon"),
        t("Pick a presentation template", .done(3), in: "Prepare Presentation", under: "Slides and notes"),
        t("Buy a guidebook", .done(4), in: "Vacation in Rome", under: "Before we go"),
        t("Italian lesson 3", .done(5), in: "Learn Basic Italian"),
        t("File the expense report", .done(6), area: "Work"),
        t("Visit the bike shop", .done(8), in: "Buy a New Bike"),
        t("Photograph the old kitchen", .done(9), in: "Plan Kitchen Remodel"),
        t("Book hotel near Trastevere", .done(11), in: "Vacation in Rome", under: "Before we go"),

        // A second helping: a move, taxes, a blog, reading, and loose ends, so every list has plenty in it.
        t("Scan the lease and send it to the bank", .inbox, tags: ["Admin"]),
        t("Ask Daniel for the Q3 deck", .inbox, tags: ["Work"]),
        t("Gift idea for Dad: record player?", .inbox, notes: "He mentioned the old jazz records in the attic."),
        t("Return the faulty headphones", .inbox, tags: ["Errand"], due: 5),
        t("Look up the recycling schedule for the new street", .inbox),

        t("Sign the new lease", .day(0), in: "Move to the New Flat", under: "Paperwork", tags: ["Important", "Admin"], due: 1),
        t("Order moving boxes", .day(0), in: "Move to the New Flat", under: "Packing", checklist: ["20 medium", "10 large", "Tape", "Marker pens"]),
        t("Send tax documents to the accountant", .day(0), in: "File Taxes", under: "Collect",
          notes: "She needs them before **Friday**'s call.", checklist: ["Salary statement", "Bank interest", "Donation receipts", "Rental income"],
          tags: ["Admin"], due: 1),
        t("Write the lentil soup post", .day(0), in: "Launch the Recipe Blog", under: "Writing", tags: ["Writing"]),
        t("Read 30 pages", .day(0, evening: true), in: "Read 12 Books This Year"),
        t("Cancel the old internet contract", .day(-2), in: "Move to the New Flat", under: "Paperwork", tags: ["Admin"], due: -1),

        t("Book the movers' lift permit", .day(1), in: "Move to the New Flat", under: "Paperwork", due: 3),
        t("Pack the books", .day(2), in: "Move to the New Flat", under: "Packing"),
        t("Photograph five recipes", .day(2), in: "Launch the Recipe Blog", under: "Writing", checklist: ["Soup", "Flatbread", "Shakshuka", "Granola", "Lemon cake"]),
        t("Compare electricity tariffs", .day(3), in: "Cut Monthly Costs", tags: ["Admin"]),
        t("Pack the kitchen", .day(4), in: "Move to the New Flat", under: "Packing"),
        t("Choose a blog theme", .day(4), in: "Launch the Recipe Blog", under: "Site"),
        t("Defrost the freezer", .day(5), in: "Move to the New Flat", under: "Packing", tags: ["Home"]),
        t("Wash the windows", .day(6), in: "Spring Clean", tags: ["Home"]),
        t("Hand over the old keys", .day(7), in: "Move to the New Flat", under: "After the move", tags: ["Important"], due: 8),
        t("Register the new address", .day(9), in: "Move to the New Flat", under: "After the move", tags: ["Admin"], due: 21),
        t("Review the tax draft", .day(10), in: "File Taxes", under: "Submit", due: 14),
        t("Set up the newsletter form", .day(11), in: "Launch the Recipe Blog", under: "Site"),
        t("Publish the blog", .day(15), in: "Launch the Recipe Blog", under: "Launch", tags: ["Important"], due: 18),
        t("Submit the tax return", .day(17), in: "File Taxes", under: "Submit", tags: ["Important", "Admin"], due: 25),
        t("Renew the car insurance", .day(22), tags: ["Admin"], due: 28),
        t("Dentist check-up for the kids", .day(26), area: "Family"),

        t("Update the address with the bank", .anytime, in: "Move to the New Flat", under: "After the move", tags: ["Admin"]),
        t("Buy curtains for the bedroom", .anytime, in: "Move to the New Flat", under: "After the move", tags: ["Errand"]),
        t("Hang the pictures", .anytime, in: "Move to the New Flat", under: "After the move"),
        t("Sort the wardrobe for donations", .anytime, in: "Spring Clean"),
        t("Clean out the cellar", .anytime, in: "Spring Clean", checklist: ["Old paint", "Bike parts", "Boxes from the last move"]),
        t("Review all subscriptions", .anytime, in: "Cut Monthly Costs", notes: "Check the card statement for anything forgotten."),
        t("Switch the phone plan", .anytime, in: "Cut Monthly Costs"),
        t("Find last year's return", .anytime, in: "File Taxes", under: "Collect"),
        t("Write the About page", .anytime, in: "Launch the Recipe Blog", under: "Site", tags: ["Writing"]),
        t("Draft the launch announcement", .anytime, in: "Launch the Recipe Blog", under: "Launch", tags: ["Writing"]),
        t("Pick the next three books", .anytime, in: "Read 12 Books This Year"),
        t("Return library books", .anytime, in: "Read 12 Books This Year", tags: ["Errand"], due: 9),
        t("Back up the laptop", .anytime, tags: ["Admin"]),
        t("Fix the squeaky door", .anytime, area: "Home", tags: ["Home"]),
        t("Prepare the performance review notes", .anytime, area: "Work", tags: ["Work"], due: 12),
        t("Set up automatic savings", .anytime, area: "Money"),

        t("Build a balcony herb garden", .someday, area: "Home"),
        t("Start a pension top-up", .someday, area: "Money"),
        t("Record cooking videos", .someday, in: "Launch the Recipe Blog"),
        t("Learn to bake sourdough", .someday),
        t("Run a book swap with the neighbours", .someday, in: "Read 12 Books This Year"),
        t("Take a photography course", .someday, area: "Side Projects"),

        t("View the new flat", .done(0), in: "Move to the New Flat"),
        t("Pay the deposit", .done(1), in: "Move to the New Flat", under: "Paperwork", tags: ["Admin"]),
        t("Give notice on the old flat", .done(2), in: "Move to the New Flat", under: "Paperwork"),
        t("Book the movers", .done(3), in: "Move to the New Flat"),
        t("Finish \"The Remains of the Day\"", .done(3), in: "Read 12 Books This Year"),
        t("Register the blog domain", .done(4), in: "Launch the Recipe Blog", under: "Site"),
        t("Write the flatbread post", .done(5), in: "Launch the Recipe Blog", under: "Writing", tags: ["Writing"]),
        t("Cancel the gym nobody uses", .done(6), in: "Cut Monthly Costs"),
        t("Collect donation receipts", .done(7), in: "File Taxes", under: "Collect"),
        t("Deep-clean the oven", .done(8), in: "Spring Clean", tags: ["Home"]),
        t("Quarterly planning notes", .done(10), area: "Work", tags: ["Work"]),
        t("Car inspection", .done(13), tags: ["Errand"]),
        t("Finish \"Kitchen Confidential\"", .done(16), in: "Read 12 Books This Year"),
        t("Order new bank card", .done(20), area: "Money", tags: ["Admin"]),
    ]
}
