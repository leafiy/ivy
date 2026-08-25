import Foundation
import XCTest
@testable import Ivy

final class ManualSyncThrottleTests: XCTestCase {
    func testManualSyncRunsAtMostOnceEveryTenMinutesPerAccount() throws {
        let suiteName = "ManualSyncThrottleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let throttle = ManualSyncThrottle(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertTrue(throttle.consume(accountID: "account-a", now: start))
        XCTAssertFalse(throttle.consume(accountID: "account-a", now: start.addingTimeInterval(599)))
        XCTAssertTrue(throttle.consume(accountID: "account-a", now: start.addingTimeInterval(600)))
        XCTAssertTrue(throttle.consume(accountID: "account-b", now: start.addingTimeInterval(1)))
    }
}
