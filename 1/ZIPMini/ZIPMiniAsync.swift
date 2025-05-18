import Foundation

extension FileManager {
    /// 异步压缩项目
    public func zipItemAsync(at sourceURL: URL, to destinationURL: URL,
                            shouldKeepParent: Bool = true,
                            compressionMethod: CompressionMethod = .none,
                            progress: Progress? = nil,
                            completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.zipItem(at: sourceURL, to: destinationURL,
                                shouldKeepParent: shouldKeepParent,
                                compressionMethod: compressionMethod,
                                progress: progress)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }
    
    /// 异步解压缩项目
    public func unzipItemAsync(at sourceURL: URL, to destinationURL: URL,
                              skipCRC32: Bool = false,
                              progress: Progress? = nil,
                              preferredEncoding: String.Encoding? = nil,
                              completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.unzipItem(at: sourceURL, to: destinationURL,
                                  skipCRC32: skipCRC32,
                                  progress: progress,
                                  preferredEncoding: preferredEncoding)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }
}