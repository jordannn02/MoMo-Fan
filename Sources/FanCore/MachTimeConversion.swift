/// Converts Mach timebase ticks without losing integer precision or overflowing
/// an intermediate multiplication. Invalid or unrepresentable values stay absent.
public enum MachTimeConversion {
    public static func nanoseconds(ticks: UInt64, numerator: UInt32, denominator: UInt32) -> UInt64? {
        guard numerator > 0, denominator > 0 else { return nil }
        let product = ticks.multipliedFullWidth(by: UInt64(numerator))
        let divisor = UInt64(denominator)
        // dividingFullWidth traps when its quotient cannot fit in UInt64.
        guard product.high < divisor else { return nil }
        return divisor.dividingFullWidth(product).quotient
    }
}
