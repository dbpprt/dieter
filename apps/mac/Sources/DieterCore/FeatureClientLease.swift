import Foundation

/// A feature borrows a captured route and returns it without stopping another borrower.
@MainActor package final class FeatureClientLease<Client> {
    package let client: Client
    private var onRelease: (() -> Void)?
    package init(client: Client, release: @escaping () -> Void = {}) { self.client = client; onRelease = release }
    package func release() { let action = onRelease; onRelease = nil; action?() }
}
