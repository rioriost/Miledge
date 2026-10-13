import MiledgeApplication
import MiledgeDomain
import XCTest
@testable import MiledgeApp

@MainActor
final class ConflictReviewTests: XCTestCase {
    private func versions() -> [VaultRevision] {
        let first = VaultRevision(title: "Synthetic first")
        var second = first
        second.revisionId = UUID()
        second.title = "Synthetic second"
        return [first, second]
    }

    func testReviewUsesStableIdentityOrderingAndRequiresWritableSameScopeCompetitors() {
        let versions = versions()
        let review = ConflictReview(versions: versions, reload: { [] }, resolve: { _, _ in })
        XCTAssertEqual(review.versions.map(\.revisionId), versions.map(\.revisionId).sorted {
            $0.uuidString < $1.uuidString
        })
        XCTAssertTrue(review.path.isEmpty)
        XCTAssertTrue(review.canResolve)
        XCTAssertFalse(ConflictReview(versions: [], reload: { [] }, resolve: { _, _ in }).canResolve)
        XCTAssertFalse(ConflictReview(versions: [versions[0]], reload: { [] }, resolve: { _, _ in }).canResolve)
        var blocked = versions
        blocked[1].schemaVersion = 999
        XCTAssertFalse(ConflictReview(versions: blocked, reload: { [] }, resolve: { _, _ in }).canResolve)
        blocked[1] = versions[1]
        blocked[1].storageScope = .synchronizable
        XCTAssertFalse(ConflictReview(versions: blocked, reload: { [] }, resolve: { _, _ in }).canResolve)
    }

    func testConfirmationPassesOnlyTheExplicitChoiceAndReviewedHeads() {
        let versions = versions()
        var choices: [UUID] = []
        var expectedHeads: Set<UUID> = []
        let review = ConflictReview(versions: versions, selected: versions[1].revisionId, reload: { [] }) {
            choices.append($0)
            expectedHeads = $1
        }
        XCTAssertEqual(review.path, [versions[1].revisionId])
        review.confirming = versions[1].revisionId
        review.resolveVersion(versions[1].revisionId)
        XCTAssertEqual(choices, [versions[1].revisionId])
        XCTAssertEqual(expectedHeads, Set(versions.map(\.revisionId)))
        XCTAssertNil(review.confirming)
        XCTAssertNil(review.issue)
        XCTAssertEqual(review.versions, versions.sorted { $0.revisionId.uuidString < $1.revisionId.uuidString })
    }

    func testStaleChoiceKeepsSnapshotAndRequiresReloadBeforeRetry() {
        let versions = versions()
        var attempts = 0
        let review = ConflictReview(versions: versions, selected: versions[1].revisionId, reload: { versions }) {
            _, _ in
            attempts += 1
            throw SessionError.staleRevision
        }
        review.confirming = versions[1].revisionId
        review.resolveVersion(versions[1].revisionId)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(review.issue, String(localized: "Versions changed. Reload before resolving."))
        XCTAssertNil(review.confirming)
        XCTAssertEqual(review.path, [versions[1].revisionId])
        XCTAssertEqual(Set(review.versions.map(\.revisionId)), Set(versions.map(\.revisionId)))
    }

    func testFailedWriteLeavesReviewOpenAndSuccessfulRetryClearsError() {
        let versions = versions()
        var fail = true
        var writes = 0
        let review = ConflictReview(versions: versions, selected: versions[0].revisionId, reload: { [] }) {
            _, _ in
            if fail { throw CocoaError(.fileWriteUnknown) }
            writes += 1
        }
        review.resolveVersion(versions[0].revisionId)
        XCTAssertEqual(review.issue, String(localized: "The conflict could not be resolved. No versions were removed."))
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(review.path, [versions[0].revisionId])
        fail = false
        review.resolveVersion(versions[0].revisionId)
        XCTAssertEqual(writes, 1)
        XCTAssertNil(review.issue)
    }

    func testReloadPublishesOnlySuccessfulSnapshotAndClearsSelectionAndConfirmation() {
        let versions = versions()
        var fail = true
        let current = VaultRevision(title: "Synthetic resolved elsewhere")
        let review = ConflictReview(versions: versions, selected: versions[0].revisionId, reload: {
            if fail { throw CocoaError(.fileReadUnknown) }
            return [current]
        }, resolve: { _, _ in XCTFail("Reload must not append") })
        review.confirming = versions[0].revisionId
        review.reloadVersions()
        XCTAssertEqual(review.issue, String(localized: "Versions could not be reloaded. Try again."))
        XCTAssertEqual(review.path, [versions[0].revisionId])
        XCTAssertEqual(review.confirming, versions[0].revisionId)
        XCTAssertEqual(Set(review.versions.map(\.revisionId)), Set(versions.map(\.revisionId)))
        fail = false
        review.reloadVersions()
        XCTAssertEqual(review.versions, [current])
        XCTAssertTrue(review.path.isEmpty)
        XCTAssertNil(review.confirming)
        XCTAssertNil(review.issue)
        XCTAssertFalse(review.canResolve)
    }
}
