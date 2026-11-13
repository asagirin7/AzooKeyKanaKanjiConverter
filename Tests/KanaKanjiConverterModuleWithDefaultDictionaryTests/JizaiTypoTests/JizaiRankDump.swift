import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

/// 打ち間違いの直しの候補と、打ったとおりの候補の並びと値を書き出す(/tmp/jizai-rank-dump.txt)。
/// 入力は /tmp/jizai-rank-in.txt の各行(かな = フリック、英字 = ローマ字)。
final class JizaiRankDump: XCTestCase {
    static func out(_ line: String) {
        let url = URL(fileURLWithPath: "/tmp/jizai-rank-dump.txt")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }

    func options() -> ConvertRequestOptions {
        .withDefaultDictionary(needTypoCorrection: true, requireJapanesePrediction: true, requireEnglishPrediction: false,
                               keyboardLanguage: .ja_JP, learningType: .nothing, maxMemoryCount: 0, shouldResetMemory: false,
                               memoryDirectoryURL: URL(fileURLWithPath: ""), sharedContainerURL: URL(fileURLWithPath: ""), metadata: nil)
    }

    @MainActor func testDump() {
        TypoCorrectionTable.direct = JizaiTypoTests.flickTable(dir: 7, neighbor: 8)
        TypoCorrectionTable.roman2Kana = JizaiTypoTests.romanTable(row: 7, diag: 8)
        TypoCorrectionTable.maxPenalty = 8
        let text = (try? String(contentsOfFile: "/tmp/jizai-rank-in.txt", encoding: .utf8)) ?? "うちまちがい"
        for line in text.split(separator: "\n") {
            let input = String(line).trimmingCharacters(in: .whitespaces)
            guard !input.isEmpty, !input.hasPrefix("#") else { continue }
            let roman = input.unicodeScalars.allSatisfy { $0.isASCII }
            let converter = KanaKanjiConverter()
            var c = ComposingText()
            var r: [Candidate] = []
            for ch in input {
                c.insertAtCursorPosition(String(ch), inputStyle: roman ? .roman2kana : .direct)
                r = converter.requestCandidates(c, options: options()).mainResults
            }
            let reading = c.convertTarget
            let kata = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
            Self.out("=== \(input) (\(reading))")
            for (i, x) in r.prefix(40).enumerated() {
                var rest = c
                rest.prefixComplete(composingCount: x.composingCount)
                let used = reading.count - rest.convertTarget.count
                let ruby = x.data.map(\.ruby).joined()
                let typedPart = String(kata.prefix(used))
                let mark: String
                if ruby == kata { mark = "EXACT" }
                else if used == reading.count && ruby.hasPrefix(kata) { mark = "pred" }
                else if used < reading.count && ruby == typedPart { mark = "part" }
                else { mark = "TYPO" }
                Self.out(String(format: "  %2d %@ %7.2f used %d rc %d %@ [%@]", i, mark, x.value, used, x.rubyCount, x.text, ruby))
            }
        }
    }
}
