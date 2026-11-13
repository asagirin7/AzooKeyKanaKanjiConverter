import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

/// 打ち間違いの直しを入れて 1 字ずつ打ったときも、まとめて変換したときと同じ候補が出ること。
/// (1 字ずつのときに入力の位置 0 から始まる語が文頭として扱われず、「にとべるように」で「に飛べるように」が出なかった)
final class JizaiGradualTypoTests: XCTestCase {
    func options() -> ConvertRequestOptions {
        .withDefaultDictionary(needTypoCorrection: true, requireJapanesePrediction: true, requireEnglishPrediction: false,
                               keyboardLanguage: .ja_JP, learningType: .nothing, maxMemoryCount: 0, shouldResetMemory: false,
                               memoryDirectoryURL: URL(fileURLWithPath: ""), sharedContainerURL: URL(fileURLWithPath: ""), metadata: nil)
    }

    @MainActor func texts(_ input: String, gradual: Bool) -> [String] {
        let converter = KanaKanjiConverter()
        var c = ComposingText()
        var r: [Candidate] = []
        for ch in input {
            c.insertAtCursorPosition(String(ch), inputStyle: .direct)
            if gradual { r = converter.requestCandidates(c, options: options()).mainResults }
        }
        if !gradual { r = converter.requestCandidates(c, options: options()).mainResults }
        return r.filter { $0.rubyCount == c.convertTarget.count }.map(\.text)
    }

    @MainActor func testGradualMatchesFull() {
        TypoCorrectionTable.direct = JizaiTypoTests.flickTable(dir: 7, neighbor: 8)
        TypoCorrectionTable.maxPenalty = 8
        for input in ["にとべるように", "にとべるよ", "はとべるように"] {
            let gradual = texts(input, gradual: true)
            XCTAssertEqual(gradual.prefix(5), texts(input, gradual: false).prefix(5), input)
        }
        XCTAssertTrue(texts("にとべるように", gradual: true).prefix(5).contains("に飛べるように"))
    }
}
