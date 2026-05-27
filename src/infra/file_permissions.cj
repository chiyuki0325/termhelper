package termhelper.infra

import std.posix.*

/// 尝试将敏感文件权限收紧为 0600。失败时仅记录日志。
public func restrictFileToOwner(path: String): Unit {
    debugTrace("restrictFileToOwner: chmod 0600 start path=${path}")
    try {
        let rc = chmod(path, 0o600u32)
        if (rc != 0) {
            debugTrace("restrictFileToOwner: chmod failed rc=${rc}, path=${path}")
            return
        }
    } catch (e: Exception) {
        debugTrace("restrictFileToOwner: chmod exception path=${path}, err=${e.message}")
        return
    }
    debugTrace("restrictFileToOwner: chmod 0600 end path=${path}")
}
