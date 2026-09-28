import AVFoundation
import CoreMedia
import Foundation
import Speech
import Translation

// Live (or file-based) lecture transcription with translation. Speech recognition runs
// on-device (macOS 26 SpeechAnalyzer). With an API key, Claude streams a live translation
// of what is being said and then cleans up and translates each finished sentence;
// without one, finished sentences are translated on-device.

let usage = """
用法:
  livetrans                    实时：麦克风 → 英文 → 中文（Ctrl-C 结束）
  livetrans <音频文件>           转写并翻译一个录音文件（m4a / mp3 / wav …）

选项:
  -o, --out <文件>              输出 Markdown 路径（默认 ./transcripts/<时间>.md）
  --vocab <名字或文件>           术语表，比如 --vocab polymer（在 livetrans/vocab/ 里找 polymer.txt）
  --topic <文字>                课程主题，告诉 AI 这是什么课（默认取术语表里的 "# topic:" 那一行）
  --provider <名字>              AI 翻译服务：claude、deepseek、openai（任意兼容 OpenAI 的接口）
                               默认 auto：有 ANTHROPIC_API_KEY 用 Claude，否则有 DEEPSEEK_API_KEY 用 DeepSeek
  --model <名字>                 模型（默认 Claude 用 claude-sonnet-5，DeepSeek 用 deepseek-flash）
  --api-base <地址>              接口地址（openai 必填，比如 http://localhost:11434/v1）
  --api-key-env <变量名>          key 所在的环境变量（openai 默认不需要 key）
  --no-ai                      不用 AI，只用本地翻译
  --no-preview                 不边听边翻（省 API 费用），只翻译定稿的句子
  --from <locale>              说话语言（默认 en-US）
  --to <语言>                   翻译目标语言（默认 zh-Hans，繁体用 zh-Hant）
  --fast                       本地定稿翻译用低延迟模式
  --no-translate               只转写，不翻译
  --check                      检查识别模型、翻译语言包、麦克风权限、API key
  --engine <whisper|apple>     语音识别引擎（默认 whisper，没装模型时用系统听写）
  --whisper-model <文件>        指定 Whisper 模型文件（默认 models/ 里的 large-v3-turbo）

设置了环境变量 ANTHROPIC_API_KEY 时用 Claude 边听边翻，每句定稿后再纠错精翻；
没设置就用本地翻译，只翻译定稿的句子。
"""

// MARK: - Options

struct Options {
    var audioFile: String?
    var outPath: String?
    var from = "en-US"
    var to = "zh-Hans"
    var vocabPath: String?
    var topic = ""
    var model: String?
    var provider = "auto"
    var apiBase: String?
    var apiKeyVariable: String?
    var ai = true
    var preview = true
    var fast = false
    var translate = true
    var check = false
    var engine = "auto"
    var whisperModel: String?
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func parseOptions() throws -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func value(for flag: String) throws -> String {
        guard !args.isEmpty else { throw CLIError("\(flag) 需要一个参数") }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "-o", "--out": o.outPath = try value(for: arg)
        case "--from": o.from = try value(for: arg)
        case "--to": o.to = try value(for: arg)
        case "--vocab": o.vocabPath = try value(for: arg)
        case "--topic": o.topic = try value(for: arg)
        case "--model": o.model = try value(for: arg)
        case "--provider": o.provider = try value(for: arg)
        case "--api-base": o.apiBase = try value(for: arg)
        case "--api-key-env": o.apiKeyVariable = try value(for: arg)
        case "--no-ai": o.ai = false
        case "--no-preview": o.preview = false
        case "--fast": o.fast = true
        case "--no-translate": o.translate = false
        case "--check": o.check = true
        case "--engine": o.engine = try value(for: arg)
        case "--whisper-model": o.whisperModel = try value(for: arg)
        case "-h", "--help": print(usage); exit(0)
        default:
            if arg.hasPrefix("-") { throw CLIError("未知选项 \(arg)\n\n\(usage)") }
            o.audioFile = arg
        }
    }
    return o
}

// MARK: - Terminal output

enum ANSI {
    static let dim = "\u{1B}[2m"
    static let cyan = "\u{1B}[36m"
    static let brightCyan = "\u{1B}[1;36m"
    static let reset = "\u{1B}[0m"
    static let saveCursor = "\u{1B}7"
    static let restoreCursor = "\u{1B}8"
    static let clearBelow = "\u{1B}[J"
}

func terminalWidth() -> Int {
    var size = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
    return 100
}

func timestamp(_ seconds: Double) -> String {
    let s = seconds.isFinite ? max(Int(seconds), 0) : 0
    return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
}

/// Debug: LIVETRANS_DEBUG=<file> appends timestamped pipeline events to that file.
let debugLog: FileHandle? = ProcessInfo.processInfo.environment["LIVETRANS_DEBUG"].flatMap { path in
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}
let debugStart = Date()

func debug(_ message: @autoclosure () -> String) {
    guard let debugLog else { return }
    debugLog.write(Data(String(format: "%7.2f  %@\n", Date().timeIntervalSince(debugStart), message()).utf8))
}

/// Terminal columns a character takes up: CJK and emoji are two wide.
func columns(_ c: Character) -> Int {
    guard let v = c.unicodeScalars.first?.value else { return 0 }
    switch v {
    case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
         0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
         0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD,
         // East Asian "ambiguous" symbols (… ▍ ▁ etc.) render two wide in some CJK setups; assume the worst.
         0x2010...0x2027, 0x2190...0x21FF, 0x2500...0x25FF:
        return 2
    default:
        return 1
    }
}

/// Wraps text into rows of at most `width` columns and keeps only the last `maxRows`.
func wrapTail(_ text: String, width: Int, maxRows: Int) -> [String] {
    var rows: [String] = []
    var row = ""
    var used = 0
    for c in text.replacingOccurrences(of: "\n", with: " ") {
        let w = columns(c)
        if used + w > width {
            rows.append(row)
            row = ""
            used = 0
        }
        row.append(c)
        used += w
    }
    if !row.isEmpty { rows.append(row) }
    guard rows.count > maxRows else { return rows }
    var tail = Array(rows.suffix(maxRows))
    tail[0] = "…" + tail[0].dropFirst()
    return tail
}

struct Segment {
    let start: Double
    let text: String
}

/// Committed blocks scroll up; underneath is a live area redrawn in place: the
/// English not committed yet (finished segments waiting for their final
/// translation, then the still-changing tail) and a rolling translation preview.
actor Console {
    private let isTTY = isatty(STDOUT_FILENO) != 0
    private var liveShown = false
    private var status = ""
    private var meter = ""
    private var showLive = true
    private var pending: [Segment] = []
    private var volatile = ""
    private var preview = ""
    private var buffer = ""  // everything for one screen update, written at once to avoid flicker
    private var previewReady: AsyncStream<Void>.Continuation?
    private var finalReady: AsyncStream<Void>.Continuation?
    private var silentSince: Date?
    private var warnedSilent = false
    private var closed = false
    private var lastRender = Date.distantPast
    private var renderScheduled = false

    private var liveSource: String {
        (pending.map(\.text) + [volatile]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func connect(previewReady: AsyncStream<Void>.Continuation?,
                 finalReady: AsyncStream<Void>.Continuation, showLive: Bool) {
        self.previewReady = previewReady
        self.finalReady = finalReady
        self.showLive = showLive
    }

    func endInput() {
        previewReady?.finish()
        finalReady?.finish()
    }

    func setStatus(_ text: String) {
        status = text
        redraw()
        flush()
    }

    func setVolatile(_ text: String) {
        volatile = text
        requestPreview()
        redraw()
        flush()
    }

    func addFinal(_ segment: Segment) {
        pending.append(segment)
        volatile = ""
        finalReady?.yield()
        requestPreview()
        redraw()
        flush()
    }

    func pendingBatch(max: Int) -> [Segment] {
        Array(pending.prefix(max))
    }

    /// Replaces the first `count` pending segments with their finished output. The
    /// preview stays up (it may briefly include committed text) until a newer one lands.
    func commit(_ count: Int, output: String) {
        clearDrawn()
        write(output)
        pending.removeFirst(min(count, pending.count))
        requestPreview()
        render()
        flush()
    }

    /// What the preview should translate: the last sentence or two of the live text,
    /// so requests stay short and the translation tracks what was just said.
    func previewSource() -> String {
        let source = liveSource
        guard source.count > 200 else { return source }
        var tail = Substring(source.suffix(200))
        if let end = tail.firstIndex(where: { ".?!".contains($0) }),
           tail.distance(from: tail.startIndex, to: end) < 120 {
            tail = tail[tail.index(after: end)...]
        } else if let space = tail.firstIndex(of: " ") {
            tail = tail[tail.index(after: space)...]
        }
        return tail.trimmingCharacters(in: .whitespaces)
    }

    /// A streamed translation replaces the shown one only once it has caught up (or is
    /// complete), so the preview grows or swaps whole instead of blinking back to its start.
    func setPreview(_ text: String, complete: Bool) {
        guard !liveSource.isEmpty, complete || text.count >= preview.count else { return }
        preview = text
        redraw()
        flush()
    }

    func emit(_ text: String) {
        clearDrawn()
        write(text + "\n")
        render()
        flush()
    }

    /// Mic level (0…1), shown while nothing is being recognized so you can tell the mic is live.
    func setLevel(_ level: Float) {
        if level == 0 {
            let since = silentSince ?? Date()
            silentSince = since
            if !warnedSilent, Date().timeIntervalSince(since) > 3 {
                warnedSilent = true
                emit("""
                    ⚠️ 麦克风完全没有声音。常见原因：
                       · MacBook 合盖接外接显示器时，内置麦克风会被关掉 —— 打开盖子，
                         或在 系统设置 → 声音 → 输入 里换成 iPhone / AirPods / 外接麦克风
                       · 终端 App 没有麦克风权限（系统设置 → 隐私与安全性 → 麦克风）

                    """)
            }
        } else {
            silentSince = nil
        }
        let bars = Array("▁▂▃▄▅▆▇█")
        let index = min(Int(level * Float(bars.count)), bars.count - 1)
        let next = "🎙 " + String(repeating: bars[index], count: 1 + index) + (level == 0 ? "  （没有声音输入）" : "")
        guard next != meter else { return }
        meter = next
        if liveSource.isEmpty && status.isEmpty { redraw() }
        flush()
    }

    private func requestPreview() {
        if liveSource.isEmpty {
            preview = ""
        } else {
            previewReady?.yield()
        }
    }

    /// Stops drawing the live area (no leftover meter once the program is done).
    func close() {
        clearDrawn()
        closed = true
        flush()
    }

    /// At most ~15 frames a second: streamed text can change far faster than a terminal
    /// can redraw, and a terminal that falls behind stalls everything writing to it.
    private func redraw() {
        let wait = 0.07 - Date().timeIntervalSince(lastRender)
        guard wait > 0 else { return render() }
        guard !renderScheduled else { return }
        renderScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(wait))
            renderScheduledFrame()
        }
    }

    private func renderScheduledFrame() {
        renderScheduled = false
        render()
        flush()
    }

    private func render() {
        guard isTTY else { return }
        lastRender = Date()
        clearDrawn()
        guard !closed else { return }
        let width = max(terminalWidth() - 1, 20)
        var rows: [String] = []
        let source = showLive ? liveSource : ""
        if !source.isEmpty {
            rows += wrapTail("▍" + source, width: width, maxRows: 3).map { ANSI.dim + $0 + ANSI.reset }
            if !preview.isEmpty {
                rows += wrapTail("▍" + preview, width: width, maxRows: 3).map { ANSI.brightCyan + $0 + ANSI.reset }
            }
        } else if !status.isEmpty {
            rows += wrapTail(status, width: width, maxRows: 1).map { ANSI.dim + $0 + ANSI.reset }
        } else if !meter.isEmpty {
            rows.append(ANSI.dim + meter + ANSI.reset)
        }
        guard !rows.isEmpty else { return }
        // Make room below first so drawing never scrolls, then remember where the
        // live area starts: clearing jumps back there and erases everything below,
        // which stays correct even if the terminal wraps a row we thought would fit.
        write(String(repeating: "\n", count: Console.reservedRows) + "\u{1B}[\(Console.reservedRows)A\r" + ANSI.saveCursor)
        write(rows.joined(separator: "\n"))
        liveShown = true
    }

    private static let reservedRows = 8

    private func clearDrawn() {
        guard isTTY, liveShown else { return }
        write(ANSI.restoreCursor + ANSI.clearBelow)
        liveShown = false
    }

    private func write(_ text: String) {
        buffer += text
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        FileHandle.standardOutput.write(Data(buffer.utf8))
        buffer = ""
    }
}

// MARK: - Transcript file

final class TranscriptWriter {
    let url: URL
    private let handle: FileHandle

    init(url: URL, title: String) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("# \(title)\n\n".utf8))
    }

    func append(_ line: Line) {
        var entry = "**[\(timestamp(line.start))]** \(line.en)\n"
        if let zh = line.zh { entry += "> \(zh)\n" }
        handle.write(Data((entry + "\n").utf8))
    }
}

// MARK: - On-device translation

final class Translator {
    private let from: Locale.Language
    private let to: Locale.Language
    private var fast: Bool
    private var session: TranslationSession

    init(from: Locale.Language, to: Locale.Language, fast: Bool) {
        self.from = from
        self.to = to
        self.fast = fast
        session = Translator.makeSession(from: from, to: to, fast: fast)
    }

    private static func makeSession(from: Locale.Language, to: Locale.Language, fast: Bool) -> TranslationSession {
        if #available(macOS 26.4, *) {
            return TranslationSession(installedSource: from, target: to,
                                      preferredStrategy: fast ? .lowLatency : .highFidelity)
        }
        return TranslationSession(installedSource: from, target: to)
    }

    /// Each strategy has its own model; if the preferred one isn't installed, switch to the other for good.
    func translate(_ text: String) async throws -> String {
        do {
            return try await session.translate(text).targetText
        } catch where TranslationError.notInstalled ~= error {
            fast.toggle()
            session = Translator.makeSession(from: from, to: to, fast: fast)
            return try await session.translate(text).targetText
        }
    }
}

func describe(_ status: LanguageAvailability.Status) -> String {
    switch status {
    case .installed: return "已安装 ✓"
    case .supported: return "支持但未下载"
    case .unsupported: return "不支持"
    @unknown default: return "未知"
    }
}

// MARK: - AI translation

struct Line {
    let start: Double
    let en: String
    let zh: String?
}

enum APIError: Error, CustomStringConvertible {
    case unauthorized
    case refused
    case http(Int, String)
    case badResponse

    var description: String {
        switch self {
        case .unauthorized: return "API key 无效"
        case .refused: return "模型拒绝了这段内容"
        case .http(let status, let message): return "HTTP \(status)：\(message)"
        case .badResponse: return "返回格式不对"
        }
    }

    /// Worth one more try: rate limits, server hiccups, or an empty/garbled reply.
    var isRetryable: Bool {
        switch self {
        case .http(let status, _): return status == 429 || status >= 500
        case .badResponse: return true
        default: return false
        }
    }

    /// Reads an error response; a non-API body (a proxy or gateway page) shows its start.
    init(status: Int, body: Data) {
        if status == 401 || status == 403 {
            self = .unauthorized
            return
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
            ?? String(decoding: body.prefix(160), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        debug("HTTP \(status): \(String(decoding: body.prefix(2000), as: UTF8.self))")
        self = .http(status, message)
    }
}

/// An AI service used for translation. `translate` handles finished segments (cleaned-up
/// English plus a translation); `preview` streams a quick translation of unfinished speech,
/// calling `onUpdate` with the text so far and once more, complete, when it ends.
protocol AITranslator: AnyObject {
    var label: String { get }
    var disabled: Bool { get }  // set once the API key is rejected
    func translate(_ batch: [Segment]) async throws -> [Line]
    func preview(_ text: String, onUpdate: (String, Bool) async -> Void) async throws
    /// A tiny request; returns the model the server says it used.
    func ping() async throws -> String
}

/// What every AI backend is told, plus the reply shape and the rolling context.
final class TranslationBrief {
    let system: String
    let previewSystem: String
    private var history: [(en: String, zh: String)] = []

    struct Reply: Decodable {
        struct Item: Decodable {
            let en: String
            let zh: String
        }
        let items: [Item]
    }

    init(topic: String, targetLanguage: String, glossary: [String]) {
        var system = """
            You turn live classroom speech into \(targetLanguage) subtitles. Lecture topic: \(topic).

            The input comes from speech recognition on a classroom microphone, so punctuation is unreliable and some words are misheard. For each numbered segment, return:
            - "en": what the speaker most likely said. Fix misrecognized words using the topic and the earlier context (a misheard technical term usually sounds like the right one) and add punctuation. Don't add or summarize content.
            - "zh": a natural \(targetLanguage) translation of "en", using the standard terminology of textbooks in this field. Keep formulas, symbols and abbreviations as written (e.g. Tg, Mn, PDI). Inside "zh", quote with “ ” or 「」, never with ASCII double quotes.

            Return exactly one item per segment, in order, and translate each segment in full. A segment may start or end mid-sentence; translate it as it is without merging it with its neighbors.
            Reply with JSON only, in this form: {"items": [{"en": "...", "zh": "..."}]}
            """
        if !glossary.isEmpty {
            system += "\n\nCourse glossary (\"English = preferred translation\"; lines without \"=\" are terms that may come up):\n"
                + glossary.joined(separator: "\n")
        }
        self.system = system
        previewSystem = """
            You write live \(targetLanguage) subtitles for a lecture on \(topic). The input is what the speaker has said so far, straight from speech recognition: it may stop mid-sentence and some words may be misheard. Translate it into natural \(targetLanguage), quietly fixing obvious misrecognitions. Output only the translation.
            """
    }

    /// The request for a batch: recent translated lines for context, then the new segments.
    func request(for batch: [Segment]) -> String {
        var prompt = ""
        if !history.isEmpty {
            prompt += "Earlier in the lecture (context only, already translated):\n"
            for h in history { prompt += "EN: \(h.en)\nZH: \(h.zh)\n" }
            prompt += "\n"
        }
        prompt += "New segments:\n"
        for (i, segment) in batch.enumerated() { prompt += "\(i + 1). \(segment.text)\n" }
        return prompt
    }

    /// Parses a reply into lines (merged if the count doesn't match) and remembers them.
    func lines(for batch: [Segment], reply text: String) throws -> [Line] {
        // Some models wrap the JSON in a code fence or a sentence; take the outermost object.
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let items = try? JSONDecoder().decode(Reply.self, from: Data(text[open...close].utf8)).items,
              !items.isEmpty
        else { throw APIError.badResponse }
        let lines: [Line]
        if items.count == batch.count {
            lines = zip(batch, items).map { Line(start: $0.start, en: $1.en, zh: $1.zh) }
        } else {
            lines = [Line(start: batch[0].start, en: items.map(\.en).joined(separator: " "),
                          zh: items.map(\.zh).joined())]
        }
        history += lines.compactMap { line in line.zh.map { (line.en, $0) } }
        history = Array(history.suffix(6))
        return lines
    }
}

/// Tries once more after a retryable failure.
func withRetry<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let error as APIError where error.isRetryable {
        try? await Task.sleep(for: .seconds(1))
    } catch is URLError {
        try? await Task.sleep(for: .seconds(1))
    }
    return try await body()
}

/// Claude via the Anthropic Messages API (raw HTTP; there is no official Swift SDK).
final class ClaudeTranslator: AITranslator {
    let model: String
    var label: String { "Claude（\(model)）" }
    private(set) var disabled = false
    private let apiKey: String
    private let brief: TranslationBrief

    init(apiKey: String, model: String, brief: TranslationBrief) {
        self.apiKey = apiKey
        self.model = model
        self.brief = brief
    }

    func translate(_ batch: [Segment]) async throws -> [Line] {
        let prompt = brief.request(for: batch)
        return try await withRetry { try brief.lines(for: batch, reply: try await complete(prompt)) }
    }

    func preview(_ text: String, onUpdate: (String, Bool) async -> Void) async throws {
        let request = try makeRequest(system: brief.previewSystem, cacheSystem: false, prompt: text,
                                      maxTokens: 1024, format: nil, stream: true)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw failure(status: status, body: body)
        }
        var translation = ""
        for try await line in bytes.lines where line.hasPrefix("data:") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))) as? [String: Any]
            else { continue }
            if event["type"] as? String == "error" {
                throw APIError.http(0, (event["error"] as? [String: Any])?["message"] as? String ?? "")
            }
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let piece = delta["text"] as? String
            else { continue }
            translation += piece
            await onUpdate(translation, false)
        }
        await onUpdate(translation, true)
    }

    func ping() async throws -> String {
        let request = try makeRequest(system: "Reply with OK.", cacheSystem: false, prompt: "ping",
                                      maxTokens: 16, format: nil, stream: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw failure(status: status, body: data) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["model"] as? String ?? model
    }

    /// One structured-output request; returns the reply's JSON text.
    private func complete(_ prompt: String) async throws -> String {
        let item: [String: Any] = [
            "type": "object",
            "properties": ["en": ["type": "string"], "zh": ["type": "string"]],
            "required": ["en", "zh"],
            "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["items": ["type": "array", "items": item]],
            "required": ["items"],
            "additionalProperties": false,
        ]
        let request = try makeRequest(system: brief.system, cacheSystem: true, prompt: prompt, maxTokens: 16000,
                                      format: ["type": "json_schema", "schema": schema], stream: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw failure(status: status, body: data) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if json["stop_reason"] as? String == "refusal" { throw APIError.refused }
        guard let blocks = json["content"] as? [[String: Any]],
              let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw APIError.badResponse }
        return text
    }

    private func makeRequest(system: String, cacheSystem: Bool, prompt: String, maxTokens: Int,
                             format: [String: Any]?, stream: Bool) throws -> URLRequest {
        var outputConfig: [String: Any] = [:]
        if let format { outputConfig["format"] = format }
        // Short, latency-sensitive tasks: keep thinking light. Haiku 4.5 doesn't take `effort`.
        if !model.contains("haiku") { outputConfig["effort"] = "low" }
        var systemBlock: [String: Any] = ["type": "text", "text": system]
        if cacheSystem { systemBlock["cache_control"] = ["type": "ephemeral"] }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": [systemBlock],
            "messages": [["role": "user", "content": prompt]],
            "output_config": outputConfig,
        ]
        if stream { body["stream"] = true }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // If a safety classifier declines, let the API retry on its recommended fallback model.
        if model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable") {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func failure(status: Int, body: Data) -> APIError {
        let error = APIError(status: status, body: body)
        if case .unauthorized = error { disabled = true }
        return error
    }
}

/// Any OpenAI-style chat-completions API: DeepSeek, Qwen, Kimi, a local Ollama server …
final class OpenAICompatibleTranslator: AITranslator {
    let label: String
    private(set) var disabled = false
    private let endpoint: URL
    private let apiKey: String  // empty for local servers
    private let model: String
    private let extraBody: [String: Any]
    private let brief: TranslationBrief
    private var jsonMode = true  // off once a server rejects `response_format`

    init(name: String, baseURL: URL, apiKey: String, model: String, extraBody: [String: Any] = [:],
         brief: TranslationBrief) {
        label = "\(name)（\(model)）"
        endpoint = baseURL.appendingPathComponent("chat/completions")
        self.apiKey = apiKey
        self.model = model
        self.extraBody = extraBody
        self.brief = brief
    }

    func translate(_ batch: [Segment]) async throws -> [Line] {
        let prompt = brief.request(for: batch)
        return try await withRetry { try brief.lines(for: batch, reply: try await complete(prompt)) }
    }

    func preview(_ text: String, onUpdate: (String, Bool) async -> Void) async throws {
        let request = try makeRequest(system: brief.previewSystem, prompt: text, json: false, stream: true)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw failure(status: status, body: body)
        }
        var translation = ""
        for try await line in bytes.lines where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
                  let delta = (event["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any],
                  let piece = delta["content"] as? String, !piece.isEmpty
            else { continue }
            translation += piece
            await onUpdate(translation, false)
        }
        await onUpdate(translation, true)
    }

    func ping() async throws -> String {
        var request = try makeRequest(system: "Reply with OK.", prompt: "ping", json: false, stream: false)
        var body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        body["max_tokens"] = 16
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw failure(status: status, body: data) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["model"] as? String ?? model
    }

    /// One JSON-mode request; returns the reply's JSON text.
    private func complete(_ prompt: String) async throws -> String {
        let request = try makeRequest(system: brief.system, prompt: prompt, json: jsonMode, stream: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400, jsonMode, String(decoding: data, as: UTF8.self).contains("response_format") {
            // JSON mode isn't universal; the system prompt already asks for JSON, so go without.
            jsonMode = false
            return try await complete(prompt)
        }
        guard status == 200 else { throw failure(status: status, body: data) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty
        else { throw APIError.badResponse }
        return text
    }

    private func makeRequest(system: String, prompt: String, json: Bool, stream: Bool) throws -> URLRequest {
        var body = extraBody
        body["model"] = model
        body["messages"] = [["role": "system", "content": system], ["role": "user", "content": prompt]]
        body["max_tokens"] = json ? 4096 : 1024  // only widely supported parameters: servers differ on the rest
        if json { body["response_format"] = ["type": "json_object"] }
        if stream { body["stream"] = true }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func failure(status: Int, body: Data) -> APIError {
        let error = APIError(status: status, body: body)
        if case .unauthorized = error { disabled = true }
        return error
    }
}

/// Final translation of finished segments: the AI backend when configured (falling back
/// to on-device translation when a request fails), otherwise on-device only.
final class FinalTranslator {
    private let ai: AITranslator?
    private let local: Translator?
    private let console: Console
    private var lastWarning = ""

    init(ai: AITranslator?, local: Translator?, console: Console) {
        self.ai = ai
        self.local = local
        self.console = console
    }

    func finalize(_ batch: [Segment]) async -> [Line] {
        if let ai, !ai.disabled {
            do {
                return try await ai.translate(batch)
            } catch {
                let warning = "⚠️ AI 翻译失败（\(reason(error))），这几句改用本地翻译" + (ai.disabled ? "，本次不再调用 AI。" : "。")
                if warning != lastWarning {
                    lastWarning = warning
                    await console.emit(warning)
                }
            }
        }
        var lines: [Line] = []
        for segment in batch {
            let zh = try? await local?.translate(segment.text)
            lines.append(Line(start: segment.start, en: segment.text, zh: zh))
        }
        return lines
    }
}

struct Translation {
    let preview: AITranslator?
    let final: FinalTranslator
}

func reason(_ error: Error) -> String {
    (error as? APIError)?.description ?? error.localizedDescription
}

/// Where an AI backend lives and which key it needs.
struct Provider {
    let name: String
    let model: String
    let keyVariable: String?  // nil: no key needed (local server)
    let keyPrefix: String?
    let make: (_ key: String, _ brief: TranslationBrief) -> AITranslator

    /// `--provider auto` picks Claude, then DeepSeek, whichever has a key set.
    static func resolve(_ o: Options) throws -> Provider? {
        let env = ProcessInfo.processInfo.environment
        switch o.provider {
        case "auto":
            if !(env["ANTHROPIC_API_KEY"] ?? "").isEmpty { return claude(o) }
            if !(env["DEEPSEEK_API_KEY"] ?? "").isEmpty { return deepseek(o) }
            return claude(o)  // not configured; reported as missing key
        case "claude": return claude(o)
        case "deepseek": return deepseek(o)
        case "openai":
            guard let base = o.apiBase.flatMap(URL.init(string:)) else {
                throw CLIError("--provider openai 需要 --api-base <地址>，比如 http://localhost:11434/v1")
            }
            guard let model = o.model else { throw CLIError("--provider openai 需要 --model <模型名>") }
            return Provider(name: base.host ?? "OpenAI 兼容接口", model: model, keyVariable: o.apiKeyVariable,
                            keyPrefix: nil) { key, brief in
                OpenAICompatibleTranslator(name: base.host ?? "API", baseURL: base, apiKey: key, model: model, brief: brief)
            }
        default:
            throw CLIError("不认识的 --provider \(o.provider)（可选：claude、deepseek、openai）")
        }
    }

    static func claude(_ o: Options) -> Provider {
        let model = o.model ?? "claude-sonnet-5"
        return Provider(name: "Claude", model: model, keyVariable: "ANTHROPIC_API_KEY", keyPrefix: "sk-ant-") { key, brief in
            ClaudeTranslator(apiKey: key, model: model, brief: brief)
        }
    }

    static func deepseek(_ o: Options) -> Provider {
        let model = o.model ?? "deepseek-flash"
        return Provider(name: "DeepSeek", model: model, keyVariable: o.apiKeyVariable ?? "DEEPSEEK_API_KEY",
                        keyPrefix: "sk-") { key, brief in
            OpenAICompatibleTranslator(
                name: "DeepSeek", baseURL: URL(string: o.apiBase ?? "https://api.deepseek.com")!, apiKey: key,
                model: model,
                extraBody: ["thinking": ["type": "disabled"]],  // on by default; far too slow for live subtitles
                brief: brief)
        }
    }

    /// The key from the environment, or why it can't be used.
    func key() -> (key: String, problem: String?) {
        guard let keyVariable else { return ("", nil) }
        let key = (ProcessInfo.processInfo.environment[keyVariable] ?? "").trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return ("", "没有设置 \(keyVariable)") }
        if let problem = apiKeyProblem(key, prefix: keyPrefix) { return (key, "\(keyVariable) 看起来不对（\(problem)）") }
        return (key, nil)
    }
}

/// Catches a key that was pasted twice, cut short, or picked up stale from an old shell.
func apiKeyProblem(_ key: String, prefix: String?) -> String? {
    if key.contains(where: { $0.isWhitespace || $0 == "\"" }) { return "里面有空格或引号" }
    if key.count > 300 { return "长度 \(key.count)，太长了，可能粘贴了多次" }
    guard let prefix else { return nil }
    if !key.hasPrefix(prefix) { return "不是以 \(prefix) 开头" }
    if key.components(separatedBy: prefix).count > 2 { return "里面有好几个 key，可能粘贴了多次" }
    if key.count < 20 { return "长度 \(key.count)，太短了" }
    return nil
}

func targetLanguageName(_ identifier: String) -> String {
    if identifier.hasPrefix("zh-Hant") || identifier == "zh-TW" || identifier == "zh-HK" { return "Traditional Chinese" }
    if identifier.hasPrefix("zh") { return "Simplified Chinese" }
    return Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? identifier
}

func setUpTranslation(_ o: Options, glossary: [String], console: Console) async throws -> Translation? {
    guard o.translate else { return nil }
    let from = Locale(identifier: o.from).language
    let to = Locale.Language(identifier: o.to)
    let localStatus = await LanguageAvailability().status(from: from, to: to)
    let localReady = localStatus == .installed

    var ai: AITranslator?
    if o.ai, let provider = try Provider.resolve(o) {
        let (key, problem) = provider.key()
        if let problem {
            await console.emit("⚠️ \(problem)，这次不用 AI 翻译。"
                + (key.isEmpty ? "" : "\n   如果刚改过 ~/.zshrc：关掉这个终端标签页，开一个新的再运行。"))
        } else {
            let brief = TranslationBrief(topic: o.topic, targetLanguage: targetLanguageName(o.to), glossary: glossary)
            ai = provider.make(key, brief)
        }
    }

    guard localReady || ai != nil else {
        await console.emit("""
            ⚠️ 没有可用的 AI 翻译，本地翻译语言包也\(describe(localStatus))。这次先只转写英文。
               本地翻译的下载方法：系统设置 → 通用 → 语言与地区 → 最下面「翻译语言…」。

            """)
        return nil
    }
    if let ai {
        await console.emit("翻译：\(ai.label)"
            + (o.preview ? "边听边翻，每句定稿后再纠错精翻" : "每句定稿后纠错并翻译（实时翻译已关闭）"))
    } else {
        // The on-device model competes with speech recognition for the chip, so it only
        // translates finished sentences; live translation needs an API.
        await console.emit("翻译：本地翻译（效果一般），每句定稿后出中文")
    }
    return Translation(preview: o.preview ? ai : nil,
                       final: FinalTranslator(ai: ai,
                                              local: localReady ? Translator(from: from, to: to, fast: o.fast) : nil,
                                              console: console))
}

// MARK: - Speech setup

func describe(_ status: AssetInventory.Status) -> String {
    switch status {
    case .installed: return "已安装 ✓"
    case .downloading: return "下载中"
    case .supported: return "支持但未下载"
    case .unsupported: return "不支持"
    @unknown default: return "未知"
    }
}

struct Piece {
    let text: String
    let start: Double
    let end: Double
    let isFinal: Bool
}

/// SpeechTranscriber is the newer long-form model; DictationTranscriber is the
/// system dictation model, which is often already installed. Same analyzer, same results shape.
enum Engine {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var module: any SpeechModule {
        switch self {
        case .speech(let t): return t
        case .dictation(let t): return t
        }
    }

    var name: String {
        switch self {
        case .speech: return "SpeechTranscriber（长语音模型）"
        case .dictation: return "DictationTranscriber（系统听写模型，远场模式）"
        }
    }

    func pieces() -> AsyncThrowingStream<Piece, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch self {
                    case .speech(let t):
                        for try await r in t.results {
                            continuation.yield(Piece(text: String(r.text.characters), start: r.range.start.seconds,
                                                     end: r.range.end.seconds, isFinal: r.isFinal))
                        }
                    case .dictation(let t):
                        for try await r in t.results {
                            continuation.yield(Piece(text: String(r.text.characters), start: r.range.start.seconds,
                                                     end: r.range.end.seconds, isFinal: r.isFinal))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func candidates(for identifier: String, live: Bool) async -> [Engine] {
        let requested = Locale(identifier: identifier)
        var engines: [Engine] = []
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            engines.append(.speech(SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                     reportingOptions: live ? [.volatileResults] : [],
                                                     attributeOptions: [.audioTimeRange])))
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
            engines.append(.dictation(DictationTranscriber(locale: locale, contentHints: [.farField],
                                                           transcriptionOptions: [.punctuation],
                                                           reportingOptions: live ? [.volatileResults] : [],
                                                           attributeOptions: [.audioTimeRange])))
        }
        return engines
    }
}

/// Prefers an engine whose model is already installed; otherwise tries to
/// download one, giving up on a download that makes no progress.
func chooseEngine(_ identifier: String, live: Bool, console: Console) async throws -> Engine {
    let engines = await Engine.candidates(for: identifier, live: live)
    guard !engines.isEmpty else { throw CLIError("语音识别不支持 \(identifier)") }
    for engine in engines where await AssetInventory.status(forModules: [engine.module]) == .installed {
        return engine
    }
    for engine in engines where try await download(engine, console: console) {
        return engine
    }
    throw CLIError("""
        语音识别模型下载不了。可以试试：系统设置 → 键盘 → 听写，打开听写并把语言设成 English (US)，
        等它下载完再运行（用 ./livetrans --check 查看状态）。
        """)
}

func download(_ engine: Engine, console: Console) async throws -> Bool {
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [engine.module]) else {
        return true
    }
    await console.emit("正在下载语音识别模型：\(engine.name)…")
    let progress = request.progress
    let started = Date()
    let outcome = Outcome()
    let downloader = Task {
        do {
            try await request.downloadAndInstall()
            await outcome.resolve(true)
        } catch {
            await outcome.resolve(false)
        }
    }
    // The system sometimes accepts the request but never starts; don't hang forever.
    let watchdog = Task {
        while !Task.isCancelled {
            await console.setStatus(String(format: "下载中 %.0f%%", progress.fractionCompleted * 100))
            if progress.fractionCompleted == 0, Date().timeIntervalSince(started) > 60 {
                await outcome.resolve(false)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
    let ok = await outcome.value()
    watchdog.cancel()
    if !ok { downloader.cancel() }
    await console.setStatus("")
    if !ok { await console.emit("  这个模型没能下载，换下一个。") }
    return ok
}

/// First resolution wins; everyone awaiting `value()` gets it.
actor Outcome {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        waiters.forEach { $0.resume(returning: value) }
        waiters = []
    }

    func value() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

func ensureSpeechAuthorization() async {
    guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
    _ = await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
}

func ensureMicAccess() async throws {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return
    case .notDetermined: if await AVCaptureDevice.requestAccess(for: .audio) { return }
    default: break
    }
    throw CLIError("没有麦克风权限。请到 系统设置 → 隐私与安全性 → 麦克风，给你用的终端 App 打开，然后重开终端。")
}

struct Vocab {
    var topic: String?           // from a "# topic: ..." line
    var terms: [String] = []     // English terms: hints for speech recognition
    var glossary: [String] = []  // whole lines ("english = 中文"): guidance for Claude
}

/// `--vocab polymer` means livetrans/vocab/polymer.txt; a real path works too.
func resolveVocab(_ name: String) throws -> String {
    if FileManager.default.fileExists(atPath: name) { return name }
    let dir = toolDirectory().appendingPathComponent("vocab")
    for candidate in [name, name + ".txt"] {
        let path = dir.appendingPathComponent(candidate).path
        if FileManager.default.fileExists(atPath: path) { return path }
    }
    let available = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasSuffix(".txt") }.map { String($0.dropLast(4)) }.sorted()
    throw CLIError("找不到术语表 \(name)（现有的：\(available.joined(separator: "、"))）")
}

func loadVocab(_ path: String) throws -> Vocab {
    let all = try String(contentsOfFile: try resolveVocab(path), encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    let topic = all.first { $0.lowercased().hasPrefix("# topic:") }
        .map { String($0.dropFirst("# topic:".count)).trimmingCharacters(in: .whitespaces) }
    let lines = all.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    let terms = lines.map { $0.components(separatedBy: "=")[0].trimmingCharacters(in: .whitespaces) }
    return Vocab(topic: topic, terms: terms, glossary: lines)
}

// MARK: - Pipeline

func render(_ line: Line) -> String {
    var block = "\(ANSI.dim)[\(timestamp(line.start))]\(ANSI.reset) \(line.en)"
    if let zh = line.zh { block += "\n\(ANSI.cyan)\(zh)\(ANSI.reset)" }
    return block + "\n\n"
}

func seconds(_ value: Double) -> String { String(format: "%.2f", value) }

/// Three concurrent parts: recognition feeds the console; a preview task streams a
/// translation of the live text from Claude (at most one request a second, always the
/// newest text); a final task translates finished segments in order and commits them.
func runPipeline(pieces: AsyncThrowingStream<Piece, Error>, translation: Translation?, writer: TranscriptWriter,
                 console: Console, live: Bool, progress: ((Double) -> String)? = nil) async throws {
    let (previewReady, previewSink) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (finalReady, finalSink) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let previewer = live ? translation?.preview : nil
    await console.connect(previewReady: previewer == nil ? nil : previewSink, finalReady: finalSink, showLive: live)

    let previewTask = Task {
        guard let previewer else { return }
        var lastText = ""
        var lastStart = Date.distantPast
        var warned = false
        for await _ in previewReady {
            let wait = 1.0 - Date().timeIntervalSince(lastStart)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if previewer.disabled { return }
            let text = await console.previewSource()
            guard !text.isEmpty, text != lastText else { continue }
            lastText = text
            lastStart = Date()
            debug("preview request (\(text.count) chars)")
            do {
                try await previewer.preview(text) { await console.setPreview($0, complete: $1) }
            } catch {
                if Task.isCancelled { return }
                if previewer.disabled {
                    await console.emit("⚠️ API key 无效，这次改用本地翻译，只翻译定稿的句子。")
                    return
                }
                if !warned {
                    warned = true
                    await console.emit("⚠️ 边听边翻出错（\(reason(error))），定稿翻译不受影响。")
                }
            }
        }
    }
    let finalTask = Task {
        func drain() async {
            while true {
                let batch = await console.pendingBatch(max: 8)
                if batch.isEmpty { return }
                debug("final translation start: \(batch.count) segment(s)")
                let lines = await translation?.final.finalize(batch)
                    ?? batch.map { Line(start: $0.start, en: $0.text, zh: nil) }
                debug("final translation done")
                lines.forEach(writer.append)
                await console.commit(batch.count, output: lines.map(render).joined())
            }
        }
        for await _ in finalReady { await drain() }
        await drain()
    }

    do {
        for try await piece in pieces {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.isFinal {
                debug("final [\(seconds(piece.start))–\(seconds(piece.end))] \(text)")
                if !text.contains(where: { $0.isLetter || $0.isNumber }) {
                    await console.setVolatile("")
                } else {
                    await console.addFinal(Segment(start: piece.start, text: text))
                }
                if let progress { await console.setStatus(progress(piece.end)) }
            } else {
                debug("partial [\(seconds(piece.start))–\(seconds(piece.end))] …\(text.suffix(40))")
                await console.setVolatile(text)
            }
        }
    } catch {
        await console.endInput()
        previewTask.cancel()
        await finalTask.value
        throw error
    }
    await console.endInput()
    previewTask.cancel()
    await finalTask.value
}

/// Loudness of the first channel mapped to 0…1 (-60 dB … 0 dB).
func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
    var sum: Float = 0
    for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
    let rms = (sum / Float(buffer.frameLength)).squareRoot()
    guard rms > 0 else { return 0 }
    return max(0, min(1, (20 * log10(rms) + 60) / 60))
}

/// Resamples buffers into the format a recognizer wants.
func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
             to format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var fed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if fed {
            status.pointee = .noDataNow
            return nil
        }
        fed = true
        status.pointee = .haveData
        return buffer
    }
    return error == nil && output.frameLength > 0 ? output : nil
}

var interruptSource: DispatchSourceSignal?

/// First Ctrl-C stops recording and lets pending text finish; a second one quits immediately.
func onInterrupt(_ handler: @escaping () -> Void) {
    signal(SIGINT, SIG_IGN)
    var fired = false
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler {
        if fired { _exit(130) }
        fired = true
        handler()
    }
    source.resume()
    interruptSource = source
}

// MARK: - Audio input

/// The microphone, or (for testing) LIVETRANS_SIMULATE_MIC=<audio file> played through
/// the same live path in real time, so it can be exercised without making a sound.
final class AudioInput {
    private let engine = AVAudioEngine()
    private let simulated: AVAudioFile?
    private var stopped = false
    let format: AVAudioFormat

    init() throws {
        simulated = try ProcessInfo.processInfo.environment["LIVETRANS_SIMULATE_MIC"]
            .map { try AVAudioFile(forReading: URL(fileURLWithPath: $0)) }
        format = simulated?.processingFormat ?? engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CLIError("没有找到可用的麦克风") }
    }

    /// Delivers buffers until `stop()`; a simulated file also ends by itself and calls `onEnd`.
    func start(_ handler: @escaping (AVAudioPCMBuffer) -> Void, onEnd: @escaping () -> Void) throws {
        guard let file = simulated else {
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in handler(buffer) }
            engine.prepare()
            try engine.start()
            return
        }
        let format = self.format
        Task {
            let chunk = AVAudioFrameCount(format.sampleRate / 10)
            while !self.stopped, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                  (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 {
                handler(buffer)
                try? await Task.sleep(for: .milliseconds(100))
            }
            onEnd()
        }
    }

    func stop() {
        stopped = true
        guard simulated == nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
}

// MARK: - Whisper (whisper.cpp, on-device)

let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
let defaultWhisperModel = "ggml-large-v3-turbo-q5_0.bin"
let defaultVADModel = "ggml-silero-v5.1.2.bin"

/// Where the livetrans binary really lives (through any symlink); models/ and vocab/ sit next to it.
func toolDirectory() -> URL {
    (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .resolvingSymlinksInPath().deletingLastPathComponent()
}

func modelsDirectory() -> URL {
    toolDirectory().appendingPathComponent("models")
}

func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
    guard let data = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
}

/// Whisper sometimes "hears" stock phrases in noise or music; drop those and sound tags.
func cleanWhisperText(_ raw: String) -> String {
    let text = raw.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|♪"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let stock: Set<String> = ["you", "thank you.", "thank you", "thanks for watching!", "thanks for watching.",
                              "thank you for watching.", "thank you for watching!", "bye.", "bye!"]
    return stock.contains(text.lowercased()) ? "" : text
}

/// Short context for Whisper: the course and its terms help it spell technical words.
func whisperPrompt(topic: String, terms: [String]) -> String {
    var prompt = "A university lecture on \(topic)."
    if !terms.isEmpty { prompt += " Terms: " + terms.joined(separator: ", ") }
    return String(prompt.prefix(600)) + "."
}

/// A whisper.cpp model on the GPU. Calls are serialized on one queue.
final class Whisper: @unchecked Sendable {  // all whisper.cpp calls go through `queue`
    private let ctx: OpaquePointer
    private let language: String
    private let queue = DispatchQueue(label: "livetrans.whisper")

    init(modelPath: String, language: String) throws {
        whisper_log_set({ _, _, _ in }, nil)
        ggml_backend_load_all()  // ggml's Metal/CPU backends are plugins; nothing runs until they're loaded
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw CLIError("加载 Whisper 模型失败：\(modelPath)")
        }
        self.ctx = ctx
        self.language = language
    }

    deinit { whisper_free(ctx) }

    /// 16 kHz mono samples → text. `quick` (the live line) decodes greedily; otherwise a
    /// small beam search, a little slower and a little more accurate.
    func transcribe(_ samples: [Float], prompt: String, quick: Bool) async -> String {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.run(samples, prompt: prompt, quick: quick)) }
        }
    }

    private func run(_ samples: [Float], prompt: String, quick: Bool) -> String {
        var params = whisper_full_default_params(quick ? WHISPER_SAMPLING_GREEDY : WHISPER_SAMPLING_BEAM_SEARCH)
        params.n_threads = 4
        params.no_context = true
        params.no_timestamps = true
        params.single_segment = quick
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.suppress_nst = true
        if !quick { params.beam_search.beam_size = 3 }
        let status = language.withCString { language in
            prompt.withCString { prompt in
                params.language = language
                params.initial_prompt = prompt
                return samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
            }
        }
        guard status == 0 else { return "" }
        let text = (0..<whisper_full_n_segments(ctx))
            .map { String(cString: whisper_full_get_segment_text(ctx, $0)) }
            .joined()
        return cleanWhisperText(text)
    }
}

/// whisper.cpp's Silero VAD: probability of speech for each 32 ms frame.
final class VoiceDetector {
    static let frame = 512
    private let ctx: OpaquePointer

    init(modelPath: String) throws {
        var params = whisper_vad_default_context_params()
        params.n_threads = 1
        params.use_gpu = false
        guard let ctx = whisper_vad_init_from_file_with_params(modelPath, params) else {
            throw CLIError("加载 VAD 模型失败：\(modelPath)")
        }
        self.ctx = ctx
    }

    deinit { whisper_vad_free(ctx) }

    func probability(_ frame: [Float]) -> Float {
        let ok = frame.withUnsafeBufferPointer {
            whisper_vad_detect_speech_no_reset(ctx, $0.baseAddress, Int32($0.count))
        }
        let count = Int(whisper_vad_n_probs(ctx))
        guard ok, count > 0, let probs = whisper_vad_probs(ctx) else { return 0 }
        return probs[count - 1]
    }

    func reset() { whisper_vad_reset_state(ctx) }
}

/// Splits a 16 kHz stream into utterances with the VAD: speech starts after two voiced
/// frames, ends after 0.6 s without speech, and an utterance running past 12 s is cut
/// at the least speech-like frame of its last 3 s, so a lecturer who never pauses still
/// lands in the scrollback every few sentences. Not thread-safe.
final class Utterances {
    struct Chunk {
        let start: Double
        let samples: [Float]
        var end: Double { start + Double(samples.count) / 16000 }
    }

    private static let frame = VoiceDetector.frame
    private static let prerollFrames = 10     // ~0.3 s kept from before speech starts
    private static let endSilenceFrames = 19  // ~0.6 s
    private static let keptSilenceFrames = 6  // ~0.2 s left on the end
    private static let maxSamples = 12 * 16000

    private let vad: VoiceDetector
    private let emit: (Chunk) -> Void
    private var input: [Float] = []
    private var preroll: [Float] = []
    private var current: [Float] = []
    private var probs: [Float] = []  // one per frame of `current`
    private var start = 0.0
    private var consumed = 0
    private var voiced = 0
    private var silent = 0
    private var speaking = false
    private var id = 0

    init(vad: VoiceDetector, emit: @escaping (Chunk) -> Void) {
        self.vad = vad
        self.emit = emit
    }

    func append(_ samples: [Float]) {
        input += samples
        var offset = 0
        while input.count - offset >= Self.frame {
            let frame = Array(input[offset..<offset + Self.frame])
            offset += Self.frame
            step(frame, vad.probability(frame))
            consumed += Self.frame
        }
        input.removeFirst(offset)
    }

    /// The utterance being spoken right now, if any.
    func inProgress() -> (id: Int, start: Double, samples: [Float])? {
        speaking ? (id, start, current) : nil
    }

    func isCurrent(_ id: Int) -> Bool { speaking && self.id == id }

    /// End of input: emit whatever speech is in progress.
    func flush() {
        if speaking { emitChunk(current) }
        speaking = false
        current = []
        probs = []
    }

    private func step(_ frame: [Float], _ p: Float) {
        guard speaking else {
            preroll += frame
            if preroll.count > Self.prerollFrames * Self.frame { preroll.removeFirst(Self.frame) }
            voiced = p >= 0.5 ? voiced + 1 : 0
            if voiced >= 2 {
                speaking = true
                silent = 0
                id += 1
                current = preroll
                probs = Array(repeating: 1, count: preroll.count / Self.frame)
                start = Double(consumed + Self.frame - preroll.count) / 16000
                preroll = []
            }
            return
        }
        current += frame
        probs.append(p)
        silent = p < 0.35 ? silent + 1 : 0
        if silent >= Self.endSilenceFrames {
            emitChunk(Array(current.dropLast((silent - Self.keptSilenceFrames) * Self.frame)))
            preroll = Array(current.suffix(Self.prerollFrames * Self.frame))
            current = []
            probs = []
            speaking = false
            voiced = 0
            vad.reset()
        } else if current.count >= Self.maxSamples {
            let quietest = probs.indices.suffix(94).min { probs[$0] < probs[$1] } ?? probs.count - 1
            let cut = (quietest + 1) * Self.frame
            emitChunk(Array(current.prefix(cut)))
            current.removeFirst(cut)
            probs.removeFirst(quietest + 1)
            start += Double(cut) / 16000
            id += 1  // the rest counts as a new utterance for the live line
        }
    }

    private func emitChunk(_ samples: [Float]) {
        guard samples.count >= 16000 * 3 / 10 else { return }  // under 0.3 s: a click, not speech
        emit(Chunk(start: start, samples: samples))
    }
}

/// Speech → text with Whisper. The VAD cuts the audio into utterances; each finished one
/// gets a full pass (final text). While live, the one in progress also gets a quick pass
/// about once a second (the live line).
final class WhisperRecognizer: @unchecked Sendable {  // `utterances` is only touched on `queue`
    let pieces: AsyncThrowingStream<Piece, Error>
    private let sink: AsyncThrowingStream<Piece, Error>.Continuation
    private let chunkSink: AsyncStream<Utterances.Chunk>.Continuation
    private let whisper: Whisper
    private let basePrompt: String
    private let queue = DispatchQueue(label: "livetrans.vad")  // owns `utterances`
    private var utterances: Utterances!
    private var partialTask: Task<Void, Never>?
    private var lastFinal = ""
    private var finished = false

    init(whisper: Whisper, vad: VoiceDetector, prompt: String, live: Bool) {
        (pieces, sink) = AsyncThrowingStream.makeStream()
        let (chunks, chunkSink) = AsyncStream<Utterances.Chunk>.makeStream()
        self.chunkSink = chunkSink
        self.whisper = whisper
        basePrompt = prompt
        utterances = Utterances(vad: vad) { chunkSink.yield($0) }
        Task {
            for await chunk in chunks {
                let text = await whisper.transcribe(chunk.samples, prompt: self.prompt, quick: false)
                debug("whisper final [\(seconds(chunk.start))–\(seconds(chunk.end))] \(text)")
                guard !text.isEmpty else { continue }
                self.lastFinal = text
                self.sink.yield(Piece(text: text, start: chunk.start, end: chunk.end, isFinal: true))
            }
            self.sink.finish()
        }
        if live { partialTask = Task { await self.runPartials() } }
    }

    private var prompt: String {
        lastFinal.isEmpty ? basePrompt : basePrompt + " " + String(lastFinal.suffix(200))
    }

    func feed(_ samples: [Float]) {
        queue.async { self.utterances.append(samples) }
    }

    /// End of input: the last utterance is transcribed, then `pieces` finishes.
    func finish() async {
        guard !finished else { return }
        finished = true
        partialTask?.cancel()
        await withCheckedContinuation { continuation in
            queue.async {
                self.utterances.flush()
                continuation.resume()
            }
        }
        chunkSink.finish()
    }

    private func runPartials() async {
        var lastID = -1
        var lastCount = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard let now = queue.sync(execute: { utterances.inProgress() }),
                  now.samples.count >= 16000 * 7 / 10,
                  now.id != lastID || now.samples.count - lastCount >= 16000 * 8 / 10
            else { continue }
            lastID = now.id
            lastCount = now.samples.count
            let text = await whisper.transcribe(now.samples, prompt: prompt, quick: true)
            guard !text.isEmpty, queue.sync(execute: { utterances.isCurrent(now.id) }) else { continue }
            sink.yield(Piece(text: text, start: now.start,
                             end: now.start + Double(now.samples.count) / 16000, isFinal: false))
        }
    }
}

func runWhisperMic(recognizer: WhisperRecognizer, translation: Translation?,
                   writer: TranscriptWriter, console: Console) async throws {
    let input = try AudioInput()
    guard let converter = AVAudioConverter(from: input.format, to: whisperFormat) else {
        throw CLIError("无法匹配麦克风音频格式")
    }
    try input.start({ buffer in
        let level = rmsLevel(buffer)
        Task { await console.setLevel(level) }
        if let converted = convert(buffer, with: converter, to: whisperFormat) { recognizer.feed(samples(converted)) }
    }, onEnd: {
        Task { await recognizer.finish() }
    })
    onInterrupt {
        input.stop()
        Task {
            await console.emit("\n正在收尾…（再按一次 Ctrl-C 立即退出）")
            await recognizer.finish()
        }
    }
    await console.emit("🎙  正在听… 按 Ctrl-C 结束。记录保存在 \(writer.url.path)\n")
    try await runPipeline(pieces: recognizer.pieces, translation: translation, writer: writer, console: console, live: true)
}

func runWhisperFile(_ path: String, recognizer: WhisperRecognizer, translation: Translation?,
                    writer: TranscriptWriter, console: Console) async throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let duration = Double(file.length) / file.processingFormat.sampleRate
    guard let converter = AVAudioConverter(from: file.processingFormat, to: whisperFormat) else {
        throw CLIError("读不了这个音频格式")
    }
    await console.emit("处理 \(path)（\(timestamp(duration))）\n")
    Task {
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate)
        while let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
              (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 {
            if let converted = convert(buffer, with: converter, to: whisperFormat) { recognizer.feed(samples(converted)) }
        }
        await recognizer.finish()
    }
    try await runPipeline(pieces: recognizer.pieces, translation: translation, writer: writer, console: console,
                          live: false, progress: { String(format: "处理中 %.0f%%", min($0 / max(duration, 1), 1) * 100) })
}

// MARK: - Apple speech (fallback)

func runAppleMic(analyzer: SpeechAnalyzer, engine: Engine, translation: Translation?,
                 writer: TranscriptWriter, console: Console) async throws {
    let input = try AudioInput()
    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [engine.module],
                                                                             considering: input.format),
          let converter = AVAudioConverter(from: input.format, to: analyzerFormat)
    else { throw CLIError("无法匹配麦克风音频格式") }

    let (inputs, inputSink) = AsyncStream<AnalyzerInput>.makeStream()
    try await analyzer.prepareToAnalyze(in: analyzerFormat)
    try await analyzer.start(inputSequence: inputs)
    let finish = {
        inputSink.finish()
        Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }
    try input.start({ buffer in
        let level = rmsLevel(buffer)
        Task { await console.setLevel(level) }
        if let converted = convert(buffer, with: converter, to: analyzerFormat) {
            inputSink.yield(AnalyzerInput(buffer: converted))
        }
    }, onEnd: finish)
    onInterrupt {
        input.stop()
        Task { await console.emit("\n正在收尾…（再按一次 Ctrl-C 立即退出）") }
        finish()
    }
    await console.emit("🎙  正在听… 按 Ctrl-C 结束。记录保存在 \(writer.url.path)\n")
    try await runPipeline(pieces: engine.pieces(), translation: translation, writer: writer, console: console, live: true)
}

func runAppleFile(_ path: String, analyzer: SpeechAnalyzer, engine: Engine,
                  translation: Translation?, writer: TranscriptWriter, console: Console) async throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let duration = Double(file.length) / file.processingFormat.sampleRate
    await console.emit("处理 \(path)（\(timestamp(duration))）\n")
    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
    try await runPipeline(pieces: engine.pieces(), translation: translation, writer: writer, console: console,
                          live: false, progress: { String(format: "处理中 %.0f%%", min($0 / max(duration, 1), 1) * 100) })
}

// MARK: - Main

@main
struct LiveTrans {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        do {
            try await run(try parseOptions())
        } catch {
            let message = (error as? CLIError)?.description ?? error.localizedDescription
            FileHandle.standardError.write(Data("\n错误：\(message)\n".utf8))
            _exit(1)
        }
        // Everything is written by now. Skip C++ static teardown: ggml's Metal backend
        // asserts if it's torn down while a Whisper context still holds GPU buffers.
        _exit(0)
    }

    static func whisperModelPath(_ o: Options) -> String {
        o.whisperModel ?? modelsDirectory().appendingPathComponent(defaultWhisperModel).path
    }

    static func check(_ o: Options) async {
        let fm = FileManager.default
        let whisper = whisperModelPath(o)
        let vad = modelsDirectory().appendingPathComponent(defaultVADModel).path
        print("Whisper 模型：", fm.fileExists(atPath: whisper) ? "已安装 ✓（\(URL(fileURLWithPath: whisper).lastPathComponent)）" : "没找到 \(whisper)")
        print("VAD 模型：", fm.fileExists(atPath: vad) ? "已安装 ✓" : "没找到 \(vad)")
        let engines = await Engine.candidates(for: o.from, live: true)
        for engine in engines {
            print("\(engine.name)（后备）：", describe(await AssetInventory.status(forModules: [engine.module])))
        }
        let status = await LanguageAvailability().status(from: Locale(identifier: o.from).language,
                                                          to: Locale.Language(identifier: o.to))
        print("本地翻译语言包（\(o.from) → \(o.to)）：", describe(status))
        do {
            if let provider = try Provider.resolve(o) {
                let (key, problem) = provider.key()
                if let problem {
                    print("AI 翻译： \(provider.name) —— \(problem)（没有 AI 时只用本地翻译，效果一般）")
                } else {
                    print("AI 翻译： \(provider.name)（设定的模型 \(provider.model)）")
                    let brief = TranslationBrief(topic: "", targetLanguage: "Simplified Chinese", glossary: [])
                    do {
                        let served = try await provider.make(key, brief).ping()
                        print("连接测试： ✓ key 可用，服务器实际使用的模型：\(served)")
                    } catch {
                        print("连接测试： ✗ \(reason(error))")
                    }
                }
            }
        } catch {
            print("AI 翻译： \(error)")
        }
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "已授权 ✓"
        case .notDetermined: mic = "还没问过（第一次录音时会弹窗）"
        default: mic = "被拒绝 —— 去 系统设置 → 隐私与安全性 → 麦克风 打开"
        }
        print("麦克风权限：", mic)
    }

    static func run(_ options: Options) async throws {
        if options.check { return await check(options) }

        let console = Console()
        let live = options.audioFile == nil
        let vocab = try options.vocabPath.map(loadVocab) ?? Vocab()
        var o = options
        if o.topic.isEmpty { o.topic = vocab.topic ?? "a university course" }
        let whisperModel = whisperModelPath(o)
        let vadModel = modelsDirectory().appendingPathComponent(defaultVADModel).path
        let haveWhisper = FileManager.default.fileExists(atPath: whisperModel)
            && FileManager.default.fileExists(atPath: vadModel)
        if o.engine == "whisper" && !haveWhisper { throw CLIError("找不到 Whisper 模型：\(whisperModel)") }

        var recognizer: WhisperRecognizer?
        var apple: (engine: Engine, analyzer: SpeechAnalyzer)?
        if haveWhisper && o.engine != "apple" {
            await console.emit("识别引擎：Whisper large-v3-turbo（本地）")
            await console.setStatus("正在加载 Whisper 模型…")
            let whisper = try Whisper(modelPath: whisperModel, language: String(o.from.prefix(2)))
            _ = await whisper.transcribe([Float](repeating: 0, count: 16000), prompt: "", quick: true)  // warm up the GPU
            await console.setStatus("")
            recognizer = WhisperRecognizer(whisper: whisper, vad: try VoiceDetector(modelPath: vadModel),
                                           prompt: whisperPrompt(topic: o.topic, terms: vocab.terms), live: live)
        } else {
            await ensureSpeechAuthorization()
            let engine = try await chooseEngine(o.from, live: live, console: console)
            await console.emit("识别引擎：\(engine.name)" + (o.engine == "apple" ? "" : "（没找到 Whisper 模型）"))
            let analyzer = SpeechAnalyzer(modules: [engine.module])
            if !vocab.terms.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocab.terms
                try await analyzer.setContext(context)
            }
            apple = (engine, analyzer)
        }
        let translation = try await setUpTranslation(o, glossary: vocab.glossary, console: console)

        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)_\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))-\(minute: .twoDigits)",
                                               timeZone: .current, calendar: .current))
        let name = o.audioFile.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? stamp
        let outURL = URL(fileURLWithPath: o.outPath ?? "transcripts/\(name).md")
        let writer = try TranscriptWriter(url: outURL, title: live ? "课堂录音 \(stamp)" : name)

        if !live { /* no microphone needed */ } else { try await ensureMicAccess() }
        switch (recognizer, apple, o.audioFile) {
        case let (recognizer?, _, path?):
            try await runWhisperFile(path, recognizer: recognizer, translation: translation, writer: writer, console: console)
        case let (recognizer?, _, nil):
            try await runWhisperMic(recognizer: recognizer, translation: translation, writer: writer, console: console)
        case let (nil, apple?, path?):
            try await runAppleFile(path, analyzer: apple.analyzer, engine: apple.engine, translation: translation,
                                   writer: writer, console: console)
        case let (nil, apple?, nil):
            try await runAppleMic(analyzer: apple.analyzer, engine: apple.engine, translation: translation,
                                  writer: writer, console: console)
        default:
            throw CLIError("没有可用的识别引擎")
        }
        await console.close()
        await console.emit("✅ 已保存：\(writer.url.path)")
    }
}
