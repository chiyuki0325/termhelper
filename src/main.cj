package termhelper

import termhelper.types.*
import termhelper.tui.*

/// 程序入口
/// 用法：
///   termhelper <自然语言查询>    — 执行查询，启动 TUI
///   termhelper --install          — 安装 Shell 集成
///   termhelper --uninstall        — 卸载 Shell 集成
///   termhelper --help             — 打印帮助信息
main(args: Array<String>): Int64 {
    if (args.size == 0) {
        println("用法: termhelper <查询> | --install | --uninstall | --help")
        println("尝试: termhelper --help")
        return 1
    }

    let firstArg = args[0]

    // 以 -- 为前缀的参数精确匹配保留词列表
    if (firstArg.startsWith("--")) {
        match (firstArg) {
            case "--install" =>
                println("[阶段 1 占位] 安装 Shell 集成")
                return 0
            case "--uninstall" =>
                println("[阶段 1 占位] 卸载 Shell 集成")
                return 0
            case "--help" =>
                printHelp()
                return 0
            case _ =>
                println("未知参数: ${firstArg}")
                println("尝试: termhelper --help")
                return 1
        }
    }

    // 其他所有参数拼接为自然语言查询
    let query = joinArgs(args)
    println("查询: ${query}")
    println("[阶段 1] 类型系统初始化完成，TUI 验证待进行")

    // 尝试初始化 TUI（验证 ratatui binding）
    match (initTUI()) {
        case Ok(terminal) =>
            println("[阶段 1] TUI 初始化成功，进入主循环（按 Esc 退出）")
            match (runMainLoop(terminal)) {
                case Ok(_) => ()
                case Err(e) => println("TUI 循环错误: ${e.message}")
            }
            cleanupTUI(terminal)
        case Err(e) =>
            println("[阶段 1] TUI 初始化失败: ${e.message}")
            println("[阶段 1] 回退到 CLI 模式")
            return 1
    }

    return 0
}

/// 打印帮助信息
func printHelp(): Unit {
    println("termhelper — Linux 终端智能助手")
    println("将自然语言转换为可执行的 Shell 命令，辅以说明和安全警告")
    println()
    println("用法:")
    println("  termhelper <自然语言查询>    执行查询，启动全屏 TUI")
    println("  termhelper --install          安装 Shell 集成 (alias/def 写入 RC 文件)")
    println("  termhelper --uninstall        卸载 Shell 集成 (从 RC 文件移除)")
    println("  termhelper --help             打印此帮助信息")
    println()
    println("示例:")
    println("  ?? 删除所有 std 开头的文件夹")
    println("  ?? 更新系统")
}

/// 将参数数组拼接为空格分隔的查询字符串
func joinArgs(args: Array<String>): String {
    var result = ""
    for (i in 0..args.size) {
        if (i > 0) {
            result += " "
        }
        result += args[i]
    }
    result
}
