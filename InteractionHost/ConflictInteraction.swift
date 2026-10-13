import MiledgeApplication
import MiledgeDomain
import SwiftUI

enum ConflictInteractionFixture {
    static let recordId = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let firstId = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    static let secondId = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
    static let thirdId = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!

    static var first: VaultRevision {
        VaultRevision(
            recordId: recordId, revisionId: firstId, title: "Synthetic conflict Alpha",
            tags: ["Keep Alpha"], favorite: true, sections: [
                VaultSection(id: "custom", fields: [
                    VaultField(
                        id: "key", kind: "key-material", value: .string("  Alpha\r\n0001 secret  "),
                        concealed: true, label: "Synthetic key"
                    )
                ])
            ], linkedRecordIds: [recordId, recordId]
        )
    }

    static var second: VaultRevision {
        var revision = first
        revision.revisionId = secondId
        revision.title = "Synthetic conflict Beta"
        revision.tags = ["Keep Beta"]
        revision.sections[0].fields[0].value = .string("  Beta\r\n0002 secret  ")
        return revision
    }
}

@MainActor
struct SyntheticConflictLedger: View {
    @State private var session: VaultSession
    @State private var inspection: String?
    private let fixture: SyntheticConflictStore

    init(scenario: String) {
        do {
            var second = ConflictInteractionFixture.second
            if scenario == "conflict-delete" { second.deleted = true }
            if scenario == "conflict-unsupported" { second.schemaVersion = 999 }
            if scenario == "conflict-scope" { second.storageScope = .synchronizable }
            let fixture = SyntheticConflictStore(
                records: try [ConflictInteractionFixture.first, second].map(RevisionCodec.encode), scenario: scenario
            )
            self.fixture = fixture
            _session = State(initialValue: VaultSession(authenticate: {}, load: {
                fixture.reads += 1
                if fixture.scenario == "conflict-reload-failure", fixture.reads == 2 {
                    throw CocoaError(.fileReadUnknown)
                }
                if fixture.scenario == "conflict-stale", fixture.reads == 2 {
                    var third = ConflictInteractionFixture.first
                    third.revisionId = ConflictInteractionFixture.thirdId
                    third.title = "Synthetic conflict Gamma"
                    fixture.records.append(try RevisionCodec.encode(third))
                }
                return fixture.records
            }, append: { data, _, _ in
                fixture.writes += 1
                if fixture.scenario == "conflict-retry", fixture.writes == 1 {
                    throw CocoaError(.fileWriteUnknown)
                }
                fixture.records.append(data)
            }))
        } catch {
            fatalError("Synthetic conflict fixture encoding failed: \(error)")
        }
    }

    var body: some View {
        VStack {
            LedgerView(session: session)
                .task {
                    do { try await session.unlock() }
                    catch { fatalError("Synthetic conflict ledger could not open: \(error)") }
                }
            Button("Inspect test history") {
                do {
                    let records = try fixture.records.map { try JSONSerialization.jsonObject(with: $0) }
                    inspection = String(decoding: try JSONSerialization.data(
                        withJSONObject: records, options: [.sortedKeys]
                    ), as: UTF8.self)
                } catch {
                    fatalError("Synthetic history encoding failed: \(error)")
                }
            }
            if let inspection {
                Text("Synthetic history inspection").accessibilityIdentifier("test-history")
                    .accessibilityValue(inspection)
            }
        }
    }
}

@MainActor
private final class SyntheticConflictStore {
    var records: [Data]
    let scenario: String
    var reads = 0
    var writes = 0

    init(records: [Data], scenario: String) {
        self.records = records
        self.scenario = scenario
    }
}
