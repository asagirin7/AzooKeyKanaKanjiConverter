//
//  DicdataStore.swift
//  Keyboard
//
//  Created by ensan on 2020/09/17.
//  Copyright © 2020 ensan. All rights reserved.
//

import Algorithms
import Foundation
import SwiftUtils

public final class DicdataStore {
    public init(convertRequestOptions: ConvertRequestOptions) {
        self.requestOptions = convertRequestOptions
        self.setup()
    }

    init(requestOptions: ConvertRequestOptions = .default) {
        self.requestOptions = requestOptions
        debug("DicdataStoreが初期化されました")
        self.setup()
    }

    private var ccParsed: [Bool] = .init(repeating: false, count: 1319)
    private var ccLines: [[Int: PValue]] = []
    private var mmValue: [PValue] = []

    private var loudses: [String: LOUDS] = [:]
    private var loudstxts: [String: Data] = [:]
    private var importedLoudses: Set<String> = []
    private var charsID: [Character: UInt8] = [:]
    private var learningManager = LearningManager()

    private var dynamicUserDict: [DicdataElement] = []

    /// 辞書のエントリの最大長さ
    ///  - TODO: make this value as an option
    public let maxlength: Int = 20
    /// この値以下のスコアを持つエントリは積極的に無視する
    ///  - TODO: make this value as an option
    public let threshold: PValue = -17
    private let midCount = 502
    private let cidCount = 1319

    private var requestOptions: ConvertRequestOptions = .default

    private let numberFormatter = NumberFormatter()
    /// 初期化時のセットアップ用の関数。プロパティリストを読み込み、連接確率リストを読み込んで行分割し保存しておく。
    private func setup() {
        numberFormatter.numberStyle = .spellOut
        numberFormatter.locale = .init(identifier: "ja-JP")
        self.ccLines = [[Int: PValue]].init(repeating: [:], count: CIDData.totalCount)

        do {
            let string = try String(contentsOf: self.requestOptions.dictionaryResourceURL.appendingPathComponent("louds/charID.chid", isDirectory: false), encoding: String.Encoding.utf8)
            charsID = [Character: UInt8].init(uniqueKeysWithValues: string.enumerated().map {($0.element, UInt8($0.offset))})
        } catch {
            debug("Error: louds/charID.chidが存在しません。このエラーは深刻ですが、テスト時には無視できる場合があります。Description: \(error)")
        }
        do {
            let url = requestOptions.dictionaryResourceURL.appendingPathComponent("mm.binary", isDirectory: false)
            do {
                let binaryData = try Data(contentsOf: url, options: [.uncached])
                self.mmValue = binaryData.toArray(of: Float.self).map {PValue($0)}
            } catch {
                debug("Error: mm.binaryが存在しません。このエラーは深刻ですが、テスト時には無視できる場合があります。Description: \(error)")
                self.mmValue = [PValue].init(repeating: .zero, count: self.midCount * self.midCount)
            }
        }
        self.reloadUser()
        _ = self.loadLOUDS(query: "user")
        self.reloadMemory()
        _ = self.loadLOUDS(query: "memory")

        if requestOptions.preloadDictionary {
            self.preloadDictionary()
        }
    }

    /// ファイルI/Oの遅延を減らすために、辞書を事前に読み込む関数。
    private func preloadDictionary() {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: self.requestOptions.dictionaryResourceURL.appendingPathComponent("louds", isDirectory: true),
            includingPropertiesForKeys: nil
        ) else { return }

        for url in fileURLs {
            let identifier = url.deletingPathExtension().lastPathComponent
            let pathExt = url.pathExtension
            
            switch pathExt {
                case "louds":
                    // userやmemoryは実行中に更新される場合があるため、キャッシュから除外
                    if identifier == "user" || identifier == "memory" {
                        continue
                    }
                    loudses[identifier] = LOUDS.load(identifier, option: self.requestOptions)
                case "loudstxt3":
                    if let data = try? Data(contentsOf: url) {
                        loudstxts[identifier] = data
                    } else {
                        debug("Error: Could not load loudstxt3 file at \(url)")
                    }
                default:
                    continue
            }
        }
    }

    public enum Notification {
        /// use `importDynamicUserDict` for data that cannot be obtained statically.
        /// - warning: Too many dynamic user dictionary will damage conversion performance, as dynamic user dictionary uses inefficent algorithms for looking up. If your entries can be listed up statically, then use normal user dictionaries.
        case importDynamicUserDict([DicdataElement])
        @available(*, deprecated, renamed: "importDynamicUserDict", message: "it will be removed in AzooKeyKanaKanjiConverter v1.0")
        case importOSUserDict([DicdataElement])
        case setRequestOptions(ConvertRequestOptions)
        case forgetMemory(Candidate)
        case closeKeyboard
    }

    func sendToDicdataStore(_ data: Notification) {
        switch data {
        case .closeKeyboard:
            self.closeKeyboard()
        case .importOSUserDict(let dicdata), .importDynamicUserDict(let dicdata):
            self.dynamicUserDict = dicdata
            self.dynamicUserDict.mutatingForEach {
                $0.metadata = .isFromUserDictionary
            }
        case let .forgetMemory(candidate):
            self.learningManager.forgetMemory(data: candidate.data)
            // loudsの処理があるので、リセットを実施する
            self.reloadMemory()
        case let .setRequestOptions(value):
            // bundleURLが変わる場合はsetupを再実行する
            if value.dictionaryResourceURL != self.requestOptions.dictionaryResourceURL {
                self.requestOptions = value
                self.setup()
            } else {
                self.requestOptions = value
            }
            let shouldReset = self.learningManager.setRequestOptions(value)
            if shouldReset {
                self.reloadMemory()
            }
        }
    }

    func character2charId(_ character: Character) -> UInt8 {
        self.charsID[character, default: .max]
    }

    private func reloadMemory() {
        self.loudses.removeValue(forKey: "memory")
        self.importedLoudses.remove("memory")
    }

    private func reloadUser() {
        self.loudses.removeValue(forKey: "user")
        self.importedLoudses.remove("user")
    }

    private func closeKeyboard() {
        self.learningManager.save()
        // saveしたあとにmemoryのキャッシュされたLOUDSを使い続けないよう、キャッシュから削除する。
        self.reloadMemory()
        self.reloadUser()
    }

    /// ペナルティ関数。文字数で決める。
    @inlinable static func getPenalty(data: borrowing DicdataElement) -> PValue {
        -2.0 / PValue(data.word.count)
    }

    /// 計算時に利用。無視すべきデータかどうか。
    private func shouldBeRemoved(value: PValue, wordCount: Int) -> Bool {
        let d = value - self.threshold
        if d < 0 {
            return true
        }
        // dは正
        return -2.0 / PValue(wordCount) < -d
    }

    /// 計算時に利用。無視すべきデータかどうか。
    @inlinable func shouldBeRemoved(data: borrowing DicdataElement) -> Bool {
        let d = data.value() - self.threshold
        if d < 0 {
            return true
        }
        return Self.getPenalty(data: data) < -d
    }

    func loadLOUDS(query: String) -> LOUDS? {
        if importedLoudses.contains(query) {
            return self.loudses[query]
        }
        // LOUDSが読み込めたか否かにかかわらず、importedLoudsesは更新する
        importedLoudses.insert(query)
        // 一部のASCII文字はエスケープする
        let identifier = [
            "\\n": "[0A]",
            " ": "[20]",
            "\"": "[22]",
            "\'": "[27]",
            "*": "[2A]",
            "+": "[2B]",
            ".": "[2E]",
            "/": "[2F]",
            ":": "[3A]",
            "<": "[3C]",
            ">": "[3E]",
            "\\": "[5C]",
            "|": "[7C]",
        ][query, default: query]
        if let louds = LOUDS.load(identifier, option: self.requestOptions) {
            self.loudses[query] = louds
            return louds
        } else {
            if identifier == "user" || identifier == "memory" {
                debug("Error: IDが「\(identifier) (query: \(query))」のloudsファイルの読み込みに失敗しましたが、このエラーは深刻ではありません。")
            } else {
                debug("Error: IDが「\(identifier) (query: \(query))」のloudsファイルの読み込みに失敗しました。IDに対する辞書データが存在しないことが想定される場合はこのエラーは深刻ではありませんが、そうでない場合は深刻なエラーの可能性があります。")
            }
            return nil
        }
    }

    /// 完全一致検索を行う関数。
    /// - Parameters:
    ///   - query: 対象とするLOUDS辞書の識別子（通常は先頭1文字や"user"など）。
    ///   - charIDs: 検索する語を表す文字ID列。
    /// - Returns: 与えられた文字ID列と完全に一致するノードインデックスの配列（存在すれば1件、存在しなければ空配列）。
    ///
    /// 入力の文字ID列がLOUDS内のノードと完全一致する場合、そのノードのインデックスを返す。
    /// 一致しない場合は空の配列を返す。
    func perfectMatchingSearch(query: String, charIDs: [UInt8]) -> [Int] {
        guard let louds = self.loadLOUDS(query: query) else {
            return []
        }
        return [louds.searchNodeIndex(chars: charIDs)].compactMap {$0}
    }

    private struct UnifiedGenerator {
        struct SurfaceGenerator {
            var surface: [Character] = []
            var range: TypoCorrectionGenerator.ProcessRange
            var currentIndex: Int

            init(surface: [Character], range: TypoCorrectionGenerator.ProcessRange) {
                self.surface = surface
                self.range = range
                self.currentIndex = range.rightIndexRange.lowerBound
            }

            mutating func setUnreachablePath<C: Collection<Character>>(target: C) where C.Indices == Range<Int> {
                if self.surface[self.range.leftIndex...].hasPrefix(target) {
                    // new upper boundを計算
                    let currentLowerBound = self.range.rightIndexRange.lowerBound
                    let currentUpperBound = self.range.rightIndexRange.upperBound
                    let targetUpperBound = self.range.leftIndex + target.indices.upperBound
                    self.range.rightIndexRange = min(currentLowerBound, targetUpperBound) ..< min(currentUpperBound, targetUpperBound)
                }
            }

            mutating func next() -> ([Character], (endIndex: Lattice.LatticeIndex, penalty: PValue))? {
                if self.surface.indices.contains(self.currentIndex), self.currentIndex < self.range.rightIndexRange.upperBound {
                    defer {
                        self.currentIndex += 1
                    }
                    let characters = Array(self.surface[self.range.leftIndex ... self.currentIndex])
                    return (characters, (.surface(self.currentIndex), 0))
                }
                return nil
            }
        }

        var typoCorrectionGenerator: TypoCorrectionGenerator? = nil
        var surfaceGenerator: SurfaceGenerator? = nil

        mutating func register(_ generator: TypoCorrectionGenerator) {
            self.typoCorrectionGenerator = generator
        }
        mutating func register(_ generator: SurfaceGenerator) {
            self.surfaceGenerator = generator
        }
        mutating func setUnreachablePath<C: Collection<Character>>(target: C) where C.Indices == Range<Int> {
            self.typoCorrectionGenerator?.setUnreachablePath(target: target)
            self.surfaceGenerator?.setUnreachablePath(target: target)
        }
        mutating func next() -> ([Character], (endIndex: Lattice.LatticeIndex, penalty: PValue))? {
            if let next = self.surfaceGenerator?.next() {
                return next
            }
            if let next = self.typoCorrectionGenerator?.next() {
                return next
            }
            return nil
        }
    }

    func movingTowardPrefixSearch(
        composingText: ComposingText,
        inputProcessRange: TypoCorrectionGenerator.ProcessRange?,
        surfaceProcessRange: TypoCorrectionGenerator.ProcessRange?,
        useMemory: Bool,
        needTypoCorrection: Bool
    ) -> (
        stringToInfo: [[Character]: (endIndex: Lattice.LatticeIndex, penalty: PValue)],
        indices: [(key: String, indices: [Int])],
        temporaryMemoryDicdata: [DicdataElement]
    ) {
        var generator = UnifiedGenerator()
        if let surfaceProcessRange {
            let surfaceGenerator = UnifiedGenerator.SurfaceGenerator(
                surface: Array(composingText.convertTarget.toKatakana()),
                range: surfaceProcessRange
            )
            generator.register(surfaceGenerator)
        }
        if let inputProcessRange {
            let typoCorrectionGenerator = TypoCorrectionGenerator(
                inputs: composingText.input,
                range: inputProcessRange,
                needTypoCorrection: needTypoCorrection
            )
            generator.register(typoCorrectionGenerator)
        }
        var targetLOUDS: [String: LOUDS.MovingTowardPrefixSearchHelper] = [:]
        var stringToInfo: [([Character], (endIndex: Lattice.LatticeIndex, penalty: PValue))] = []
        // 動的辞書（一時学習データ、動的ユーザ辞書）から取り出されたデータ
        var dynamicDicdata: [Int: [DicdataElement]] = [:]
        // ジェネレータを舐める
        while let (characters, info) = generator.next() {
            guard let firstCharacter = characters.first else {
                continue
            }
            let charIDs = characters.map(self.character2charId(_:))
            // 覚えた語(学習)は、打ち間違いを直した読みでは引かない(覚えた語の高い値のまま、
            // 打ったとおりの候補より前に出てしまうため)。直した読みでは辞書の値に罰点を引いた値で出る。
            let keys: [String] = if useMemory && info.penalty.isZero {
                [String(firstCharacter), "user", "memory"]
            } else {
                [String(firstCharacter), "user"]
            }
            var updated = false
            var availableMaxIndex = 0
            for key in keys {
                withMutableValue(&targetLOUDS[key]) { helper in
                    if helper == nil, let louds = self.loadLOUDS(query: key) {
                        helper = LOUDS.MovingTowardPrefixSearchHelper(louds: louds)
                    }
                    guard helper != nil else {
                        return
                    }
                    let result = helper!.update(target: charIDs)
                    updated = updated || result.updated
                    availableMaxIndex = max(availableMaxIndex, result.availableMaxIndex)
                }
            }
            // 短期記憶についてはこの位置で処理する(打ち間違いを直した読みでは引かない)
            if info.penalty.isZero {
                let result = self.learningManager.movingTowardPrefixSearchOnTemporaryMemory(charIDs: consume charIDs)
                updated = updated || !(result.dicdata.isEmpty)
                availableMaxIndex = max(availableMaxIndex, result.availableMaxIndex)
                for (depth, dicdata) in result.dicdata {
                    for data in dicdata {
                        dynamicDicdata[depth, default: []].append(data)
                    }
                }
            }
            if !self.dynamicUserDict.isEmpty {
                // 動的ユーザ辞書にデータがある場合、この位置で処理する
                let katakanaString = String(characters).toKatakana()
                let dynamicUserDictResult = self.getMatchDynamicUserDict(katakanaString)
                updated = updated || !dynamicUserDictResult.isEmpty
                for data in dynamicUserDictResult {
                    let depth = characters.endIndex
                    if info.penalty.isZero {
                        dynamicDicdata[depth, default: []].append(data)
                    } else {
                        let ratio = Self.penaltyRatio[data.lcid]
                        let pUnit: PValue = Self.getPenalty(data: data) / 2   // 負の値
                        let adjust = pUnit * info.penalty * ratio
                        if self.shouldBeRemoved(value: data.value() + adjust, wordCount: Array(data.ruby).count) {
                            continue
                        }
                        dynamicDicdata[depth, default: []].append(data.adjustedData(adjust))
                    }
                }
            }
            if availableMaxIndex < characters.endIndex - 1 {
                // 到達不可能だったパスを通知
                generator.setUnreachablePath(target: characters[...(availableMaxIndex + 1)])
            }
            if updated {
                stringToInfo.append((characters, info))
            }
        }
        let minCount = stringToInfo.map {$0.0.count}.min() ?? 0
        return (
            Dictionary(
                stringToInfo,
                uniquingKeysWith: { (lhs, rhs) in
                    if lhs.penalty < rhs.penalty {
                        return lhs
                    } else if lhs.penalty == rhs.penalty {
                        return switch (lhs.endIndex, rhs.endIndex) {
                        case (.input, .input), (.surface, .surface): lhs // どっちでもいい
                        case (.surface, .input): lhs  // surfaceIndexを優先
                        case (.input, .surface): rhs  // surfaceIndexを優先
                        }
                    } else {
                        return rhs
                    }
                }
            ),
            targetLOUDS.map {
                ($0.key, $0.value.indicesInDepth(depth: minCount - 1 ..< .max))
            },
            dynamicDicdata.flatMap {
                minCount < $0.key + 1 ? $0.value : []
            }
        )
    }
    /// prefixを起点として、それに続く語（prefix match）をLOUDS上で探索する関数。
    /// - Parameters:
    ///   - query: 辞書ファイルの識別子（通常は先頭1文字や"user"など）。
    ///   - charIDs: 接頭辞を構成する文字ID列。
    ///   - depth: 接頭辞から何文字先まで探索するかの上限。
    ///   - maxCount: 最大取得件数。多すぎると性能劣化につながるため制限できる。
    /// - Returns: 与えられたprefixで始まる語のノードインデックスのリスト。
    ///
    /// 入力のprefixにマッチする語をLOUDSから最大`maxCount`件、最大`depth`文字先まで探索する。
    /// 「ABC」→「ABC」「ABCD」「ABCDE」などを対象とする検索。
    private func startingFromPrefixSearch(query: String, charIDs: [UInt8], depth: Int = .max, maxCount: Int = .max) -> [Int] {
        guard let louds = self.loadLOUDS(query: query) else {
            return []
        }
        return louds.prefixNodeIndices(chars: charIDs, maxDepth: depth, maxCount: maxCount)
    }

    package func getDicdataFromLoudstxt3(identifier: String, indices: some Sequence<Int>) -> [DicdataElement] {
        // split = 2048
        let dict = [Int: [Int]].init(grouping: indices, by: {$0 >> 11})
        var data: [DicdataElement] = []
        for (key, value) in dict {
            data.append(contentsOf: LOUDS.getDataForLoudstxt3(identifier + "\(key)", indices: value.map {$0 & 2047}, cache: self.loudstxts[identifier + "\(key)"], option: self.requestOptions))
        }
        if identifier == "memory" {
            data.mutatingForEach {
                $0.metadata = .isLearned
            }
        }
        if identifier == "user" {
            data.mutatingForEach {
                $0.metadata = .isFromUserDictionary
            }
        }
        return data
    }
    
    /// 辞書データを取得する
    /// - Parameters:
    ///   - composingText: 現在の入力情報
    ///   - inputRange: 検索に用いる`composingText.input`の範囲。
    ///   - surfaceRange: 検索に用いる`composingText.convertTarget`の範囲。
    ///   - needTypoCorrection: 誤り訂正を行うかどうか
    /// - Returns: 発見された辞書データを`LatticeNode`のインスタンスとしたもの。
    public func lookupDicdata(
        composingText: ComposingText,
        inputRange:(startIndex: Int, endIndexRange: Range<Int>?)? = nil,
        surfaceRange: (startIndex: Int, endIndexRange: Range<Int>?)? = nil,
        needTypoCorrection: Bool = true
    ) -> [LatticeNode] {

        let inputProcessRange: TypoCorrectionGenerator.ProcessRange?
        if let inputRange {
            let toInputIndexLeft = inputRange.endIndexRange?.startIndex ?? inputRange.startIndex
            let toInputIndexRight = min(
                inputRange.endIndexRange?.endIndex ?? composingText.input.count,
                inputRange.startIndex + self.maxlength
            )
            if inputRange.startIndex > toInputIndexLeft || toInputIndexLeft >= toInputIndexRight {
                debug(#function, "index is wrong", inputRange)
                return []
            }
            inputProcessRange = .init(leftIndex: inputRange.startIndex, rightIndexRange: toInputIndexLeft ..< toInputIndexRight)
        } else {
            inputProcessRange = nil
        }

        let surfaceProcessRange: TypoCorrectionGenerator.ProcessRange?
        if let surfaceRange {
            let toSurfaceIndexLeft = surfaceRange.endIndexRange?.startIndex ?? surfaceRange.startIndex
            let toSurfaceIndexRight = min(
                surfaceRange.endIndexRange?.endIndex ?? composingText.convertTarget.count,
                surfaceRange.startIndex + self.maxlength
            )
            if surfaceRange.startIndex > toSurfaceIndexLeft || toSurfaceIndexLeft >= toSurfaceIndexRight {
                debug(#function, "index is wrong", surfaceRange)
                return []
            }
            surfaceProcessRange = .init(leftIndex: surfaceRange.startIndex, rightIndexRange: toSurfaceIndexLeft ..< toSurfaceIndexRight)
        } else {
            surfaceProcessRange = nil
        }
        if inputProcessRange == nil && surfaceProcessRange == nil {
            debug(#function, "either of inputProcessRange and surfaceProcessRange must not be nil")
            return []
        }
        // MARK: 誤り訂正の対象を列挙する。非常に重い処理。
        var (stringToInfo, indices, dicdata) = self.movingTowardPrefixSearch(
            composingText: composingText,
            inputProcessRange: inputProcessRange,
            surfaceProcessRange: surfaceProcessRange,
            useMemory: self.learningManager.enabled,
            needTypoCorrection: needTypoCorrection
        )
        // MARK: 検索によって得たindicesから辞書データを実際に取り出していく
        for (identifier, value) in indices {
            let result: [DicdataElement] = self.getDicdataFromLoudstxt3(identifier: identifier, indices: value).compactMap { (data) -> DicdataElement? in
                let rubyArray = Array(data.ruby)
                let penalty = stringToInfo[rubyArray]?.penalty ?? 0
                if penalty.isZero {
                    return data
                }
                let ratio = Self.penaltyRatio[data.lcid]
                let pUnit: PValue = Self.getPenalty(data: data) / 2   // 負の値
                let adjust = pUnit * penalty * ratio
                if self.shouldBeRemoved(value: data.value() + adjust, wordCount: rubyArray.count) {
                    return nil
                }
                return data.adjustedData(adjust)
            }
            dicdata.append(contentsOf: result)
        }

        // 機械的に一部のデータを生成する
        if let surfaceProcessRange {
            let chars = Array(composingText.convertTarget.toKatakana())
            var segment = String(chars[surfaceProcessRange.leftIndex ..< surfaceProcessRange.rightIndexRange.lowerBound])
            for i in surfaceProcessRange.rightIndexRange {
                segment.append(String(chars[i]))
                let result = self.getWiseDicdata(
                    convertTarget: segment,
                    inputData: composingText,
                    surfaceRange: surfaceProcessRange.leftIndex ..< i + 1
                )
                for item in result {
                    stringToInfo[Array(item.ruby)] = (.surface(i), 0)
                }
                dicdata.append(contentsOf: result)
            }
        }
        let needBOS = inputRange?.startIndex == .zero || surfaceRange?.startIndex == .zero
        let result: [LatticeNode] = dicdata.compactMap {
            guard let endIndex = stringToInfo[Array($0.ruby)]?.endIndex else {
                return nil
            }
            let range: Lattice.LatticeRange = switch endIndex {
            case .input(let endIndex): .input(from: (inputRange?.startIndex)!, to: endIndex + 1)
            case .surface(let endIndex): .surface(from: (surfaceRange?.startIndex)!, to: endIndex + 1)
            }
            let node = LatticeNode(data: $0, range: range)
            if needBOS {
                node.prevs.append(RegisteredNode.BOSNode())
            }
            return node
        }
        return result
    }

    func getZeroHintPredictionDicdata(lastRcid: Int) -> [DicdataElement] {
        do {
            let csvString = try String(contentsOf: requestOptions.dictionaryResourceURL.appendingPathComponent("p/pc_\(lastRcid).csv", isDirectory: false), encoding: .utf8)
            let csvLines = csvString.split(separator: "\n")
            let csvData = csvLines.map {$0.split(separator: ",", omittingEmptySubsequences: false)}
            let dicdata: [DicdataElement] = csvData.map {self.parseLoudstxt2FormattedEntry(from: $0)}
            return dicdata
        } catch {
            debug("Error: 右品詞ID\(lastRcid)のためのZero Hint Predictionのためのデータの読み込みに失敗しました。このエラーは深刻ですが、テスト時には無視できる場合があります。 Description: \(error.localizedDescription)")
            return []
        }
    }

    /// 辞書から予測変換データを読み込む関数
    /// - Parameters:
    ///   - head: 辞書を引く文字列
    /// - Returns:
    ///   発見されたデータのリスト。
    func getPredictionLOUDSDicdata(key: some StringProtocol) -> [DicdataElement] {
        let count = key.count
        if count == .zero {
            return []
        }
        // 最大700件に絞ることによって低速化を回避する。
        let maxCount = 700
        var result: [DicdataElement] = []
        let first = String(key.first!)
        let charIDs = key.map(self.character2charId)
        // 1, 2文字に対する予測変換は候補数が大きいので、depth（〜文字数）を制限する
        let depth = if count == 1 {
            3
        } else if count == 2 {
            5
        } else {
            Int.max
        }
        let prefixIndices = self.startingFromPrefixSearch(query: first, charIDs: charIDs, depth: depth, maxCount: maxCount)

        result.append(
            contentsOf: self.getDicdataFromLoudstxt3(identifier: first, indices: Set(prefixIndices))
                .filter { Self.predictionUsable[$0.rcid] }
        )
        let userDictIndices = self.startingFromPrefixSearch(query: "user", charIDs: charIDs, maxCount: maxCount)
        result.append(contentsOf: self.getDicdataFromLoudstxt3(identifier: "user", indices: Set(consume userDictIndices)))
        if learningManager.enabled {
            let memoryDictIndices = self.startingFromPrefixSearch(query: "memory", charIDs: charIDs, maxCount: maxCount)
            result.append(contentsOf: self.getDicdataFromLoudstxt3(identifier: "memory", indices: Set(consume memoryDictIndices)))
            result.append(contentsOf: self.learningManager.temporaryPrefixMatch(charIDs: charIDs))
        }
        return result
    }

    private func parseLoudstxt2FormattedEntry(from dataString: [some StringProtocol]) -> DicdataElement {
        let ruby = String(dataString[0])
        let word = dataString[1].isEmpty ? ruby:String(dataString[1])
        let lcid = Int(dataString[2]) ?? .zero
        let rcid = Int(dataString[3]) ?? lcid
        let mid = Int(dataString[4]) ?? .zero
        let value: PValue = PValue(dataString[5]) ?? -30.0
        return DicdataElement(word: word, ruby: ruby, lcid: lcid, rcid: rcid, mid: mid, value: value)
    }

    /// 補足的な辞書情報を得る。
    ///  - parameters:
    ///     - convertTarget: カタカナ変換済みの文字列
    /// - note
    ///     - 入力全体をカタカナとかひらがなに変換するやつは、Converter側でやっているので注意。
    func getWiseDicdata(convertTarget: String, inputData: ComposingText, surfaceRange: Range<Int>) -> [DicdataElement] {
        print(#function, convertTarget, inputData, surfaceRange)
        var result: [DicdataElement] = []
        result.append(contentsOf: self.getJapaneseNumberDicdata(head: convertTarget))
        if inputData.convertTarget.prefix(surfaceRange.lowerBound).last?.isNumber != true,
           inputData.convertTarget.dropFirst(surfaceRange.upperBound).first?.isNumber != true,
            let number = Int(convertTarget) {
            result.append(DicdataElement(ruby: convertTarget, cid: CIDData.数.cid, mid: MIDData.小さい数字.mid, value: -14))
            if Double(number) <= 1E12 && -1E12 <= Double(number), let kansuji = self.numberFormatter.string(from: NSNumber(value: number)) {
                result.append(DicdataElement(word: kansuji, ruby: convertTarget, cid: CIDData.数.cid, mid: MIDData.小さい数字.mid, value: -16))
            }
        }
        // convertTargetを英単語として候補に追加する
        if requestOptions.keyboardLanguage == .en_US && convertTarget.onlyRomanAlphabet {
            result.append(DicdataElement(ruby: convertTarget, cid: CIDData.固有名詞.cid, mid: MIDData.英単語.mid, value: -14))
        }
        // convertTargetが1文字のケースでは、ひらがな・カタカナに変換したものを候補に追加する
        if convertTarget.count == 1 {
            let katakana = convertTarget.toKatakana()
            let hiragana = convertTarget.toHiragana()
            if katakana == hiragana {
                // カタカナとひらがなが同じ場合（記号など）
                let element = DicdataElement(ruby: katakana, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -14)
                result.append(element)
            } else {
                // カタカナとひらがなが異なる場合は両方追加
                let hiraganaElement = DicdataElement(word: hiragana, ruby: katakana, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -13)
                let katakanaElement = DicdataElement(ruby: katakana, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -14)
                result.append(hiraganaElement)
                result.append(katakanaElement)
            }
        }
        // 記号変換
        if convertTarget.count == 1, let first = convertTarget.first {
            var value: PValue = -14
            let hs = Self.fullwidthToHalfwidth[first, default: first]

            if hs != first {
                result.append(DicdataElement(word: convertTarget, ruby: convertTarget, cid: CIDData.記号.cid, mid: MIDData.一般.mid, value: value))
                value -= 5.0
                result.append(DicdataElement(word: String(hs), ruby: convertTarget, cid: CIDData.記号.cid, mid: MIDData.一般.mid, value: value))
                value -= 5.0
            }
            if let fs = Self.halfwidthToFullwidth[first], fs != first {
                result.append(DicdataElement(word: convertTarget, ruby: convertTarget, cid: CIDData.記号.cid, mid: MIDData.一般.mid, value: value))
                value -= 5.0
                result.append(DicdataElement(word: String(fs), ruby: convertTarget, cid: CIDData.記号.cid, mid: MIDData.一般.mid, value: value))
                value -= 5.0
            }
            for group in Self.weakRelatingSymbolGroups where group.contains(hs) {
                for symbol in group where symbol != hs {
                    result.append(DicdataElement(word: String(symbol), ruby: convertTarget, cid: CIDData.記号.cid, mid: MIDData.一般.mid, value: value))
                    value -= 5.0
                    if let fs = Self.halfwidthToFullwidth[symbol] {
                        result.append(DicdataElement(word: String(fs), ruby: convertTarget, cid: CIDData.記号.cid, mid: MIDData.一般.mid, value: value))
                        value -= 5.0
                    }
                }
            }
        }
        return result
    }

    // 記号に対する半角・全角変換
    private static let (fullwidthToHalfwidth, halfwidthToFullwidth) = zip(
        "＋ー＊＝・！＃％＆＇＂〜｜￡＄￥＠｀；：＜＞，．＼／＿￣－",
        "＋ー＊＝・！＃％＆＇＂〜｜￡＄￥＠｀；：＜＞，．＼／＿￣－".applyingTransform(.fullwidthToHalfwidth, reverse: false)!
    )
    .reduce(into: ([Character: Character](), [Character: Character]())) { (results: inout ([Character: Character], [Character: Character]), values: (Character, Character)) in
        results.0[values.0] = values.1
        results.1[values.1] = values.0
    }

    // 弱い類似(矢印同士のような関係)にある記号をグループにしたもの
    // 例えば→に対して⇒のような記号はより類似度が強いため、上位に出したい。これを実現する必要が生じた場合はstrongRelatingSymbolGroupsを新設する。
    // 宣言順不同
    // 1つを入れると他が出る、というイメージ
    // 半角と全角がある場合は半角のみ
    private static let weakRelatingSymbolGroups: [[Character]] = [
        // 異体字セレクト用 (試験実装)
        ["高", "髙"], // ハシゴダカ
        ["斎", "斉", "齋", "齊"],
        ["澤", "沢"],
        ["気", "氣"],
        ["澁", "渋"],
        ["対", "對"],
        ["辻", "辻󠄀"],
        ["禰󠄀", "禰"],
        ["煉󠄁", "煉"],
        ["崎", "﨑"], // タツザキ
        ["栄", "榮"],
        ["吉", "𠮷"], // ツチヨシ
        ["橋", "𣘺", "槗", "𫞎"],
        ["浜", "濱", "濵"],
        ["鴎", "鷗"],
        ["学", "學"],
        ["角", "⻆"],
        ["亀", "龜"],
        ["桜", "櫻"],
        ["真", "眞"],

        // 記号変換
        ["☆", "★", "♡", "☾", "☽"],  // 星
        ["^", "＾"],  // ハット
        ["¥", "$", "¢", "€", "£", "₿"], // 通貨
        ["%", "‰"], // パーセント
        ["°", "℃", "℉"],
        ["◯"], // 図形
        ["*", "※", "✳︎", "✴︎"],   // こめ
        ["・", "…", "‥", "•"],
        ["+", "±", "⊕"],
        ["×", "❌", "✖️"],
        ["÷", "➗" ],
        ["<", "≦", "≪", "〈", "《", "‹", "«"],
        [">", "≧", "≫", "〉", "》", "›", "»"],
        ["=", "≒", "≠", "≡"],
        [":", ";"],
        ["!", "❗️", "❣️", "‼︎", "⁉︎", "❕", "‼️", "⁉️", "¡"],
        ["?", "❓", "⁉︎", "⁇", "❔", "⁉️", "¿"],
        ["〒", "〠", "℡", "☎︎"],
        ["々", "ヾ", "ヽ", "ゝ", "ゞ", "〃", "仝", "〻"],
        ["〆", "〼", "ゟ", "ヿ"], // 特殊仮名
        ["♂", "♀", "⚢", "⚣", "⚤", "⚥", "⚦", "⚧", "⚨", "⚩", "⚪︎", "⚲"], // ジェンダー記号
        ["→", "↑", "←", "↓", "↙︎", "↖︎", "↘︎", "↗︎", "↔︎", "↕︎", "↪︎", "↩︎", "⇆"], // 矢印
        ["♯", "♭", "♪", "♮", "♫", "♬", "♩", "𝄞", "𝄞"],  // 音符
        ["√", "∛", "∜"]  // 根号
    ]

    private func loadCCBinary(url: URL) -> [(Int32, Float)] {
        do {
            let binaryData = try Data(contentsOf: url, options: [.uncached])
            return binaryData.toArray(of: (Int32, Float).self)
        } catch {
            debug("Error: 品詞連接コストデータの読み込みに失敗しました。このエラーは深刻ですが、テスト時には無視できる場合があります。 Description: \(error.localizedDescription)")
            return []
        }
    }

    /// 動的ユーザ辞書からrubyに等しい語を返す。
    func getMatchDynamicUserDict(_ ruby: some StringProtocol) -> [DicdataElement] {
        self.dynamicUserDict.filter {$0.ruby == ruby}
    }

    /// 動的ユーザ辞書からrubyに先頭一致する語を返す。
    func getPrefixMatchDynamicUserDict(_ ruby: some StringProtocol) -> [DicdataElement] {
        self.dynamicUserDict.filter {$0.ruby.hasPrefix(ruby)}
    }

    // 学習を反映する
    // TODO: previousの扱いを改善したい
    func updateLearningData(_ candidate: Candidate, with previous: DicdataElement?) {
        if let previous {
            self.learningManager.update(data: [previous] + candidate.data)
        } else {
            self.learningManager.update(data: candidate.data)
        }
    }
    // 予測変換に基づいて学習を反映する
    // TODO: previousの扱いを改善したい
    func updateLearningData(_ candidate: Candidate, with predictionCandidate: PostCompositionPredictionCandidate) {
        switch predictionCandidate.type {
        case .additional(data: let data):
            self.learningManager.update(data: candidate.data, updatePart: data)
        case .replacement(targetData: let targetData, replacementData: let replacementData):
            self.learningManager.update(data: candidate.data.dropLast(targetData.count), updatePart: replacementData)
        }
    }
    /// class idから連接確率を得る関数
    /// - Parameters:
    ///   - former: 左側の語のid
    ///   - latter: 右側の語のid
    /// - Returns:
    ///   連接確率の対数。
    /// - 要求があった場合ごとにファイルを読み込んで
    /// 速度: ⏱0.115224 : 変換_処理_連接コスト計算_CCValue
    public func getCCValue(_ former: Int, _ latter: Int) -> PValue {
        if !ccParsed[former] {
            let url = requestOptions.dictionaryResourceURL.appendingPathComponent("cb/\(former).binary", isDirectory: false)
            let values = loadCCBinary(url: url)
            ccLines[former] = [Int: PValue].init(uniqueKeysWithValues: values.map {(Int($0.0), PValue($0.1))})
            ccParsed[former] = true
        }
        let defaultValue = ccLines[former][-1, default: -25]
        return ccLines[former][latter, default: defaultValue]
    }

    /// meaning idから意味連接尤度を得る関数
    /// - Parameters:
    ///   - former: 左側の語のid
    ///   - latter: 右側の語のid
    /// - Returns:
    ///   意味連接確率の対数。
    /// - 要求があった場合ごとに確率値をパースして取得する。
    public func getMMValue(_ former: Int, _ latter: Int) -> PValue {
        if former == 500 || latter == 500 {
            return 0
        }
        return self.mmValue[former * self.midCount + latter]
    }

    /*
     文節の切れ目とは

     * 後置機能語→前置機能語
     * 後置機能語→内容語
     * 内容語→前置機能語
     * 内容語→内容語

     となる。逆に文節の切れ目にならないのは

     * 前置機能語→内容語
     * 内容語→後置機能語

     の二通りとなる。

     */
    /// class idから、文節かどうかを判断する関数。
    /// - Parameters:
    ///   - c_former: 左側の語のid
    ///   - c_latter: 右側の語のid
    /// - Returns:
    ///   そこが文節の境界であるかどうか。
    @inlinable static func isClause(_ former: Int, _ latter: Int) -> Bool {
        // EOSが基本多いので、この順の方がヒット率が上がると思われる。
        let latter_wordtype = Self.wordTypes[latter]
        if latter_wordtype == 3 {
            return false
        }
        let former_wordtype = Self.wordTypes[former]
        if former_wordtype == 3 {
            return false
        }
        if latter_wordtype == 0 {
            return former_wordtype != 0
        }
        if latter_wordtype == 1 {
            return former_wordtype != 0
        }
        return false
    }

    /// wordTypesの初期化時に使うのみ。
    private static let BOS_EOS_wordIDs: Set<Int> = [CIDData.BOS.cid, CIDData.EOS.cid]
    /// wordTypesの初期化時に使うのみ。
    private static let PREPOSITION_wordIDs: Set<Int> = [1315, 6, 557, 558, 559, 560]
    /// wordTypesの初期化時に使うのみ。
    private static let INPOSITION_wordIDs: Set<Int> = Set<Int>(
        Array(561..<868).chained(1283..<1297).chained(1306..<1310).chained(11..<53).chained(555..<557).chained(1281..<1283)
    ).union([1314, 3, 2, 4, 5, 1, 9])

    /*
     private static let POSTPOSITION_wordIDs: Set<Int> = Set<Int>((7...8).map{$0}
     + (54..<555).map{$0}
     + (868..<1281).map{$0}
     + (1297..<1306).map{$0}
     + (1310..<1314).map{$0}
     ).union([10])
     */

    /// - Returns:
    ///   - 3 when BOS/EOS
    ///   - 0 when preposition
    ///   - 1 when core
    ///   - 2 when postposition
    /// - データ1つあたり1Bなので、1.3KBくらいのメモリを利用する。
    public static let wordTypes = (0...1319).map(_judgeWordType)

    /// wordTypesの初期化時に使うのみ。
    private static func _judgeWordType(cid: Int) -> UInt8 {
        if Self.BOS_EOS_wordIDs.contains(cid) {
            return 3    // BOS/EOS
        }
        if Self.PREPOSITION_wordIDs.contains(cid) {
            return 0    // 前置
        }
        if Self.INPOSITION_wordIDs.contains(cid) {
            return 1 // 内容
        }
        return 2   // 後置
    }

    @inlinable static func includeMMValueCalculation(_ data: DicdataElement) -> Bool {
        // 非自立動詞
        if 895...1280 ~= data.lcid || 895...1280 ~= data.rcid {
            return true
        }
        // 非自立名詞
        if 1297...1305 ~= data.lcid || 1297...1305 ~= data.rcid {
            return true
        }
        // 内容語かどうか
        return wordTypes[data.lcid] == 1 || wordTypes[data.rcid] == 1
    }

    /// - データ1つあたり2Bなので、2.6KBくらいのメモリを利用する。
    static let penaltyRatio = (0...1319).map(_getTypoPenaltyRatio)

    /// penaltyRatioの初期化時に使うのみ。
    static func _getTypoPenaltyRatio(_ lcid: Int) -> PValue {
        // 助詞147...368, 助動詞369...554
        if 147...554 ~= lcid {
            return 2.5
        }
        return 1
    }

    /// 予測変換で終端になれない品詞id
    static let predictionUsable = (0...1319).map(_getPredictionUsable)
    /// penaltyRatioの初期化時に使うのみ。
    static func _getPredictionUsable(_ rcid: Int) -> Bool {
        // 連用タ接続
        // 次のコマンドにより機械的に生成`cat cid.txt | grep 連用タ | awk '{print $1}' | xargs -I {} echo -n "{}, "`
        if Set([33, 34, 50, 86, 87, 88, 103, 127, 128, 144, 397, 398, 408, 426, 427, 450, 457, 480, 687, 688, 703, 704, 727, 742, 750, 758, 766, 786, 787, 798, 810, 811, 829, 830, 831, 893, 973, 974, 975, 976, 977, 1007, 1008, 1009, 1010, 1063, 1182, 1183, 1184, 1185, 1186, 1187, 1188, 1189, 1190, 1191, 1192, 1193, 1194, 1240, 1241, 1242, 1243, 1268, 1269, 1270, 1271]).contains(rcid) {
            return false
        }
        // 仮定縮約
        // cat cid.txt | grep 仮定縮約 | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([15, 16, 17, 18, 41, 42, 59, 60, 61, 62, 63, 64, 94, 95, 109, 110, 111, 112, 135, 136, 379, 380, 381, 382, 402, 412, 413, 442, 443, 471, 472, 562, 572, 582, 591, 598, 618, 627, 677, 678, 693, 694, 709, 710, 722, 730, 737, 745, 753, 761, 770, 771, 791, 869, 878, 885, 896, 906, 917, 918, 932, 948, 949, 950, 951, 952, 987, 988, 989, 990, 1017, 1018, 1033, 1034, 1035, 1036, 1058, 1078, 1079, 1080, 1081, 1082, 1083, 1084, 1085, 1086, 1087, 1088, 1089, 1090, 1212, 1213, 1214, 1215]).contains(rcid) {
            return false
        }
        // 未然形
        // cat cid.txt | grep 未然形 | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([372, 406, 418, 419, 431, 437, 438, 455, 462, 463, 464, 495, 496, 504, 533, 534, 540, 551, 567, 577, 587, 595, 606, 614, 622, 630, 641, 647, 653, 659, 665, 672, 683, 684, 699, 700, 715, 716, 725, 733, 740, 748, 756, 764, 780, 781, 794, 806, 807, 823, 824, 825, 837, 842, 847, 852, 859, 865, 873, 881, 890, 901, 911, 925, 935, 963, 964, 965, 966, 967, 999, 1000, 1001, 1002, 1023, 1024, 1045, 1046, 1047, 1048, 1061, 1143, 1144, 1145, 1146, 1147, 1148, 1149, 1150, 1151, 1152, 1153, 1154, 1155, 1224, 1225, 1226, 1227, 1260, 1261, 1262, 1263, 1278]).contains(rcid) {
            return false
        }
        // 未然特殊
        // cat cid.txt | grep 未然特殊 | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([420, 421, 631, 782, 783, 795, 891, 936, 1156, 1157, 1158, 1159, 1160, 1161, 1162, 1163, 1164, 1165, 1166, 1167, 1168, 1228, 1229, 1230, 1231]).contains(rcid) {
            return false
        }
        // 未然ウ接続
        // cat cid.txt | grep 未然ウ接続 | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([25, 26, 46, 74, 75, 76, 99, 119, 120, 140, 389, 390, 405, 416, 417, 447, 476, 493, 494, 566, 576, 585, 594, 603, 621, 629, 671, 681, 682, 697, 698, 713, 714, 724, 732, 739, 747, 755, 763, 778, 779, 793, 804, 805, 820, 821, 822, 872, 880, 889, 900, 910, 923, 924, 934, 958, 959, 960, 961, 962, 995, 996, 997, 998, 1021, 1022, 1041, 1042, 1043, 1044, 1060, 1130, 1131, 1132, 1133, 1134, 1135, 1136, 1137, 1138, 1139, 1140, 1141, 1142, 1220, 1221, 1222, 1223, 1256, 1257, 1258, 1259]).contains(rcid) {
            return false
        }
        // 未然ヌ接続
        // cat cid.txt | grep 未然ヌ接続 | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([27, 28, 47, 77, 78, 79, 100, 121, 122, 141, 391, 392, 448, 477, 604]).contains(rcid) {
            return false
        }
        // 体言接続特殊
        // cat cid.txt | grep 体言接続特殊 | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([404, 564, 565, 574, 575, 600, 601, 620, 774, 775, 776, 777, 871, 887, 888, 898, 899, 908, 909, 921, 922, 1104, 1105, 1106, 1107, 1108, 1109, 1110, 1111, 1112, 1113, 1114, 1115, 1116, 1117, 1118, 1119, 1120, 1121, 1122, 1123, 1124, 1125, 1126, 1127, 1128, 1129]).contains(rcid) {
            return false
        }
        // 仮定形
        // cat cid.txt | grep 仮定形 | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([13, 14, 40, 56, 57, 58, 93, 107, 108, 134, 369, 377, 378, 401, 410, 411, 433, 434, 441, 452, 470, 483, 489, 490, 527, 528, 537, 542, 548, 561, 571, 581, 590, 597, 611, 617, 626, 636, 638, 644, 650, 656, 662, 668, 675, 676, 691, 692, 707, 708, 721, 729, 736, 744, 752, 760, 768, 769, 790, 800, 801, 814, 815, 816, 835, 840, 845, 850, 855, 862, 868, 877, 884, 895, 905, 915, 916, 931, 941, 943, 944, 945, 946, 947, 983, 984, 985, 986, 1015, 1016, 1029, 1030, 1031, 1032, 1057, 1065, 1066, 1067, 1068, 1069, 1070, 1071, 1072, 1073, 1074, 1075, 1076, 1077, 1208, 1209, 1210, 1211, 1248, 1249, 1250, 1251, 1276]).contains(rcid) {
            return false
        }
        // 「食べよ」のような命令形も除外する
        // 命令ｙｏ
        // cat cid.txt | grep 命令ｙｏ | awk '{print $1}' | xargs -I {} echo -n "{}, "
        if Set([373, 553, 569, 579, 589, 596, 609, 624, 634, 642, 648, 654, 660, 666, 673, 860, 866, 875, 903, 913, 928, 929, 939]).contains(rcid) {
            return false
        }
        return true
    }

    // 学習を有効にする語彙を決める。
    @inlinable static func needWValueMemory(_ data: DicdataElement) -> Bool {
        // 助詞、助動詞
        if 147...554 ~= data.lcid {
            return false
        }
        // 接頭辞
        if 557...560 ~= data.lcid {
            return false
        }
        // 接尾名詞を除去
        if 1297...1305 ~= data.lcid {
            return false
        }
        // 記号を除去
        if 6...9 ~= data.lcid {
            return false
        }
        if 0 == data.lcid || 1316 == data.lcid {
            return false
        }

        return true
    }

    static let possibleNexts: [String: [String]] = [
        "x": ["ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ", "ュ", "ョ", "ヮ"],
        "l": ["ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ", "ュ", "ョ", "ヮ"],
        "xt": ["ッ"],
        "lt": ["ッ"],
        "xts": ["ッ"],
        "lts": ["ッ"],
        "xy": ["ャ", "ュ", "ョ"],
        "ly": ["ャ", "ュ", "ョ"],
        "xw": ["ヮ"],
        "lw": ["ヮ"],
        "v": ["ヴ"],
        "k": ["カ", "キ", "ク", "ケ", "コ"],
        "q": ["クァ", "クィ", "クゥ", "クェ", "クォ"],
        "qy": ["クャ", "クィ", "クュ", "クェ", "クョ"],
        "qw": ["クヮ", "クィ", "クゥ", "クェ", "クォ"],
        "ky": ["キャ", "キィ", "キュ", "キェ", "キョ"],
        "g": ["ガ", "ギ", "グ", "ゲ", "ゴ"],
        "gy": ["ギャ", "ギィ", "ギュ", "ギェ", "ギョ"],
        "s": ["サ", "シ", "ス", "セ", "ソ"],
        "sy": ["シャ", "シィ", "シュ", "シェ", "ショ"],
        "sh": ["シャ", "シィ", "シュ", "シェ", "ショ"],
        "z": ["ザ", "ジ", "ズ", "ゼ", "ゾ"],
        "zy": ["ジャ", "ジィ", "ジュ", "ジェ", "ジョ"],
        "j": ["ジ"],
        "t": ["タ", "チ", "ツ", "テ", "ト"],
        "ty": ["チャ", "チィ", "チュ", "チェ", "チョ"],
        "ts": ["ツ"],
        "th": ["テャ", "ティ", "テュ", "テェ", "テョ"],
        "tw": ["トァ", "トィ", "トゥ", "トェ", "トォ"],
        "cy": ["チャ", "チィ", "チュ", "チェ", "チョ"],
        "ch": ["チ"],
        "d": ["ダ", "ヂ", "ヅ", "デ", "ド"],
        "dy": ["ヂャ", "ヂィ", "ヂュ", "ヂェ", "ヂョ"],
        "dh": ["デャ", "ディ", "デュ", "デェ", "デョ"],
        "dw": ["ドァ", "ドィ", "ドゥ", "ドェ", "ドォ"],
        "n": ["ナ", "ニ", "ヌ", "ネ", "ノ", "ン"],
        "ny": ["ニャ", "ニィ", "ニュ", "ニェ", "ニョ"],
        "h": ["ハ", "ヒ", "フ", "ヘ", "ホ"],
        "hy": ["ヒャ", "ヒィ", "ヒュ", "ヒェ", "ヒョ"],
        "hw": ["ファ", "フィ", "フェ", "フォ"],
        "f": ["フ"],
        "b": ["バ", "ビ", "ブ", "ベ", "ボ"],
        "by": ["ビャ", "ビィ", "ビュ", "ビェ", "ビョ"],
        "p": ["パ", "ピ", "プ", "ペ", "ポ"],
        "py": ["ピャ", "ピィ", "ピュ", "ピェ", "ピョ"],
        "m": ["マ", "ミ", "ム", "メ", "モ"],
        "my": ["ミャ", "ミィ", "ミュ", "ミェ", "ミョ"],
        "y": ["ヤ", "ユ", "イェ", "ヨ"],
        "r": ["ラ", "リ", "ル", "レ", "ロ"],
        "ry": ["リャ", "リィ", "リュ", "リェ", "リョ"],
        "w": ["ワ", "ウィ", "ウェ", "ヲ"],
        "wy": ["ヰ", "ヱ"]
    ]
}
