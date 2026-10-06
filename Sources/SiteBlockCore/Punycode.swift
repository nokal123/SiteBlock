import Foundation

/// Converts a single Unicode domain label into the ASCII "xn--" form defined by RFC 3492, so international names can travel through systems that only understand ASCII.
public enum Punycode {
    // The fixed parameters from RFC 3492 section 5.
    private static let base: UInt32 = 36
    private static let tMin: UInt32 = 1
    private static let tMax: UInt32 = 26
    private static let skew: UInt32 = 38
    private static let damp: UInt32 = 700
    private static let initialBias: UInt32 = 72
    private static let initialN: UInt32 = 128

    /// Recomputes the bias after each encoded value; the bias controls how many digits the next value needs, which keeps typical output short.
    private static func adapt(delta: UInt32, numPoints: UInt32, firstTime: Bool) -> UInt32 {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k: UInt32 = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }

    /// Turns a digit value 0-35 into its output character: 0-25 become a-z and 26-35 become 0-9.
    private static func encodeDigit(_ digit: UInt32) -> Character {
        let code = digit < 26 ? 97 + digit : 22 + digit
        return Character(Unicode.Scalar(UInt8(code)))
    }

    /// Encodes one label (already lowercased by the caller) and returns it without the "xn--" prefix, or nil when the arithmetic would overflow.
    public static func encode(_ label: String) -> String? {
        let input = label.unicodeScalars.map { $0.value }
        var output = ""
        // Plain ASCII characters are copied through first, in their original order.
        for value in input where value < 0x80 { output.unicodeScalars.append(Unicode.Scalar(UInt8(value))) }
        let basicCount = UInt32(output.unicodeScalars.count)
        var handled = basicCount
        // The delimiter only appears when there is at least one plain character to separate from the encoded part.
        if basicCount > 0 { output.append("-") }
        var n = initialN
        var delta: UInt32 = 0
        var bias = initialBias
        let total = UInt32(input.count)
        while handled < total {
            // The next code point to encode is the smallest one at or above n; one always exists while handled < total.
            guard let m = input.filter({ $0 >= n }).min() else { return nil }
            let (step, stepOverflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            if stepOverflow { return nil }
            let (grown, growOverflow) = delta.addingReportingOverflow(step)
            if growOverflow { return nil }
            delta = grown
            n = m
            for value in input {
                if value < n {
                    let (bumped, bumpOverflow) = delta.addingReportingOverflow(1)
                    if bumpOverflow { return nil }
                    delta = bumped
                }
                if value == n {
                    // Write delta as a variable-length number whose digit thresholds depend on the current bias.
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(encodeDigit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(encodeDigit(q))
                    bias = adapt(delta: delta, numPoints: handled + 1, firstTime: handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            let (nextDelta, nextOverflow) = delta.addingReportingOverflow(1)
            if nextOverflow { return nil }
            delta = nextDelta
            n += 1
        }
        return output
    }

    /// Returns the label unchanged when it is pure ASCII, otherwise "xn--" followed by the encoded form, or nil when encoding overflows.
    public static func toASCII(label: String) -> String? {
        if label.unicodeScalars.allSatisfy({ $0.isASCII }) { return label }
        guard let encoded = encode(label) else { return nil }
        return "xn--" + encoded
    }
}
