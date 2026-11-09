import XCTest
@testable import OutAgain

final class SocialInviteTests: XCTestCase {
    func testInviteLinksAndPastedCodesNormalizeWithoutTrustingOtherHosts() {
        let code = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(SocialInviteCode.normalized(" \(code.uppercased())\n"), code)
        XCTAssertEqual(SocialInviteCode.normalized("https://cristianrebolloso.github.io/invite/?code=\(code)"), code)
        XCTAssertEqual(SocialInviteCode.normalized("outagain://invite?code=\(code)"), code)
        XCTAssertNil(SocialInviteCode.normalized("https://example.com/invite/?code=\(code)"))
        XCTAssertNil(SocialInviteCode.normalized("https://cristianrebolloso.github.io/privacy/?code=\(code)"))
        XCTAssertNil(SocialInviteCode.normalized("outagain://quick-post?code=\(code)"))
        XCTAssertNil(SocialInviteCode.normalized("not-an-invite"))
    }

    func testSearchNormalizesPastedNamesAndHandles() {
        XCTAssertEqual(PeopleSearchRules.normalized(" \n@ALEX_2  "), "alex_2")
        XCTAssertEqual(PeopleSearchRules.normalized("  Alex\t  Morgan \n"), "alex morgan")
        XCTAssertEqual(PeopleSearchRules.normalized("José   García"), "josé garcía")
    }
}
