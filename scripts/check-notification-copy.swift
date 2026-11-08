import Foundation

@main
struct NotificationCopyChecks {
    struct Fixture: Decodable {
        let kind: String
        let title: String
        let expected: String
    }

    static func main() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/notification-copy.json")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            let headline = NotificationCopy.headline(kind: fixture.kind, title: fixture.title)
            precondition(headline == fixture.expected, "Incorrect \(fixture.kind) headline: \(headline)")
            precondition(NotificationCopy.headline(kind: fixture.kind, title: headline) == headline,
                         "Formatting an already updated notification changed its wording")
        }
        print("PASS: \(fixtures.count) legacy/current headlines, reply context, names, and unchanged announcement copy")
    }
}
