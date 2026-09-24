import Foundation

/// The shipping app's bundle identity. Dev, tests, and previews derive their own identity from
/// `Bundle.main`, so only the release value is fixed here.
enum OPNProductIdentity {
    static let releaseBundleIdentifier = "io.github.opencloudgaming.opennow"
}
