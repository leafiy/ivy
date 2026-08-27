import Foundation
import XCTest
@testable import Ivy

final class ManualSyncThrottleTests: XCTestCase {
    func testManualSyncRunsAtMostOnceEveryTenMinutesPerAccount() {
        let throttle = ManualSyncThrottle()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertTrue(throttle.consume(accountID: "account-a", now: start))
        XCTAssertFalse(throttle.consume(accountID: "account-a", now: start.addingTimeInterval(599)))
        XCTAssertTrue(throttle.consume(accountID: "account-a", now: start.addingTimeInterval(600)))
        XCTAssertTrue(throttle.consume(accountID: "account-b", now: start.addingTimeInterval(1)))
    }
}
