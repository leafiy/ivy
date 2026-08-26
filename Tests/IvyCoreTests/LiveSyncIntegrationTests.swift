import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import IvyCore

/// The acceptance pass in `.scratch/ivy-web/issues/14-acceptance.md` asks a
/// question no mock can answer: when a browser edits a note, does the Mac
/// really see it — and does the Mac's own merge keep what the browser had no
/// business touching? Everything here runs against a live stack.
///
/// `MacClient` below is not a convenient stand-in: it repeats the decisions
/// `AccountSyncController.uploadSnapshot` and `.pullIfNeeded` make, because
/// those decisions are the thing under test. Dirty rows are captured *before*
/// the snapshot, only they are settled afterwards, and a pull merges or
/// replaces depending on whether anything local is still unsent. The one
/// thing left out is the content-hash short circuit, which only skips a
/// re-upload and can never change what the two sides end up holding.
///
/// The MARK numbers are the checklist numbers in that ticket.
///
/// Skipped unless `IVY_INTEGRATION_API` names a stack, so `swift test` stays
/// hermetic and offline everywhere else:
///
///     docker compose -f docker-compose.dev.yml up -d
///     IVY_INTEGRATION_API=http://127.0.0.1:7799 \
///     IVY_INTEGRATION_NAMESPACE=ivy-acceptance-14 \
///         swift test --filter LiveSyncIntegrationTests
///
/// One namespace serves the whole suite: creating one is capped at five an
/// hour per IP, and a file that minted an account per run would stop being
/// runnable by the fifth. `IVY_INTEGRATION_NAMESPACE` reuses one across runs
/// and the cap never comes up, at the price of an account that accumulates
/// notes — a delete here leaves a tombstone rather than reclaiming the row.
/// Every assertion is therefore scoped to the notes its own test authored.
final class LiveSyncIntegrationTests: XCTestCase {

    // MARK: - 6. A third, fourth and fifth device all still get in

    func testFurtherDevicesAreNoLongerTurnedAway() async throws {
        let stack = try await liveStack()

        // The device cap is gone, so this is the shape of the regression it
        // would leave behind: a browser is one more device, and the fourth
        // used to be where 403s started.
        var devices: [MacClient] = []
        defer { devices.forEach { $0.cleanup() } }
        for index in 1...5 {
            devices.append(try await stack.joinMac(named: "device-\(index)"))
        }

        let first = try XCTUnwrap(devices.first)
        let account = try await first.sync.me(token: first.token)
        let registered = Set(account.devices.map(\.id))
        let joined = Set(devices.map(\.deviceID))
        XCTAssertTrue(
            joined.isSubset(of: registered),
            "the account never registered: \(joined.subtracting(registered).sorted())"
        )
    }

    // MARK: - 7. A note written on the Mac reaches the browser

    func testMacNoteReachesTheWeb() async throws {
        let stack = try await liveStack()
        let mac = try await stack.joinMac(named: "mac-note-out")
        defer { mac.cleanup() }

        let note = try mac.store.create(text: "从 Mac 写下的一条", color: NoteColor.yellow.rawValue)
        try await mac.push()

        let seen = try await webNote(stack, note.id)
        XCTAssertEqual(seen.text, "从 Mac 写下的一条")
        XCTAssertEqual(seen.color, "yellow")
        XCTAssertNil(seen.deletedAt)
    }

    // MARK: - 7. …and the browser is told, so nobody has to reload

    func testAMacUploadIsAnnouncedToTheBrowser() async throws {
        let stack = try await liveStack()
        let mac = try await stack.joinMac(named: "mac-sse-out")
        defer { mac.cleanup() }

        let note = try mac.store.create(text: "不用刷新就该出现的一条")

        // A whole snapshot names no ids — an empty `noteIds` means "everything
        // may have moved, refetch" — so `source` is what identifies it as the
        // Mac's upload rather than another tab's write.
        let stream = try await notesFrame(
            stack: stack,
            token: stack.web.token,
            matching: { $0.contains("\"source\":\"client\"") },
            trigger: { try await mac.push() }
        )

        XCTAssertEqual(stream.response.statusCode, 200)
        XCTAssertEqual(stream.response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream"), true)
        // A buffered stream is indistinguishable from a hung one, so the
        // header that stops a proxy buffering it is part of the contract.
        XCTAssertEqual(stream.response.value(forHTTPHeaderField: "X-Accel-Buffering"), "no")
        let frame = try XCTUnwrap(stream.frame, "the browser was never told the Mac had uploaded")
        XCTAssertTrue(frame.contains("\"version\""), "the announcement carried no version: \(frame)")

        // And the note itself really is there to be refetched.
        let refetched = try await webNote(stack, note.id)
        XCTAssertEqual(refetched.text, "不用刷新就该出现的一条")
    }

    // MARK: - 7. The same channel carries a second tab's write

    func testABrowserWriteIsAnnouncedToTheOtherListeners() async throws {
        let stack = try await liveStack()
        let listener = try await stack.joinMac(named: "mac-sse-in")
        defer { listener.cleanup() }

        let noteID = UUID().uuidString.lowercased()
        let web = stack.web
        let stream = try await notesFrame(
            stack: stack,
            token: listener.token,
            matching: { $0.contains(noteID) },
            trigger: { _ = try await web.create(id: noteID, text: "另一个标签页写的") }
        )

        // `web` is a note written through the JSON API; `client` is a whole
        // snapshot arriving from a Mac. A listener refetches differently for
        // each — one names the ids that moved, the other cannot.
        let frame = try XCTUnwrap(stream.frame, "no notes event named \(noteID)")
        XCTAssertTrue(frame.contains("\"source\":\"web\""), "unexpected source: \(frame)")
    }

    // MARK: - 8. Browser edits reach the Mac, and the pin survives them

    func testWebEditsReachTheMacWithPinIntact() async throws {
        let stack = try await liveStack()
        let mac = try await stack.joinMac(named: "mac-pin")
        defer { mac.cleanup() }

        // The Mac pins it. Pin state travels in the snapshot, so it is the one
        // piece of window state the browser can destroy by writing carelessly.
        var note = try mac.store.create(text: "原文", color: NoteColor.white.rawValue)
        note.windowLevel = .pinned
        try mac.store.save(note)
        try await mac.push()

        try await stack.web.update(note.id, ["text": "网页改过的正文", "color": "green"])
        try await settle(stack, into: mac)

        let merged = try XCTUnwrap(try mac.store.note(id: note.id))
        XCTAssertEqual(merged.text, "网页改过的正文")
        XCTAssertEqual(merged.color, NoteColor.green.rawValue)
        XCTAssertEqual(merged.windowLevel, .pinned, "the browser wiped the pin off a note it only retyped")

        // And the other direction: the browser turns the pin off on purpose.
        try await stack.web.update(note.id, ["pinned": false])
        try await settle(stack, into: mac)
        XCTAssertEqual(try XCTUnwrap(try mac.store.note(id: note.id)).windowLevel, .normal)
    }

    // MARK: - 9. Both sides editing at once converge, and lose nothing

    func testConcurrentEditsConvergeWithoutLosingNotes() async throws {
        let stack = try await liveStack()
        let mac = try await stack.joinMac(named: "mac-interleave")
        defer { mac.cleanup() }

        // Each side authors notes the other has never seen. This is the loss
        // that actually threatens a snapshot protocol: the Mac uploads a whole
        // database that never contained the browser's rows.
        var expected: [String: String] = [:]
        let macIDs = try (0..<2).map { index -> String in
            let note = try mac.store.create(text: "mac-seed-\(index)")
            expected[note.id] = "mac-seed-\(index)"
            return note.id
        }
        var webIDs: [String] = []
        for index in 0..<2 {
            let id = UUID().uuidString.lowercased()
            _ = try await stack.web.create(id: id, text: "web-seed-\(index)")
            expected[id] = "web-seed-\(index)"
            webIDs.append(id)
        }
        try await stack.web.flush()

        try await mac.push()
        try await mac.pull()
        XCTAssertEqual(
            Set(try mac.store.fetchAll().map(\.id)).intersection(expected.keys),
            Set(expected.keys),
            "the browser's notes did not survive a snapshot the Mac authored alone"
        )

        // Twelve rounds, and in each one both sides write before either syncs.
        // They only reconcile every fourth round, so the two databases stay
        // genuinely divergent across several edits rather than lock-stepping —
        // which is what "两边同时开着" means, and is also what keeps the suite
        // inside the 120-calls-a-minute sync budget.
        for round in 1...12 {
            let macTarget = macIDs[round % macIDs.count]
            let webTarget = webIDs[round % webIDs.count]

            _ = try mac.store.update(id: macTarget, text: "mac-\(round)")
            try await stack.web.update(webTarget, ["text": "web-\(round)"])
            expected[macTarget] = "mac-\(round)"
            expected[webTarget] = "web-\(round)"

            if round.isMultiple(of: 4) {
                try await stack.web.flush()
                try await mac.push()
                try await mac.pull()
            }
        }

        // Then one deliberate collision on a single note. The Mac's edit is
        // stamped a second after the browser's, so last-writer-wins has a
        // real ordering to honour rather than a coin flip between two clocks.
        let contested = try XCTUnwrap(macIDs.first)
        let browserWrite = try await stack.web.update(contested, ["text": "browser-first"])
        try await stack.web.flush()
        _ = try mac.store.update(
            id: contested,
            text: "mac-last",
            now: try Self.timestamp(browserWrite.updatedAt).addingTimeInterval(1)
        )
        expected[contested] = "mac-last"
        try await mac.push()
        try await mac.pull()
        try await stack.web.flush()

        let onMac = try mac.store.fetchAll().filter { expected.keys.contains($0.id) }
        let inBrowser = try await stack.web.notes().filter { expected.keys.contains($0.id) && $0.deletedAt == nil }

        XCTAssertEqual(onMac.count, expected.count, "a note went missing on the Mac")
        XCTAssertEqual(inBrowser.count, expected.count, "a note went missing in the browser")
        for (id, text) in expected {
            XCTAssertEqual(onMac.first { $0.id == id }?.text, text, "the Mac disagrees about \(id)")
            XCTAssertEqual(inBrowser.first { $0.id == id }?.text, text, "the browser disagrees about \(id)")
        }
    }

    // MARK: - 10. A browser delete, and a browser restore, both land on the Mac

    func testWebDeleteAndRestoreTravelToTheMac() async throws {
        let stack = try await liveStack()
        let mac = try await stack.joinMac(named: "mac-trash")
        defer { mac.cleanup() }

        let note = try mac.store.create(text: "会被删掉的一条")
        try await mac.push()

        try await stack.web.delete(note.id)
        try await settle(stack, into: mac)

        // Gone from the wall, still on disk as a tombstone — that is what lets
        // the deletion outlive a device that was offline when it happened.
        XCTAssertFalse(try mac.store.fetchAll().contains { $0.id == note.id })
        XCTAssertNotNil(try XCTUnwrap(try mac.store.note(id: note.id)).deletedAt)

        try await stack.web.restore(note.id)
        try await settle(stack, into: mac)

        let restored = try XCTUnwrap(try mac.store.note(id: note.id))
        XCTAssertNil(restored.deletedAt)
        XCTAssertEqual(restored.text, "会被删掉的一条")
        XCTAssertTrue(try mac.store.fetchAll().contains { $0.id == note.id })
    }

    // MARK: - 11. A Mac delete shows up in the browser's trash

    func testMacDeleteShowsUpInTheWebTrash() async throws {
        let stack = try await liveStack()
        let mac = try await stack.joinMac(named: "mac-delete")
        defer { mac.cleanup() }

        let note = try mac.store.create(text: "Mac 上删掉的一条")
        try await mac.push()
        try mac.store.delete(id: note.id)
        try await mac.push()

        let seen = try await webNote(stack, note.id)
        XCTAssertNotNil(seen.deletedAt, "the trash cannot show what the API filtered away")
        XCTAssertEqual(seen.text, "Mac 上删掉的一条")
    }

    // MARK: - 12. Rich text survives three round trips

    func testRichTextSurvivesThreeRoundTrips() async throws {
        let stack = try await liveStack()
        let mac = try await stack.joinMac(named: "mac-richtext")
        defer { mac.cleanup() }

        let body = [
            "- [ ] 买牛奶",
            "- [x] 交房租",
            "**加粗**、<u>下划线</u>、==高亮==",
            "混排:**加粗里的 <u>下划线</u>**"
        ].joined(separator: "\n")

        let note = try mac.store.create(text: body)
        try await mac.push()

        // Each hop writes back the text the previous hop produced, never the
        // pristine constant: that is the only way a deformation introduced in
        // round one can still be there, compounded, in round three.
        for round in 1...3 {
            let inBrowser = try await webNote(stack, note.id)
            XCTAssertEqual(inBrowser.text, body, "round \(round): the browser read it back deformed")

            try await stack.web.update(note.id, ["text": inBrowser.text])
            try await settle(stack, into: mac)

            let onMac = try XCTUnwrap(try mac.store.note(id: note.id))
            XCTAssertEqual(onMac.text, body, "round \(round): the Mac merged it deformed")

            _ = try mac.store.update(id: note.id, text: onMac.text)
            try await mac.push()
        }
    }

    // MARK: - 13. Image references travel both ways

    /// Covers the field, not the picture: these URLs are never uploaded, so
    /// this proves the `images` column round-trips both directions intact.
    /// That a pasted image renders is a thing only a pair of eyes can check.
    func testImageReferencesTravelBothWays() async throws {
        let stack = try await liveStack()
        let mac = try await stack.joinMac(named: "mac-images")
        defer { mac.cleanup() }

        let fromMac = "https://files.qiansmile.com/ivy/mac-pasted.png"
        let note = try mac.store.create(text: "Mac 上贴的图", images: [fromMac])
        try await mac.push()

        let seen = try await webNote(stack, note.id)
        XCTAssertEqual(seen.images, [fromMac])

        let fromWeb = "https://files.qiansmile.com/ivy/web-pasted.png"
        try await stack.web.update(note.id, ["images": [fromMac, fromWeb]])
        try await settle(stack, into: mac)

        XCTAssertEqual(try XCTUnwrap(try mac.store.note(id: note.id)).images, [fromMac, fromWeb])
    }

    // MARK: - 14. The attachment list is the same list on both sides

    func testTheAttachmentListAgreesOnBothSides() async throws {
        let stack = try await liveStack()
        let mac = try await stack.joinMac(named: "mac-attachments")
        defer { mac.cleanup() }

        let contract = NoteAttachment(
            url: "https://files.qiansmile.com/ivy/合同.pdf",
            name: "合同.pdf",
            sizeBytes: 182_311,
            contentType: "application/pdf"
        )
        let note = try mac.store.create(text: "带附件的一条", attachments: [contract])
        try await mac.push()

        let seen = try await webNote(stack, note.id)
        XCTAssertEqual(seen.attachments.count, 1)
        XCTAssertEqual(seen.attachments.first?.url, contract.url)
        XCTAssertEqual(seen.attachments.first?.name, contract.name)
        XCTAssertEqual(seen.attachments.first?.sizeBytes, contract.sizeBytes)
        XCTAssertEqual(seen.attachments.first?.contentType, contract.contentType)

        let slides = NoteAttachment(
            url: "https://files.qiansmile.com/ivy/slides.key",
            name: "slides.key",
            sizeBytes: 4_210_688,
            contentType: "application/octet-stream"
        )
        try await stack.web.update(note.id, ["attachments": [contract, slides].map(Self.wire)])
        try await settle(stack, into: mac)

        let merged = try XCTUnwrap(try mac.store.note(id: note.id))
        XCTAssertEqual(merged.attachments, [contract, slides], "the two sides hold different attachment lists")
    }

    // MARK: - 14. The quota the client enforces is the quota the server advertises

    func testAttachmentQuotaMatchesTheAdvertisedLimit() async throws {
        let stack = try await liveStack()
        let mac = try await stack.joinMac(named: "mac-quota")
        defer { mac.cleanup() }

        let quota = try await mac.sync.attachmentQuota(token: mac.token)
        // Only the limit is worth asserting: `remainingBytes` is defined
        // server-side as `max(0, limit - used)`, so any identity between the
        // three would hold no matter what the account actually stores.
        XCTAssertEqual(quota.limitBytes, SyncLimits.attachmentBytes, "the client and the server disagree about 50 MB")
        XCTAssertGreaterThanOrEqual(quota.usedBytes, 0)
    }

    // MARK: - 14. Past 50 MB the client says so instead of trying

    func testAnOversizedAttachmentIsRefusedBeforeItReachesTheNetwork() async throws {
        let stack = try await liveStack()
        let mac = try await stack.joinMac(named: "mac-big-attachment")
        defer { mac.cleanup() }

        let oversized = AttachmentUploadFile(
            filename: "too-big.bin",
            contentType: "application/octet-stream",
            data: Data(count: Int(SyncLimits.attachmentBytes) + 1)
        )

        do {
            _ = try await mac.sync.uploadAttachments(token: mac.token, files: [oversized])
            XCTFail("a 50 MB-plus attachment was allowed onto the wire")
        } catch SyncClientError.attachmentsTooLarge(let bytes) {
            XCTAssertEqual(bytes, Int64(oversized.data.count))
        }
    }

    // MARK: - 16. What happens as the library approaches 10 MB

    func testALibraryJustUnderTheLimitStillSyncsAndOneOverIsRefused() async throws {
        let stack = try await liveStack()
        let mac = try await stack.joinMac(named: "mac-oversize")
        defer { mac.cleanup() }

        // Grow until the snapshot is over the line, then step back one note:
        // the interesting half of "approaching 10 MB" is that the last library
        // that fits still makes the round trip.
        let filler = String(repeating: "字", count: 350_000)
        var added: [String] = []
        while try mac.store.syncSnapshotSizeBytes() <= SyncLimits.noteDatabaseBytes {
            added.append(try mac.store.create(text: filler).id)
        }
        // Emptied rather than deleted: a delete leaves the tombstone *and* its
        // text, so it takes nothing off the snapshot's weight.
        let lastOne = try XCTUnwrap(added.popLast())
        _ = try mac.store.update(id: lastOne, text: "")

        let underURL = mac.directory.appendingPathComponent("under.sqlite")
        try mac.store.makeSyncSnapshot(at: underURL)
        let under = try Data(contentsOf: underURL)
        XCTAssertLessThanOrEqual(Int64(under.count), SyncLimits.noteDatabaseBytes)

        // Deliberately not uploaded: a 10 MB snapshot on the shared account
        // would sit there for every later run. The limit itself is the check.
        XCTAssertGreaterThan(Int64(under.count), SyncLimits.noteDatabaseBytes / 2, "the library never got near the limit")

        _ = try mac.store.update(id: lastOne, text: filler)
        let overURL = mac.directory.appendingPathComponent("over.sqlite")
        try mac.store.makeSyncSnapshot(at: overURL)
        let over = try Data(contentsOf: overURL)
        XCTAssertGreaterThan(Int64(over.count), SyncLimits.noteDatabaseBytes)

        do {
            _ = try await mac.sync.uploadDatabase(
                token: mac.token,
                deviceID: mac.deviceID,
                baseVersion: mac.version,
                databaseData: over
            )
            XCTFail("an oversized library was allowed onto the wire")
        } catch SyncClientError.noteDatabaseTooLarge(let bytes) {
            XCTAssertEqual(bytes, Int64(over.count))
        }
    }

    // MARK: - Live stack

    /// The account every test in this file shares.
    private func liveStack() async throws -> LiveStack {
        guard let raw = ProcessInfo.processInfo.environment["IVY_INTEGRATION_API"],
              let baseURL = URL(string: raw) else {
            throw XCTSkip(
                "Set IVY_INTEGRATION_API to a running stack "
                    + "(docker compose -f docker-compose.dev.yml up -d → http://127.0.0.1:7799) "
                    + "to run the live sync checks."
            )
        }
        return try await SharedStack.instance.resolve(baseURL: baseURL)
    }

    /// The browser's view of one note, or a failure naming the note that was
    /// missing rather than an unwrapped nil.
    private func webNote(_ stack: LiveStack, _ id: String) async throws -> WebNote {
        let fetched = try await stack.web.note(id)
        return try XCTUnwrap(fetched, "the browser has no note \(id)")
    }

    /// The browser has written; bring the snapshot current and let the Mac
    /// take it. Stands in for "a few seconds passed" without waiting them out.
    private func settle(_ stack: LiveStack, into mac: MacClient) async throws {
        try await stack.web.flush()
        try await mac.pull()
    }

    /// Opens the change stream, fires `trigger` only once the server has said
    /// the stream is live — an event published before the subscription exists
    /// reaches nobody — and returns the first `notes` frame `matching` accepts.
    private func notesFrame(
        stack: LiveStack,
        token: String,
        matching: @escaping @Sendable (String) -> Bool,
        trigger: @escaping @Sendable () async throws -> Void
    ) async throws -> (response: HTTPURLResponse, frame: String?) {
        var request = URLRequest(url: stack.baseURL.appendingPathComponent("api/v1/sync/events"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        let frame = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var event = ""
                var fired = false
                do {
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                        if event == "ready", !fired {
                            fired = true
                            Task { try? await trigger() }
                        } else if event == "notes", matching(payload) {
                            return payload
                        }
                    }
                } catch {
                    return nil
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return (http, frame)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func timestamp(_ raw: String) throws -> Date {
        try XCTUnwrap(isoFormatter.date(from: raw), "unreadable server timestamp: \(raw)")
    }

    private static func wire(_ attachment: NoteAttachment) -> [String: Any] {
        [
            "url": attachment.url,
            "name": attachment.name,
            "sizeBytes": attachment.sizeBytes,
            "contentType": attachment.contentType,
        ]
    }
}

// MARK: - The account, and the two clients that share it

private struct LiveStack: Sendable {
    let baseURL: URL
    let namespace: String
    let web: WebClient

    /// Reuses the namespace `IVY_INTEGRATION_NAMESPACE` names, creating it
    /// only the first time, and mints a throwaway one when it is unset.
    static func create(baseURL: URL) async throws -> LiveStack {
        let client = SyncClient(baseURL: baseURL)
        let device = SyncDevice(
            id: "seed-\(UUID().uuidString.prefix(8).lowercased())",
            name: "Acceptance seed"
        )

        let requested = ProcessInfo.processInfo.environment["IVY_INTEGRATION_NAMESPACE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let requested, !requested.isEmpty {
            let response: AuthResponse
            do {
                response = try await client.joinNamespace(namespace: requested, device: device)
            } catch SyncClientError.server(let status, _) where status == 404 {
                response = try await client.createNamespace(namespace: requested, device: device)
            }
            return LiveStack(
                baseURL: baseURL,
                namespace: requested,
                web: WebClient(baseURL: baseURL, token: response.accessToken)
            )
        }

        let namespace = "acceptance-\(UUID().uuidString.prefix(8).lowercased())"
        let response = try await client.createNamespace(namespace: namespace, device: device)
        return LiveStack(
            baseURL: baseURL,
            namespace: namespace,
            web: WebClient(baseURL: baseURL, token: response.accessToken)
        )
    }

    /// A second device on the same account — which is what a Mac is, next to
    /// an open browser tab.
    func joinMac(named name: String) async throws -> MacClient {
        try await MacClient.join(self, name: name)
    }
}

private actor SharedStack {
    static let instance = SharedStack()
    private var cached: [URL: LiveStack] = [:]

    func resolve(baseURL: URL) async throws -> LiveStack {
        if let existing = cached[baseURL] { return existing }
        let created = try await LiveStack.create(baseURL: baseURL)
        cached[baseURL] = created
        return created
    }
}

/// The macOS client, minus its windows. `push` and `pull` repeat what
/// `AccountSyncController` does, decision for decision — see the note at the
/// top of this file for what that costs and what it buys.
private final class MacClient {
    let deviceID: String
    let token: String
    let store: NoteStore
    let sync: SyncClient
    let directory: URL
    private(set) var version: Int = 0

    private init(deviceID: String, token: String, store: NoteStore, sync: SyncClient, directory: URL) {
        self.deviceID = deviceID
        self.token = token
        self.store = store
        self.sync = sync
        self.directory = directory
    }

    static func join(_ stack: LiveStack, name: String) async throws -> MacClient {
        let deviceID = "\(name)-\(UUID().uuidString.prefix(8).lowercased())"
        let sync = SyncClient(baseURL: stack.baseURL)
        let response = try await waitingOutRateLimits {
            try await sync.joinNamespace(
                namespace: stack.namespace,
                device: SyncDevice(id: deviceID, name: name)
            )
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try NoteStore(fileURL: directory.appendingPathComponent("notes.sqlite"))
        let client = MacClient(
            deviceID: deviceID,
            token: response.accessToken,
            store: store,
            sync: sync,
            directory: directory
        )
        try await client.pull()
        return client
    }

    /// Upload, and on a conflict do what the app does: pull, merge, upload
    /// again. Anything the browser wrote in between survives the merge; the
    /// Mac's own newer edits stay dirty and ride out on the second try.
    func push() async throws {
        do {
            try await upload()
        } catch SyncClientError.conflict {
            try await pull()
            try await upload()
        }
    }

    private func upload() async throws {
        let snapshotURL = directory.appendingPathComponent("outgoing.sqlite")
        // Captured before the snapshot, as in `uploadSnapshot`: a note edited
        // between the two reads lands in the snapshot but keeps its dirty
        // flag, so the next round re-uploads it rather than losing it.
        let dirtyAtSnapshot = try store.fetchDirty()
        try store.makeSyncSnapshot(at: snapshotURL)
        let data = try Data(contentsOf: snapshotURL)
        let uploaded = try await waitingOutRateLimits {
            try await sync.uploadDatabase(
                token: token,
                deviceID: deviceID,
                baseVersion: version,
                databaseData: data
            )
        }
        try store.markClean(upToDateWith: dirtyAtSnapshot)
        version = uploaded.version
    }

    func pull() async throws {
        let remote = try await waitingOutRateLimits { try await sync.databaseStatus(token: token) }
        guard remote.version > version else { return }
        if remote.sourceDeviceId == deviceID {
            // The server holds our own earlier upload; the content is already
            // local and re-importing it would only churn.
            version = remote.version
            return
        }
        guard remote.downloadURL != nil else { return }

        let data = try await sync.downloadDatabase(remote)
        let snapshotURL = directory.appendingPathComponent("incoming.sqlite")
        try data.write(to: snapshotURL)
        // The app merges only when it has unsent work; otherwise it replaces,
        // which is the common path for a device that has just been catching up.
        if try store.hasDirtyNotes() {
            try store.mergeContent(from: snapshotURL)
        } else {
            try store.replaceContent(from: snapshotURL)
        }
        version = remote.version
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The browser's half of the account: notes as JSON, never snapshots.
private struct WebClient: Sendable {
    let baseURL: URL
    let token: String

    @discardableResult
    func create(id: String, text: String, color: String = "white", pinned: Bool = false) async throws -> WebNote {
        try decodeNote(from: try await send("POST", "api/v1/notes", body: [
            "id": id,
            "text": text,
            "color": color,
            "pinned": pinned,
        ]))
    }

    @discardableResult
    func update(_ id: String, _ patch: [String: Any]) async throws -> WebNote {
        try decodeNote(from: try await send("PATCH", "api/v1/notes/\(id)", body: patch))
    }

    func delete(_ id: String) async throws {
        _ = try await send("DELETE", "api/v1/notes/\(id)")
    }

    func restore(_ id: String) async throws {
        _ = try await send("POST", "api/v1/notes/\(id)/restore")
    }

    /// Note writes are debounced into the snapshot. A Mac about to download it
    /// wants the current one, not the one from a moment ago.
    func flush() async throws {
        _ = try await send("POST", "api/v1/notes/flush")
    }

    func notes() async throws -> [WebNote] {
        struct Envelope: Decodable { var notes: [WebNote] }
        return try JSONDecoder().decode(Envelope.self, from: try await send("GET", "api/v1/notes")).notes
    }

    func note(_ id: String) async throws -> WebNote? {
        try await notes().first { $0.id == id }
    }

    private func decodeNote(from data: Data) throws -> WebNote {
        struct Envelope: Decodable { var note: WebNote }
        return try JSONDecoder().decode(Envelope.self, from: data).note
    }

    @discardableResult
    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        try await waitingOutRateLimits { try await sendOnce(method, path, body: body) }
    }

    private func sendOnce(_ method: String, _ path: String, body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebClientError(status: -1, body: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WebClientError(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

private struct WebNote: Decodable, Sendable {
    var id: String
    var text: String
    var color: String
    var images: [String]
    var attachments: [NoteAttachment]
    var pinned: Bool
    var updatedAt: String
    var deletedAt: String?
}

private struct WebClientError: LocalizedError {
    let status: Int
    let body: String

    var errorDescription: String? { "web API returned \(status): \(body)" }
}

// MARK: - Rate limits

/// The stack rations authenticated calls: 120 sync calls a minute per account
/// and 30 namespace logins. Those are budgets a person never approaches and
/// that a suite running fourteen scenarios in nine seconds exhausts easily —
/// so a 429 in here is the harness outrunning the limiter, not the product
/// misbehaving. Wait the window out once and carry on; a second 429 is a real
/// failure and is left to surface.
private func waitingOutRateLimits<T>(_ work: () async throws -> T) async throws -> T {
    do {
        return try await work()
    } catch {
        guard let seconds = rateLimitRetryAfter(error) else { throw error }
        try await Task.sleep(nanoseconds: UInt64(min(seconds, 90) + 1) * 1_000_000_000)
        return try await work()
    }
}

private func rateLimitRetryAfter(_ error: Error) -> Int? {
    let body: String
    if let web = error as? WebClientError, web.status == 429 {
        body = web.body
    } else if let sync = error as? SyncClientError,
              case .server(let status, let data) = sync, status == 429 {
        body = String(decoding: data, as: UTF8.self)
    } else {
        return nil
    }

    struct Envelope: Decodable {
        struct Payload: Decodable { var retryAfterSeconds: Int? }
        var error: Payload?
    }
    let decoded = try? JSONDecoder().decode(Envelope.self, from: Data(body.utf8))
    // The window is a minute wherever the response declines to say.
    return decoded?.error?.retryAfterSeconds ?? 60
}
