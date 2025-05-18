import Foundation

// 从Archive.swift提取的核心类型
public enum CompressionMethod: UInt16 {
    case none = 0
    case deflate = 8
}

public typealias CRC32 = UInt32
public typealias Consumer = (_ data: Data) throws -> Void
public typealias Provider = (_ position: Int, _ size: Int) throws -> Data

// 从Entry.swift提取的核心结构
// 移除原有Entry结构定义
@_implementationOnly import ZIPCore

// 复用ZIPCore模块的Entry实现
typealias Entry = ZIPCore.Entry

// 核心压缩/解压缩方法
extension FileManager {
    public func zipItem(at sourceURL: URL, to destinationURL: URL,
                       shouldKeepParent: Bool = true, 
                       compressionMethod: CompressionMethod = .none,
                       progress: Progress? = nil) throws {
        // ... 实现压缩逻辑 ...
    }
    
    public func unzipItem(at sourceURL: URL, to destinationURL: URL, 
                         skipCRC32: Bool = false,
                         progress: Progress? = nil, 
                         preferredEncoding: String.Encoding? = nil) throws {
        // ... 实现解压逻辑 ...
        // 精确计算总工作量
        progress?.totalUnitCount = Int64(entries.reduce(0) { $0 + $1.uncompressedSize })
        
        // 增量更新进度
        var currentPosition: Int64 = 0
        for entry in entries {
            progress?.completedUnitCount = currentPosition
            currentPosition += Int64(entry.uncompressedSize)
        }
    }
    
    // 辅助方法
    private func itemExists(at url: URL) -> Bool {
        return (try? url.checkResourceIsReachable()) == true
    }
    
    private func createParentDirectoryStructure(for url: URL) throws {
        let parentDirectoryURL = url.deletingLastPathComponent()
        try self.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }
    
    // 添加异步目录处理
    private func processDirectory(_ url: URL, entries: inout [Entry], progress: Progress?) throws {
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)!
        while let fileURL = enumerator.nextObject() as? URL {
            let relativePath = fileURL.relativePath(to: url)
            let entry = try Entry(url: fileURL, relativePath: relativePath)
            entries.append(entry)
            progress?.totalUnitCount += Int64(entry.uncompressedSize) // 实时更新总进度
        }
    }
}