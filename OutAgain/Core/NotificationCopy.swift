import Foundation

/// Also applied by notify-activity so cached rows and pushes use the same copy.
enum NotificationCopy {
    static func headline(kind: String, title: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == "nightRecap" { return "Last night's photos" }

        let replacements: [(String, String)]
        switch kind {
        case "comment":
            replacements = [
                (" commented on your post", " left a comment on your post!"),
                (" replied to your comment", " replied to your comment!")
            ]
        case "photoReply":
            replacements = [
                (" commented on your post", " left a photo on your post!"),
                (" replied to your comment", " replied to your comment with a photo!")
            ]
        case "friendRequest":
            replacements = [(" sent you a friend request", " sent you a friend request!")]
        case "friendAccepted":
            replacements = [(" accepted your friend request", " accepted your friend request!")]
        case "commentTagged":
            replacements = [(" mentioned you in a comment", " mentioned you in a comment!")]
        default:
            return title
        }

        var sentence = title
        while let last = sentence.last, last == "." || last == "!" {
            sentence.removeLast()
        }
        for (oldEnding, newEnding) in replacements where sentence.hasSuffix(oldEnding) {
            return String(sentence.dropLast(oldEnding.count)) + newEnding
        }
        return title
    }
}
