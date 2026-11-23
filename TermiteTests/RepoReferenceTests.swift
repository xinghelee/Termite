import XCTest
@testable import Termite

final class RepoReferenceTests: XCTestCase {
    private func check(_ raw: String, _ url: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let ref = RepoReference(raw)
        XCTAssertEqual(ref?.url, url, file: file, line: line)
        XCTAssertEqual(ref?.name, name, file: file, line: line)
    }

    func testShorthand() {
        check("xinghelee/Termite", "https://github.com/xinghelee/Termite.git", "Termite")
        check("  owner/repo.git \n", "https://github.com/owner/repo.git", "repo")
    }

    func testGitHubWebLinks() {
        check("https://github.com/owner/repo", "https://github.com/owner/repo.git", "repo")
        check("https://github.com/owner/repo/", "https://github.com/owner/repo.git", "repo")
        check("https://github.com/owner/repo/tree/main/src", "https://github.com/owner/repo.git", "repo")
        check("https://github.com/owner/repo.git", "https://github.com/owner/repo.git", "repo")
        check("github.com/owner/my.repo", "https://github.com/owner/my.repo.git", "my.repo")
    }

    func testPastedCommands() {
        check("git clone https://github.com/owner/repo.git", "https://github.com/owner/repo.git", "repo")
        check("gh repo clone owner/repo", "https://github.com/owner/repo.git", "repo")
    }

    func testOtherGitURLsPassThrough() {
        check("git@github.com:owner/repo.git", "git@github.com:owner/repo.git", "repo")
        check("https://gitlab.com/group/sub/proj.git", "https://gitlab.com/group/sub/proj.git", "proj")
        check("ssh://git@host:2222/a/b", "ssh://git@host:2222/a/b", "b")
    }

    func testRejects() {
        XCTAssertNil(RepoReference(""))
        XCTAssertNil(RepoReference("just-a-word"))
        XCTAssertNil(RepoReference("https://github.com/owner"))
        XCTAssertNil(RepoReference("owner/../etc"))
        XCTAssertNil(RepoReference("/Users/me/repo"))
        XCTAssertNil(RepoReference("a b/c"))
        XCTAssertNil(RepoReference("--upload-pack=touch${IFS}x://h/r"))
        XCTAssertNil(RepoReference("-oProxyCommand=x@host:r"))
        XCTAssertNil(RepoReference("ext::sh${IFS}-c${IFS}x://a/b"))
        XCTAssertNil(RepoReference("file:///etc/repo"))
    }
}
