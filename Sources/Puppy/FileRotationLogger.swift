import Dispatch
import Foundation

public class FileRotationLogger: FileLoggerable {
    public let label: String
    public let queue: DispatchQueue
    public let logLevel: LogLevel
    public let logFormat: LogFormattable?

    public let fileURL: URL
    public let filePermission: String
    private var currentFileURL: URL

    let rotationConfig: RotationConfig
    private weak var delegate: FileRotationLoggerDelegate?

    private var dateFormat: DateFormatter

    public init(_ label: String, logLevel: LogLevel = .trace, logFormat: LogFormattable? = nil, fileURL: URL, filePermission: String = "640", dateFormatter: DateFormatter, rotationConfig: RotationConfig, delegate: FileRotationLoggerDelegate? = nil) throws {
        self.label = label
        self.queue = DispatchQueue(label: label)
        self.logLevel = logLevel
        self.logFormat = logFormat

        self.dateFormat = dateFormatter

        self.fileURL = fileURL
        puppyDebug("initialized, fileURL: \(fileURL)")
        self.filePermission = filePermission

        self.rotationConfig = rotationConfig
        self.delegate = delegate
        
        self.currentFileURL = fileURL
        
        self.currentFileURL = getCurrentFile(fileURL)
        try validateFileURL(currentFileURL)
        try validateFilePermission(currentFileURL, filePermission: filePermission)
        try openFile(currentFileURL)
    }

    public func log(_ level: LogLevel, string: String) {
        rotateFiles(currentFileURL)
        append(level, fileURL: currentFileURL, string: string)
        rotateFiles(currentFileURL)
    }
    
    private func getCurrentFile(_ fileURL: URL) -> URL {
        switch rotationConfig.fileRotateCreationStrategy {
        case .archive_old_files:
            return fileURL
        case .create_new_file:
            let archivedFiles = ascArchivedFileURLs(fileURL)
            return archivedFiles.last ?? fileURL
        }
    }

    private func fileSize(_ fileURL: URL) throws -> UInt64 {
        #if os(Windows)
        return try FileManager.default.windowsFileSize(atPath: fileURL.path)
        #else
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        // swiftlint:disable force_cast
        return attributes[.size] as! UInt64
        // swiftlint:enable force_cast
        #endif
    }

    private func rotateFiles(_ fileURL: URL) {
        guard let size = try? fileSize(fileURL), size > rotationConfig.maxFileSize else { return }
        
        switch rotationConfig.fileRotateCreationStrategy {
        case .archive_old_files:
            // Rotates old archived files.
            rotateOldArchivedFiles()
            
            // Archives the target file.
            archiveTargetFiles()
            
            // Removes extra archived files.
            removeArchivedFiles(fileURL, maxArchivedFilesCount: rotationConfig.maxArchivedFilesCount)
            
        case .create_new_file:
            switch rotationConfig.suffixExtension {
            case .numbering:
                let fileExtension = fileURL.pathExtension
                currentFileURL = currentFileURL.deletingPathExtension().appendingPathExtension("1").appendingPathExtension(fileExtension)
            case .date_uuid:
                let fileExtension = fileURL.pathExtension
                var fileName = fileURL.lastPathComponent
                fileName = fileName.replacingOccurrences(of: ".\(fileExtension)", with: "")
                fileName = fileName + "_" + dateFormatter(Date(), withFormatter: self.dateFormat) + "_" + UUID().uuidString.lowercased()
                currentFileURL = URL(string: fileURL.deletingLastPathComponent().absoluteString + "/" + fileName + fileExtension)!
            }
        }

        // Opens a new target file.
        do {
            puppyDebug("will openFile in rotateFiles")
            try openFile(currentFileURL)
        } catch {
            print("error in openFile while rotating, error: \(error.localizedDescription)")
        }
    }

    private func archiveTargetFiles() {
        do {
            var archivedFileURL: URL
            switch rotationConfig.suffixExtension {
            case .numbering:
                let fileExtension = fileURL.pathExtension
                archivedFileURL = fileURL.deletingPathExtension().appendingPathExtension("1").appendingPathExtension(fileExtension)
            case .date_uuid:
                archivedFileURL = fileURL.appendingPathExtension(dateFormatter(Date(), withFormatter: self.dateFormat) + "_" + UUID().uuidString.lowercased())
            }
            try FileManager.default.moveItem(at: fileURL, to: archivedFileURL)
            delegate?.fileRotationLogger(self, didArchiveFileURL: fileURL, toFileURL: archivedFileURL)
        } catch {
            print("error in archiving the target file, error: \(error.localizedDescription)")
        }
    }

    private func rotateOldArchivedFiles() {
        switch rotationConfig.suffixExtension {
        case .numbering:
            do {
                let oldArchivedFileURLs = ascArchivedFileURLs(fileURL)
                for (index, oldArchivedFileURL) in oldArchivedFileURLs.enumerated() {
                    let generationNumber = oldArchivedFileURLs.count + 1 - index
                    let fileExtension = fileURL.pathExtension
                    let rotatedFileURL = oldArchivedFileURL.deletingPathExtension().deletingPathExtension().appendingPathExtension("\(generationNumber)").appendingPathExtension(fileExtension)
                    puppyDebug("generationNumber: \(generationNumber), rotatedFileURL: \(rotatedFileURL)")
                    if !FileManager.default.fileExists(atPath: rotatedFileURL.path) {
                        try FileManager.default.moveItem(at: oldArchivedFileURL, to: rotatedFileURL)
                    }
                }
            } catch {
                print("error in rotating old archive files, error: \(error.localizedDescription)")
            }
        case .date_uuid:
            break
        }
    }

    private func ascArchivedFileURLs(_ fileURL: URL) -> [URL] {
        var ascArchivedFileURLs: [URL] = []
        do {
            let archivedDirectoryURL: URL = fileURL.deletingLastPathComponent()
            let archivedFileURLs = try FileManager.default.contentsOfDirectory(atPath: archivedDirectoryURL.path)
                .map { archivedDirectoryURL.appendingPathComponent($0) }
                .filter { $0 != fileURL && $0.deletingPathExtension() == fileURL }

            ascArchivedFileURLs = try archivedFileURLs.sorted {
                #if os(Windows)
                let modificationTime0 = try FileManager.default.windowsModificationTime(atPath: $0.path)
                let modificationTime1 = try FileManager.default.windowsModificationTime(atPath: $1.path)
                return modificationTime0 < modificationTime1
                #else
                // swiftlint:disable force_cast
                let modificationDate0 = try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as! Date
                let modificationDate1 = try FileManager.default.attributesOfItem(atPath: $1.path)[.modificationDate] as! Date
                // swiftlint:enable force_cast
                return modificationDate0.timeIntervalSince1970 < modificationDate1.timeIntervalSince1970
                #endif
            }
        } catch {
            print("error in ascArchivedFileURLs, error: \(error.localizedDescription)")
        }
        puppyDebug("ascArchivedFileURLs: \(ascArchivedFileURLs)")
        return ascArchivedFileURLs
    }

    private func removeArchivedFiles(_ fileURL: URL, maxArchivedFilesCount: UInt8) {
        do {
            let archivedFileURLs = ascArchivedFileURLs(fileURL)
            if archivedFileURLs.count > maxArchivedFilesCount {
                for index in 0 ..< archivedFileURLs.count - Int(maxArchivedFilesCount) {
                    puppyDebug("\(archivedFileURLs[index]) will be removed...")
                    try FileManager.default.removeItem(at: archivedFileURLs[index])
                    puppyDebug("\(archivedFileURLs[index]) has been removed")
                    delegate?.fileRotationLogger(self, didRemoveArchivedFileURL: archivedFileURLs[index])
                }
            }
        } catch {
            print("error in removing extra archived files, error: \(error.localizedDescription)")
        }
    }
}

public struct RotationConfig: Sendable {
    public enum SuffixExtension: Sendable {
        case numbering
        case date_uuid
    }
    public var suffixExtension: SuffixExtension
    
    public enum FileRotateCreationStrategy: Sendable {
        case archive_old_files
        case create_new_file
    }
    public var fileRotateCreationStrategy: FileRotateCreationStrategy

    public typealias ByteCount = UInt64
    public var maxFileSize: ByteCount
    public var maxArchivedFilesCount: UInt8

    public init(suffixExtension: SuffixExtension = .numbering, maxFileSize: ByteCount = 10 * 1024 * 1024, maxArchivedFilesCount: UInt8 = 5, fileRotateCreationStrategy: FileRotateCreationStrategy = .archive_old_files) {
        self.suffixExtension = suffixExtension
        self.maxFileSize = maxFileSize
        self.maxArchivedFilesCount = maxArchivedFilesCount
        self.fileRotateCreationStrategy = fileRotateCreationStrategy
    }
}

public protocol FileRotationLoggerDelegate: AnyObject, Sendable {
    func fileRotationLogger(_ fileRotationLogger: FileRotationLogger, didArchiveFileURL: URL, toFileURL: URL)
    func fileRotationLogger(_ fileRotationLogger: FileRotationLogger, didRemoveArchivedFileURL: URL)
}
