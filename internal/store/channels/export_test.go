package channels

// SetRetention lowers the retention bounds for a test and returns the restore.
func SetRetention(retain, compact int) func() {
	oldRetain, oldCompact := retainMessages, compactLines
	retainMessages, compactLines = retain, compact
	return func() { retainMessages, compactLines = oldRetain, oldCompact }
}
