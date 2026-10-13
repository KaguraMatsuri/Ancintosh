import AndcintoshCore
import Foundation

enum Copy {
    static let bluetoothVisibility = "关闭 wifi传输后，数据仅通过蓝牙发送，Wi-Fi 网络观察者更难发现这部分传输；附近仍可检测到蓝牙信号。"
    static let keyHelp = "输入 64 位十六进制密钥，与这台 Android 上的密钥保持一致。编辑已有设备时，留空保留原密钥。"
    static let clipboardHelp = "自动同步需要粘贴板的“始终允许”权限。请在系统设置中允许 Andcintosh 读取粘贴板。"
    static func failure(_ error: any Error) -> String {
        guard let code = error as? ProtocolFailure else { return "操作未完成，请检查文件和权限后重试。" }
        switch code {
        case .unsupportedVersion: return "协议版本不兼容，请更新两端客户端。"
        case .invalidKey: return "密钥须为 64 位十六进制字符。"
        case .authenticationFailed: return "认证失败，请检查两端密钥是否一致。"
        case .originalUnavailable: return "无法取得图片原文件，请从文件或原图分享入口发送。"
        case .sourceUnavailable: return "无法读取内容，请重新选择文件或复制内容后重试。"
        case .insufficientSpace: return "可用空间不足，请清理磁盘后重试。"
        case .digestMismatch: return "文件校验失败，请重试。"
        case .permissionDenied: return "权限未获允许，请检查系统设置。"
        case .peerUnavailable, .timeout: return "设备不可用，请检查蓝牙与连接后重试。"
        case .unsupported: return "设备或内容不支持此操作。"
        case .invalidName: return "文件名无效，请重新选择文件。"
        case .cancelled: return "已取消。"
        case .invalidHandshake, .invalidFrame, .replay, .oversizedRecord, .invalidManifest, .invalidOffset:
            return "传输数据无效，请重新连接后重试。"
        }
    }
}
