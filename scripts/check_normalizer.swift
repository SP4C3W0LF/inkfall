import Foundation

@main
enum NormalizerCheck {
    static func main() {
        let normalizer = TranscriptNormalizer()

        let filler = normalizer.normalize("um send this to jordan you know tomorrow", vocabulary: ["Jordan"])
        expect("fillers", normalizer.finalize(filler), "Send this to Jordan tomorrow.")

        let scratch = normalizer.normalize("send this to alex scratch that send this to sam", vocabulary: [])
        expect("scratch that", normalizer.finalize(scratch), "Send this to sam.")

        let actually = normalizer.normalize("meet at five actually meet at six", vocabulary: [])
        expect("actually", normalizer.finalize(actually), "Meet at six.")

        let formatting = normalizer.normalize("summary new paragraph bullet list first item next bullet second item", vocabulary: [])
        expect("formatting", normalizer.finalize(formatting), "Summary\n\n- First item\n- Second item")

        print("Normalizer checks passed")
    }

    private static func expect(_ name: String, _ actual: String, _ expected: String) {
        guard actual == expected else {
            fputs("FAIL \(name)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
            exit(1)
        }
    }
}
