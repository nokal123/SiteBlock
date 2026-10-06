import Foundation
import Testing
import SiteBlockCore

// Expected values come from RFC 3492 § 7.1 (the sample strings), cross-checked against Python's punycode codec, and from
// the examples in 05-testing-and-operations.md § Unit Tests (PunycodeTests). Input strings are written as scalar escapes
// so that no editor can silently normalize them.

// The RFC 3492 § 7.1 samples whose basic (ASCII) characters are all lowercase or absent: (name, unicode label, encoded label).
private let lowercaseRFCSamples: [(String, String, String)] = [
    ("A Arabic (Egyptian)", "\u{644}\u{64A}\u{647}\u{645}\u{627}\u{628}\u{62A}\u{643}\u{644}\u{645}\u{648}\u{634}\u{639}\u{631}\u{628}\u{64A}\u{61F}", "egbpdaj6bu4bxfgehfvwxn"),
    ("B Chinese (simplified)", "\u{4ED6}\u{4EEC}\u{4E3A}\u{4EC0}\u{4E48}\u{4E0D}\u{8BF4}\u{4E2D}\u{6587}", "ihqwcrb4cv8a8dqg056pqjye"),
    ("C Chinese (traditional)", "\u{4ED6}\u{5011}\u{7232}\u{4EC0}\u{9EBD}\u{4E0D}\u{8AAA}\u{4E2D}\u{6587}", "ihqwctvzc91f659drss3x8bo0yb"),
    ("E Hebrew", "\u{5DC}\u{5DE}\u{5D4}\u{5D4}\u{5DD}\u{5E4}\u{5E9}\u{5D5}\u{5D8}\u{5DC}\u{5D0}\u{5DE}\u{5D3}\u{5D1}\u{5E8}\u{5D9}\u{5DD}\u{5E2}\u{5D1}\u{5E8}\u{5D9}\u{5EA}", "4dbcagdahymbxekheh6e0a7fei0b"),
    ("F Hindi (Devanagari)", "\u{92F}\u{939}\u{932}\u{94B}\u{917}\u{939}\u{93F}\u{928}\u{94D}\u{926}\u{940}\u{915}\u{94D}\u{92F}\u{94B}\u{902}\u{928}\u{939}\u{940}\u{902}\u{92C}\u{94B}\u{932}\u{938}\u{915}\u{924}\u{947}\u{939}\u{948}\u{902}", "i1baa7eci9glrd9b2ae1bj0hfcgg6iyaf8o0a1dig0cd"),
    ("G Japanese (kanji and hiragana)", "\u{306A}\u{305C}\u{307F}\u{3093}\u{306A}\u{65E5}\u{672C}\u{8A9E}\u{3092}\u{8A71}\u{3057}\u{3066}\u{304F}\u{308C}\u{306A}\u{3044}\u{306E}\u{304B}", "n8jok5ay5dzabd5bym9f0cm5685rrjetr6pdxa"),
    ("H Korean (Hangul syllables)", "\u{C138}\u{ACC4}\u{C758}\u{BAA8}\u{B4E0}\u{C0AC}\u{B78C}\u{B4E4}\u{C774}\u{D55C}\u{AD6D}\u{C5B4}\u{B97C}\u{C774}\u{D574}\u{D55C}\u{B2E4}\u{BA74}\u{C5BC}\u{B9C8}\u{B098}\u{C88B}\u{C744}\u{AE4C}", "989aomsvi5e83db1d2a355cv1e0vak1dwrv93d5xbh15a0dt30a5jpsd879ccm6fea98c"),
    ("I Russian (Cyrillic)", "\u{43F}\u{43E}\u{447}\u{435}\u{43C}\u{443}\u{436}\u{435}\u{43E}\u{43D}\u{438}\u{43D}\u{435}\u{433}\u{43E}\u{432}\u{43E}\u{440}\u{44F}\u{442}\u{43F}\u{43E}\u{440}\u{443}\u{441}\u{441}\u{43A}\u{438}", "b1abfaaepdrnnbgefbadotcwatmq2g4l"),
    ("O hitotsu yane no shita 2", "\u{3072}\u{3068}\u{3064}\u{5C4B}\u{6839}\u{306E}\u{4E0B}2", "2-u9tlzr9756bt3uc0v"),
    ("Q pafii de runba", "\u{30D1}\u{30D5}\u{30A3}\u{30FC}de\u{30EB}\u{30F3}\u{30D0}", "de-jg4avhby1noc0d"),
    ("R sono supiido de", "\u{305D}\u{306E}\u{30B9}\u{30D4}\u{30FC}\u{30C9}\u{3067}", "d9juau41awczczp"),
]

// The RFC 3492 § 7.1 samples that contain uppercase ASCII letters. RFC 3492 copies basic code points unchanged, so the
// uppercase letters must survive in the output.
private let mixedCaseRFCSamples: [(String, String, String)] = [
    ("D Czech", "Pro\u{10D}prost\u{11B}nemluv\u{ED}\u{10D}esky", "Proprostnemluvesky-uyb24dma41a"),
    ("J Spanish", "Porqu\u{E9}nopuedensimplementehablarenEspa\u{F1}ol", "PorqunopuedensimplementehablarenEspaol-fmd56a"),
    ("K Vietnamese", "T\u{1EA1}isaoh\u{1ECD}kh\u{F4}ngth\u{1EC3}ch\u{1EC9}n\u{F3}iti\u{1EBF}ngVi\u{1EC7}t", "TisaohkhngthchnitingVit-kjcr8268qyxafd2f1b9g"),
    ("L 3nen B gumi kinpachi sensei", "3\u{5E74}B\u{7D44}\u{91D1}\u{516B}\u{5148}\u{751F}", "3B-ww4c5e180e575a65lsy2b"),
    ("M amuro namie with SUPER MONKEYS", "\u{5B89}\u{5BA4}\u{5948}\u{7F8E}\u{6075}-with-SUPER-MONKEYS", "-with-SUPER-MONKEYS-pc58ag80a8qai00g7n9n"),
    ("N Hello Another Way", "Hello-Another-Way-\u{305D}\u{308C}\u{305E}\u{308C}\u{306E}\u{5834}\u{6240}", "Hello-Another-Way--fc4qua05auwb3674vfr0b"),
    ("P Maji de Koi suru 5 byou mae", "Maji\u{3067}Koi\u{3059}\u{308B}5\u{79D2}\u{524D}", "MajiKoi5-783gue6qz075azm5e"),
]

@Suite struct PunycodeTests {
    @Test(arguments: lowercaseRFCSamples)
    func encodeMatchesRFC3492SampleStrings(name: String, unicode: String, encoded: String) {
        #expect(Punycode.encode(unicode) == encoded, "RFC 3492 § 7.1 sample \(name)")
    }

    @Test(arguments: mixedCaseRFCSamples)
    func encodeKeepsUppercaseBasicCharactersLikeRFC3492(name: String, unicode: String, encoded: String) {
        #expect(Punycode.encode(unicode) == encoded, "RFC 3492 § 7.1 sample \(name)")
    }

    @Test(arguments: lowercaseRFCSamples)
    func toASCIIAddsTheXnPrefixToRFC3492SampleStrings(name: String, unicode: String, encoded: String) {
        #expect(Punycode.toASCII(label: unicode) == "xn--" + encoded, "RFC 3492 § 7.1 sample \(name)")
    }

    // Examples named in 05-testing-and-operations.md § Unit Tests.
    @Test func encodeMatchesTheDesignExamples() {
        #expect(Punycode.encode("bücher") == "bcher-kva")
        #expect(Punycode.encode("münchen") == "mnchen-3ya")
    }

    // A label made only of non-ASCII characters has no basic characters, so there is no "-" delimiter.
    @Test(arguments: [("ü", "tda"), ("ñ", "ida"), ("é", "9ca"), ("日本語", "wgv71a119e"), ("😀", "e28h"), ("рф", "p1ai"), ("中国", "fiqs8s")])
    func encodeMatchesIndependentCodecForSmallLabels(label: String, expected: String) {
        #expect(Punycode.encode(label) == expected)
    }

    // Two-scalar labels chosen by search so that the first delta falls where the bias-adaptation constants matter (a
    // changed "damp" value of 701 instead of 700 gives different output for each). Expected values are from Python's codec.
    @Test(arguments: [("\u{191F}\u{4E00}", "dffz37v"), ("\u{191F}\u{20AC}", "dff136a"), ("\u{1BDD}\u{4E00}", "fzf015s"), ("\u{1BDD}\u{20AC}", "fzf07r"), ("\u{1E9B}\u{4E00}", "hkg887p")])
    func encodeMatchesIndependentCodecWhereTheBiasAdaptationConstantsMatter(label: String, expected: String) {
        #expect(Punycode.encode(label) == expected)
    }

    @Test func toASCIIConvertsLabelsToTheXnForm() {
        #expect(Punycode.toASCII(label: "bücher") == "xn--bcher-kva")
        #expect(Punycode.toASCII(label: "münchen") == "xn--mnchen-3ya")
        #expect(Punycode.toASCII(label: "😀") == "xn--e28h")
    }

    // The design says an all-ASCII label comes back unchanged. That includes empty, uppercase (the caller lowercases),
    // digits, hyphens, and a label that is already in xn-- form (it must not be encoded a second time).
    @Test(arguments: ["", "example", "Example", "EXAMPLE", "a-b", "123", "a1-2b", "xn--bcher-kva", "xn--", "-", "a"])
    func toASCIIReturnsAllASCIILabelsUnchanged(label: String) {
        #expect(Punycode.toASCII(label: label) == label)
    }

    @Test func encodeOfEmptyLabelIsEmpty() {
        #expect(Punycode.encode("") == "")
    }

    // A label of one repeated non-ASCII scalar: the first scalar costs "tda" and each repeat costs exactly one "a"
    // (hand-derived from RFC 3492 § 6.3 with bias adapted down to 0; confirmed against Python's codec).
    @Test func encodeOfRepeatedScalarGrowsByOneCharacterPerRepeat() {
        let label = String(repeating: "ü", count: 60)
        #expect(Punycode.encode(label) == "tda" + String(repeating: "a", count: 59))
    }

    // Combining marks are separate Unicode scalars and must be encoded as such, not as one grapheme cluster. Sample F
    // (Hindi) is full of them; this checks the smallest case: "e" followed by U+0301 is two scalars.
    @Test func encodeTreatsCombiningMarksAsSeparateScalars() {
        #expect(Punycode.encode("e\u{301}") == "e-xbb")
        #expect(Punycode.encode("\u{E9}") == "9ca")
    }

    // The label is passed in already lowercased by the caller, so encode must not fold case itself: "BÜCHER" keeps its
    // uppercase basic characters (RFC 3492 copies them unchanged).
    @Test func encodeDoesNotChangeTheCaseOfBasicCharacters() {
        #expect(Punycode.encode("B\u{DC}CHER") == "BCHER-2pa")
    }

    // Edge: a scalar at the top of the Unicode range.
    @Test func encodeHandlesTheHighestScalar() {
        #expect(Punycode.encode("\u{10FFFF}") == "dn32g")
    }

    // The normalizer feeds user text to this function before it checks any length, so an enormous label must come back as
    // a value or as nil (the design says nil on overflow), never trap the process.
    @Test func encodeSurvivesALabelBuiltToOverflow32BitArithmetic() {
        // 6,000 copies of U+0100 followed by U+10FFFF: the RFC's delta counter reaches about 6.6 billion, past 2^32.
        let label = String(repeating: "\u{100}", count: 6000) + "\u{10FFFF}"
        let result = Punycode.encode(label)
        // The design allows nil on overflow; an answer is only acceptable if it is the true encoding. Python's codec (no
        // overflow) gives a 6012-character result starting "xdaaaaaaaaaa" and ending "aa969453597d".
        if let result {
            #expect(result.count == 6012)
            #expect(result.hasPrefix("xdaaaaaaaaaa") && result.hasSuffix("aa969453597d"), "a wrapped-around calculation gives a wrong encoding")
        }
    }
}
