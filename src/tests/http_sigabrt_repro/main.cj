package termhelper.tests.http_sigabrt_repro

import stdx.net.http.*
import stdx.net.tls.*
import std.io.*
import std.time.*

foreign func getenv(name: CString): CPointer<Int8>

func envGet(name: String): ?String {
    unsafe {
        let cname = LibC.mallocCString(name)
        let ptr = getenv(cname)
        LibC.free(cname)
        if (ptr.isNull()) {
            None
        } else {
            Some(CString(CPointer<UInt8>(ptr)).toString())
        }
    }
}

func envGetOrDefault(name: String, default: String): String {
    match (envGet(name)) {
        case Some(v) => if (v.size > 0) { v } else { default }
        case None => default
    }
}

func makeRequest(apiKey: String): HttpRequest {
    let body = "{\"model\":\"deepseek-v4-pro\",\"messages\":[{\"role\":\"user\",\"content\":\"Return only ok.\"}],\"max_tokens\":8}"
    HttpRequestBuilder()
        .post()
        .url("https://api.deepseek.com/v1/chat/completions")
        .header("Authorization", "Bearer " + apiKey)
        .header("Content-Type", "application/json")
        .body(body)
        .build()
}

func runWithTlsConfig(apiKey: String): Unit {
    println("http_sigabrt_repro: HTTPS POST with ClientBuilder.tlsConfig(TlsClientConfig())")
    let tlsConfig = TlsClientConfig()
    let client = ClientBuilder()
        .tlsConfig(tlsConfig)
        .readTimeout(Duration.second * 30)
        .writeTimeout(Duration.second * 30)
        .build()
    let resp = client.send(makeRequest(apiKey))
    println("status=${resp.status}")
    let text = StringReader(resp.body).readToEnd()
    println("body_size=${text.size}")
    if (text.size > 0) {
        let previewSize = if (text.size > 240) { 240 } else { text.size }
        println(text[0..previewSize])
    }
    client.close()
}

func runWithoutTlsConfig(apiKey: String): Unit {
    println("http_sigabrt_repro: HTTPS POST without ClientBuilder.tlsConfig")
    let client = ClientBuilder()
        .readTimeout(Duration.second * 30)
        .writeTimeout(Duration.second * 30)
        .build()
    let resp = client.send(makeRequest(apiKey))
    println("status=${resp.status}")
    let text = StringReader(resp.body).readToEnd()
    println("body_size=${text.size}")
    client.close()
}

main(args: Array<String>): Int64 {
    let apiKey = envGetOrDefault("DEEPSEEK_API_KEY", "fake")
    println("api_key_len=${apiKey.size}")
    if (args.size > 0 && args[0] == "no-tls-config") {
        runWithoutTlsConfig(apiKey)
    } else {
        runWithTlsConfig(apiKey)
    }
    println("done")
    0
}
