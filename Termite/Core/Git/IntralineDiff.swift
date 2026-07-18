import Foundation

/// 行内(词级)diff:一对「删除行/新增行」里找出真正变化的中段。
/// 用共同前缀+后缀剥离(GitHub/delta 的主要可读性来源即此),中段整体标强调。
enum IntralineDiff {

    /// 返回两行各自「变化区间」的字符范围;整行相同 → 双 nil;完全不同 → 整行
    static func changedRanges(old: String, new: String) -> (old: Range<Int>?, new: Range<Int>?) {
        if old == new { return (nil, nil) }
        let oldChars = Array(old)
        let newChars = Array(new)

        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count, oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldChars.count - prefix, suffix < newChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }
        let oldRange = prefix..<(oldChars.count - suffix)
        let newRange = prefix..<(newChars.count - suffix)
        // 中段占比过高(≥90%)等于整行重写,强调反而降噪
        let oldRatio = old.isEmpty ? 1 : Double(oldRange.count) / Double(oldChars.count)
        let newRatio = new.isEmpty ? 1 : Double(newRange.count) / Double(newChars.count)
        if oldRatio > 0.9, newRatio > 0.9 { return (nil, nil) }
        return (oldRange.isEmpty ? nil : oldRange, newRange.isEmpty ? nil : newRange)
    }

    /// 把 hunk 的行序列按「连续删除块 + 紧随的连续新增块」配对,
    /// 返回 行索引 → 变化字符区间(仅当该行有可强调中段)
    static func emphasis(for lines: [UnifiedDiff.Line]) -> [Int: Range<Int>] {
        var result: [Int: Range<Int>] = [:]
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else {
                index += 1
                continue
            }
            var removed: [Int] = []
            while index < lines.count, lines[index].kind == .removed {
                removed.append(index)
                index += 1
            }
            var added: [Int] = []
            while index < lines.count, lines[index].kind == .added {
                added.append(index)
                index += 1
            }
            for pair in 0..<min(removed.count, added.count) {
                let oldLine = lines[removed[pair]].text
                let newLine = lines[added[pair]].text
                let ranges = changedRanges(old: oldLine, new: newLine)
                if let oldRange = ranges.old { result[removed[pair]] = oldRange }
                if let newRange = ranges.new { result[added[pair]] = newRange }
            }
        }
        return result
    }
}
