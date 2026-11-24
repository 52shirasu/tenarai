import Foundation

/// Explicit conversion only; no background work or input persistence.
enum DateTimeCandidates {
    static func suggestions(reading: String, now: Date = Date(), timeZone: TimeZone = .current) -> [String] {
        let text = reading.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? reading
        if (3...4).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) }),
           let hour = Int(text.dropLast(2)), let minute = Int(text.suffix(2)), hour < 24, minute < 60 {
            return [String(format: "%02d:%02d", hour, minute), "\(hour)時\(minute)分"]
        }
        let offsets = ["きょう": 0, "今日": 0, "ほんじつ": 0, "本日": 0,
                       "あした": 1, "あす": 1, "明日": 1,
                       "あさって": 2, "明後日": 2,
                       "きのう": -1, "昨日": -1, "おととい": -2, "一昨日": -2]
        guard let offset = offsets[text] else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { return [] }
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day, let weekday = parts.weekday else { return [] }
        let dayName = ["日", "月", "火", "水", "木", "金", "土"][weekday - 1]
        return [String(format: "%04d/%02d/%02d", year, month, day),
                String(format: "%04d-%02d-%02d", year, month, day),
                "\(month)月\(day)日", "\(month)月\(day)日（\(dayName)）"]
    }
}
