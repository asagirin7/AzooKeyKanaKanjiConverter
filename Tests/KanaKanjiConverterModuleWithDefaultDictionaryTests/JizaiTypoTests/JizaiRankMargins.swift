import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

/// 打ち間違いの直しの候補を前に出す差(margin)ごとに、正しく打った語の 1 個目が直しの候補になる数と、
/// 打ち間違いの例で欲しい語が何番目に出るかを数える(/tmp/jizai-rank-margins.txt)。
final class JizaiRankMargins: XCTestCase {
    struct Item { var text: String; var ruby: String; var value: PValue; var used: Int; var rubyCount: Int }

    static func out(_ line: String) {
        let url = URL(fileURLWithPath: "/tmp/jizai-rank-margins.txt")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }

    func options() -> ConvertRequestOptions {
        .withDefaultDictionary(needTypoCorrection: true, requireJapanesePrediction: true, requireEnglishPrediction: false,
                               keyboardLanguage: .ja_JP, learningType: .nothing, maxMemoryCount: 0, shouldResetMemory: false,
                               memoryDirectoryURL: URL(fileURLWithPath: ""), sharedContainerURL: URL(fileURLWithPath: ""), metadata: nil)
    }

    @MainActor func convert(_ input: String) -> (items: [Item], reading: String) {
        let roman = input.unicodeScalars.allSatisfy { $0.isASCII }
        let converter = KanaKanjiConverter()
        var c = ComposingText()
        var r: [Candidate] = []
        for ch in input {
            c.insertAtCursorPosition(String(ch), inputStyle: roman ? .roman2kana : .direct)
            r = converter.requestCandidates(c, options: options()).mainResults
        }
        let reading = c.convertTarget
        let items = r.prefix(40).map { x -> Item in
            var rest = c
            rest.prefixComplete(composingCount: x.composingCount)
            return Item(text: x.text, ruby: x.data.map(\.ruby).joined(), value: x.value,
                        used: reading.count - rest.convertTarget.count, rubyCount: x.rubyCount)
        }
        return (items, reading)
    }

    /// 旧: 1 個目だけ、直しの候補が打ったとおりの候補より margin 良ければ直しの候補。
    static func oldOrder(_ raw: [Item], reading: String, margin: PValue) -> [Item] {
        let full = reading.count
        let typed = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
        var raw = raw
        let e = raw.firstIndex { $0.used == full && $0.rubyCount == full && $0.ruby == typed }
        let t = raw.firstIndex { $0.used == full && $0.rubyCount == full && $0.ruby != typed }
        let head: Int?
        switch (e, t) {
        case let (e?, t?): head = raw[t].value > raw[e].value + margin ? t : e
        default: head = e ?? t
        }
        if let i = head, i > 0 { raw.insert(raw.remove(at: i), at: 0) }
        return raw
    }

    /// 新: 打ったとおりの候補(全部を変換)の azooKey での一番と比べ、直しの候補はその読みの一番が margin より良いときだけ
    /// 元の位置に残す。ほかの直しの候補は、打ったとおりの候補(読みの先まで補った予測・読みの頭だけの候補を含む)を after 個置いた後ろへ回す。
    nonisolated(unsafe) static var after = 2
    static func newOrder(_ raw: [Item], reading: String, margin: PValue) -> [Item] {
        let full = reading.count
        let typed = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
        func isTypo(_ x: Item) -> Bool { !x.ruby.hasPrefix(String(typed.prefix(x.used))) }
        guard let e = raw.first(where: { $0.used == full && $0.rubyCount == full && $0.ruby == typed }) else {
            return oldOrder(raw, reading: reading, margin: margin)
        }
        var strong = Set<String>()
        for x in raw where isTypo(x) && x.used == full && x.rubyCount == full && x.value > e.value + margin { strong.insert(x.ruby) }
        func weak(_ x: Item) -> Bool { isTypo(x) && !strong.contains(String(x.ruby.prefix(full))) }
        // 弱い直しの候補は、打ったとおりの候補が after 個出るまで後ろへ送る(前へは出さない)。
        var o: [Item] = [], held: [Item] = [], count = 0
        for x in oldOrder(raw, reading: reading, margin: margin) {
            if weak(x) && count < after { held.append(x); continue }
            o.append(x)
            if !isTypo(x) { count += 1; if count == after { o += held; held = [] } }
        }
        o += held
        return o
    }

    @MainActor func testMargins() {
        TypoCorrectionTable.direct = JizaiTypoTests.flickTable(dir: 7, neighbor: 8)
        TypoCorrectionTable.roman2Kana = JizaiTypoTests.romanTable(row: 7, diag: 8)
        TypoCorrectionTable.maxPenalty = 8
        func lines(_ path: String) -> [String] {
            ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        let correct = lines("/tmp/jizai-rank-cases.txt").map { (input: $0, r: convert($0)) }
        let typos = lines("/tmp/jizai-rank-typo.txt").map { l -> (input: String, want: String, r: (items: [Item], reading: String)) in
            let p = l.split(separator: " ").map(String.init); return (p[0], p[1], convert(p[0]))
        }
        let typedOf: (String) -> String = { $0.applyingTransform(.hiraganaToKatakana, reverse: false) ?? $0 }
        for (name, order, afters) in [("old", Self.oldOrder, [0]), ("new", Self.newOrder, [2, 3, 4, 5])] {
            for a in afters { Self.after = a
            for m: PValue in (name == "old" ? [3] : [6, 7, 8]) {
                var headTypo: [String] = [], top3Typo = 0
                for x in correct {
                    let o = order(x.r.items, x.r.reading, m)
                    let t = typedOf(x.r.reading)
                    if let h = o.first, !h.ruby.hasPrefix(String(t.prefix(h.used))) { headTypo.append("\(x.input)→\(h.text)") }
                    top3Typo += o.prefix(5).filter { !$0.ruby.hasPrefix(String(t.prefix($0.used))) }.count
                }
                var hit1 = 0, hit5 = 0, miss: [String] = []
                for x in typos {
                    let o = order(x.r.items, x.r.reading, m).map(\.text)
                    var seen = Set<String>(); let texts = o.filter { seen.insert($0).inserted }
                    let rank = texts.firstIndex(of: x.want)
                    if rank == 0 { hit1 += 1 }
                    if let rank, rank < 5 { hit5 += 1 } else { miss.append("\(x.input)[\(texts.prefix(5).joined(separator: " "))]") }
                    if rank != 0 && rank != nil && m == 10 { }
                }
                Self.out("\(name) after=\(a) m=\(m): 正しく打った \(correct.count) 語のうち 1 個目が直し \(headTypo.count)、上 5 つの直し計 \(top3Typo) / 打ち間違い \(typos.count) 例で 1 位 \(hit1)・5 位以内 \(hit5)")
                Self.out("   1個目が直し: \(headTypo.joined(separator: ", "))")
                Self.out("   5位外: \(miss.joined(separator: " / "))")
            }
            }
        }
        Self.after = 3
        for x in correct.prefix(30) {
            Self.out("  \(x.input) 旧: " + Self.oldOrder(x.r.items, reading: x.r.reading, margin: 3).prefix(5).map(\.text).joined(separator: " ") + "  新: " + Self.newOrder(x.r.items, reading: x.r.reading, margin: 8).prefix(5).map(\.text).joined(separator: " "))
        }
        for x in typos {
            Self.out("  \(x.input)→\(x.want): " + Self.newOrder(x.r.items, reading: x.r.reading, margin: 8).prefix(5).map { "\($0.text)(\(String(format: "%.1f", $0.value)))" }.joined(separator: " "))
        }
    }
}
