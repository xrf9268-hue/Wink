import Testing
@testable import Wink

@Test
func permissionSnapshotKeepsAccessibilityAndInputMonitoringSeparate() {
    let service = AccessibilityPermissionService(client: .init(
        isAccessibilityTrusted: { false },
        isInputMonitoringTrusted: { true },
        requestAccessibilityPermission: { _ in false },
        requestInputMonitoringAccess: { false }
    ))

    #expect(service.isTrusted() == false)
    #expect(service.isAccessibilityTrusted() == false)
    #expect(service.isInputMonitoringTrusted() == true)
}

@Test
func requestWithoutPromptDoesNotRequestInputMonitoringAccess() {
    let recorder = PermissionRequestRecorder()
    let service = AccessibilityPermissionService(client: .init(
        isAccessibilityTrusted: { true },
        isInputMonitoringTrusted: { false },
        requestAccessibilityPermission: { prompt in
            recorder.accessibilityPromptValues.append(prompt)
            return true
        },
        requestInputMonitoringAccess: {
            recorder.inputMonitoringRequestCount += 1
            return true
        }
    ))

    let granted = service.requestIfNeeded(prompt: false, inputMonitoringRequired: true)

    #expect(granted == false)
    #expect(recorder.accessibilityPromptValues == [false])
    #expect(recorder.inputMonitoringRequestCount == 0)
}

@Test
func requestWithPromptSkipsInputMonitoringWhenCurrentConfigurationDoesNotNeedIt() {
    let recorder = PermissionRequestRecorder()
    let service = AccessibilityPermissionService(client: .init(
        isAccessibilityTrusted: { true },
        isInputMonitoringTrusted: { false },
        requestAccessibilityPermission: { prompt in
            recorder.accessibilityPromptValues.append(prompt)
            return true
        },
        requestInputMonitoringAccess: {
            recorder.inputMonitoringRequestCount += 1
            return true
        }
    ))

    let granted = service.requestIfNeeded(prompt: true, inputMonitoringRequired: false)

    #expect(granted == true)
    #expect(recorder.accessibilityPromptValues == [true])
    #expect(recorder.inputMonitoringRequestCount == 0)
}

@Test
func requestWithPromptRequestsInputMonitoringAccessWhenPreflightFailsAndHyperNeedsIt() {
    let recorder = PermissionRequestRecorder()
    let service = AccessibilityPermissionService(client: .init(
        isAccessibilityTrusted: { true },
        isInputMonitoringTrusted: { false },
        requestAccessibilityPermission: { prompt in
            recorder.accessibilityPromptValues.append(prompt)
            return true
        },
        requestInputMonitoringAccess: {
            recorder.inputMonitoringRequestCount += 1
            return true
        }
    ))

    let granted = service.requestIfNeeded(prompt: true, inputMonitoringRequired: true)

    #expect(granted == true)
    #expect(recorder.accessibilityPromptValues == [true])
    #expect(recorder.inputMonitoringRequestCount == 1)
}

private final class PermissionRequestRecorder: @unchecked Sendable {
    var accessibilityPromptValues: [Bool] = []
    var inputMonitoringRequestCount = 0
}
