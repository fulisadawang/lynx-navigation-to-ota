import Foundation

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

@main
struct LynxTabLoadGenerationTests {
    static func main() {
        var generations = LynxTabLoadGeneration()
        let first = generations.begin()
        guard generations.accepts(first) else { fail("first generation should be current") }

        let second = generations.begin()
        guard !generations.accepts(first) else { fail("new load must invalidate old generation") }
        guard generations.accepts(second) else { fail("second generation should be current") }

        generations.invalidate()
        guard !generations.accepts(second) else { fail("refresh must invalidate the in-flight generation") }
        print("LynxTabLoadGenerationTests PASS")
    }
}
