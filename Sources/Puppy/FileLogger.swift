import Foundation

public class FileLogger: BaseLogger {

    public enum FlushMode {
        case always
        case manual
    }
    public private(set) var flushMode: FlushMode

    private let filePermission: String
    private var uintPermission: UInt16 {
        return UInt16(filePermission, radix: 8)!
    }

    var fileHandle: FileHandle!
    let fileURL: URL

    public init(_ label: String, fileURL: URL, filePermission: String = "640", flushMode: FlushMode = .always) throws {
        self.fileURL = fileURL
        self.filePermission = filePermission
        self.flushMode = flushMode
        puppyDebug("initialized, fileURL: \(fileURL)")
        super.init(label)
        try validateFileURL(fileURL)
        try validateFilePermission(fileURL, filePermission: filePermission)
        try openFile()
    }

    deinit {
        closeFile()
    }

    public override func log(_ level: LogLevel, string: String) {
        do {
            _ = try fileHandle?.seekToEnd()
            if let data = (string + "\r\n").data(using: .utf8) {
                // swiftlint:disable force_try
                try! fileHandle?.write(contentsOf: data)
                // swiftlint:enable force_try
                if flushMode == .always {
                    try? fileHandle?.synchronize()
                }
            }
        } catch {
            print("error in seekToEnd, error: \(error.localizedDescription)")
        }
    }

    public func delete(_ url: URL) -> Result<URL, FileError> {
        queue!.sync {
            Result { try FileManager.default.removeItem(at: url) }
                .map { url }
                .mapError { _ in
                    FileError.deletingFailed(at: url)
                }
        }
    }

    public func delete(_ url: URL, completion: @escaping (Result<URL, FileError>) -> Void) {
        queue!.async {
            let result = Result { try FileManager.default.removeItem(at: url) }
                .map { url }
                .mapError { _ in
                    FileError.deletingFailed(at: url)
                }
            completion(result)
        }
    }

    public func flush() {
        queue!.sync {
            try? fileHandle?.synchronize()
        }
    }

    public func flush(completion: @escaping () -> Void) {
        queue!.async {
            try? self.fileHandle?.synchronize()
            completion()
        }
    }

    func openFile() throws {
        closeFile()
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            puppyDebug("created directoryURL, directoryURL: \(directoryURL)")
        } catch {
            throw FileError.creatingDirectoryFailed(at: directoryURL)
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let successful = FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [FileAttributeKey.posixPermissions: uintPermission])
            if successful {
                puppyDebug("succeeded in creating filePath")
            } else {
                throw FileError.creatingFileFailed(at: fileURL)
            }
        } else {
            puppyDebug("filePath exists, filePath: \(fileURL.path)")
        }

        if fileHandle == nil {
            do {
                fileHandle = try FileHandle(forWritingTo: fileURL)
            } catch {
                throw FileError.openingForWritingFailed(at: fileURL)
            }
        }
    }

    func closeFile() {
        if fileHandle != nil {
            try? fileHandle.synchronize()
            try? fileHandle.close()
            fileHandle = nil
        }
    }

    private func validateFileURL(_ url: URL) throws {
        if url.hasDirectoryPath {
            throw FileError.isNotFile(url: url)
        }
    }

    private func validateFilePermission(_ url: URL, filePermission: String) throws {
        let min = UInt16("000", radix: 8)!
        let max = UInt16("777", radix: 8)!
        if let uintPermission = UInt16(filePermission, radix: 8), uintPermission >= min, uintPermission <= max {
        } else {
            throw FileError.invalidPermission(at: url, filePermission: filePermission)
        }
    }
}
