import Foundation
import SwiftData
import Testing
@testable import Ezra

/// Ezra as a tool server for Claude: the protocol's answers, and who is let in.
@MainActor
struct MCPTests {
    private func ask(_ json: String, _ container: ModelContainer) throws -> JSONValue? {
        try MCPService.respond(to: Data(json.utf8), container: container).map { try JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    @Test func claudeIsGreetedAndGivenTheToolsThatReadAndChangeData() throws {
        let (_, container) = try makeWorkspace()
        let hello = try #require(try ask(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#, container))
        #expect(hello["id"] == .number(1) && hello["result"]?["protocolVersion"]?.text == "2025-03-26")
        #expect(hello["result"]?["serverInfo"]?["name"]?.text == "ezra")
        // A version Ezra does not know is answered with the newest it does.
        #expect(try ask(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#, container)?["result"]?["protocolVersion"]?.text == "2025-06-18")
        // Notifications are owed nothing.
        #expect(try ask(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, container) == nil)

        let listed = try #require(try ask(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, container)?["result"]?["tools"]?.items)
        let names = Set(listed.compactMap { $0["name"]?.text })
        #expect(names.isSuperset(of: ["listTasks", "addTask", "updateTask", "completeTask", "addProject", "writeNote", "listNotes", "attachNote"]))
        // The tools that draw in Ezra's own chat, or act on the user's behalf outside the data, are not offered.
        #expect(names.isDisjoint(with: ["showPage", "buildArtifact", "plan", "delegate", "notify", "setTimer", "remember"]))
        #expect(listed.allSatisfy { $0["inputSchema"]?["type"]?.text == "object" && $0["description"]?.text?.isEmpty == false })
    }

    @Test func callsChangeTheDataAndFailuresComeBackAsText() throws {
        let (workspace, container) = try makeWorkspace()
        try workspace.addNote(title: "Debug log", project: try workspace.addProject(name: "Checkout"))
        func call(_ name: String, _ arguments: String) throws -> (text: String, failed: Bool) {
            let reply = try #require(try ask(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#, container))
            let result = try #require(reply["result"])
            return (result["content"]?.items.first?["text"]?.text ?? "", result["isError"] == .bool(true))
        }
        #expect(try call("addTask", #"{"title":"Fix retry bug","project":"Checkout","tags":["bug"]}"#).failed == false)
        #expect(try workspace.findToDo("Fix retry bug").project?.name == "Checkout")
        #expect(try call("attachNote", #"{"task":"Fix retry bug","note":"Debug log"}"#).text.contains("Attached"))
        #expect(try workspace.attachedNotes(of: try workspace.findToDo("Fix retry bug")).map(\.title) == ["Debug log"])
        #expect(try call("listNotes", "{}").text == "- Debug log [Checkout]")
        #expect(try call("completeTask", #"{"title":"Fix retry bug"}"#).failed == false)
        #expect(try workspace.tasks().isEmpty)

        // A missing argument, an unknown task and an unknown tool are told to Claude; nothing is changed.
        #expect(try call("addTask", #"{"title":"No tags"}"#).failed)
        #expect(try call("completeTask", #"{"title":"Nothing like this"}"#).failed)
        #expect(try call("eraseEverything", "{}").failed)
        #expect(try workspace.allToDos().count == 1)
        // An unknown method and a request that is not JSON are errors of the protocol.
        #expect(try ask(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#, container)?["error"]?["code"] == .number(-32601))
        #expect(try ask("not json", container)?["error"]?["code"] == .number(-32700))
        // A batch gets its answers together, without one for the notification in it.
        let batch = try ask(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/x"}]"#, container)
        #expect(batch?.items.count == 1)
    }

    @Test func onlyTheHolderOfTheTokenOnThisMacIsLetIn() throws {
        let (_, container) = try makeWorkspace()
        let server = MCPServer()
        server.start(container: container, port: 47_955, token: "secret")
        defer { server.stop() }
        func status(_ head: String, body: String = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#) throws -> String {
            let request = try #require(HTTPRequest(Data("\(head)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)))
            return server.reply(to: request).status
        }
        #expect(try status("POST /mcp HTTP/1.1\r\nAuthorization: Bearer secret") == "200 OK")
        #expect(try status("POST /mcp HTTP/1.1\r\nauthorization: Bearer secret", body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == "202 Accepted")
        #expect(try status("POST /mcp HTTP/1.1\r\nAuthorization: Bearer wrong") == "401 Unauthorized")
        #expect(try status("POST /mcp HTTP/1.1") == "401 Unauthorized")
        // A page in a browser is refused even with the right token.
        #expect(try status("POST /mcp HTTP/1.1\r\nAuthorization: Bearer secret\r\nOrigin: https://example.com") == "403 Forbidden")
        #expect(try status("GET /mcp HTTP/1.1\r\nAuthorization: Bearer secret") == "405 Method Not Allowed")
        #expect(try status("POST /other HTTP/1.1\r\nAuthorization: Bearer secret") == "404 Not Found")
        // A request whose body has not all arrived is waited for, not answered.
        #expect(HTTPRequest(Data("POST /mcp HTTP/1.1\r\nContent-Length: 50\r\n\r\n{}".utf8)) == nil)
        // With no token set, nobody gets in.
        server.start(container: container, port: 47_955, token: "")
        #expect(try status("POST /mcp HTTP/1.1\r\nAuthorization: Bearer ") == "401 Unauthorized")
    }

    @Test func ezraIsAddedToClaudesSettingsAndTheRestIsKept() throws {
        func read(_ data: Data) throws -> [String: Any] { try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]) }
        // A file with other settings and another server keeps both.
        let before = Data(#"{"preferences":{"theme":"dark"},"mcpServers":{"other":{"command":"x"}}}"#.utf8)
        let after = try read(try ClaudeDesktop.adding(command: "/Applications/Ezra.app/Contents/MacOS/ezra-mcp", token: "t0", to: before))
        let servers = try #require(after["mcpServers"] as? [String: Any])
        #expect((after["preferences"] as? [String: String]) == ["theme": "dark"] && servers["other"] != nil)
        let ezra = try #require(servers["ezra"] as? [String: Any])
        #expect(ezra["command"] as? String == "/Applications/Ezra.app/Contents/MacOS/ezra-mcp" && (ezra["env"] as? [String: String]) == ["EZRA_MCP_TOKEN": "t0"])
        // No servers yet, and an empty file, both work; adding twice leaves one entry with the newer token.
        #expect(try read(try ClaudeDesktop.adding(command: "c", token: "t", to: Data(#"{"a":1}"#.utf8)))["a"] as? Int == 1)
        let twice = try ClaudeDesktop.adding(command: "c", token: "new", to: try ClaudeDesktop.adding(command: "c", token: "old", to: Data(" \n".utf8)))
        #expect(((try read(twice)["mcpServers"] as? [String: Any])?["ezra"] as? [String: Any])?["env"] as? [String: String] == ["EZRA_MCP_TOKEN": "new"])
        // A file that is not settings is refused, and so is any file but Claude's.
        #expect(throws: ClaudeDesktop.Unreadable.self) { try ClaudeDesktop.adding(command: "c", token: "t", to: Data("[1,2]".utf8)) }
        #expect(throws: ClaudeDesktop.Unreadable.self) { try ClaudeDesktop.adding(command: "c", token: "t", to: Data(#"{"mcpServers":[]}"#.utf8)) }
        #expect(throws: ClaudeDesktop.WrongFile.self) { try ClaudeDesktop.add(command: "c", token: "t", toFileAt: URL(fileURLWithPath: "/tmp/package.json")) }
    }
}

/// Erasing Ezra's data on this Mac.
@MainActor
struct FreshStartTests {
    @Test func erasingRemovesTheDataAndSettingsButKeepsClaudesSwitchAndOtherFiles() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appending(path: "ezra-fresh-\(UUID().uuidString)")
        try files.createDirectory(at: folder.appending(path: "Attachments"), withIntermediateDirectories: true)
        try files.createDirectory(at: folder.appending(path: ".default_SUPPORT"), withIntermediateDirectories: true)
        for name in ["default.store", "default.store-wal", "default.store-shm", ".default_SUPPORT/big", "Attachments/photo.png", "something-else.txt"] {
            try Data("x".utf8).write(to: folder.appending(path: name))
        }
        let domain = "ezra.tests.fresh.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: MCPServer.enabledKey)
        defaults.set(true, forKey: "sidebar.hidden")
        defaults.set("dark", forKey: Brand.Appearance.key)
        var forgotten: [String] = []

        let stores = [folder.appending(path: "default.store"), folder.appending(path: "never-made.store")]
        try FreshStart.erase(stores: stores, attachments: folder.appending(path: "Attachments"), defaults: defaults, domain: domain) { forgotten.append($0) }

        // The store and the attached files are gone; a file Ezra did not make is left alone.
        #expect(try files.contentsOfDirectory(atPath: folder.path) == ["something-else.txt"])
        // Settings are back to their defaults, except that Claude may still use Ezra.
        #expect(defaults.object(forKey: "sidebar.hidden") == nil && defaults.object(forKey: Brand.Appearance.key) == nil)
        #expect(defaults.bool(forKey: MCPServer.enabledKey))
        // Sync is signed out; the keys for Claude are not touched.
        #expect(forgotten == [Keychain.syncSession])
        // Erasing where there is nothing to erase is not an error.
        try FreshStart.erase(stores: stores, attachments: folder.appending(path: "Attachments"), defaults: defaults, domain: domain) { _ in }
        // The store is looked for where SwiftData really keeps it, which is a file called default.store somewhere real.
        #expect(EzraStore.storeURL().lastPathComponent == "default.store" && EzraStore.storeURL(named: "x").lastPathComponent == "x.store")
        // Asked to start with nothing at all, the demo content is noted as already given, so it is not put in.
        #expect(defaults.object(forKey: Seeder.seededKey) == nil)
        try FreshStart.erase(stores: stores, attachments: folder.appending(path: "Attachments"), defaults: defaults, domain: domain, withoutDemo: true) { _ in }
        #expect(defaults.bool(forKey: Seeder.seededKey) && defaults.integer(forKey: Seeder.versionKey) == Seeder.version)
        // A saved setting with the argument's name does not count as being asked.
        #expect(!FreshStart.requested)
    }
}

