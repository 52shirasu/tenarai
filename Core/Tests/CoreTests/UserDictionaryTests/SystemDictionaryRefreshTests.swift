import Foundation
import SQLite3
import Testing
@testable import Core

@Test func systemDictionaryRefreshReflectsDeletionAndRejectsBrokenStore() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("dictionary.db").path
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    #expect(sqlite3_exec(db, "CREATE TABLE ZTEXTREPLACEMENTENTRY (ZSHORTCUT TEXT, ZPHRASE TEXT, ZWASDELETED INTEGER); INSERT INTO ZTEXTREPLACEMENTENTRY VALUES ('まっく','Mac',0),('ふるい','Old',1);", nil, nil, nil) == SQLITE_OK)
    let first = try SystemUserDictionaryHelper.readDatabase(at: path)
    #expect(first.count == 1)
    #expect(first.first?.phrase == "Mac")
    #expect(sqlite3_exec(db, "UPDATE ZTEXTREPLACEMENTENTRY SET ZWASDELETED=1;", nil, nil, nil) == SQLITE_OK)
    #expect(try SystemUserDictionaryHelper.readDatabase(at: path).isEmpty)
    #expect(sqlite3_exec(db, "DROP TABLE ZTEXTREPLACEMENTENTRY;", nil, nil, nil) == SQLITE_OK)
    #expect(throws: SystemUserDictionaryHelper.FetchError.self) {
        try SystemUserDictionaryHelper.readDatabase(at: path)
    }
}
