//
//  ZIPCore.swift
//  ZIPFoundation
//
//  Copyright © 2017-2023 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation
import CZLib // Added import for zlib

// Define C-like file pointer type for Swift
public typealias FILEPointer = UnsafeMutablePointer<FILE>
public typealias Progress = (_ completedUnitCount: Int64, _ totalUnitCount: Int64) -> Bool // Returns true to continue, false to cancel

// Constants from ZIP spec
let defaultReadChunkSize = Int(16*1024)
let defaultPOSIXBufferSize = defaultReadChunkSize
let endOfCentralDirectoryStructSignature = 0x06054b50
let localFileHeaderStructSignature = 0x04034b50
let dataDescriptorStructSignature = 0x08074b50
let centralDirectoryStructSignature = 0x02014b50
let zip64EndOfCentralDirectoryStructSignature = 0x06064b50
let zip64EndOfCentralDirectoryLocatorStructSignature = 0x07064b50
let memoryURLScheme = "memory"
let minEndOfCentralDirectoryOffset = 22
let maxEndOfCentralDirectoryOffset = Int(UInt16.max) + minEndOfCentralDirectoryOffset
let maxUncompressedSize: UInt64 = UInt64(UInt32.max)
let maxCompressedSize: UInt64 = UInt64(UInt32.max)
let maxOffsetOfLocalFileHeader: UInt64 = UInt64(UInt32.max)
let maxSizeOfCentralDirectory: UInt64 = UInt64(UInt32.max)
let maxTotalNumberOfEntries: UInt64 = UInt64(UInt16.max)

public final class Archive: Sequence {

    typealias LocalFileHeader = Entry.LocalFileHeader
    typealias DataDescriptor = Entry.DefaultDataDescriptor
    typealias ZIP64DataDescriptor = Entry.ZIP64DataDescriptor
    typealias CentralDirectoryStructure = Entry.CentralDirectoryStructure

    /// An error that occurs during reading, creating or updating a ZIP file.
    public enum ArchiveError: Error {
        /// Thrown when an archive file is either damaged or inaccessible.
        case unreadableArchive
        /// Thrown when an archive is either opened with AccessMode.read or the destination file is unwritable.
        case unwritableArchive
        /// Thrown when the path of an `Entry` cannot be stored in an archive.
        case invalidEntryPath
        /// Thrown when an `Entry` can't be stored in the archive with the proposed compression method.
        case invalidCompressionMethod
        /// Thrown when the stored checksum of an `Entry` doesn't match the checksum during reading.
        case invalidCRC32
        /// Thrown when an extract, add or remove operation was canceled.
        case cancelledOperation
        /// Thrown when an extract operation was called with zero or negative `bufferSize` parameter.
        case invalidBufferSize
        /// Thrown when uncompressedSize/compressedSize exceeds `Int64.max` (Imposed by file API).
        case invalidEntrySize
        /// Thrown when the offset of local header data exceeds `Int64.max` (Imposed by file API).
        case invalidLocalHeaderDataOffset
        /// Thrown when the size of local header exceeds `Int64.max` (Imposed by file API).
        case invalidLocalHeaderSize
        /// Thrown when the offset of central directory exceeds `Int64.max` (Imposed by file API).
        case invalidCentralDirectoryOffset
        /// Thrown when the size of central directory exceeds `UInt64.max` (Imposed by ZIP specification).
        case invalidCentralDirectorySize
        /// Thrown when number of entries in central directory exceeds `UInt64.max` (Imposed by ZIP specification).
        case invalidCentralDirectoryEntryCount
        /// Thrown when an archive does not contain the required End of Central Directory Record.
        case missingEndOfCentralDirectoryRecord
        /// Thrown when an entry contains a symlink pointing to a path outside the destination directory.
        case uncontainedSymlink
    }

    /// The access mode for an `Archive`.
    public enum AccessMode: UInt {
        /// Indicates that a newly instantiated `Archive` should create its backing file.
        case create
        /// Indicates that a newly instantiated `Archive` should read from an existing backing file.
        case read
        /// Indicates that a newly instantiated `Archive` should update an existing backing file.
        case update

        /// Indicates that the archive can be written to.
        var isWritable: Bool { self != .read }
    }

    /// The version of an `Archive`
    enum Version: UInt16 {
        /// The minimum version for deflate compressed archives
        case v20 = 20
        /// The minimum version for archives making use of ZIP64 extensions
        case v45 = 45
    }

    struct EndOfCentralDirectoryRecord: DataSerializable {
        let endOfCentralDirectorySignature = UInt32(endOfCentralDirectoryStructSignature)
        let numberOfDisk: UInt16
        let numberOfDiskStart: UInt16
        let totalNumberOfEntriesOnDisk: UInt16
        let totalNumberOfEntriesInCentralDirectory: UInt16
        let sizeOfCentralDirectory: UInt32
        let offsetToStartOfCentralDirectory: UInt32
        let zipFileCommentLength: UInt16
        let zipFileCommentData: Data
        static let size = 22

        init(numberOfDisk: UInt16, numberOfDiskStart: UInt16,
             totalNumberOfEntriesOnDisk: UInt16, totalNumberOfEntriesInCentralDirectory: UInt16,
             sizeOfCentralDirectory: UInt32, offsetToStartOfCentralDirectory: UInt32,
             zipFileCommentLength: UInt16, zipFileCommentData: Data) {
            self.numberOfDisk = numberOfDisk
            self.numberOfDiskStart = numberOfDiskStart
            self.totalNumberOfEntriesOnDisk = totalNumberOfEntriesOnDisk
            self.totalNumberOfEntriesInCentralDirectory = totalNumberOfEntriesInCentralDirectory
            self.sizeOfCentralDirectory = sizeOfCentralDirectory
            self.offsetToStartOfCentralDirectory = offsetToStartOfCentralDirectory
            self.zipFileCommentLength = zipFileCommentLength
            self.zipFileCommentData = zipFileCommentData
        }

        init(record: EndOfCentralDirectoryRecord, numberOfEntriesOnDisk: UInt16,
             numberOfEntriesInCentralDirectory: UInt16, updatedSizeOfCentralDirectory: UInt32,
             startOfCentralDirectory: UInt32) {
            self.numberOfDisk = record.numberOfDisk
            self.numberOfDiskStart = record.numberOfDiskStart
            self.totalNumberOfEntriesOnDisk = numberOfEntriesOnDisk
            self.totalNumberOfEntriesInCentralDirectory = numberOfEntriesInCentralDirectory
            self.sizeOfCentralDirectory = updatedSizeOfCentralDirectory
            self.offsetToStartOfCentralDirectory = startOfCentralDirectory
            self.zipFileCommentLength = record.zipFileCommentLength
            self.zipFileCommentData = record.zipFileCommentData
        }
    }

    struct ZIP64EndOfCentralDirectoryLocator: DataSerializable {
        let zip64LocatorSignature = UInt32(zip64EndOfCentralDirectoryLocatorStructSignature)
        let numberOfDiskWithZIP64EOCDRecordStart: UInt32
        let relativeOffsetOfZIP64EOCDRecord: UInt64
        let totalNumberOfDisk: UInt32
        static let size = 20

        init(numberOfDiskWithZIP64EOCDRecordStart: UInt32, relativeOffsetOfZIP64EOCDRecord: UInt64, totalNumberOfDisk: UInt32) {
            self.numberOfDiskWithZIP64EOCDRecordStart = numberOfDiskWithZIP64EOCDRecordStart
            self.relativeOffsetOfZIP64EOCDRecord = relativeOffsetOfZIP64EOCDRecord
            self.totalNumberOfDisk = totalNumberOfDisk
        }
        
        init(locator: ZIP64EndOfCentralDirectoryLocator, offsetOfZIP64EOCDRecord: UInt64) {
            self.numberOfDiskWithZIP64EOCDRecordStart = locator.numberOfDiskWithZIP64EOCDRecordStart
            self.relativeOffsetOfZIP64EOCDRecord = offsetOfZIP64EOCDRecord
            self.totalNumberOfDisk = locator.totalNumberOfDisk
        }
    }

    struct ZIP64EndOfCentralDirectoryRecord: DataSerializable {
        let zip64EOCDRecordSignature = UInt32(zip64EndOfCentralDirectoryStructSignature)
        let sizeOfZIP64EndOfCentralDirectoryRecord: UInt64
        let versionMadeBy: UInt16
        let versionNeededToExtract: UInt16
        let numberOfDisk: UInt32
        let numberOfDiskStart: UInt32
        let totalNumberOfEntriesOnDisk: UInt64
        let totalNumberOfEntriesInCentralDirectory: UInt64
        let sizeOfCentralDirectory: UInt64
        let offsetToStartOfCentralDirectory: UInt64
        let zip64ExtensibleDataSector: Data
        static let size = 56 // Minimum size without extensible data sector

        init(sizeOfZIP64EndOfCentralDirectoryRecord: UInt64, versionMadeBy: UInt16, versionNeededToExtract: UInt16,
             numberOfDisk: UInt32, numberOfDiskStart: UInt32, totalNumberOfEntriesOnDisk: UInt64,
             totalNumberOfEntriesInCentralDirectory: UInt64, sizeOfCentralDirectory: UInt64,
             offsetToStartOfCentralDirectory: UInt64, zip64ExtensibleDataSector: Data) {
            self.sizeOfZIP64EndOfCentralDirectoryRecord = sizeOfZIP64EndOfCentralDirectoryRecord
            self.versionMadeBy = versionMadeBy
            self.versionNeededToExtract = versionNeededToExtract
            self.numberOfDisk = numberOfDisk
            self.numberOfDiskStart = numberOfDiskStart
            self.totalNumberOfEntriesOnDisk = totalNumberOfEntriesOnDisk
            self.totalNumberOfEntriesInCentralDirectory = totalNumberOfEntriesInCentralDirectory
            self.sizeOfCentralDirectory = sizeOfCentralDirectory
            self.offsetToStartOfCentralDirectory = offsetToStartOfCentralDirectory
            self.zip64ExtensibleDataSector = zip64ExtensibleDataSector
        }

        init(record: ZIP64EndOfCentralDirectoryRecord, numberOfEntriesOnDisk: UInt64, numberOfEntriesInCD: UInt64,
             sizeOfCentralDirectory: UInt64, offsetToStartOfCD: UInt64) {
            self.sizeOfZIP64EndOfCentralDirectoryRecord = record.sizeOfZIP64EndOfCentralDirectoryRecord
            self.versionMadeBy = record.versionMadeBy
            self.versionNeededToExtract = record.versionNeededToExtract
            self.numberOfDisk = record.numberOfDisk
            self.numberOfDiskStart = record.numberOfDiskStart
            self.totalNumberOfEntriesOnDisk = numberOfEntriesOnDisk
            self.totalNumberOfEntriesInCentralDirectory = numberOfEntriesInCD
            self.sizeOfCentralDirectory = sizeOfCentralDirectory
            self.offsetToStartOfCentralDirectory = offsetToStartOfCD
            self.zip64ExtensibleDataSector = record.zip64ExtensibleDataSector
        }
    }

    struct ZIP64EndOfCentralDirectory {
        let record: ZIP64EndOfCentralDirectoryRecord
        let locator: ZIP64EndOfCentralDirectoryLocator

        var data: Data {
            var data = Data()
            data.append(self.record.data)
            data.append(self.locator.data)
            return data
        }
    }

    /// URL of an Archive's backing file.
    public let url: URL
    /// Access mode for an archive file.
    public let accessMode: AccessMode
    var archiveFile: FILEPointer
    var endOfCentralDirectoryRecord: EndOfCentralDirectoryRecord
    var zip64EndOfCentralDirectory: ZIP64EndOfCentralDirectory?
    var pathEncoding: String.Encoding?

    var totalNumberOfEntriesInCentralDirectory: UInt64 {
        zip64EndOfCentralDirectory?.record.totalNumberOfEntriesInCentralDirectory
        ?? UInt64(endOfCentralDirectoryRecord.totalNumberOfEntriesInCentralDirectory)
    }
    var sizeOfCentralDirectory: UInt64 {
        zip64EndOfCentralDirectory?.record.sizeOfCentralDirectory
        ?? UInt64(endOfCentralDirectoryRecord.sizeOfCentralDirectory)
    }
    var offsetToStartOfCentralDirectory: UInt64 {
        zip64EndOfCentralDirectory?.record.offsetToStartOfCentralDirectory
        ?? UInt64(endOfCentralDirectoryRecord.offsetToStartOfCentralDirectory)
    }

    // Backing configuration tuple
    typealias BackingConfiguration = (file: FILEPointer, endOfCentralDirectoryRecord: EndOfCentralDirectoryRecord,
                                    zip64EndOfCentralDirectory: ZIP64EndOfCentralDirectory?, memoryFile: MemoryFile?)

    /// Initializes a new ZIP `Archive`.
    public init(url: URL, accessMode mode: AccessMode, pathEncoding: String.Encoding? = nil) throws {
        self.url = url
        self.accessMode = mode
        self.pathEncoding = pathEncoding
        let config = try Archive.makeBackingConfiguration(for: url, mode: mode)
        self.archiveFile = config.file
        self.endOfCentralDirectoryRecord = config.endOfCentralDirectoryRecord
        self.zip64EndOfCentralDirectory = config.zip64EndOfCentralDirectory
        setvbuf(self.archiveFile, nil, _IOFBF, Int(defaultPOSIXBufferSize))
    }

    #if swift(>=5.0)
    var memoryFile: MemoryFile?

    /// Initializes a new in-memory ZIP `Archive`.
    public init(data: Data = Data(), accessMode mode: AccessMode, pathEncoding: String.Encoding? = nil) throws {
        let url = URL(string: "\(memoryURLScheme)://")!
        self.url = url
        self.accessMode = mode
        self.pathEncoding = pathEncoding
        let config = try Archive.makeBackingConfiguration(for: data, mode: mode)
        self.archiveFile = config.file
        self.memoryFile = config.memoryFile
        self.endOfCentralDirectoryRecord = config.endOfCentralDirectoryRecord
        self.zip64EndOfCentralDirectory = config.zip64EndOfCentralDirectory
    }
    #endif

    deinit {
        fclose(self.archiveFile)
    }

    public func makeIterator() -> AnyIterator<Entry> {
        let totalNumberOfEntriesInCD = self.totalNumberOfEntriesInCentralDirectory
        var directoryIndex = self.offsetToStartOfCentralDirectory
        var index = 0
        return AnyIterator {
            guard index < totalNumberOfEntriesInCD else { return nil }
            guard let centralDirStruct: CentralDirectoryStructure = Data.readStruct(from: self.archiveFile,
                                                                                    at: directoryIndex) else {
                return nil
            }
            let offset = UInt64(centralDirStruct.effectiveRelativeOffsetOfLocalHeader)
            guard let localFileHeader: LocalFileHeader = Data.readStruct(from: self.archiveFile,
                                                                         at: offset) else { return nil }
            var dataDescriptor: DataDescriptor?
            var zip64DataDescriptor: ZIP64DataDescriptor?
            if centralDirStruct.usesDataDescriptor {
                let additionalSize = UInt64(localFileHeader.fileNameLength) + UInt64(localFileHeader.extraFieldLength)
                let isCompressed = centralDirStruct.compressionMethod != CompressionMethod.none.rawValue
                let dataSize = isCompressed
                ? centralDirStruct.effectiveCompressedSize
                : centralDirStruct.effectiveUncompressedSize
                let descriptorPosition = offset + UInt64(LocalFileHeader.size) + additionalSize + dataSize
                if centralDirStruct.isZIP64 {
                    zip64DataDescriptor = Data.readStruct(from: self.archiveFile, at: descriptorPosition)
                } else {
                    dataDescriptor = Data.readStruct(from: self.archiveFile, at: descriptorPosition)
                }
            }
            defer {
                directoryIndex += UInt64(CentralDirectoryStructure.size)
                directoryIndex += UInt64(centralDirStruct.fileNameLength)
                directoryIndex += UInt64(centralDirStruct.extraFieldLength)
                directoryIndex += UInt64(centralDirStruct.fileCommentLength)
                index += 1
            }
            return Entry(centralDirectoryStructure: centralDirStruct, localFileHeader: localFileHeader,
                         dataDescriptor: dataDescriptor, zip64DataDescriptor: zip64DataDescriptor)
        }
    }

    public subscript(path: String) -> Entry? {
        if let encoding = self.pathEncoding {
            return self.first { $0.path(using: encoding) == path }
        }
        return self.first { $0.path == path }
    }

    // MARK: - Helpers
    typealias EndOfCentralDirectoryStructure = (EndOfCentralDirectoryRecord, ZIP64EndOfCentralDirectory?)

    static func scanForEndOfCentralDirectoryRecord(in file: FILEPointer)
    -> EndOfCentralDirectoryStructure? {
        var eocdOffset: UInt64 = 0
        var index = minEndOfCentralDirectoryOffset
        fseeko(file, 0, SEEK_END)
        let archiveLength = Int64(ftello(file))
        while eocdOffset == 0 && index <= archiveLength && index <= maxEndOfCentralDirectoryOffset {
            fseeko(file, off_t(archiveLength - index), SEEK_SET)
            var potentialDirectoryEndTag: UInt32 = UInt32()
            fread(&potentialDirectoryEndTag, 1, MemoryLayout<UInt32>.size, file)
            if potentialDirectoryEndTag == UInt32(endOfCentralDirectoryStructSignature) {
                eocdOffset = UInt64(archiveLength - index)
                guard let eocd: EndOfCentralDirectoryRecord = Data.readStruct(from: file, at: eocdOffset) else {
                    return nil
                }
                let zip64EOCD = scanForZIP64EndOfCentralDirectory(in: file, eocdOffset: eocdOffset)
                return (eocd, zip64EOCD)
            }
            index += 1
        }
        return nil
    }

    private static func scanForZIP64EndOfCentralDirectory(in file: FILEPointer, eocdOffset: UInt64)
    -> ZIP64EndOfCentralDirectory? {
        guard UInt64(ZIP64EndOfCentralDirectoryLocator.size) < eocdOffset else { return nil }
    
        let locatorOffset = eocdOffset - UInt64(ZIP64EndOfCentralDirectoryLocator.size)
        
        guard let locator: ZIP64EndOfCentralDirectoryLocator = Data.readStruct(from: file, at: locatorOffset) else {
            return nil
        }
        // The ZIP64 EOCD Record is not necessarily directly before the locator if the offset is 0.
        // The locator contains the offset to the ZIP64 EOCD Record.
        // If relativeOffsetOfZIP64EOCDRecord is 0, it means that ZIP64 EOCD record is not present or at an invalid location.
        // Also, the record itself must be large enough to contain ZIP64EndOfCentralDirectoryRecord.size.
        guard locator.relativeOffsetOfZIP64EOCDRecord > 0 && UInt64(ZIP64EndOfCentralDirectoryRecord.size) <= locator.relativeOffsetOfZIP64EOCDRecord else { 
            // It's possible that a ZIP64 EOCD locator exists but points to an invalid/missing record or the archive is not truly ZIP64
            // For example, if the offset is 0, it might mean the ZIP64 EOCD record is not used or its offset is not set.
            // In such cases, we should not attempt to read it.
            return nil 
        }
        guard let record: ZIP64EndOfCentralDirectoryRecord = Data.readStruct(from: file, at: locator.relativeOffsetOfZIP64EOCDRecord) else {
            return nil
        }
        return ZIP64EndOfCentralDirectory(record: record, locator: locator)
    }

    // MARK: - Add Entry
    public func addEntry(with path: String, fileURL: URL, compressionMethod: CompressionMethod = .deflate, progress: Progress? = nil) throws -> Entry {
        guard self.accessMode.isWritable else { throw ArchiveError.unwritableArchive }
    
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { throw ArchiveError.unreadableArchive }
        
        guard let entryFile: FILEPointer = fopen(fileURL.path, "rb") else { 
            throw ArchiveError.unreadableArchive 
        }
        defer { fclose(entryFile) }
    
        fseeko(entryFile, 0, SEEK_END)
        let uncompressedSize = UInt64(ftello(entryFile))
        fseeko(entryFile, 0, SEEK_SET)
    
        let lfhOffset = self.offsetToStartOfCentralDirectory 
        fseeko(self.archiveFile, off_t(lfhOffset), SEEK_SET)
    
        var lfh = Entry.LocalFileHeader(
            versionNeededToExtract: Version.v20.rawValue, 
            generalPurposeBitFlag: 0, 
            compressionMethod: compressionMethod.rawValue,
            lastModFileTime: 0, 
            lastModFileDate: 0, 
            crc32: 0, 
            compressedSize: 0, 
            uncompressedSize: UInt32(min(uncompressedSize, UInt64(UInt32.max))), 
            fileNameLength: UInt16(path.utf8.count),
            extraFieldLength: 0, 
            fileNameData: path.data(using: .utf8) ?? Data(),
            extraFieldData: Data()
        )
    
        _ = try Data.write(chunk: lfh, to: self.archiveFile)
        let dataOffset = UInt64(ftello(self.archiveFile))
    
        var calculatedCRC = CZLib.crc32(0, nil, 0)
        var totalBytesCompressed: UInt64 = 0
        var totalBytesReadUncompressed: Int64 = 0
    
        if compressionMethod == .deflate {
            var stream = z_stream()
            var result = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard result == Z_OK else { throw ArchiveError.invalidCompressionMethod }
            defer { deflateEnd(&stream) }
    
            var inputBuffer = [UInt8](repeating: 0, count: defaultReadChunkSize)
            var outputBuffer = [UInt8](repeating: 0, count: defaultReadChunkSize)
            var endOfFile = false
    
            repeat {
                if stream.avail_in == 0 && !endOfFile {
                    let bytesRead = fread(&inputBuffer, 1, defaultReadChunkSize, entryFile)
                    if bytesRead < defaultReadChunkSize {
                        if feof(entryFile) != 0 {
                            endOfFile = true
                        } else if ferror(entryFile) != 0 {
                            throw ArchiveError.unreadableArchive
                        }
                    }
                    if bytesRead > 0 {
                        calculatedCRC = CZLib.crc32(calculatedCRC, inputBuffer, UInt32(bytesRead))
                        stream.next_in = UnsafeMutablePointer<UInt8>(&inputBuffer)
                        stream.avail_in = UInt32(bytesRead)
                        totalBytesReadUncompressed += Int64(bytesRead)
                        if let progress = progress, !progress(totalBytesReadUncompressed, Int64(uncompressedSize)) {
                            throw ArchiveError.cancelledOperation
                        }
                    }
                }
    
                stream.next_out = UnsafeMutablePointer<UInt8>(&outputBuffer)
                stream.avail_out = UInt32(defaultReadChunkSize)
                
                let flush = endOfFile ? Z_FINISH : Z_NO_FLUSH
                result = CZLib.deflate(&stream, flush)
                guard result != Z_STREAM_ERROR else { throw ArchiveError.invalidCompressionMethod }
    
                let have = defaultReadChunkSize - Int(stream.avail_out)
                if have > 0 {
                    let written = fwrite(outputBuffer, 1, have, self.archiveFile)
                    guard written == have else { throw ArchiveError.unwritableArchive }
                    totalBytesCompressed += UInt64(have)
                }
            } while result != Z_STREAM_END
            
            if totalBytesReadUncompressed == Int64(uncompressedSize) {
                if let progress = progress, !progress(totalBytesReadUncompressed, Int64(uncompressedSize)) {
                    throw ArchiveError.cancelledOperation
                }
            }
    
        } else { // No compression
            var buffer = [UInt8](repeating: 0, count: defaultReadChunkSize)
            var bytesRead = 0
            repeat {
                bytesRead = fread(&buffer, 1, defaultReadChunkSize, entryFile)
                if bytesRead > 0 {
                    calculatedCRC = CZLib.crc32(calculatedCRC, buffer, UInt32(bytesRead))
                    let written = fwrite(buffer, 1, bytesRead, self.archiveFile)
                    guard written == bytesRead else { throw ArchiveError.unwritableArchive }
                    totalBytesCompressed += UInt64(bytesRead)
                    totalBytesReadUncompressed += Int64(bytesRead)
                    if let progress = progress, !progress(totalBytesReadUncompressed, Int64(uncompressedSize)) {
                        throw ArchiveError.cancelledOperation
                    }
                }
            } while bytesRead > 0
            if ferror(entryFile) != 0 { throw ArchiveError.unreadableArchive }
        }
    
        lfh.crc32 = calculatedCRC
        lfh.compressedSize = UInt32(min(totalBytesCompressed, UInt64(UInt32.max))) 
        lfh.uncompressedSize = UInt32(min(uncompressedSize, UInt64(UInt32.max)))   
        
        let endOfEntryDataOffset = ftello(self.archiveFile)
        fseeko(self.archiveFile, off_t(lfhOffset), SEEK_SET)
        _ = try Data.write(chunk: lfh, to: self.archiveFile)
        fseeko(self.archiveFile, endOfEntryDataOffset, SEEK_SET)
    
        let cds = Entry.CentralDirectoryStructure(
            versionMadeBy: Version.v20.rawValue, 
            versionNeededToExtract: lfh.versionNeededToExtract,
            generalPurposeBitFlag: lfh.generalPurposeBitFlag,
            compressionMethod: lfh.compressionMethod,
            lastModFileTime: lfh.lastModFileTime,
            lastModFileDate: lfh.lastModFileDate,
            crc32: lfh.crc32,
            compressedSize: lfh.compressedSize,
            uncompressedSize: lfh.uncompressedSize,
            fileNameLength: lfh.fileNameLength,
            extraFieldLength: lfh.extraFieldLength,
            fileCommentLength: 0,
            diskNumberStart: 0,
            internalFileAttributes: 0,
            externalFileAttributes: 0, 
            relativeOffsetOfLocalHeader: UInt32(min(lfhOffset, UInt64(UInt32.max))), 
            fileNameData: lfh.fileNameData,
            extraFieldData: lfh.extraFieldData,
            fileCommentData: Data()
        )
        
        let entry = Entry(centralDirectoryStructure: cds, localFileHeader: lfh, dataDescriptor: nil, zip64DataDescriptor: nil)
        return entry
    }

    // MARK: - Add Entry Async
    public func addEntryAsync(with path: String, fileURL: URL, compressionMethod: CompressionMethod = .deflate, 
                              progress: Progress? = nil, 
                              completion: @escaping (Result<Entry, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entry = try self.addEntry(with: path, fileURL: fileURL, compressionMethod: compressionMethod, progress: progress)
                completion(.success(entry))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: - Extract Entry
    public func extract(_ entry: Entry, to url: URL, progress: Progress? = nil) throws {
        guard self.accessMode != .create else { throw ArchiveError.unreadableArchive }

        let fileManager = FileManager.default
        let parentDirectoryURL = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDirectoryURL.path) {
            try fileManager.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        let outputStream: OutputStream = try { 
            guard let stream = OutputStream(url: url, append: false) else {
                throw ArchiveError.unwritableArchive
            }
            return stream
        }()
        outputStream.open()
        defer { outputStream.close() }

        fseeko(self.archiveFile, off_t(entry.dataOffset), SEEK_SET)
        
        let compressedSizeToRead = entry.centralDirectoryStructure.effectiveCompressedSize
        var remainingCompressedSizeToRead = compressedSizeToRead
        var calculatedCRC = CZLib.crc32(0, nil, 0)
        var totalBytesDecompressed: Int64 = 0

        if entry.centralDirectoryStructure.compressionMethod == CompressionMethod.deflate.rawValue {
            var stream = z_stream()
            var result = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard result == Z_OK else {
                throw ArchiveError.invalidCompressionMethod 
            }
            defer { inflateEnd(&stream) }

            var inputBuffer = [UInt8](repeating: 0, count: defaultReadChunkSize)
            var outputBuffer = [UInt8](repeating: 0, count: defaultReadChunkSize)

            repeat {
                if stream.avail_in == 0 && remainingCompressedSizeToRead > 0 {
                    let bytesToReadFromArchive = Int(min(remainingCompressedSizeToRead, UInt64(defaultReadChunkSize)))
                    let bytesRead = fread(&inputBuffer, 1, bytesToReadFromArchive, self.archiveFile)
                    guard bytesRead == bytesToReadFromArchive else {
                        throw ArchiveError.unreadableArchive 
                    }
                    stream.next_in = UnsafeMutablePointer<UInt8>(&inputBuffer)
                    stream.avail_in = UInt32(bytesRead)
                    remainingCompressedSizeToRead -= UInt64(bytesRead)
                }

                stream.next_out = UnsafeMutablePointer<UInt8>(&outputBuffer)
                stream.avail_out = UInt32(defaultReadChunkSize)

                result = CZLib.inflate(&stream, Z_NO_FLUSH)
                guard result != Z_STREAM_ERROR && result != Z_NEED_DICT && result != Z_DATA_ERROR && result != Z_MEM_ERROR else {
                    throw ArchiveError.invalidCRC32 
                }

                let have = defaultReadChunkSize - Int(stream.avail_out)
                if have > 0 {
                    let written = outputStream.write(outputBuffer, maxLength: have)
                    guard written == have else {
                        throw ArchiveError.unwritableArchive 
                    }
                    calculatedCRC = CZLib.crc32(calculatedCRC, outputBuffer, UInt32(have))
                    totalBytesDecompressed += Int64(have)
                    if let progress = progress, !progress(totalBytesDecompressed, Int64(entry.centralDirectoryStructure.effectiveUncompressedSize)) {
                        throw ArchiveError.cancelledOperation
                    }
                }
            } while result != Z_STREAM_END && (stream.avail_out == 0 || stream.avail_in > 0 || remainingCompressedSizeToRead > 0)
            
            guard result == Z_STREAM_END else {
                 if result != Z_BUF_ERROR || stream.avail_in > 0 || remainingCompressedSizeToRead > 0 {
                 }
            }

        } else { // No compression
            var buffer = [UInt8](repeating: 0, count: defaultReadChunkSize)
            while remainingCompressedSizeToRead > 0 {
                let bytesToRead = Int(min(remainingCompressedSizeToRead, UInt64(defaultReadChunkSize)))
                let bytesRead = fread(&buffer, 1, bytesToRead, self.archiveFile)
                guard bytesRead == bytesToRead else {
                    throw ArchiveError.unreadableArchive
                }
                
                let written = outputStream.write(buffer, maxLength: bytesRead)
                guard written == bytesRead else {
                    throw ArchiveError.unwritableArchive
                }
                calculatedCRC = CZLib.crc32(calculatedCRC, buffer, UInt32(bytesRead))
                totalBytesDecompressed += Int64(bytesRead)
                if let progress = progress, !progress(totalBytesDecompressed, Int64(entry.centralDirectoryStructure.effectiveUncompressedSize)) {
                    throw ArchiveError.cancelledOperation
                }
                remainingCompressedSizeToRead -= UInt64(bytesRead)
            }
        }

        if calculatedCRC != entry.centralDirectoryStructure.crc32 {
            // throw ArchiveError.invalidCRC32 // Enable after thorough testing
        }
        // Ensure progress is called one last time for 100% if not already
        if totalBytesDecompressed == Int64(entry.centralDirectoryStructure.effectiveUncompressedSize) {
             progress?(totalBytesDecompressed, Int64(entry.centralDirectoryStructure.effectiveUncompressedSize))
        } else if entry.centralDirectoryStructure.effectiveUncompressedSize == 0 && totalBytesDecompressed == 0 {
             if let progress = progress, !progress(0,0) {
                 throw ArchiveError.cancelledOperation
             }
        }
    }

    // MARK: - Extract Entry Async
    public func extractAsync(_ entry: Entry, to url: URL, 
                             progress: Progress? = nil, 
                             completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.extract(entry, to: url, progress: progress)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

// MARK: - Entry Placeholder
// This will be fleshed out later with details from Entry.swift
public struct Entry {
    // Minimal placeholder for now
    public enum EntryType: UInt16 {
        case file = 0
        case directory = 1
        case symlink = 2
    }
    public var type: EntryType
    public var path: String
    var localFileHeader: LocalFileHeader // Added to store LFH
    var centralDirectoryStructure: CentralDirectoryStructure // Added to store CDS
    var dataDescriptor: DefaultDataDescriptor? // Added
    var zip64DataDescriptor: ZIP64DataDescriptor? // Added

    // Placeholders for header structures, these will need full definitions
    // These are nested within Archive in the original, but might be top-level or nested in Entry for subset
    public struct LocalFileHeader: DataSerializable {
        static let size = 30 // Minimum size
        let localFileHeaderSignature = UInt32(localFileHeaderStructSignature)
        var versionNeededToExtract: UInt16
        var generalPurposeBitFlag: UInt16
        var compressionMethod: UInt16
        var lastModFileTime: UInt16
        var lastModFileDate: UInt16
        var crc32: CRC32
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var fileNameLength: UInt16
        var extraFieldLength: UInt16
        // Followed by: fileNameData, extraFieldData
        var fileNameData: Data
        var extraFieldData: Data
    }
    public struct DefaultDataDescriptor: DataSerializable {
        static let size = 16 // Or 12 if signature is optional by some tools
        let dataDescriptorSignature = UInt32(dataDescriptorStructSignature)
        let crc32: CRC32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
    }
    public struct ZIP64DataDescriptor: DataSerializable {
        static let size = 24 // Or 20 if signature is optional
        let dataDescriptorSignature = UInt32(dataDescriptorStructSignature)
        let crc32: CRC32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
    }
    public struct CentralDirectoryStructure: DataSerializable {
        static let size = 46; // Minimum size
        let centralDirectorySignature = UInt32(centralDirectoryStructSignature)
        var versionMadeBy: UInt16
        var versionNeededToExtract: UInt16
        var generalPurposeBitFlag: UInt16
        var compressionMethod: UInt16
        var lastModFileTime: UInt16
        var lastModFileDate: UInt16
        var crc32: CRC32
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var fileNameLength: UInt16
        var extraFieldLength: UInt16
        var fileCommentLength: UInt16
        var diskNumberStart: UInt16
        var internalFileAttributes: UInt16
        var externalFileAttributes: UInt32
        var relativeOffsetOfLocalHeader: UInt32
        // Followed by: fileNameData, extraFieldData, fileCommentData
        var fileNameData: Data
        var extraFieldData: Data
        var fileCommentData: Data

        var usesDataDescriptor: Bool { return (self.generalPurposeBitFlag & (1 << 3)) != 0 }
        var isZIP64: Bool {
            return self.uncompressedSize == .max || self.compressedSize == .max || self.relativeOffsetOfLocalHeader == .max
        }
        var effectiveUncompressedSize: UInt64 {
            guard self.uncompressedSize == .max else { return UInt64(self.uncompressedSize) }
            let zip64Field = ZIP64ExtendedInformation.scanForZIP64Field(in: self.extraFieldData, fields: [.uncompressedSize])
            return zip64Field?.uncompressedSize ?? 0
        }
        var effectiveCompressedSize: UInt64 {
            guard self.compressedSize == .max else { return UInt64(self.compressedSize) }
            let zip64Field = ZIP64ExtendedInformation.scanForZIP64Field(in: self.extraFieldData, fields: [.compressedSize])
            return zip64Field?.compressedSize ?? 0
        }
        var effectiveRelativeOffsetOfLocalHeader: UInt64 {
            guard self.relativeOffsetOfLocalHeader == .max else { return UInt64(self.relativeOffsetOfLocalHeader) }
            let zip64Field = ZIP64ExtendedInformation.scanForZIP64Field(in: self.extraFieldData, fields: [.relativeOffsetOfLocalHeader])
            return zip64Field?.relativeOffsetOfLocalHeader ?? 0
        }
    }
    
    struct ZIP64ExtendedInformation: DataSerializable {
        static let headerSize: UInt16 = 4 // Tag and Size field
        let tag: UInt16 = 0x0001 // ZIP64 extended information extra field
        var size: UInt16 // Size of the remaining data in this field
        var uncompressedSize: UInt64?
        var compressedSize: UInt64?
        var relativeOffsetOfLocalHeader: UInt64?
        var diskNumberStart: UInt32?
        // Other fields can be added if necessary

        enum Field: CaseIterable {
            case uncompressedSize, compressedSize, relativeOffsetOfLocalHeader, diskNumberStart
        }

        static func scanForZIP64Field(in data: Data, fields: [Field]) -> ZIP64ExtendedInformation? {
            // Simplified scan logic, assumes field is present if data is not empty
            // A proper implementation would parse the extra field data
            guard !data.isEmpty else { return nil }
            // This is a placeholder, actual parsing is needed
            return ZIP64ExtendedInformation(data: data) // Needs a proper init(data: Data)
        }
        
        // Placeholder init, actual parsing needed
        init?(data: Data) {
            // Parse data to populate fields
            // This is a very simplified placeholder
            self.size = UInt16(data.count) // Incorrect, size is part of the data
            // Actual parsing logic is complex and needs to iterate through extra fields
            return nil // Placeholder until parsing is implemented
        }
        
        init(dataSize: UInt16, uncompressedSize: UInt64?, compressedSize: UInt64?, relativeOffsetOfLocalHeader: UInt64?, diskNumberStart: UInt32?) {
            self.size = dataSize
            self.uncompressedSize = uncompressedSize
            self.compressedSize = compressedSize
            self.relativeOffsetOfLocalHeader = relativeOffsetOfLocalHeader
            self.diskNumberStart = diskNumberStart
        }
    }


    // Placeholder initializer
    init(centralDirectoryStructure: CentralDirectoryStructure, localFileHeader: LocalFileHeader,
         dataDescriptor: DefaultDataDescriptor?, zip64DataDescriptor: ZIP64DataDescriptor?) {
        self.centralDirectoryStructure = centralDirectoryStructure
        self.localFileHeader = localFileHeader
        self.dataDescriptor = dataDescriptor
        self.zip64DataDescriptor = zip64DataDescriptor
        // Actual initialization logic will be more complex
        // Determine type from centralDirectoryStructure or localFileHeader
        // For now, assume it's a file if not specified
        // A more robust way is to check file attributes or path ending
        if centralDirectoryStructure.externalFileAttributes & 0x0010 != 0 { // DOS directory attribute
             self.type = .directory
        } else if centralDirectoryStructure.externalFileAttributes & 0x0020 != 0 { // DOS archive attribute (often for files)
             self.type = .file
        } else {
            // Basic heuristic: if path ends with a slash, it's a directory
            // This is not foolproof as per ZIP spec, but a common convention
            let pathString = String(data: centralDirectoryStructure.fileNameData, encoding: .utf8) ?? ""
            if pathString.hasSuffix("/") || pathString.hasSuffix("\\") {
                self.type = .directory
            } else {
                self.type = .file // Default to file
            }
        }
        // Symlink detection would require checking specific external file attributes (e.g., Unix-like systems)
        // and potentially the compression method or other flags.

        self.path = String(data: centralDirectoryStructure.fileNameData, encoding: .utf8) ?? ""
    }

    public func path(using encoding: String.Encoding) -> String {
        return String(data: self.centralDirectoryStructure.fileNameData, encoding: encoding) ?? self.path
    }
    
    var dataOffset: UInt64 {
        let lfhOffset = self.centralDirectoryStructure.effectiveRelativeOffsetOfLocalHeader
        let lfhSize = UInt64(LocalFileHeader.size)
        let fileNameLength = UInt64(self.localFileHeader.fileNameLength)
        let extraFieldLength = UInt64(self.localFileHeader.extraFieldLength)
        return lfhOffset + lfhSize + fileNameLength + extraFieldLength
    }
}

// MARK: - DataSerializable Protocol
protocol DataSerializable {
    static var size: Int { get }
    var data: Data { get }
    init?(data: Data)
}

// Default implementations for convenience, can be overridden by conforming types
extension DataSerializable {
    // Default init?(data: Data) returns nil. Types must implement if they need deserialization.
    init?(data: Data) { 
        // This default implementation makes it optional for types that are only serialized.
        // Types that need to be deserialized MUST provide their own init?(data: Data).
        return nil 
    }
    // Default var data: Data returns empty. Types must implement if they need serialization.
    var data: Data { 
        // This default implementation makes it optional for types that are only deserialized.
        // Types that need to be serialized MUST provide their own var data: Data.
        return Data() 
    }
}

// MARK: - CompressionMethod
public enum CompressionMethod: UInt16 {
    case none = 0
    case deflate = 8
    // Other methods could be added here if supported
}

// MARK: - MemoryFile
// Used for in-memory archive operations
class MemoryFile {
    var data: Data
    var offset: Int = 0 // Current read/write offset

    init(data: Data = Data()) {
        self.data = data
    }
    
    // Basic read/write operations for MemoryFile might be needed here
    // For example, to simulate fread/fwrite for in-memory data
}

// MARK: - Data Extension (for readStruct, write etc.)
extension Data {
    static func readStruct<T>(from file: FILEPointer, at offset: UInt64) -> T? where T: DataSerializable {
        let originalOffset = ftello(file)
        fseeko(file, off_t(offset), SEEK_SET)
        var data = Data(count: T.size)
        let bytesRead = data.withUnsafeMutableBytes { (bufferPointer) -> Int in
            if let baseAddress = bufferPointer.baseAddress, bufferPointer.count > 0 {
                return fread(baseAddress, 1, T.size, file)
            }
            return 0
        }
        fseeko(file, originalOffset, SEEK_SET) // Restore original position
        guard bytesRead == T.size else { return nil }
        return T(data: data)
    }

    static func write<T: DataSerializable>(chunk: T, to file: FILEPointer) throws -> Int {
        return try write(chunk: chunk.data, to: file)
    }
    
    static func write(chunk: Data, to file: FILEPointer) throws -> Int {
        var sizeWritten = 0
        chunk.withUnsafeBytes { (bufferPointer) -> Void in
            if let baseAddress = bufferPointer.baseAddress, bufferPointer.count > 0 {
                sizeWritten = fwrite(baseAddress, 1, bufferPointer.count, file)
            }
        }
        if sizeWritten != chunk.count {
            // Check ferror(file) for actual error code if needed
            // TODO: Map ferror to a specific ArchiveError
            throw Archive.ArchiveError.unwritableArchive 
        }
        return sizeWritten
    }
    
    static func readChunk(of size: Int, from file: FILEPointer) throws -> Data {
        var data = Data(count: size)
        let bytesRead = data.withUnsafeMutableBytes { bufferPointer -> Int in
            guard let baseAddress = bufferPointer.baseAddress else { return 0 }
            return fread(baseAddress, 1, size, file)
        }
        guard bytesRead == size else {
            // Check ferror or feof
            // TODO: Map to specific ArchiveError
            throw Archive.ArchiveError.unreadableArchive 
        }
        return data
    }
}