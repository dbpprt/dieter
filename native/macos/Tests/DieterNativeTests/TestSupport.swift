import Testing

/// Records a failed check at the caller's source location. Unlike `#expect`,
/// the condition is evaluated as a plain `Bool`, so it may call mutating members
/// (the capture state machines advance as they answer).
func check(
    _ condition: Bool, _ comment: @autoclosure () -> Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(condition, comment(), sourceLocation: sourceLocation)
}
