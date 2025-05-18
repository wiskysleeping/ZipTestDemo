import Foundation
import ZIPFoundation

struct ZIPDemo {
    let manager = ZIPManager.shared
    
    func runDemo() {
        let tempDir = FileManager.default.temporaryDirectory
        let srcFile = tempDir.appendingPathComponent("demo.txt")
        let zipFile = tempDir.appendingPathComponent("demo.zip")
        let destDir = tempDir.appendingPathComponent("unzipped")
        
        // 准备测试文件
        try? "测试内容".write(to: srcFile, atomically: true, encoding: .utf8)
        
        // 同步压缩示例
        do {
            let progress = Progress().bindToZIPOperation()
            try manager.zipItem(at: srcFile, to: zipFile, progress: progress)
            print("✅ 同步压缩完成 进度: \(progress.fractionCompleted)")
        } catch {
            print("❌ 同步压缩失败: \(error)")
        }
        
        // 异步解压示例
        let semaphore = DispatchSemaphore(value: 0)
        let asyncProgress = Progress().bindToZIPOperation()
        
        manager.unzipItemAsync(at: zipFile, to: destDir, progress: asyncProgress) { error in
            if let error = error {
                print("❌ 异步解压失败: \(error)")
            } else {
                print("✅ 异步解压完成 进度: \(asyncProgress.fractionCompleted)")
            }
            semaphore.signal()
        }
        
        semaphore.wait()
    }
}

// 执行演示
ZIPDemo().runDemo()