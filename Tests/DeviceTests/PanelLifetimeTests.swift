import AppKit
import XCTest
@testable import VolumeBar

final class PanelLifetimeTests: XCTestCase {
    @MainActor
    func testOptionsRemainAccessibleAfterSelectingTheOptionsTab() {
        _ = NSApplication.shared
        let model = MixerModel(defaults: UserDefaults(suiteName: "com.volumebar.panel-lifetime-tests")!, testing: true)
        defer { model.shutdown() }
        let controller = MixerPanelController(model: model)
        let tabs = controller.view.subviews.compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 3 }!
        let previous = UserDefaults.standard.object(forKey: "OnboardingComplete")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "OnboardingComplete") }
            else { UserDefaults.standard.removeObject(forKey: "OnboardingComplete") }
        }
        // Onboarding may hide the tabs in a fresh CI account; its button completes it.
        if tabs.isHidden {
            let start = controller.view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Open mixer" }!
            NSApp.sendAction(start.action!, to: start.target, from: start)
        }
        tabs.selectedSegment = 2
        NSApp.sendAction(tabs.action!, to: tabs.target, from: tabs)
        let visible = controller.view.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }.map(\.title)
        XCTAssertTrue(visible.contains("Quit VolumeBar"))
        XCTAssertTrue(visible.contains("Show setup tips"))
        XCTAssertTrue(visible.contains("Audio recording permission…"))
    }
    @MainActor
    func testLoadedPanelIsReleasedWithItsSubscriptions() {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "com.volumebar.panel-lifetime-tests")!
        let model = MixerModel(defaults: defaults, testing: true)
        defer { model.shutdown() }
        for _ in 0..<5 {
            weak var released: MixerPanelController?
            autoreleasepool {
                let controller = MixerPanelController(model: model)
                released = controller
                _ = controller.view
                XCTAssertNotNil(released)
            }
            XCTAssertNil(released, "A closed panel must not be retained by its controls or Combine subscriptions")
        }
    }
}
