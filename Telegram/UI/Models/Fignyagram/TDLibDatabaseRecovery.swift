import Foundation

/// Protects startup from a corrupted TDLib binlog (td::Binlog::do_reindex ->
/// process_fatal_error). A clean-exit marker distinguishes a normal launch from
/// a crash; an unclean database is rebuilt from the server instead of crashing.
enum TDLibDatabaseRecovery {
    private static let markerName = ".fny_clean_exit"
    private static let runningName = ".fny_running"

    static func databaseFiles(in directory: String) -> [String] {
        let names = ["tdlib.binlog", "tdlib.binlog.0", "db.sqlite", "db.sqlite-wal", "db.sqlite-shm"]
        return names.map { (directory as NSString).appendingPathComponent($0) }
    }

    /// Call before creating the TDLib client. Returns true when the cache was reset.
    @discardableResult
    static func prepare(databaseDirectory: String) -> Bool {
        let fm = FileManager.default
        let marker = (databaseDirectory as NSString).appendingPathComponent(markerName)
        let running = (databaseDirectory as NSString).appendingPathComponent(runningName)
        let binlog = (databaseDirectory as NSString).appendingPathComponent("tdlib.binlog")
        let hasDatabase = fm.fileExists(atPath: binlog)
        let clean = !fm.fileExists(atPath: running)

        if hasDatabase && !clean {
            for path in databaseFiles(in: databaseDirectory) {
                try? fm.removeItem(atPath: path)
            }
            CallDiag.log("tdlib recovery: corrupt binlog evicted at \(databaseDirectory)")
            CrashTrace.step("tdlib recovery: cache evicted")
            return true
        }
        try? fm.removeItem(atPath: marker)
        // Mark the database as in-use: if the process dies, the marker stays and
        // the next launch rebuilds the cache instead of aborting in binlog.
        fm.createFile(atPath: running, contents: Data(), attributes: nil)
        return false
    }

    /// Call once the client is authorized and the database is known-good.
    static func markClean(databaseDirectory: String) {
        let fm = FileManager.default
        let running = (databaseDirectory as NSString).appendingPathComponent(runningName)
        try? fm.removeItem(atPath: running)
        let marker = (databaseDirectory as NSString).appendingPathComponent(markerName)
        try? Data().write(to: URL(fileURLWithPath: marker))
    }
}

// placeholder to force rebuild
