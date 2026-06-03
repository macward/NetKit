import Testing
import Foundation
@testable import NetKit

// MARK: - SSEConfiguration Tests

@Suite("SSEConfiguration")
struct SSEConfigurationTests {
    @Test("Default initializer uses a long timeout")
    func defaultTimeout() {
        let configuration: SSEConfiguration = SSEConfiguration()
        #expect(configuration.timeout == 300)
    }

    @Test("Custom timeout is preserved")
    func customTimeout() {
        let configuration: SSEConfiguration = SSEConfiguration(timeout: 120)
        #expect(configuration.timeout == 120)
    }

    @Test("short preset uses a 60 second timeout")
    func shortPreset() {
        #expect(SSEConfiguration.short.timeout == 60)
    }

    @Test("standard preset uses a 5 minute timeout")
    func standardPreset() {
        #expect(SSEConfiguration.standard.timeout == 300)
    }

    @Test("long preset uses a 1 hour timeout")
    func longPreset() {
        #expect(SSEConfiguration.long.timeout == 3600)
    }

    @Test("Presets are ordered by increasing timeout")
    func presetOrdering() {
        #expect(SSEConfiguration.short.timeout < SSEConfiguration.standard.timeout)
        #expect(SSEConfiguration.standard.timeout < SSEConfiguration.long.timeout)
    }

    @Test("Equatable compares configurations by timeout")
    func equality() {
        #expect(SSEConfiguration(timeout: 99) == SSEConfiguration(timeout: 99))
        #expect(SSEConfiguration(timeout: 99) != SSEConfiguration(timeout: 100))
    }
}
