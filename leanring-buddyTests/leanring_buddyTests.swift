//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import Clicky

@MainActor
struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func previouslyConfirmedScreenRecordingPermissionStaysGrantedForAppFlow() async throws {
        let permissionStatus = WindowPositionManager.currentScreenRecordingPermissionStatus(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(permissionStatus.isGrantedForAppFlow)
        #expect(permissionStatus.requiresRelaunch)
    }

    @Test func liveScreenRecordingPermissionDoesNotRequireRelaunch() async throws {
        let permissionStatus = WindowPositionManager.currentScreenRecordingPermissionStatus(
            hasScreenRecordingPermissionNow: true,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(permissionStatus.isGrantedNow)
        #expect(permissionStatus.isGrantedForAppFlow)
        #expect(!permissionStatus.requiresRelaunch)
    }

}
