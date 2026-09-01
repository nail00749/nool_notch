import AppKit
import CoreGraphics
import QuartzCore
import XCTest
@testable import NotchApp

final class NotchInteractionTests: XCTestCase {
    @MainActor
    func testCompactHeightDefaultsToFortyAndPersists() {
        let suiteName = "NotchInteractionTests.compactHeight.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NotchVisualSettings(defaults: defaults)
        XCTAssertEqual(settings.compactHeight, 40)

        settings.compactHeight = 42

        let restoredSettings = NotchVisualSettings(defaults: defaults)
        XCTAssertEqual(restoredSettings.compactHeight, 42)
    }

    @MainActor
    func testCompactQuotaGradientUsesOversizedCompositorRotation() throws {
        let view = CompactQuotaGradientView(
            frame: CGRect(x: 0, y: 0, width: 340, height: 44)
        )
        view.update(
            primaryColor: .systemMint,
            secondaryColor: .systemBlue,
            isAnimating: true,
            rotationsPerSecond: 0.55
        )
        view.layoutSubtreeIfNeeded()

        let gradientLayer = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first
        )
        let animation = try XCTUnwrap(
            gradientLayer.animation(forKey: "quotaGradientRotation") as? CABasicAnimation
        )

        XCTAssertEqual(gradientLayer.type, .conic)
        XCTAssertEqual(gradientLayer.bounds.width, gradientLayer.bounds.height, accuracy: 0.001)
        XCTAssertGreaterThan(gradientLayer.bounds.width, view.bounds.width)
        XCTAssertEqual(animation.keyPath, "transform.rotation.z")
        XCTAssertEqual(animation.repeatCount, .infinity)
    }

    @MainActor
    func testCompactQuotaGradientStopsRotationWhenMotionIsReduced() {
        let view = CompactQuotaGradientView(
            frame: CGRect(x: 0, y: 0, width: 340, height: 44)
        )
        view.update(
            primaryColor: .systemMint,
            secondaryColor: .systemBlue,
            isAnimating: true,
            rotationsPerSecond: 0.55
        )
        view.update(
            primaryColor: .systemMint,
            secondaryColor: .systemBlue,
            isAnimating: false,
            rotationsPerSecond: 0.55
        )

        let gradientLayer = view.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first
        XCTAssertNil(gradientLayer?.animation(forKey: "quotaGradientRotation"))
    }

    func testCompactLayoutUsesSideWingsAroundPhysicalNotch() {
        let metrics = NotchLayout.metrics(
            safeAreaTop: 38,
            leftAuxiliaryArea: CGRect(x: 0, y: 1_131, width: 790, height: 38),
            rightAuxiliaryArea: CGRect(x: 1_010, y: 1_131, width: 790, height: 38)
        )

        XCTAssertEqual(metrics.physicalNotchSize, CGSize(width: 220, height: 38))
        XCTAssertEqual(metrics.compactSize, CGSize(width: 340, height: 40))
        XCTAssertEqual(metrics.expandedSize, CGSize(width: 500, height: 338))
        XCTAssertEqual(metrics.expandedMusicSize, CGSize(width: 500, height: 380))
        XCTAssertEqual(metrics.expandedCalendarSize, CGSize(width: 500, height: 498))
    }

    func testCompactHeightRangeKeepsMinimumInteractionFrame() {
        let metrics = NotchLayout.metrics(
            safeAreaTop: 0,
            leftAuxiliaryArea: nil,
            rightAuxiliaryArea: nil
        )

        XCTAssertEqual(NotchLayout.compactHeightRange, 39...42)
        XCTAssertEqual(
            metrics.compactSize(isPlaying: true, compactHeight: 39),
            CGSize(width: 226, height: 40)
        )
        XCTAssertEqual(
            metrics.compactSize(isPlaying: true, compactHeight: 40),
            CGSize(width: 226, height: 40)
        )
        XCTAssertEqual(
            metrics.compactSize(isPlaying: true, compactHeight: 42),
            CGSize(width: 226, height: 42)
        )
    }

    func testExpandedHeaderUsesEqualSideWingsAroundPhysicalNotch() {
        let metrics = NotchLayout.metrics(
            safeAreaTop: 38,
            leftAuxiliaryArea: CGRect(x: 0, y: 1_131, width: 790, height: 38),
            rightAuxiliaryArea: CGRect(x: 1_010, y: 1_131, width: 790, height: 38)
        )

        XCTAssertEqual(metrics.expandedHeaderWingWidth, 140)
    }

    func testExpandedHeaderUsesFullWidthWithoutPhysicalNotch() {
        let metrics = NotchLayout.metrics(
            safeAreaTop: 0,
            leftAuxiliaryArea: nil,
            rightAuxiliaryArea: nil
        )

        XCTAssertNil(metrics.expandedHeaderWingWidth)
    }

    func testLayoutKeepsOriginalSizesOnADisplayWithoutANotch() {
        let metrics = NotchLayout.metrics(
            safeAreaTop: 0,
            leftAuxiliaryArea: nil,
            rightAuxiliaryArea: nil
        )

        XCTAssertEqual(metrics.physicalNotchSize, .zero)
        XCTAssertEqual(metrics.compactSize, CGSize(width: 226, height: 40))
        XCTAssertEqual(metrics.expandedSize, CGSize(width: 500, height: 300))
        XCTAssertEqual(metrics.expandedMusicSize, CGSize(width: 500, height: 404))
        XCTAssertEqual(metrics.expandedCalendarSize, CGSize(width: 500, height: 460))
    }

    func testPersistentRootHoverPolicyOwnsOpenAndCloseActions() {
        XCTAssertEqual(
            NotchHoverPolicy.action(
                isHovering: true,
                isExpanded: false,
                hoverExpansionEnabled: true,
                isContextMenuVisible: false
            ),
            .expand
        )
        XCTAssertEqual(
            NotchHoverPolicy.action(
                isHovering: true,
                isExpanded: true,
                hoverExpansionEnabled: true,
                isContextMenuVisible: false
            ),
            .cancelCollapse
        )
        XCTAssertEqual(
            NotchHoverPolicy.action(
                isHovering: false,
                isExpanded: true,
                hoverExpansionEnabled: true,
                isContextMenuVisible: false
            ),
            .scheduleCollapse
        )
        XCTAssertEqual(
            NotchHoverPolicy.action(
                isHovering: false,
                isExpanded: true,
                hoverExpansionEnabled: true,
                isContextMenuVisible: true
            ),
            .none
        )
    }

    func testCollapseWaitsUntilExpansionAnimationHasSettled() {
        XCTAssertEqual(
            NotchHoverPolicy.collapseDelay(elapsedSinceExpansion: 0.10),
            0.62,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchHoverPolicy.collapseDelay(elapsedSinceExpansion: 1.0),
            0.18,
            accuracy: 0.001
        )
    }

    func testHoverExpansionUsesConfiguredDelay() {
        XCTAssertEqual(
            NotchHoverPolicy.expansionDelay(configuredDelay: 0.46),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchHoverPolicy.expansionDelay(configuredDelay: -1),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchHoverPolicy.expansionDelay(configuredDelay: 2),
            1,
            accuracy: 0.001
        )
    }

    func testCollapseGuardUsesActualExpandedWindowFrame() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_800, height: 1_169)
        let windowSize = CGSize(width: 500, height: 338)

        XCTAssertFalse(
            NotchHoverPolicy.shouldCollapse(
                pointerLocation: CGPoint(x: 900, y: 1_109),
                screenFrame: screenFrame,
                windowSize: windowSize
            )
        )
        XCTAssertTrue(
            NotchHoverPolicy.shouldCollapse(
                pointerLocation: CGPoint(x: 100, y: 669),
                screenFrame: screenFrame,
                windowSize: windowSize
            )
        )
    }

    func testWindowSizingPolicyUsesPanelSpecificExpandedHeights() {
        let metrics = NotchLayout.metrics(
            safeAreaTop: 38,
            leftAuxiliaryArea: CGRect(x: 0, y: 1_131, width: 790, height: 38),
            rightAuxiliaryArea: CGRect(x: 1_010, y: 1_131, width: 790, height: 38)
        )
        let noNotchMetrics = NotchLayout.metrics(
            safeAreaTop: 0,
            leftAuxiliaryArea: nil,
            rightAuxiliaryArea: nil
        )

        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: noNotchMetrics,
                isExpanded: true,
                selectedPanel: .music,
                calendarViewMode: .list,
                isShowingSettings: false
            ),
            CGSize(width: 500, height: 404)
        )
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics,
                isExpanded: true,
                selectedPanel: .music,
                calendarViewMode: .list,
                isShowingSettings: false
            ),
            CGSize(width: 500, height: 380)
        )
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics,
                isExpanded: true,
                selectedPanel: .jira,
                calendarViewMode: .list,
                isShowingSettings: false
            ),
            CGSize(width: 500, height: 380)
        )
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics,
                isExpanded: true,
                selectedPanel: .music,
                calendarViewMode: .list,
                isShowingSettings: true
            ),
            CGSize(width: 500, height: 338)
        )
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics,
                isExpanded: true,
                selectedPanel: .calendar,
                calendarViewMode: .month,
                isShowingSettings: false
            ),
            CGSize(width: 500, height: 498)
        )
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics,
                isExpanded: true,
                selectedPanel: .limits,
                calendarViewMode: .list,
                isShowingSettings: false
            ),
            CGSize(width: 500, height: 338)
        )
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics,
                isExpanded: false,
                selectedPanel: .music,
                calendarViewMode: .list,
                isShowingSettings: false
            ),
            CGSize(width: 340, height: 40)
        )
        XCTAssertEqual(
            NotchWindowSizingPolicy.size(
                metrics: metrics,
                isExpanded: false,
                selectedPanel: .music,
                calendarViewMode: .list,
                isShowingSettings: false,
                compactHeight: 42
            ),
            CGSize(width: 340, height: 42)
        )
    }

    func testJiraDisconnectIsEnabledOnlyWhenConfiguredAndNoAsyncIntentIsBusy() {
        XCTAssertFalse(
            JiraConnectionInteractionPolicy.canDisconnect(
                isConfigured: false,
                isBusy: false
            )
        )
        XCTAssertTrue(
            JiraConnectionInteractionPolicy.canDisconnect(
                isConfigured: true,
                isBusy: false
            )
        )
        XCTAssertFalse(
            JiraConnectionInteractionPolicy.canDisconnect(
                isConfigured: true,
                isBusy: true
            )
        )
        XCTAssertFalse(
            JiraConnectionInteractionPolicy.canDisconnect(
                isConfigured: false,
                isBusy: true
            )
        )
    }

    func testJiraLoadedIssueNoticeAppearsOnlyWhenServerTotalExceedsVisibleCount() {
        XCTAssertNil(
            JiraLoadedIssueNoticePolicy.text(visibleCount: 3, total: 2)
        )
        XCTAssertNil(
            JiraLoadedIssueNoticePolicy.text(visibleCount: 3, total: 3)
        )
        XCTAssertEqual(
            JiraLoadedIssueNoticePolicy.text(visibleCount: 3, total: 8),
            "Показано 3 из 8 задач"
        )
    }

    func testJiraQuickFiltersCombineWithAND() {
        let calendar = jiraTestCalendar()
        let today = jiraTestDate(day: 28, calendar: calendar)
        let issues = [
            jiraTestIssue(
                key: "MATCH-1",
                statusCategory: "indeterminate",
                priority: "Highest",
                dueDate: jiraTestDate(day: 27, calendar: calendar)
            ),
            jiraTestIssue(
                key: "FUTURE-1",
                statusCategory: "indeterminate",
                priority: "High",
                dueDate: jiraTestDate(day: 29, calendar: calendar)
            ),
            jiraTestIssue(
                key: "NEW-1",
                statusCategory: "new",
                priority: "Critical",
                dueDate: jiraTestDate(day: 27, calendar: calendar)
            ),
            jiraTestIssue(
                key: "MEDIUM-1",
                statusCategory: "indeterminate",
                priority: "Medium",
                dueDate: jiraTestDate(day: 27, calendar: calendar)
            )
        ]

        let filtered = JiraIssueFilterPolicy.filteredIssues(
            issues,
            active: [.inProgress, .overdue, .highPriority],
            now: today,
            calendar: calendar
        )

        XCTAssertEqual(filtered.map(\.key), ["MATCH-1"])
    }

    func testJiraHighPriorityFilterRecognizesJiraPriorityNames() {
        XCTAssertTrue(JiraIssueFilterPolicy.isHighPriority("High"))
        XCTAssertTrue(JiraIssueFilterPolicy.isHighPriority("HIGHEST"))
        XCTAssertTrue(JiraIssueFilterPolicy.isHighPriority("critical"))
        XCTAssertFalse(JiraIssueFilterPolicy.isHighPriority("Medium"))
        XCTAssertFalse(JiraIssueFilterPolicy.isHighPriority(nil))
    }

    func testJiraDueDatePresentationUsesRelativeLabelsAroundToday() {
        let calendar = jiraTestCalendar()
        let today = jiraTestDate(day: 28, calendar: calendar)

        XCTAssertEqual(
            JiraIssuePresentation.dueDateText(
                jiraTestDate(day: 27, calendar: calendar),
                relativeTo: today,
                calendar: calendar
            ),
            "Просрочено на 1 д."
        )
        XCTAssertEqual(
            JiraIssuePresentation.dueDateText(
                today,
                relativeTo: today,
                calendar: calendar
            ),
            "Сегодня"
        )
        XCTAssertEqual(
            JiraIssuePresentation.dueDateText(
                jiraTestDate(day: 29, calendar: calendar),
                relativeTo: today,
                calendar: calendar
            ),
            "Завтра"
        )
    }

    func testJiraNotConfiguredRecoveryOffersConnectSettingsIntent() {
        XCTAssertEqual(
            JiraPanelConnectionRecoveryPolicy.presentation(for: .notConfigured),
            JiraPanelConnectionRecoveryPresentation(
                title: "Подключите Jira",
                detail: "Откройте Настройки и укажите Base URL и PAT.",
                actionTitle: "Подключить Jira",
                intent: .openSettings
            )
        )
    }

    func testJiraUnauthorizedRecoveryOffersInvalidPATSettingsIntent() {
        XCTAssertEqual(
            JiraPanelConnectionRecoveryPolicy.presentation(for: .failed(.unauthorized)),
            JiraPanelConnectionRecoveryPresentation(
                title: "PAT недействителен",
                detail: "Укажите новый PAT в настройках Jira.",
                actionTitle: "Открыть настройки",
                intent: .openSettings
            )
        )
    }

    func testJiraOtherConnectionErrorsKeepExistingSafeHandling() {
        XCTAssertNil(
            JiraPanelConnectionRecoveryPolicy.presentation(for: .failed(.forbidden))
        )
        XCTAssertNil(
            JiraPanelConnectionRecoveryPolicy.presentation(for: .failed(.network))
        )
    }

    func testJiraConnectionResultAcceptanceRequiresTheExactCurrentDraft() {
        XCTAssertTrue(
            JiraConnectionResultAcceptancePolicy.shouldAccept(
                submittedDraft: "draft-a",
                currentDraft: "draft-a"
            )
        )
        XCTAssertFalse(
            JiraConnectionResultAcceptancePolicy.shouldAccept(
                submittedDraft: "draft-a",
                currentDraft: "edited-draft"
            )
        )
    }

    private func jiraTestCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func jiraTestDate(day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: 12))!
    }

    private func jiraTestIssue(
        key: String,
        statusCategory: String,
        priority: String?,
        dueDate: Date?
    ) -> JiraIssue {
        JiraIssue(
            id: key,
            key: key,
            summary: "Issue \(key)",
            projectKey: "APP",
            projectName: "Application",
            status: JiraStatus(id: statusCategory, name: statusCategory, categoryKey: statusCategory),
            priorityName: priority,
            dueDate: dueDate,
            updatedAt: nil
        )
    }
}
