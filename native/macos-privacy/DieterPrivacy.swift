import Darwin
import Foundation

@main private enum DieterPrivacy {
    static func main() {
        do {
            guard try PrivacyHIDService.handle(Array(CommandLine.arguments.dropFirst())) else {
                throw PrivacyHIDError("Privacy helper requires exactly one internal action")
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
