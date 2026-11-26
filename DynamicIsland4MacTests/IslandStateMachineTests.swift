import Testing
@testable import DynamicIsland4Mac

struct IslandStateMachineTests {
    @Test func restsCollapsedThenCompactWithActivity() {
        var m = IslandStateMachine()
        #expect(m.state == .collapsed)
        m.setLiveActivity(true)
        #expect(m.state == .compact)
        m.setLiveActivity(false)
        #expect(m.state == .collapsed)
    }

    @Test func activityChangesDoNotCloseAnOpenIsland() {
        var m = IslandStateMachine()
        m.open()
        m.setLiveActivity(true)
        #expect(m.state == .expanded)
        m.close()
        #expect(m.state == .compact)
    }

    @Test func alertsReturnToRestingState() {
        var m = IslandStateMachine()
        m.setLiveActivity(true)
        m.beginAlert()
        #expect(m.state == .alert)
        m.endAlert()
        #expect(m.state == .compact)
    }

    @Test func alertWhileExpandedStaysExpandedAndResurfacesOnClose() {
        var m = IslandStateMachine()
        m.open()
        m.beginAlert()
        #expect(m.state == .expanded)
        m.close()
        #expect(m.state == .alert)
        m.endAlert()
        #expect(m.state == .collapsed)
    }

    @Test func openingAnAlertExpands() {
        var m = IslandStateMachine()
        m.beginAlert()
        m.open()
        #expect(m.state == .expanded)
    }
}
