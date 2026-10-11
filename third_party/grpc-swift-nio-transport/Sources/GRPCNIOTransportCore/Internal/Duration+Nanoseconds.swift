/*
 * Local Board compatibility patch for swiftlang/swift#81771.
 *
 * Swift 6.3.2 can emit out-of-order task-local deallocation for the generic
 * duration-based Task.sleep overload. The older nanosecond overload avoids
 * that compiler/runtime path. Remove this extension and return to upstream
 * once the compiler fix is available in Board's release toolchain.
 */

@available(gRPCSwiftNIOTransport 2.0, *)
extension Duration {
  var grpcNanoseconds: UInt64 {
    let components = self.components
    guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }

    let seconds = UInt64(components.seconds)
    let fractional = UInt64(components.attoseconds) / 1_000_000_000
    let (whole, multipliedOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let (total, additionOverflow) = whole.addingReportingOverflow(fractional)
    return multipliedOverflow || additionOverflow ? .max : total
  }
}
