import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

/// Jizai の打ち間違いの表の効き目と速さを測る(表は Jizai の JizaiCore/TypoTables と同じ作り)。
final class JizaiTypoTests: XCTestCase {
    static func out(_ line: String) {
        let url = URL(fileURLWithPath: "/tmp/jizai-typo-report.txt")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }

    static let kanaRows: [[[String]]] = [
        [["あ","い","う","え","お"], ["か","き","く","け","こ"], ["さ","し","す","せ","そ"]],
        [["た","ち","つ","て","と"], ["な","に","ぬ","ね","の"], ["は","ひ","ふ","へ","ほ"]],
        [["ま","み","む","め","も"], ["や","","ゆ","","よ"], ["ら","り","る","れ","ろ"]],
        [["","","","",""], ["わ","を","ん","ー","〜"], ["","","","",""]],
    ]
    // 向きの番号: 0 真ん中, 1 左, 2 上, 3 右, 4 下。取り違えやすい向き。
    static let nearDir: [[Int]] = [[1,2,3,4], [0,2,4], [0,1,3], [0,2,4], [0,1,3]]

    static func flickTable(dir: Float, neighbor: Float) -> [String: [TypoCorrectionTable.Entry]] {
        var t: [String: [TypoCorrectionTable.Entry]] = [:]
        func kata(_ s: String) -> String { s.applyingTransform(.hiraganaToKatakana, reverse: false) ?? s }
        for (r, row) in kanaRows.enumerated() {
            for (c, key) in row.enumerated() {
                for (d, ch) in key.enumerated() where !ch.isEmpty {
                    var list: [TypoCorrectionTable.Entry] = []
                    for d2 in nearDir[d] where !key[d2].isEmpty {
                        list.append(.init(kata(key[d2]), penalty: dir))
                    }
                    for (dr, dc) in [(-1,0),(1,0),(0,-1),(0,1)] {
                        let r2 = r + dr, c2 = c + dc
                        guard kanaRows.indices.contains(r2), kanaRows[r2].indices.contains(c2) else { continue }
                        let other = kanaRows[r2][c2][d]
                        if !other.isEmpty, neighbor < 50 { list.append(.init(kata(other), penalty: neighbor)) }
                    }
                    t[kata(ch), default: []] += list
                }
            }
        }
        return t
    }

    static let qwerty = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    static func romanTable(row: Float, diag: Float) -> [String: [TypoCorrectionTable.Entry]] {
        var t: [String: [TypoCorrectionTable.Entry]] = [:]
        let rows = qwerty.map { Array($0) }
        for (r, line) in rows.enumerated() {
            for (i, ch) in line.enumerated() {
                var list: [TypoCorrectionTable.Entry] = []
                for j in [i - 1, i + 1] where line.indices.contains(j) { list.append(.init(String(line[j]), penalty: row)) }
                // 上下の段は半キーずれているので、上の段は i と i+1、下の段は i-1 と i。
                if r > 0, diag < 50 { for j in [i, i + 1] where rows[r-1].indices.contains(j) { list.append(.init(String(rows[r-1][j]), penalty: diag)) } }
                if r < 2, diag < 50 { for j in [i - 1, i] where rows[r+1].indices.contains(j) { list.append(.init(String(rows[r+1][j]), penalty: diag)) } }
                t[String(ch)] = list
            }
        }
        return t
    }

    func options() -> ConvertRequestOptions {
        .withDefaultDictionary(N_best: 10, needTypoCorrection: true, requireJapanesePrediction: true, requireEnglishPrediction: false,
                               keyboardLanguage: .ja_JP, learningType: .nothing, maxMemoryCount: 0, shouldResetMemory: false,
                               memoryDirectoryURL: URL(fileURLWithPath: ""), sharedContainerURL: URL(fileURLWithPath: ""), metadata: nil)
    }

    nonisolated(unsafe) static var margin: Float = 0
    /// Jizai の 1 番目の決め方: 打った読みそのままの候補の一番と、打ち間違いを直した候補の一番を比べ、
    /// 直した方が margin より良いときだけ直した方を 1 番目にする。
    static func jizaiOrder(_ cands: [Candidate], target: String) -> [String] {
        let kata = target.applyingTransform(.hiraganaToKatakana, reverse: false) ?? target
        func ruby(_ c: Candidate) -> String { c.data.map(\.ruby).joined() }
        let exact = cands.first { ruby($0) == kata }
        let typo = cands.first { ruby($0) != kata && $0.rubyCount == kata.count }
        var first: Candidate?
        if let e = exact, let t = typo { first = t.value > e.value + margin ? t : e } else { first = exact ?? typo }
        var out = cands.map(\.text)
        if let f = first, let i = out.firstIndex(of: f.text) { out.insert(out.remove(at: i), at: 0) }
        return out
    }

    @MainActor func run(_ input: String, style: InputStyle) -> (texts: [String], ms: Double) {
        let converter = KanaKanjiConverter()
        var c = ComposingText()
        var ms = 0.0
        var out: [String] = []
        // 1 文字ずつ打ったときと同じく、毎回変換する(最後の 1 回の時間と、全体の時間の最大を見る)。
        for ch in input {
            c.insertAtCursorPosition(String(ch), inputStyle: style)
            let t0 = Date()
            let r = converter.requestCandidates(c, options: options())
            ms = max(ms, Date().timeIntervalSince(t0) * 1000)
            out = Array(Self.jizaiOrder(r.mainResults, target: c.convertTarget).prefix(8))
        }
        return (out, ms)
    }

    static let flickCases: [(typed: String, want: String)] = [
        ("あるがとう", "ありがとう"), ("かょう", "今日"), ("よろしき", "よろしく"), ("たべもね", "食べ物"),
        ("なち", "何"), ("おねがうします", "お願いします"), ("だいじょうふ", "大丈夫"), ("あしち", "明日"),
        ("せんせお", "先生"), ("ともだに", "友達"),
    ]
    static let romanCases: [(typed: String, want: String)] = [
        ("arigatiu", "ありがとう"), ("yoroshiju", "よろしく"), ("kaugi", "会議"), ("ohayiu", "おはよう"),
        ("tomodschi", "友達"), ("sensri", "先生"), ("daijiubu", "大丈夫"), ("ashits", "明日"),
        ("benkuo", "勉強"), ("shigoro", "仕事"),
    ]
    static let correctFlick = ["きかい", "かき", "いし", "はし", "あめ", "かみ", "こうえん", "しんぶん", "きのう", "わたし", "でんしゃ", "がっこう"]
    static let correctRoman = ["kikai", "kaki", "ishi", "hashi", "ame", "kami", "kouen", "shinbun", "kinou", "watashi", "densha", "gakkou"]

    @MainActor func report(dir: Float, neighbor: Float, row: Float, diag: Float, maxPenalty: Float?) {
        TypoCorrectionTable.direct = [:]; TypoCorrectionTable.roman2Kana = [:]; TypoCorrectionTable.maxPenalty = nil
        let baseF = Self.correctFlick.map { run($0, style: .direct).texts.first ?? "" }
        let baseR = Self.correctRoman.map { run($0, style: .roman2kana).texts.first ?? "" }
        var baseMs = 0.0
        var baseHit = 0
        for (t, w) in Self.flickCases { let r = run(t, style: .direct); baseMs = max(baseMs, r.ms); if r.texts.prefix(5).contains(w) { baseHit += 1 } }
        for (t, w) in Self.romanCases { let r = run(t, style: .roman2kana); baseMs = max(baseMs, r.ms); if r.texts.prefix(5).contains(w) { baseHit += 1 } }

        TypoCorrectionTable.direct = Self.flickTable(dir: dir, neighbor: neighbor)
        TypoCorrectionTable.roman2Kana = Self.romanTable(row: row, diag: diag)
        TypoCorrectionTable.maxPenalty = maxPenalty
        var lines: [String] = []
        var hit = 0, hit1 = 0, ms = 0.0
        for (t, w) in Self.flickCases + Self.romanCases {
            let r = run(t, style: Self.flickCases.contains { $0.typed == t } ? .direct : .roman2kana)
            ms = max(ms, r.ms)
            let rank = r.texts.firstIndex(of: w).map { $0 + 1 }
            if let rank, rank <= 5 { hit += 1 }
            if rank == 1 { hit1 += 1 }
            lines.append("  \(t) → \(w): \(rank.map(String.init) ?? "-")  [\(r.texts.prefix(5).joined(separator: " "))]")
        }
        var broken: [String] = []
        for (i, s) in Self.correctFlick.enumerated() { let f = run(s, style: .direct).texts.first ?? ""; if f != baseF[i] { broken.append("\(s): \(baseF[i])→\(f)") } }
        for (i, s) in Self.correctRoman.enumerated() { let f = run(s, style: .roman2kana).texts.first ?? ""; if f != baseR[i] { broken.append("\(s): \(baseR[i])→\(f)") } }
        Self.out("=== margin \(Self.margin) dir \(dir) nb \(neighbor) row \(row) diag \(diag) max \(maxPenalty.map { "\($0)" } ?? "nil")")
        Self.out("  表なし: 5位以内 \(baseHit)/20  最大 \(String(format: "%.1f", baseMs))ms")
        Self.out("  表あり: 5位以内 \(hit)/20  1位 \(hit1)/20  最大 \(String(format: "%.1f", ms))ms")
        Self.out("  正しく打った語の1位が変わった: \(broken.isEmpty ? "なし" : broken.joined(separator: ", "))")
        lines.forEach { Self.out($0) }
    }

    @MainActor func testReport() {
        // 設定は /tmp/jizai-typo-cfg.txt の各行「dir nb row diag max」(max は 0 で既定)。
        let text = (try? String(contentsOfFile: "/tmp/jizai-typo-cfg.txt", encoding: .utf8)) ?? "4 5.5 4 5 0"
        for line in text.split(separator: "\n") {
            let v = line.split(separator: " ").compactMap { Float($0) }
            guard v.count >= 5 else { continue }
            Self.margin = v.count >= 6 ? v[5] : 0
            
            report(dir: v[0], neighbor: v[1], row: v[2], diag: v[3], maxPenalty: v[4] == 0 ? nil : v[4])
        }
    }
}
