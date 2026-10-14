import XCTest
import WebKit
@testable import Luna

@MainActor
final class CoreLogicTests: XCTestCase {
    func testProfileSessionsOwnIndependentBrowserStateAndDataStores() {
        let firstStore = WKWebsiteDataStore.nonPersistent()
        let secondStore = WKWebsiteDataStore.nonPersistent()
        let first = ProfileSession(profileId: UUID(), dataStore: firstStore)
        let second = ProfileSession(profileId: UUID(), dataStore: secondStore)

        _ = first.tabManager.newTab(url: URL(string: "https://example.com"))

        XCTAssertEqual(first.tabManager.tabCount(), 2)
        XCTAssertEqual(second.tabManager.tabCount(), 1)
        XCTAssertTrue(first.webViewWrapper.ensureWebView(for: first.tabManager.currentTab!).configuration.websiteDataStore === firstStore)
        XCTAssertTrue(second.webViewWrapper.ensureWebView(for: second.tabManager.currentTab!).configuration.websiteDataStore === secondStore)
    }

    func testExplicitBrowserCommandsAreParsedAndExecuted() throws {
        let manager = TabManager()
        _ = manager.newTab(url: URL(string: "about:blank"))
        _ = manager.newTab(url: URL(string: "https://example.com"))
        let router = CommandRouter()

        let switchProposal = try XCTUnwrap(router.proposal(for: "switch to tab 1", tabManager: manager)?.action)
        XCTAssertNoThrow(try router.execute(action: switchProposal, tabManager: manager).get())
        XCTAssertEqual(manager.currentIndex(), 0)

        let closeProposal = try XCTUnwrap(router.proposal(for: "close tab 2", tabManager: manager)?.action)
        XCTAssertNoThrow(try router.execute(action: closeProposal, tabManager: manager).get())
        XCTAssertEqual(manager.tabCount(), 1)
    }

    func testCommandRouterRejectsUnsafeSchemes() {
        let manager = TabManager()
        _ = manager.newTab(url: nil)
        let action = BrowserAction(id: UUID(), type: .navigate, payload: ["url": "file:///etc/passwd"])

        XCTAssertThrowsError(try CommandRouter().execute(action: action, tabManager: manager).get())
    }

    func testPrivateAndLocalURLsAreRejectedForContextFetching() {
        XCTAssertFalse(WebSearchService.isSafeRemoteURL(URL(string: "http://localhost:8080")!))
        XCTAssertFalse(WebSearchService.isSafeRemoteURL(URL(string: "http://192.168.1.10")!))
        XCTAssertFalse(WebSearchService.isSafeRemoteURL(URL(string: "http://[::1]")!))
        XCTAssertFalse(WebSearchService.isSafeRemoteURL(URL(string: "http://[fe80::1]")!))
        XCTAssertTrue(WebSearchService.isSafeRemoteURL(URL(string: "https://example.com")!))
    }

    func testLLMClockProvidesCurrentDateContext() {
        let fixed = Date(timeIntervalSince1970: 1_784_500_000) // Jul 2026
        let line = LLMClock.contextLine(now: fixed, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertTrue(line.contains("2026"))
        XCTAssertTrue(line.contains("Current date and time"))
    }

    func testStripHTMLDecodesNumericEntities() {
        XCTAssertEqual(
            WebSearchService.stripHTML("It&#8217;s Apple&#x2019;s year").trimmingCharacters(in: .whitespaces),
            "It’s Apple’s year"
        )
    }

    func testIPv6PrefixChecksDoNotBlockRealDomains() {
        // Regression: "fc"/"fd" IPv6 prefixes must only apply to IPv6 literals,
        // not domains that happen to start with those letters.
        XCTAssertTrue(WebSearchService.isSafeRemoteURL(URL(string: "https://facebook.com")!))
        XCTAssertTrue(WebSearchService.isSafeRemoteURL(URL(string: "https://fda.gov")!))
        XCTAssertTrue(WebSearchService.isSafeRemoteURL(URL(string: "https://fedex.com")!))
    }

    func testSameProfileSharesHistoryAndChatStoresAcrossSessions() {
        // Regression: two windows on the same profile must write through one
        // HistoryManager/ChatStore instance instead of racing on the same files.
        let profileId = UUID()
        let first = ProfileSession(profileId: profileId, dataStore: .nonPersistent())
        let second = ProfileSession(profileId: profileId, dataStore: .nonPersistent())
        let other = ProfileSession(profileId: UUID(), dataStore: .nonPersistent())

        XCTAssertTrue(first.historyManager === second.historyManager)
        XCTAssertTrue(first.chatStore === second.chatStore)
        XCTAssertFalse(first.historyManager === other.historyManager)
    }

    func testCurrencyIsNotMistakenForUnclosedMath() {
        let currency = RichMessageView.parseBlocks("The subscription costs $5 per month.")
        let equation = RichMessageView.parseBlocks("The result is $x + 1$.")

        XCTAssertFalse(currency.contains(where: \.containsMath))
        XCTAssertTrue(equation.contains(where: \.containsMath))
    }

    func testQueryClassifierKeepsNavigationAndChatDistinct() {
        XCTAssertEqual(QueryClassifier.classify("github"), .search)
        XCTAssertEqual(QueryClassifier.classify("help me outline a paper"), .ai)
    }
}

@MainActor
final class ProfileTests: XCTestCase {
    func testSwipeNeighborWrapsAround() {
        let manager = ProfileManager.shared
        let ids = manager.profiles.map(\.id)
        guard ids.count > 1 else { return }
        XCTAssertEqual(manager.neighbor(of: ids[0], offset: 1)?.id, ids[1])
        XCTAssertEqual(manager.neighbor(of: ids[0], offset: -1)?.id, ids.last)
        XCTAssertEqual(manager.neighbor(of: ids.last!, offset: 1)?.id, ids[0])
    }

    func testOldProfilesDecodeWithoutIcon() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Work","colorId":"indigo","isDefault":false}"#
        let profile = try JSONDecoder().decode(BrowserProfile.self, from: Data(json.utf8))
        XCTAssertNil(profile.iconName)
        XCTAssertEqual(profile.profileColor.id, "indigo")
    }
}
