import Foundation

/// The Mac package's directory (`apps/apple/mac`), from this file's fixed place
/// in `Tests/DieterMacTestSupport`, so tests in any feature folder find the
/// sources they scan and the build directory they write diagnostics to.
package let macPackageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Tests/DieterMacTestSupport
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // apps/apple/mac
