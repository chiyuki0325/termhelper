package termhelper.infra

public func termhelperConfigDir(): String {
    let explicit = envGetOrDefault("TERMHELPER_CONFIG_DIR", "").trimAscii()
    if (explicit.size > 0) {
        explicit
    } else {
        let xdg = envGetOrDefault("XDG_CONFIG_HOME", "").trimAscii()
        if (xdg.size > 0) {
            "${xdg}/termhelper"
        } else {
            "${envGetHome()}/.config/termhelper"
        }
    }
}

public func termhelperConfigPath(): String {
    "${termhelperConfigDir()}/config.json"
}

public func termhelperContextPath(): String {
    "${termhelperConfigDir()}/context.json"
}
