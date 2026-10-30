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

        // A zero-sized binlog is also a hard fault (interrupted reindex).
        var truncated = false
        if hasDatabase,
           let attrs = try? fm.attributesOfItem(atPath: binlog),
           (attrs[.size] as? NSNumber)?.intValue ?? 0 < 16 {
            truncated = true
        }

        if (hasDatabase && !clean) || truncated {
            purgeCorruptedDatabase(databaseDirectory)
            return true
        }
        try? fm.removeItem(atPath: marker)
        // Mark the database as in-use: if the process dies, the marker stays and
        // the next launch rebuilds the cache instead of aborting in binlog.
        fm.createFile(atPath: running, contents: Data(), attributes: nil)
        return false
    }

    /// Removes the whole cache directory and recreates it empty. TDLib then
    /// builds a fresh database and re-syncs chats from the server.
    static func purgeCorruptedDatabase(_ databaseDirectory: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: databaseDirectory)
        try? fm.createDirectory(atPath: databaseDirectory, withIntermediateDirectories: true)
        CallDiag.log("tdlib recovery: database purged at \(databaseDirectory)")
        CrashTrace.step("tdlib recovery: database purged")
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
