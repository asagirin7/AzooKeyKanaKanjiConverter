//
//  all.swift
//  Keyboard
//
//  Created by ensan on 2020/09/14.
//  Copyright © 2020 ensan. All rights reserved.
//

import Algorithms
import Foundation
import SwiftUtils

extension Kana2Kanji {
    /// カナを漢字に変換する関数, 前提はなくかな列が与えられた場合。
    /// - Parameters:
    ///   - inputData: 入力データ。
    ///   - N_best: N_best。
    /// - Returns:
    ///   変換候補。
    /// ### 実装状況
    /// (0)多用する変数の宣言。
    ///
    /// (1)まず、追加された一文字に繋がるノードを列挙する。
    ///
    /// (2)次に、計算済みノードから、(1)で求めたノードにつながるようにregisterして、N_bestを求めていく。
    ///
    /// (3)(1)のregisterされた結果をresultノードに追加していく。この際EOSとの連接計算を行っておく。
    ///
    /// (4)ノードをアップデートした上で返却する。
    func kana2lattice_all(_ inputData: ComposingText, N_best: Int, needTypoCorrection: Bool) -> (result: LatticeNode, lattice: Lattice) {
        debug("新規に計算を行います。inputされた文字列は\(inputData.input.count)文字分の\(inputData.convertTarget)")
        let result: LatticeNode = LatticeNode.EOSNode
        let inputCount: Int = inputData.input.count
        let surfaceCount = inputData.convertTarget.count
        let indexMap = LatticeDualIndexMap(inputData)
        let latticeIndices = indexMap.indices(inputCount: inputCount, surfaceCount: surfaceCount)
        let rawNodes = latticeIndices.map { index in
            let inputRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let iIndex = index.inputIndex {
                (iIndex, nil)
            } else {
                nil
            }
            let surfaceRange: (startIndex: Int, endIndexRange: Range<Int>?)? = if let sIndex = index.surfaceIndex {
                (sIndex, nil)
            } else {
                nil
            }
            return dicdataStore.lookupDicdata(
                composingText: inputData,
                inputRange: inputRange,
                surfaceRange: surfaceRange,
                needTypoCorrection: needTypoCorrection
            )
        }
        let lattice: Lattice = Lattice(
            inputCount: inputCount,
            surfaceCount: surfaceCount,
            rawNodes: rawNodes
        )
        // 「i文字目から始まるnodes」に対して
        for (isHead, nodeArray) in lattice.indexedNodes(indices: latticeIndices) {
            // それぞれのnodeに対して
            for node in nodeArray {
                if node.prevs.isEmpty {
                    continue
                }
                if self.dicdataStore.shouldBeRemoved(data: node.data) {
                    continue
                }
                // 生起確率を取得する。
                let wValue: PValue = node.data.value()
                if isHead {
                    // valuesを更新する
                    node.values = node.prevs.map {$0.totalValue + wValue + self.dicdataStore.getCCValue($0.data.rcid, node.data.lcid)}
                } else {
                    // valuesを更新する
                    node.values = node.prevs.map {$0.totalValue + wValue}
                }
                // 後続ノードのindex（正規化する）
                let nextIndex = indexMap.dualIndex(for: node.range.endIndex)
                // 文字数がcountと等しい場合登録する
                if nextIndex.inputIndex == inputCount && nextIndex.surfaceIndex == surfaceCount {
                    self.updateResultNode(with: node, resultNode: result)
                } else {
                    self.updateNextNodes(with: node, nextNodes: lattice[index: nextIndex], nBest: N_best)
                }
            }
        }
        return (result: result, lattice: lattice)
    }

    func updateResultNode(with node: LatticeNode, resultNode: LatticeNode) {
        for index in node.prevs.indices {
            let newnode: RegisteredNode = node.getRegisteredNode(index, value: node.values[index])
            resultNode.prevs.append(newnode)
        }
    }
    /// N-Best計算を高速に実行しつつ、遷移先ノードを更新する
    func updateNextNodes(with node: LatticeNode, nextNodes: some Sequence<LatticeNode>, nBest: Int) {
        for nextnode in nextNodes {
            if self.dicdataStore.shouldBeRemoved(data: nextnode.data) {
                continue
            }
            // クラスの連続確率を計算する。
            let ccValue: PValue = self.dicdataStore.getCCValue(node.data.rcid, nextnode.data.lcid)
            // nodeの持っている全てのprevnodeに対して
            for (index, value) in node.values.enumerated() {
                let newValue: PValue = ccValue + value
                // 追加すべきindexを取得する
                let lastindex: Int = (nextnode.prevs.lastIndex(where: {$0.totalValue >= newValue}) ?? -1) + 1
                let newnode: RegisteredNode = node.getRegisteredNode(index, value: newValue)
                _ = Self.register(newnode, at: lastindex, into: &nextnode.prevs, nBest: nBest)
            }
        }
    }

    /// 打ち間違いを直した語を含まない(打ったとおりの読みの)経路を、各ノードで少なくともこの数だけ残す。
    /// 直しの候補だけで N-Best が埋まると、打ったとおりの経路が途中で 1 つも残らなくなるため
    /// (「こくしてほしい」で 濃くしてほしい が、「にとべるように」で に飛べるように が消えていた)。
    static func exactReserve(nBest: Int) -> Int { max(1, nBest / 2) }

    /// `prevs`(totalValue の大きい順)の `index` に `node` を入れ、数を保つ。
    /// 上位 nBest 件に加えて、打ったとおりの経路は上位 exactReserve 件まで残す。入れなかったら false。
    static func register(_ node: RegisteredNode, at index: Int, into prevs: inout [RegisteredNode], nBest: Int) -> Bool {
        let reserve = exactReserve(nBest: nBest)
        if index >= nBest {
            // 上位 nBest 件に入らない。打ったとおりの経路で、前に打ったとおりの経路が reserve 件未満のときだけ入れる
            if node.hasTypoCorrection {
                return false
            }
            var exactBefore = 0
            for i in 0 ..< index where !prevs[i].hasTypoCorrection {
                exactBefore += 1
                if exactBefore >= reserve {
                    return false
                }
            }
        }
        prevs.insert(node, at: index)
        // あふれたら、守られていない(上位 nBest 件の外で、打ったとおりの上位 reserve 件でもない)ものを後ろから 1 つ除く
        guard prevs.count > nBest else {
            return true
        }
        var exactCount = 0
        var removable: Int? = nil
        for i in prevs.indices {
            let exact = !prevs[i].hasTypoCorrection
            if exact {
                exactCount += 1
            }
            if i >= nBest && !(exact && exactCount <= reserve) {
                removable = i
            }
        }
        if let removable {
            prevs.remove(at: removable)
        }
        return true
    }
}
