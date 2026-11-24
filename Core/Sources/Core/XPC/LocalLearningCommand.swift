import Foundation
import LearningCore

public typealias LocalTendency = LearningStore.Tendency

public enum LocalLearningCommand: Codable, Sendable {
    case observe(text: String, origin: LearningStore.Origin)
    case list
    case edit(key: String, value: String)
    case delete(key: String)
    case deleteAll
}
