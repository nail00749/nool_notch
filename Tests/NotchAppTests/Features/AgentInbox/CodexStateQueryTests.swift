import Foundation
import SQLite3
import XCTest
@testable import NotchApp

final class CodexStateQueryTests: XCTestCase {
    func testIndexedSelectionPreservesFilteringLimitAndTimes() throws {
        let fixture = try Fixture()
        try fixture.execute("""
            INSERT INTO threads VALUES ('old',0,'vscode',1000,1),
                ('new',0,'appServer',3000,3), ('middle',0,'vscode',2000,2),
                ('cli',0,'cli',5000,5), ('archived',1,'vscode',6000,6);
            CREATE INDEX "time""index" ON threads(updated_at_ms DESC, id DESC);
            """)
        XCTAssertEqual(fixture.indexOrder?.index, "time\"index")
        let indexed = try fixture.sessions(limit: 2)
        XCTAssertEqual(indexed.map(\.id.sessionID), ["new", "middle"])
        try fixture.execute("DROP INDEX \"time\"\"index\";")
        XCTAssertNil(fixture.indexOrder)
        let legacy = try fixture.sessions(limit: 2)
        XCTAssertEqual(indexed.map(\.id), legacy.map(\.id))
        XCTAssertEqual(indexed.map(\.lastActivity), legacy.map(\.lastActivity))
    }

    func testExceptionalTimestampsUseOriginalFallbackQuery() throws {
        for value in ["NULL", "0", "'not-a-time'", "1.25", "4503599627370497", "-4503599627370497"] {
            let fixture = try Fixture()
            try fixture.execute("""
                INSERT INTO threads VALUES ('ordinary',0,'vscode',2000,2),
                    ('exceptional',0,'vscode',\(value),9000);
                CREATE INDEX time_index ON threads(updated_at_ms DESC);
                """)
            XCTAssertNil(fixture.indexOrder, "Unsafe indexed ordering for \(value)")
            let withIndex = try fixture.sessions()
            try fixture.execute("DROP INDEX time_index;")
            let withoutIndex = try fixture.sessions()
            XCTAssertEqual(withIndex.map(\.id), withoutIndex.map(\.id))
            XCTAssertEqual(withIndex.map(\.lastActivity), withoutIndex.map(\.lastActivity))
            if value == "NULL" || value == "0" {
                XCTAssertEqual(withIndex.first?.id.sessionID, "exceptional")
                XCTAssertEqual(withIndex.first?.lastActivity, Date(timeIntervalSince1970: 9000))
            }
        }
    }

    func testDuplicateTimesAndPartialIndexesRetainLegacyOrdering() throws {
        let fixture = try Fixture()
        try fixture.execute("""
            INSERT INTO threads VALUES ('first',0,'vscode',2000,2), ('second',0,'vscode',2000,2);
            CREATE INDEX time_index ON threads(updated_at_ms DESC, id DESC);
            """)
        XCTAssertNil(fixture.indexOrder)
        let indexed = try fixture.sessions(limit: 1)
        try fixture.execute("DROP INDEX time_index;")
        XCTAssertEqual(indexed.map(\.id), try fixture.sessions(limit: 1).map(\.id))
        try fixture.execute("""
            UPDATE threads SET updated_at_ms=3000 WHERE id='second';
            CREATE INDEX partial_time ON threads(updated_at_ms) WHERE source='cli';
            """)
        XCTAssertNil(fixture.indexOrder)
        XCTAssertEqual(try fixture.sessions(limit: 1).first?.id.sessionID, "second")
    }

    func testPrimaryTimestampPriorityIsNotReplacedBySecondaryIndex() throws {
        let fixture = try Fixture()
        try fixture.execute("""
            INSERT INTO threads VALUES ('recent',0,'vscode',1000,1), ('updated',0,'vscode',5000,5);
            ALTER TABLE threads ADD COLUMN recency_at_ms INTEGER;
            UPDATE threads SET recency_at_ms=9000 WHERE id='recent';
            UPDATE threads SET recency_at_ms=2000 WHERE id='updated';
            CREATE INDEX secondary_time ON threads(updated_at_ms DESC);
            """)
        let columns: Set<String> = ["recency_at_ms", "updated_at_ms", "updated_at"]
        XCTAssertNil(CodexStateReader.indexedTimestampOrder(database: fixture.database, columns: columns))
        XCTAssertEqual(try fixture.sessions(limit: 1).first?.id.sessionID, "recent")
        try fixture.execute("CREATE INDEX primary_time ON threads(recency_at_ms DESC);")
        XCTAssertEqual(CodexStateReader.indexedTimestampOrder(database: fixture.database, columns: columns)?.column,
                       "recency_at_ms")
        XCTAssertEqual(try fixture.sessions(limit: 1).first?.id.sessionID, "recent")
    }

    private final class Fixture {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nool-query-\(UUID().uuidString).sqlite")
        let database: OpaquePointer

        init() throws {
            var handle: OpaquePointer?
            guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
                if let handle { sqlite3_close(handle) }
                throw CodexStateReaderError.databaseUnavailable
            }
            database = handle
            try execute("CREATE TABLE threads(id TEXT PRIMARY KEY, archived INTEGER, source TEXT, updated_at_ms INTEGER, updated_at INTEGER);")
        }

        deinit {
            sqlite3_close(database)
            try? FileManager.default.removeItem(at: url)
        }

        var indexOrder: (column: String, index: String)? {
            CodexStateReader.indexedTimestampOrder(database: database, columns: ["updated_at_ms", "updated_at"])
        }

        func sessions(limit: Int = 50) throws -> [AISession] {
            try CodexStateReader(databaseURL: url, maximumCandidateCount: limit)
                .loadSessions(now: Date(timeIntervalSince1970: 10000))
        }

        func execute(_ sql: String) throws {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw CodexStateReaderError.queryFailed
            }
        }
    }
}
