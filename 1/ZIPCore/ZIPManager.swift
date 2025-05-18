// 同步压缩核心实现
public func zipItem(at sourceURL: URL, to destinationURL: URL, compressionMethod: CompressionMethod = .deflate, progress: Progress? = nil) throws {
    let archive = try Archive(url: destinationURL, accessMode: .create)
    let entry = try Entry(
        path: sourceURL.lastPathComponent,
        type: .file,
        uncompressedSize: UInt32(sourceURL.fileSize),
        compressionMethod: compressionMethod
    )
    
    try archive.addEntry(entry) { position in
        progress?.completedUnitCount = Int64(position)
        return try Data(contentsOf: sourceURL)
    }
}

// 异步操作队列管理
private let queue = DispatchQueue(label: "ZIPOperations", qos: .userInitiated)

public func zipItemAsync(at sourceURL: URL, to destinationURL: URL, compressionMethod: CompressionMethod = .deflate, 
                       progress: Progress = Progress(), completion: @escaping (Error?) -> Void) {
    queue.async {
        do {
            try self.zipItem(at: sourceURL, to: destinationURL, 
                           compressionMethod: compressionMethod, progress: progress)
            DispatchQueue.main.async { completion(nil) }
        } catch {
            DispatchQueue.main.async { completion(error) }
        }
    }
}


public extension Progress {
    func bindToZIPOperation() -> Self {
        self.totalUnitCount = 100
        return self
    }
}
