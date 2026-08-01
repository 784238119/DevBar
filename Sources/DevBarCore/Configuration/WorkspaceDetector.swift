import Foundation

public struct DetectedService: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var service: ServiceConfig
    public let source: String

    public init(id: UUID = UUID(), service: ServiceConfig, source: String) {
        self.id = id
        self.service = service
        self.source = source
    }
}

public struct WorkspaceDetectionResult: Equatable, Sendable {
    public let rootDirectory: String
    public let services: [DetectedService]

    public init(rootDirectory: String, services: [DetectedService]) {
        self.rootDirectory = rootDirectory
        self.services = services
    }
}

public protocol WorkspaceDetecting: Sendable {
    func detect(in rootDirectory: URL) async -> WorkspaceDetectionResult
}

public struct WorkspaceDetector: WorkspaceDetecting, Sendable {
    private static let ignoredDirectoryNames: Set<String> = [
        ".git", ".build", ".gradle", ".idea", ".next", ".swiftpm", "build", "dist", "node_modules", "target"
    ]
    private static let preferredPackageScripts = ["dev", "start", "serve"]

    public init() {}

    public func detect(in rootDirectory: URL) async -> WorkspaceDetectionResult {
        let root = rootDirectory.standardizedFileURL
        return await Task.detached(priority: .userInitiated) {
            Self.detectSynchronously(in: root)
        }.value
    }

    static func detectSynchronously(
        in rootDirectory: URL,
        fileManager: FileManager = .default
    ) -> WorkspaceDetectionResult {
        let root = rootDirectory.standardizedFileURL
        var detected: [DetectedService] = []

        for directory in candidateDirectories(root: root, fileManager: fileManager) {
            if let service = packageService(in: directory, root: root) {
                detected.append(service)
            }
            if let service = mavenService(in: directory, root: root, fileManager: fileManager) {
                detected.append(service)
            }
            if let service = gradleService(in: directory, root: root, fileManager: fileManager) {
                detected.append(service)
            }
        }

        for filename in ["compose.yml", "compose.yaml", "docker-compose.yml", "docker-compose.yaml"] {
            let file = root.appending(path: filename, directoryHint: .notDirectory)
            guard fileManager.fileExists(atPath: file.path) else { continue }
            detected.append(
                DetectedService(
                    service: ServiceConfig(
                        name: "Compose",
                        workingDirectory: .relative("."),
                        command: "docker compose up",
                        includeInStartAll: false
                    ),
                    source: filename
                )
            )
            break
        }

        return WorkspaceDetectionResult(rootDirectory: root.path, services: removeDuplicates(detected))
    }

    private static func candidateDirectories(root: URL, fileManager: FileManager) -> [URL] {
        var directories = [root]
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return directories }

        for child in children.sorted(by: { $0.path < $1.path }) {
            guard !ignoredDirectoryNames.contains(child.lastPathComponent),
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else { continue }
            // Directory enumeration may resolve `/var` to `/private/var`. Keep every child
            // anchored to the exact root representation used by the workspace so relative
            // paths never depend on a symlink-expanded prefix.
            directories.append(root.appending(path: child.lastPathComponent, directoryHint: .isDirectory))
        }
        return directories
    }

    private static func packageService(in directory: URL, root: URL) -> DetectedService? {
        let file = directory.appending(path: "package.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any],
              let script = preferredPackageScripts.first(where: { scripts[$0] is String })
        else { return nil }

        let packageName = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DetectedService(
            service: ServiceConfig(
                name: displayName(packageName, directory: directory, root: root, fallback: "Node"),
                workingDirectory: relativeWorkingDirectory(directory, root: root),
                command: "npm run \(script)"
            ),
            source: sourceLabel(file, root: root)
        )
    }

    private static func mavenService(in directory: URL, root: URL, fileManager: FileManager) -> DetectedService? {
        let file = directory.appending(path: "pom.xml", directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: file.path),
              fileContains("spring-boot-maven-plugin", at: file)
        else { return nil }
        let wrapper = directory.appending(path: "mvnw", directoryHint: .notDirectory)
        return DetectedService(
            service: ServiceConfig(
                name: displayName(nil, directory: directory, root: root, fallback: "Maven"),
                workingDirectory: relativeWorkingDirectory(directory, root: root),
                command: fileManager.isExecutableFile(atPath: wrapper.path) ? "./mvnw spring-boot:run" : "mvn spring-boot:run"
            ),
            source: sourceLabel(file, root: root)
        )
    }

    private static func gradleService(in directory: URL, root: URL, fileManager: FileManager) -> DetectedService? {
        let filenames = ["build.gradle.kts", "build.gradle"]
        guard let filename = filenames.first(where: {
            fileManager.fileExists(atPath: directory.appending(path: $0, directoryHint: .notDirectory).path)
        }) else { return nil }
        let file = directory.appending(path: filename, directoryHint: .notDirectory)
        guard fileContains("org.springframework.boot", at: file) else { return nil }
        let wrapper = directory.appending(path: "gradlew", directoryHint: .notDirectory)
        return DetectedService(
            service: ServiceConfig(
                name: displayName(nil, directory: directory, root: root, fallback: "Gradle"),
                workingDirectory: relativeWorkingDirectory(directory, root: root),
                command: fileManager.isExecutableFile(atPath: wrapper.path) ? "./gradlew bootRun" : "gradle bootRun"
            ),
            source: sourceLabel(file, root: root)
        )
    }

    private static func displayName(_ explicit: String?, directory: URL, root: URL, fallback: String) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        return directory == root ? fallback : directory.lastPathComponent
    }

    private static func fileContains(_ marker: String, at file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
              let contents = String(data: data, encoding: .utf8)
        else { return false }
        return contents.contains(marker)
    }

    private static func relativeWorkingDirectory(_ directory: URL, root: URL) -> WorkingDirectory {
        guard directory != root else { return .relative(".") }
        return .relative(String(directory.path.dropFirst(root.path.count + 1)))
    }

    private static func sourceLabel(_ file: URL, root: URL) -> String {
        String(file.path.dropFirst(root.path.count + 1))
    }

    private static func removeDuplicates(_ services: [DetectedService]) -> [DetectedService] {
        var keys: Set<String> = []
        return services.filter { candidate in
            let key = "\(candidate.service.workingDirectory)|\(candidate.service.command)"
            return keys.insert(key).inserted
        }
    }
}
