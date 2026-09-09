import XCTest
@testable import VolumeBar

final class ResourcePolicyTests: XCTestCase {
    func testClosedUnadjustedMixerDoesNotPoll() {
        XCTAssertFalse(ResourcePolicy.needsPolling(panelVisible: false, enabled: true, levels: [:], sleeping: false, testing: false))
        XCTAssertFalse(ResourcePolicy.needsPolling(panelVisible: false, enabled: true, levels: ["app": 1], sleeping: false, testing: false))
    }
    func testSavedCustomLevelsContinueToBeAppliedWhileClosed() {
        XCTAssertTrue(ResourcePolicy.needsPolling(panelVisible: false, enabled: true, levels: ["app": 0.3], sleeping: false, testing: false))
        XCTAssertTrue(ResourcePolicy.needsPolling(panelVisible: false, enabled: true, levels: ["app": 0], sleeping: false, testing: false))
    }
    func testBypassedMixerDoesNotPollForCustomLevels() {
        XCTAssertFalse(ResourcePolicy.needsPolling(panelVisible: false, enabled: false, levels: ["app": 0.3], sleeping: false, testing: false))
    }
    func testOpenPanelStillRefreshesAppsWhileBypassed() {
        XCTAssertTrue(ResourcePolicy.needsPolling(panelVisible: true, enabled: false, levels: [:], sleeping: false, testing: false))
    }
    func testSleepAndDiagnosticModeSuspendPolling() {
        XCTAssertFalse(ResourcePolicy.needsPolling(panelVisible: true, enabled: true, levels: ["app": 0], sleeping: true, testing: false))
        XCTAssertFalse(ResourcePolicy.needsPolling(panelVisible: true, enabled: true, levels: ["app": 0], sleeping: false, testing: true))
    }
}
