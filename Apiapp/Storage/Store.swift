import Foundation

/// The tabs that were open, so they come back on the next launch.
struct WorkspaceState: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var id: UUID
        var draft: RequestDraft
        var baseline: RequestDraft
        var savedRequestID: UUID?
        var historyEntryID: UUID?
    }

    var tabs: [Tab] = []
    var activeTabID: UUID?
    var activeEnvironmentID: UUID?
}

/// Everything read from disk at launch.
struct LibrarySnapshot {
    var folders: [Folder] = []
    var requests: [SavedRequest] = []
    var history: [HistoryEntry] = []
    var responses: [SavedResponse] = []
    /// Nil when there is no environments file, and also when there is one that couldn't be read.
    var environments: [RequestEnvironment]?
    var workspace = WorkspaceState()
    /// Files and directories that couldn't be read, by name. Each file has a copy beside it ending in `.broken`.
    var unreadableFiles: [String] = []

    /// False after a partial read, when saving over what's on disk or cleaning up after it could lose data.
    var isComplete: Bool { unreadableFiles.isEmpty }
}

/// Plain JSON files, one per saved request, history entry and saved response:
///
///     requests/<id>.json   history/<id>.json   responses/<id>.json
///     folders.json         environments.json   workspace.json
struct Store {
    let root: URL

    /// Set when the app must leave the real data and Keychain alone: a folder given in
    /// `APIAPP_DATA_DIR`, or a throwaway one while running as the unit tests' host.
    static var isolatedRoot: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["APIAPP_DATA_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appending(path: "ApiappTestHost", directoryHint: .isDirectory)
        }
        return nil
    }

    static var defaultRoot: URL {
        isolatedRoot ?? URL.applicationSupportDirectory.appending(path: "Apiapp", directoryHint: .isDirectory)
    }

    private var requestsDirectory: URL { root.appending(path: "requests", directoryHint: .isDirectory) }
    private var historyDirectory: URL { root.appending(path: "history", directoryHint: .isDirectory) }
    private var responsesDirectory: URL { root.appending(path: "responses", directoryHint: .isDirectory) }
    private var foldersFile: URL { root.appending(path: "folders.json") }
    private var environmentsFile: URL { root.appending(path: "environments.json") }
    private var workspaceFile: URL { root.appending(path: "workspace.json") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func prepare() throws {
        for directory in [requestsDirectory, historyDirectory, responsesDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func load() throws -> LibrarySnapshot {
        try prepare()
        var snapshot = LibrarySnapshot()
        var unreadable: [String] = []
        snapshot.requests = readAll(in: requestsDirectory, unreadable: &unreadable)
        snapshot.history = readAll(in: historyDirectory, unreadable: &unreadable)
        snapshot.responses = readAll(in: responsesDirectory, unreadable: &unreadable)
        snapshot.folders = read(foldersFile, unreadable: &unreadable) ?? []
        snapshot.environments = read(environmentsFile, unreadable: &unreadable)
        snapshot.workspace = read(workspaceFile, unreadable: &unreadable) ?? WorkspaceState()
        snapshot.unreadableFiles = unreadable
        return snapshot
    }

    func save(_ request: SavedRequest) throws { try write(request, to: file(request.id, in: requestsDirectory)) }
    func save(_ entry: HistoryEntry) throws { try write(entry, to: file(entry.id, in: historyDirectory)) }
    func save(_ response: SavedResponse) throws { try write(response, to: file(response.id, in: responsesDirectory)) }
    func save(folders: [Folder]) throws { try write(folders, to: foldersFile) }
    func save(environments: [RequestEnvironment]) throws { try write(environments, to: environmentsFile) }
    func save(workspace: WorkspaceState) throws { try write(workspace, to: workspaceFile) }

    func delete(request id: UUID) throws { try remove(file(id, in: requestsDirectory)) }
    func delete(historyEntry id: UUID) throws { try remove(file(id, in: historyDirectory)) }
    func delete(response id: UUID) throws { try remove(file(id, in: responsesDirectory)) }

    private func file(_ id: UUID, in directory: URL) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    private func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func read<T: Decodable>(_ url: URL, unreadable: inout [String]) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Self.decoder.decode(T.self, from: Data(contentsOf: url))
        } catch {
            unreadable.append(url.lastPathComponent)
            keepCopy(of: url)
            return nil
        }
    }

    /// A file that can't be read stays where it is, but the app may save over it later, so
    /// a copy is kept beside it. The copy's `.broken` extension keeps it out of future reads.
    private func keepCopy(of url: URL) {
        let copy = url.appendingPathExtension("broken")
        guard !FileManager.default.fileExists(atPath: copy.path) else { return }
        try? FileManager.default.copyItem(at: url, to: copy)
    }

    private func readAll<T: Decodable>(in directory: URL, unreadable: inout [String]) -> [T] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            // Nothing in here was seen, which matters as much as a file that wouldn't parse.
            unreadable.append(directory.lastPathComponent + "/")
            return []
        }
        return files.filter { $0.pathExtension == "json" }.compactMap { read($0, unreadable: &unreadable) }
    }
}
