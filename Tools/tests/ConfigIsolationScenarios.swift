import Foundation
let key = "local.tenarai.inputmethod.tenarai.preference.learning"
precondition(Config.testSuiteName != nil)
let suite = Config.testSuiteName!
Config.userDefaults.removePersistentDomain(forName: suite)
precondition(Config.data(forKey: key) == nil)
// Even the process-standard fallback must not leak into isolated settings.
UserDefaults.standard.set("standard-sentinel", forKey: "isolationProbe")
precondition(Config.string(forKey: "isolationProbe") == nil)
Config.set(Data("\"nothing\"".utf8), forKey: key)
precondition(Config.data(forKey: key) == Data("\"nothing\"".utf8))
Config.set(5, forKey: "local.tenarai.inputmethod.tenarai.preference.zenzaiInferenceLimit")
precondition(Config.object(forKey: "local.tenarai.inputmethod.tenarai.preference.zenzaiInferenceLimit") as? Int == 5)
Config.userDefaults.removePersistentDomain(forName: suite)
UserDefaults.standard.removeObject(forKey: "isolationProbe")
print("PASS isolated read/write, standard fallback excluded")
