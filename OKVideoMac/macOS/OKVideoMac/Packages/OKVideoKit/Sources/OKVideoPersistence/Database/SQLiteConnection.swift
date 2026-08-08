import Foundation
import CSQLite
import OKVideoCore

final class SQLiteConnection {
    private var handle: OpaquePointer?
    let url: URL

    init(url: URL) throws {
        self.url = url
        let result = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 返回 \(result)"
            if let handle {
                sqlite3_close(handle)
            }
            self.handle = nil
            throw AppError.database("无法打开数据库：\(message)")
        }
        sqlite3_extended_result_codes(handle, 1)
    }

    deinit {
        close()
    }

    func close() {
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw databaseError(prefix: "执行 SQL 失败")
        }
    }

    func query(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        row: (OpaquePointer) throws -> Void
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                try row(statement)
            } else if result == SQLITE_DONE {
                return
            } else {
                throw databaseError(prefix: "查询 SQL 失败")
            }
        }
    }

    func scalarInt(_ sql: String) throws -> Int {
        var value = 0
        try query(sql) { statement in
            value = Int(sqlite3_column_int64(statement, 0))
        }
        return value
    }

    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let value = try work()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func lastChangedRowCount() -> Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: pointer)
    }

    func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else {
            throw AppError.database("数据库连接已关闭")
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw databaseError(prefix: "准备 SQL 失败")
        }
        return statement
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case .blob(let value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        bytes.baseAddress,
                        Int32(value.count),
                        sqliteTransient
                    )
                }
            }
            guard result == SQLITE_OK else {
                throw databaseError(prefix: "绑定 SQL 参数 \(index) 失败")
            }
        }
    }

    private func databaseError(prefix: String) -> AppError {
        let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "未知 SQLite 错误"
        return .database("\(prefix)：\(message)")
    }
}

enum SQLiteBinding {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    static func optional(_ value: String?) -> SQLiteBinding {
        value.map(SQLiteBinding.text) ?? .null
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

