import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

/// 長い読みを 1 字ずつ打ち足しても、1 打ごとに辞書で引く読みの数が跳ねないこと。
/// (打ち間違いの直しが 1 か所のつもりで 2 か所まで広がり、ローマ字の 1 打で約 6000 通りを引いて 1 打 0.5 秒以上かかっていた)
final class JizaiLongInputTests: XCTestCase {
    func options() -> ConvertRequestOptions {
        .withDefaultDictionary(needTypoCorrection: true, requireJapanesePrediction: true, requireEnglishPrediction: false,
                               keyboardLanguage: .ja_JP, learningType: .nothing, maxMemoryCount: 0, shouldResetMemory: false,
                               memoryDirectoryURL: URL(fileURLWithPath: ""), sharedContainerURL: URL(fileURLWithPath: ""), metadata: nil)
    }

    @MainActor func check(_ input: String, style: InputStyle, maxPerKey: Int) -> (max: Int, worstMs: Double) {
        let converter = KanaKanjiConverter()
        var c = ComposingText()
        var worst = 0
        var worstMs = 0.0
        for ch in input {
            c.insertAtCursorPosition(String(ch), inputStyle: style)
            TypoCorrectionGenerator.generatedCount = 0
            let t0 = Date()
            _ = converter.requestCandidates(c, options: options())
            worstMs = max(worstMs, Date().timeIntervalSince(t0) * 1000)
            worst = max(worst, TypoCorrectionGenerator.generatedCount)
        }
        XCTAssertLessThanOrEqual(worst, maxPerKey, "\(style) \(c.convertTarget.count) 字")
        return (worst, worstMs)
    }

    @MainActor func testLongInputStaysFlat() {
        TypoCorrectionTable.direct = JizaiTypoTests.flickTable(dir: 7, neighbor: 8)
        TypoCorrectionTable.roman2Kana = JizaiTypoTests.romanTable(row: 7, diag: 8)
        TypoCorrectionTable.maxPenalty = 8
        let roman = check("kyouhatotemoiitenkidesunesanposhitaikimochininarimasuyonetomodachitoissyonikouennniikimasenka", style: .roman2kana, maxPerKey: 1500)
        let flick = check("きょうはとてもいいてんきですねさんぽしたいきもちになりますよねともだちといっしょにこうえんにいきませんか", style: .direct, maxPerKey: 1500)
        print("JizaiLongInput roman max \(roman.max) (\(Int(roman.worstMs)) ms) / flick max \(flick.max) (\(Int(flick.worstMs)) ms)")
    }
}
