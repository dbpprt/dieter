import AppKit

extension NSView {
    /// The first non-nil `transform` result among the subviews, in order.
    ///
    /// Recursive searches use this instead of `subviews.lazy.compactMap { … }.first`:
    /// on an array that lazy chain is a collection whose `first` evaluates the
    /// matching subview twice, so a recursive search doubles its work at every
    /// level and grows exponentially with view depth.
    func firstSubviewResult<T>(_ transform: (NSView) -> T?) -> T? {
        for subview in subviews {
            if let result = transform(subview) { return result }
        }
        return nil
    }
}
