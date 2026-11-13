import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

/// 学習した語があるときの、打ち間違いの直しの候補の値を書き出す(/tmp/jizai-rank-learn.txt)。
final class JizaiRankLearn: XCTestCase {
    static func out(_ line: String) {
        let url = URL(fileURLWithPath: "/tmp/jizai-rank-learn.txt")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }
    static let dir: URL = {
        let d = URL(fileURLWithPath: "/tmp/jizai-rank-learn-mem", isDirectory: true)
        try? FileManager.default.removeItem(at: d)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    func options() -> ConvertRequestOptions {
        .withDefaultDictionary(needTypoCorrection: true, requireJapanesePrediction: true, requireEnglishPrediction: false,
                               keyboardLanguage: .ja_JP, learningType: .inputAndOutput, shouldResetMemory: false,
                               memoryDirectoryURL: Self.dir, sharedContainerURL: Self.dir, metadata: nil)
    }

    @MainActor func type(_ conv: KanaKanjiConverter, _ input: String) -> (ComposingText, [Candidate]) {
        conv.stopComposition()
        var c = ComposingText()
        var r: [Candidate] = []
        for ch in input {
            c.insertAtCursorPosition(String(ch), inputStyle: .direct)
            r = conv.requestCandidates(c, options: options()).mainResults
        }
        return (c, r)
    }

    @MainActor func dump(_ conv: KanaKanjiConverter, _ input: String) {
        let (c, r) = type(conv, input)
        let reading = c.convertTarget
        Self.out("=== \(input)")
        for (i, x) in r.prefix(14).enumerated() {
            var rest = c
            rest.prefixComplete(composingCount: x.composingCount)
            let used = reading.count - rest.convertTarget.count
            Self.out(String(format: "  %2d %7.2f used %d rc %d %@ [%@] words %d learned %@", i, x.value, used, x.rubyCount, x.text, x.data.map(\.ruby).joined(), x.data.count, x.data.map { $0.metadata.contains(.isLearned) ? "L" : "-" }.joined()))
        }
    }

    @MainActor func learn(_ conv: KanaKanjiConverter, _ input: String, _ text: String) {
        let (_, r) = type(conv, input)
        if let c = r.first(where: { $0.text == text }) {
            conv.setCompletedData(c)
            conv.updateLearningData(c)
            Self.out("learned \(text) data \(c.data.map(\.word))")
        } else { Self.out("not found \(text): \(r.prefix(8).map(\.text))") }
    }

    @MainActor func testLearn() {
        TypoCorrectionTable.direct = JizaiTypoTests.flickTable(dir: 7, neighbor: 8)
        TypoCorrectionTable.roman2Kana = JizaiTypoTests.romanTable(row: 7, diag: 8)
        TypoCorrectionTable.maxPenalty = 8
        var conv = KanaKanjiConverter()
        dump(conv, "うちまちがい")
        for _ in 0..<3 { learn(conv, "いいまちがい", "言い間違い") }
        for _ in 0..<3 { learn(conv, "ありがとう", "ありがとう") }
        learn(conv, "うちまちがいの", "内間違いの")
        conv.sendToDicdataStore(.closeKeyboard)
        conv = KanaKanjiConverter()
        dump(conv, "うちまちがい")
        dump(conv, "いいまちがい")
        dump(conv, "あるがとう")
        dump(conv, "ありがとう")
    }
}
