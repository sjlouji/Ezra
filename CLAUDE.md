Read README.md first.

- The Xcode project is generated: edit `project.yml`, then run `xcodegen generate`.
- All data changes go through `Workspace` (`Ezra/Models/Workspace.swift`); views and assistant tools call it rather than editing models' relationships themselves.
- Names, words, colours and fonts come from `Ezra/Brand/Theme.swift`. Do not hard-code them in a screen.
- Keep source files under 300 lines.
- Failures are logged through `Log` and shown to the user through `Alerts`; never swallow an error.
- After a change, run the tests (see README). To look at a screen, launch with `-DemoScreen <name> -DemoSnapshot YES` and read the PNG from the app's temporary folder.
