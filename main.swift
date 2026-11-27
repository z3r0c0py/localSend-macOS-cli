// localsend-cli — Send and receive files via the LocalSend v2 protocol.
// macOS 12+, Swift 5.7.
//

import Foundation
import Network
import CryptoKit
import UniformTypeIdentifiers

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

let PORT: UInt16 = 53317
let MULTICAST_ADDR = "224.0.0.167"
let PROTOCOL_VERSION = "2.0"
let CHUNK = 65536

// ---------------------------------------------------------------------------
// Logging & small utilities
// ---------------------------------------------------------------------------

private let logLock = NSLock()
private var logFileHandle: FileHandle?
private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func configureLogFile(_ path: String?) {
    guard let path, !path.isEmpty else { return }
    let expanded = (path as NSString).expandingTildeInPath
    let abs = (expanded as NSString).standardizingPath
    let dir = (abs as NSString).deletingLastPathComponent

    _ = try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    if !FileManager.default.fileExists(atPath: abs) {
        FileManager.default.createFile(atPath: abs, contents: nil)
    }
    logFileHandle = FileHandle(forWritingAtPath: abs)

    _ = try? logFileHandle?.seekToEnd()
}

private func writeLogLine(_ line: String, to handle: FileHandle) {
    let ts = isoFormatter.string(from: Date())
    if let data = "[\(ts)] \(line)\n".data(using: .utf8) {
        try? handle.write(contentsOf: data)
    }
}

func logInfo(_ s: String) {
    logLock.lock(); defer { logLock.unlock() }
    print(s)
    fflush(stdout)
    if let fh = logFileHandle {
        writeLogLine(s, to: fh)
    }
}

func errPrint(_ s: String) {
    logLock.lock(); defer { logLock.unlock() }
    let msg = s + "\n"
    if let data = msg.data(using: .utf8) {
        try? FileHandle.standardError.write(contentsOf: data)
    }
    if let fh = logFileHandle {
        writeLogLine("ERR: \(s)", to: fh)
    }
}

func exitWithError(_ s: String) -> Never {
    errPrint(s)
    exit(1)
}

func hostname() -> String {
    if let name = Host.current().localizedName, !name.isEmpty { return name }
    return ProcessInfo.processInfo.hostName
}

func guessMimeType(_ fileName: String) -> String {
    let ext = (fileName as NSString).pathExtension.lowercased()
    if !ext.isEmpty, let utType = UTType(filenameExtension: ext), let mime = utType.preferredMIMEType {
        return mime
    }
    let fallback: [String: String] = [
        "mkv": "video/x-matroska",
        "tar": "application/x-tar",
    ]
    return fallback[ext] ?? "application/octet-stream"
}

func normalizeIP(_ raw: String) -> String {
    var s = raw
    if let pct = s.firstIndex(of: "%") {
        s = String(s[..<pct])
    }
    let prefix = "::ffff:"
    if s.lowercased().hasPrefix(prefix) {
        s = String(s.dropFirst(prefix.count))
    }
    return s
}

func fileSize(_ path: String) -> Int {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    return (attrs?[.size] as? NSNumber)?.intValue ?? 0
}

func percentEncodeQueryValue(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+/")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

// ---------------------------------------------------------------------------
// Protocol models
// ---------------------------------------------------------------------------

struct DeviceInfo: Codable {
    var alias: String
    var version: String
    var deviceModel: String?
    var deviceType: String?
    var fingerprint: String
    var port: Int
    var scheme: String
    var download: Bool
    var announce: Bool?

    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port
        case scheme = "protocol"
        case download, announce
    }

    var typeText: String { deviceType ?? "unknown" }
    var modelText: String { deviceModel ?? "unknown" }
}

// Lenient decoding: peers may omit or null several fields.
// Lives in an extension so the memberwise initializer is preserved.
extension DeviceInfo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias       = try c.decode(String.self, forKey: .alias)
        version     = try c.decodeIfPresent(String.self, forKey: .version) ?? "2.0"
        deviceModel = try c.decodeIfPresent(String.self, forKey: .deviceModel)
        deviceType  = try c.decodeIfPresent(String.self, forKey: .deviceType)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        port        = try c.decodeIfPresent(Int.self, forKey: .port) ?? Int(PORT)
        scheme      = try c.decodeIfPresent(String.self, forKey: .scheme) ?? "https"
        download    = try c.decodeIfPresent(Bool.self, forKey: .download) ?? false
        announce    = try c.decodeIfPresent(Bool.self, forKey: .announce)
    }
}

struct FileMeta: Codable {
    let id: String
    let fileName: String
    let size: Int
    let fileType: String
    let sha256: String?
    let preview: String?
}

struct PrepareUploadRequest: Codable {
    let info: DeviceInfo
    let files: [String: FileMeta]
}

struct PrepareUploadResponse: Codable {
    let sessionId: String
    let files: [String: String?]
}

func deviceInfo(alias: String, fingerprint: String, port: Int = Int(PORT), announce: Bool? = nil) -> DeviceInfo {
    DeviceInfo(
        alias: alias,
        version: PROTOCOL_VERSION,
        deviceModel: "macOS",
        deviceType: "headless",
        fingerprint: fingerprint,
        port: port,
        scheme: "https",
        download: false,
        announce: announce
    )
}

// ---------------------------------------------------------------------------
// TLS: self-signed certificate generation (via /usr/bin/openssl)
// ---------------------------------------------------------------------------

struct Certificate {
    let identity: SecIdentity
    let fingerprint: String
}

func runCommand(_ args: [String], input: Data? = nil) -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    p.arguments = args
    let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    p.standardError = errPipe
    do {
        try p.run()
    } catch {
        exitWithError("Failed to launch openssl: \(error)")
    }
    if let input { inPipe.fileHandleForWriting.write(input) }
    inPipe.fileHandleForWriting.closeFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        exitWithError("openssl failed: \(err)")
    }
    return outPipe.fileHandleForReading.readDataToEndOfFile()
}

func generateSelfSignedCert() -> Certificate {
    let tmp = NSTemporaryDirectory() + "localsend-cli-" + UUID().uuidString
    do {
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    } catch {
        exitWithError("Failed to create temp dir: \(error)")
    }
    defer {
        _ = try? FileManager.default.removeItem(atPath: tmp)
    }

    let keyPath = tmp + "/key.pem"
    let certPath = tmp + "/cert.pem"
    let p12Path = tmp + "/id.p12"

    // !!! IMPORTANT — DO NOT "SIMPLIFY" THIS BACK TO `-subj "/CN=localsend-cli"` !!!
    // macOS's system /usr/bin/openssl is LibreSSL. With just `req -x509 -subj ...` it
    // produces a version 1 certificate with no extensions. LocalSend peers (e.g. the iOS
    // app) require mutual TLS and REJECT that certificate: the TLS handshake completes,
    // then the peer drops the connection ("The network connection was lost", -1005;
    // curl shows "alert certificate unknown"). Discovery and `send --ip` then fail with
    // "Could not reach device" even though the network is fine.
    // Fix: request a version 3 certificate with extensions via the config file below.
    // Homebrew OpenSSL is NOT required; it just happens to emit v3 certs by default.
    // To verify any change here: run `openssl x509 -in cert.pem -noout -text | grep Version`
    // and expect "Version: 3 (0x2)".
    let confPath = tmp + "/openssl.cnf"
    let conf = """
    [req]
    distinguished_name = dn
    prompt = no
    x509_extensions = v3
    [dn]
    CN = localsend-cli
    [v3]
    basicConstraints = CA:TRUE
    subjectKeyIdentifier = hash
    """
    do { try conf.write(toFile: confPath, atomically: true, encoding: .utf8) }
    catch { exitWithError("Failed to write openssl config: \(error)") }

    _ = runCommand(["req", "-x509", "-newkey", "rsa:2048",
                    "-keyout", keyPath, "-out", certPath,
                    "-days", "1", "-nodes",
                    "-config", confPath])

    let der = runCommand(["x509", "-in", certPath, "-outform", "DER"])
    let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()

    _ = runCommand(["pkcs12", "-export",
                    "-inkey", keyPath, "-in", certPath,
                    "-out", p12Path, "-passout", "pass:localsend-cli"])

    guard let p12 = FileManager.default.contents(atPath: p12Path) else {
        exitWithError("Failed to read generated identity")
    }
    var items: CFArray?
    // Fix #7: keep the identity in memory; don't add one to the user's keychain on every run.
    let options = [
        kSecImportExportPassphrase as String: "localsend-cli",
        kSecImportToMemoryOnly as String: true,
    ] as CFDictionary
    let status = SecPKCS12Import(p12 as CFData, options, &items)
    guard status == errSecSuccess,
          let array = items as? [[String: Any]],
          let identity = array.first?[kSecImportItemIdentity as String] as! SecIdentity? else {
        exitWithError("Failed to import PKCS12 identity (status \(status))")
    }
    globalClientIdentity = identity
    return Certificate(identity: identity, fingerprint: fingerprint)
}

// ---------------------------------------------------------------------------
// Device discovery state
// ---------------------------------------------------------------------------

struct DiscoveredDevice {
    let ip: String
    let info: DeviceInfo
}

final class DeviceRegistry {
    private let lock = NSLock()
    private var devices: [String: DiscoveredDevice] = [:]
    let ownFingerprint: String

    init(ownFingerprint: String) { self.ownFingerprint = ownFingerprint }

    func add(_ device: DiscoveredDevice) {
        lock.lock(); defer { lock.unlock() }
        if !device.info.fingerprint.isEmpty, device.info.fingerprint != ownFingerprint {
            devices[device.info.fingerprint] = DiscoveredDevice(ip: normalizeIP(device.ip), info: device.info)
        }
    }

    func all() -> [DiscoveredDevice] {
        lock.lock(); defer { lock.unlock() }
        return Array(devices.values)
    }
}

// ---------------------------------------------------------------------------
// HTTP over Network.framework (with TLS)
// ---------------------------------------------------------------------------

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
    let remoteIP: String
}

struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json(_ status: Int, _ obj: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    static func codable<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    static func text(_ status: Int, _ text: String = "") -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain", body: Data(text.utf8))
    }

    static let ok = HTTPResponse(status: 200, contentType: "text/plain", body: Data("OK".utf8))
}

func statusText(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 204: return "No Content"
    case 400: return "Bad Request"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 409: return "Conflict"
    case 411: return "Length Required"
    case 500: return "Internal Server Error"
    default: return "Unknown Status"
    }
}

final class HTTPServerConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void
    private var buf: [UInt8] = []
    private var closed = false
    // CRITICAL: NWConnection crashes or behaves erratically if you arm multiple `.receive()`
    // calls simultaneously. This flag ensures we only ever have one pending read at a time.
    private var isReceiving = false

    // Fix #1: server sets this so it can drop its strong reference when we close.
    var onClose: (() -> Void)?

    // Streaming state for uploads
    private var streamFile: FileHandle?
    private var streamExpectedLength = 0
    private var streamRemaining = 0
    private var streamingReceived = 0
    private var streamingDest: String?
    private var streamingPath = ""
    private var tempDest: String?  // !ATOMIC! path to the temp file for atomic writes

    // Chunked upload decoding (senders that stream without a Content-Length header)
    private enum ChunkState { case size, data, dataEnd, trailer }
    private var chunked = false
    private var chunkState = ChunkState.size
    private var chunkRemaining = 0
    private var chunkPending: [UInt8] = []
    private var expectedMetaSize = -1

    weak var serverState: ReceiveState?

    init(connection: NWConnection, queue: DispatchQueue,
         handler: @escaping (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            self.queue.async {
                switch state {
                case .failed, .cancelled:
                    self.close()
                default:
                    break
                }
            }
        }
        receiveLoop()
    }

    /// Safe to call from any thread.
    func requestClose() {
        queue.async { self.close() }
    }

    /// Must run on the connection's queue.
    func close() {
        guard !closed else { return }
        closed = true
        if streamingActive {
            abortStreaming()
        }
        connection.cancel()
        let cb = onClose
        onClose = nil      // break the server<->connection retain path
        cb?()
    }

    private func abortStreaming() {
        _ = try? streamFile?.close()
        streamFile = nil

        // !! ATOMIC !! delete the temp file if it exists (atomic-write cleanup)
        if let temp = tempDest {
            _ = try? FileManager.default.removeItem(atPath: temp)
            tempDest = nil
        }

        if let dest = streamingDest {
            errPrint("  Incomplete upload discarded: \(dest) (\(streamingReceived)/\(streamExpectedLength) bytes)")
        }
        // !! DEAD SESSION !! don't leave the receiver wedged in a dead session.
        serverState?.resetSession()
        streamingDest = nil
        streamingPath = ""
        streamExpectedLength = 0
        streamRemaining = 0
        streamingReceived = 0
        resetChunkState()
    }

    private func resetChunkState() {
        chunked = false
        chunkState = .size
        chunkRemaining = 0
        chunkPending = []
        expectedMetaSize = -1
    }

    private func receiveLoop() {
        guard !closed, !isReceiving else { return }
        isReceiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            // Callbacks are delivered on `queue` (connection.start(queue:)).
            self.isReceiving = false
            guard !self.closed else { return }
            if let data = data, !data.isEmpty {
                self.buf.append(contentsOf: data)
            }
            if let error {
                errPrint("Connection receive error: \(error)")
                self.close()
                return
            }
            self.process()
            if !isComplete && !self.closed {
                self.receiveLoop()
            } else if self.streamingActive {
                self.abortStreaming()
                self.close()
            } else if self.buf.isEmpty {
                self.close()
            }
        }
    }

    private func remoteIP() -> String {
        if case .hostPort(let host, _) = connection.endpoint {
            switch host {
            case .ipv4(let address):
                return normalizeIP(address.debugDescription)
            case .ipv6(let address):
                return normalizeIP(address.debugDescription)
            default:
                break
            }
        }
        return normalizeIP(connection.endpoint.debugDescription)
    }

    private func process() {
        if streamingActive {
            if !buf.isEmpty {
                let chunk = buf
                buf.removeAll()
                if chunked { appendChunked(chunk) } else { appendStream(chunk) }
            }
            return
        }

        guard let headerEndIdx = findHeaderEnd() else { return }

        let headerBytes = Array(buf[0..<headerEndIdx])
        guard let headerText = String(bytes: headerBytes, encoding: .utf8) else {
            sendAndContinue(HTTPResponse.text(400, "Bad request"), closeAfter: true)
            return
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { close(); return }
        let requestLineParts = lines.removeFirst().split(separator: " ").map(String.init)
        guard requestLineParts.count >= 2 else {
            sendAndContinue(HTTPResponse.text(400, "Bad request"), closeAfter: true)
            return
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = max(0, Int(headers["content-length"] ?? "0") ?? 0)
        let bodyStart = headerEndIdx + 4
        let (path, query) = Self.splitURL(requestLineParts[1])

        // Stream all upload endpoints directly to disk, even if small enough to fit in first packet
        if isUploadPath(path) {
            startStreaming(path: path, query: query, headers: headers, headerEnd: bodyStart, contentLength: contentLength)
            return
        }

        let available = buf.count - bodyStart
        guard available >= contentLength else { return }

        let bodyEnd = bodyStart + contentLength
        let bodyData = Data(buf[bodyStart..<bodyEnd])
        buf.removeFirst(bodyEnd)

        let request = HTTPRequest(
            method: requestLineParts[0],
            path: path,
            query: query,
            headers: headers,
            body: bodyData,
            remoteIP: remoteIP()
        )
        let wantsClose = (headers["connection"] ?? "").lowercased() == "close"
        handler(request) { [weak self] response in
            guard let self = self else { return }
            self.queue.async {
                self.sendAndContinue(response, closeAfter: wantsClose)
            }
        }
    }

    private var streamingActive: Bool { streamFile != nil }

    private func findHeaderEnd() -> Int? {
        guard buf.count >= 4 else { return nil }
        for i in 0...(buf.count - 4) {
            if buf[i] == 13 && buf[i+1] == 10 && buf[i+2] == 13 && buf[i+3] == 10 { return i }
        }
        return nil
    }

    private func isUploadPath(_ path: String) -> Bool {
        path == "/api/localsend/v2/upload" || path == "/api/localsend/v1/send"
    }

    private func writeChunk(_ fh: FileHandle, bytes: [UInt8], count: Int, dest: String) -> Bool {
        guard count > 0 else { return true }
        do {
            try fh.write(contentsOf: Data(bytes[0..<count]))
            return true
        } catch {
            errPrint("Failed writing upload to \(dest): \(error)")
            abortStreaming()
            sendAndContinue(HTTPResponse.text(500, "Write failed"), closeAfter: true)
            return false
        }
    }

    private func startStreaming(path: String, query: [String: String], headers: [String: String],
                                headerEnd: Int, contentLength: Int) {
        let isV2 = path.contains("v2")
        let isChunked = (headers["transfer-encoding"] ?? "").lowercased().contains("chunked")

        // Never guess a length: refuse rather than silently saving an empty file.
        if !isChunked && headers["content-length"] == nil {
            errPrint("Upload rejected: no Content-Length and not chunked")
            buf.removeAll()
            sendAndContinue(HTTPResponse.text(411, "Length required"), closeAfter: true)
            return
        }

        // Fix #3: token is always validated (v1 and v2); session also for v2.
        guard let server = serverState,
              let grant = server.prepareUploadDestination(query: query, isV2: isV2) else {
            buf.removeAll()
            sendAndContinue(HTTPResponse.text(403, "Invalid session"), closeAfter: true)
            return
        }
        let baseDest = grant.path

        let initial = buf.count > headerEnd ? Array(buf[headerEnd...]) : []
        buf.removeAll()
        streamingPath = path
        streamExpectedLength = isChunked ? max(0, grant.size) : contentLength
        streamRemaining = contentLength
        expectedMetaSize = grant.size

        let fm = FileManager.default
        let parentDir = (baseDest as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        } catch {
            errPrint("Failed creating destination directory \(parentDir): \(error)")
            server.restoreToken(fileId: grant.fileId, token: grant.token)
            sendAndContinue(HTTPResponse.text(500, "Cannot create directory"), closeAfter: true)
            return
        }

        // !! ATOMIC !! compute final destination (with collision avoidance) but write to temp file first
        var dest = baseDest
        var i = 1
        while fm.fileExists(atPath: dest) {
            let base = (baseDest as NSString).deletingPathExtension
            let ext = (baseDest as NSString).pathExtension
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            dest = "\(base) (\(i))\(suffix)"
            i += 1
        }

        // !! ATOMIC !! write to UUID-named temp file in the SAME directory (required for atomic rename)
        let tempName = ".localsend_tmp_\(UUID().uuidString)"
        let tempPath = (parentDir as NSString).appendingPathComponent(tempName)
        self.tempDest = tempPath

        fm.createFile(atPath: tempPath, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: tempPath) else {
            server.restoreToken(fileId: grant.fileId, token: grant.token)
            _ = try? fm.removeItem(atPath: tempPath)
            sendAndContinue(HTTPResponse.text(500, "Cannot open temp file"), closeAfter: true)
            return
        }
        streamFile = fh
        streamingReceived = 0
        streamingDest = dest    // !! ATOMIC !! remember "final" name for atomic rename later

        if isChunked {
            chunked = true
            chunkState = .size
            chunkRemaining = 0
            chunkPending = []
            if !initial.isEmpty { appendChunked(initial) }
            return
        }

        if !initial.isEmpty && streamRemaining > 0 {
            let take = min(initial.count, streamRemaining)
            guard writeChunk(fh, bytes: initial, count: take, dest: dest) else { return }
            streamingReceived += take
            streamRemaining -= take
        }

        if streamRemaining == 0 {
            finishStreaming()
        }
    }

    private func crlfIndex(_ a: [UInt8], from: Int) -> Int? {
        var i = from
        while i + 1 < a.count {
            if a[i] == 13 && a[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }

    /// Decodes an HTTP/1.1 chunked body straight into the destination file.
    /// NOTE: We implement this manually (rather than buffering) so we can stream
    /// multi-gigabyte uploads directly to disk without exhausting RAM. It uses a
    /// state machine to handle chunks that span across multiple TCP packets.
    private func appendChunked(_ data: [UInt8]) {
        chunkPending.append(contentsOf: data)
        var pos = 0
        defer { if pos > 0 { chunkPending.removeFirst(min(pos, chunkPending.count)) } }

        while let fh = streamFile, let dest = streamingDest {
            switch chunkState {
            case .size:
                guard let nl = crlfIndex(chunkPending, from: pos) else { return }
                let line = String(decoding: chunkPending[pos..<nl], as: UTF8.self)
                pos = nl + 2
                let hex = (line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? "")
                    .trimmingCharacters(in: .whitespaces)
                guard let size = Int(hex, radix: 16), size >= 0 else {
                    errPrint("Bad chunk size line: \(line)")
                    abortStreaming()
                    sendAndContinue(HTTPResponse.text(400, "Bad chunk"), closeAfter: true)
                    return
                }
                if size == 0 { chunkState = .trailer } else { chunkRemaining = size; chunkState = .data }

            case .data:
                let avail = chunkPending.count - pos
                if avail == 0 { return }
                let take = min(avail, chunkRemaining)
                let slice = Array(chunkPending[pos..<(pos + take)])
                guard writeChunk(fh, bytes: slice, count: take, dest: dest) else { return }
                pos += take
                chunkRemaining -= take
                streamingReceived += take
                if chunkRemaining == 0 { chunkState = .dataEnd }

            case .dataEnd:
                if chunkPending.count - pos < 2 { return }
                pos += 2
                chunkState = .size

            case .trailer:
                guard let nl = crlfIndex(chunkPending, from: pos) else { return }
                let isEmptyLine = (nl == pos)
                pos = nl + 2
                if isEmptyLine { finishStreaming(); return }
            }
        }
    }

    private func appendStream(_ data: [UInt8]) {
        guard let fh = streamFile, let dest = streamingDest, streamRemaining > 0 else { return }
        let take = min(data.count, streamRemaining)
        guard writeChunk(fh, bytes: data, count: take, dest: dest) else { return }
        streamingReceived += take
        streamRemaining -= take
        if streamRemaining <= 0 {
            finishStreaming()
        }
    }

    private func finishStreaming() {
        _ = try? streamFile?.close()
        streamFile = nil

        guard let temp = tempDest, let final = streamingDest else {
            resetChunkState()
            serverState?.noteFileReceived()
            sendAndContinue(HTTPResponse.ok, closeAfter: false)
            return
        }

        // !! ATOMIC !! validate size BEFORE making file permanent
        if expectedMetaSize >= 0 && streamingReceived != expectedMetaSize {
            errPrint("  Size mismatch for \(final): got \(streamingReceived), expected \(expectedMetaSize)")
            _ = try? FileManager.default.removeItem(atPath: temp)
            tempDest = nil
            streamingDest = nil
            streamingPath = ""
            streamExpectedLength = 0
            streamRemaining = 0
            streamingReceived = 0
            resetChunkState()
            serverState?.resetSession()
            sendAndContinue(HTTPResponse.text(400, "Size mismatch"), closeAfter: true)
            return
        }

        // !! ATOMIC !! rename — instant and safe on the same filesystem
        do {
            try FileManager.default.moveItem(atPath: temp, toPath: final)
            logInfo("  Saved: \(final) (\(streamingReceived) bytes)")
        } catch {
            errPrint("Failed to finalize file \(final): \(error)")
            _ = try? FileManager.default.removeItem(atPath: temp)
            tempDest = nil
            streamingDest = nil
            streamingPath = ""
            streamExpectedLength = 0
            streamRemaining = 0
            streamingReceived = 0
            resetChunkState()
            serverState?.resetSession()
            sendAndContinue(HTTPResponse.text(500, "Finalize failed"), closeAfter: true)
            return
        }

        // Cleanup state
        tempDest = nil
        streamingDest = nil
        streamingPath = ""
        streamExpectedLength = 0
        streamRemaining = 0
        streamingReceived = 0
        resetChunkState()

        serverState?.noteFileReceived()
        sendAndContinue(HTTPResponse.ok, closeAfter: false)
    }
    private func sendAndContinue(_ response: HTTPResponse, closeAfter: Bool) {
        guard !closed else { return }
        var head = "HTTP/1.1 \(response.status) \(statusText(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += closeAfter ? "Connection: close\r\n" : "Connection: keep-alive\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        connection.send(content: out, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                if error != nil || closeAfter {
                    self.close()
                } else if !self.isReceiving && self.buf.isEmpty && !self.streamingActive {
                    self.receiveLoop()   // no-op if a receive is already armed
                }
            }
        })
    }

    static func splitURL(_ raw: String) -> (String, [String: String]) {
        var query: [String: String] = [:]
        var path = raw
        if let qIdx = raw.firstIndex(of: "?") {
            path = String(raw[..<qIdx])
            let qs = String(raw[raw.index(after: qIdx)...])
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let key = kv[0].removingPercentEncoding ?? kv[0]
                let value = kv.count > 1 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
                query[key] = value
            }
        }
        return (path, query)
    }
}

// ---------------------------------------------------------------------------
// Receive state (server side session handling)
// ---------------------------------------------------------------------------

final class ReceiveState {
    let lock = NSLock()
    var session: String?
    var fileTokens: [String: String] = [:]
    var fileMeta: [String: FileMeta] = [:]
    var receivedCount = 0
    var expectedCount = 0

    let alias: String
    let fingerprint: String
    let listenPort: Int
    let saveDir: String
    let autoAccept: Bool
    let registry: DeviceRegistry

    // !! STALE SESSION !! for the stale-session cleanup timer
    var sessionCreatedAt: Date?
    private var cleanupTimer: DispatchSourceTimer?
    private let cleanupQueue = DispatchQueue(label: "com.localsend.cleanup", qos: .background)

    init(alias: String, fingerprint: String, listenPort: Int, saveDir: String,
         autoAccept: Bool, registry: DeviceRegistry) {
        self.alias = alias
        self.fingerprint = fingerprint
        self.listenPort = listenPort
        self.saveDir = saveDir
        self.autoAccept = autoAccept
        self.registry = registry
        // !! STALE SESSION !! start the background cleanup timer
        startSessionCleanup()
    }

    // !! STALE SESSION !! periodically clear stale sessions (5-minute timeout)
    private func startSessionCleanup() {
        cleanupTimer = DispatchSource.makeTimerSource(queue: cleanupQueue)
        cleanupTimer?.schedule(deadline: .now() + 60, repeating: 60)
        cleanupTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }

            if let createdAt = self.sessionCreatedAt,
               Date().timeIntervalSince(createdAt) > 300 {
                logInfo("Cleaning up stale transfer session (5 minute timeout).")
                self.session = nil
                self.fileTokens = [:]
                self.fileMeta = [:]
                self.receivedCount = 0
                self.expectedCount = 0
                self.sessionCreatedAt = nil
            }
        }
        cleanupTimer?.resume()
    }

    deinit {
        cleanupTimer?.cancel()
    }

    /// Validates the request and, if valid, consumes the file's token (so it can't be replayed).
    func prepareUploadDestination(query: [String: String], isV2: Bool)
        -> (path: String, fileId: String, token: String, size: Int)? {
        lock.lock(); defer { lock.unlock() }
        let fileId = query["fileId"] ?? ""
        let token = query["token"] ?? ""

        // Fix #3: always require a valid per-file token.
        guard let expected = fileTokens[fileId], expected == token else { return nil }

        // v2 additionally carries a session id.
        if isV2 {
            let sessionId = query["sessionId"] ?? ""
            guard let current = session, sessionId == current else { return nil }
        }

        // Fix #4: one-shot token.
        fileTokens[fileId] = nil

        let rawName = fileMeta[fileId]?.fileName ?? (fileId.isEmpty ? "upload.bin" : fileId)
        let safeName = (rawName as NSString).lastPathComponent
        let cleanName = safeName.isEmpty || safeName == "." || safeName == ".." ? "upload.bin" : safeName
        return ((saveDir as NSString).appendingPathComponent(cleanName), fileId, token, fileMeta[fileId]?.size ?? -1)
    }

    /// Give a token back if the upload failed before any bytes were accepted.
    func restoreToken(fileId: String, token: String) {
        lock.lock(); defer { lock.unlock() }
        if session != nil { fileTokens[fileId] = token }
    }

    func resetSession() {
        lock.lock(); defer { lock.unlock() }
        guard session != nil else { return }
        session = nil
        fileTokens = [:]
        fileMeta = [:]
        receivedCount = 0
        expectedCount = 0
        sessionCreatedAt = nil
        logInfo("Transfer session reset due to error or abort.")
    }

    func noteFileReceived() {
        lock.lock(); defer { lock.unlock() }
        receivedCount += 1
        if receivedCount >= expectedCount {
            session = nil
            fileTokens = [:]
            fileMeta = [:]
            sessionCreatedAt = nil
            logInfo("\nAll \(expectedCount) file(s) received.")
        }
    }
}

final class LocalSendHTTPServer {
    let listener: NWListener
    let handler: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void
    private let stateLock = NSLock()
    private var _receiveState: ReceiveState?

    // Fix #1: strongly retain live connections.
    private let connLock = NSLock()
    private var connections: [ObjectIdentifier: HTTPServerConnection] = [:]

    var receiveState: ReceiveState? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _receiveState }
        set { stateLock.lock(); defer { stateLock.unlock() }; _receiveState = newValue }
    }

    init(port: UInt16, certificate: Certificate, handler: @escaping (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void) throws {
        self.handler = handler

        let tlsOptions = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(certificate.identity) else {
            throw NSError(domain: "localsend", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "sec_identity_create failed"])
        }
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, completionHandler in
            completionHandler(true) // trust self-signed peers
        }, DispatchQueue.global())

        let params = NWParameters(tls: tlsOptions, tcp: .init())
        params.allowLocalEndpointReuse = true

        self.listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            let connQueue = DispatchQueue(label: "com.localsend.conn-\(UUID().uuidString)")
            let conn = HTTPServerConnection(connection: connection, queue: connQueue, handler: self.handler)
            conn.serverState = self.receiveState

            let id = ObjectIdentifier(conn)
            self.connLock.lock()
            self.connections[id] = conn
            self.connLock.unlock()

            // ARC DANCE: The server must strongly retain the connection in its dictionary
            // so it doesn't deallocate mid-transfer. However, the connection cannot strongly
            // retain the server, or we get a memory leak. We capture only the `id` and use
            // this `onClose` callback to remove the strong reference when the socket closes.
            conn.onClose = { [weak self] in
                guard let self = self else { return }
                self.connLock.lock()
                self.connections[id] = nil
                self.connLock.unlock()
            }

            connection.stateUpdateHandler = { state in
                connQueue.async {
                    switch state {
                    case .ready: conn.start()
                    case .failed, .cancelled: conn.close()
                    default: break
                    }
                }
            }
            connection.start(queue: connQueue)
        }
    }

    /// Fix #8: install the state handler *before* starting, then wait for .ready/.failed.
    func startAndWait(timeout: TimeInterval = 3) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var ready = false
        var signaled = false

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                lock.lock()
                ready = true
                let first = !signaled
                signaled = true
                lock.unlock()
                if first { sem.signal() }
            case .failed(let error):
                errPrint("Server error: \(error)")
                lock.lock()
                let first = !signaled
                signaled = true
                lock.unlock()
                if first { sem.signal() }
            default:
                break
            }
        }
        listener.start(queue: DispatchQueue.global())
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    func stop() {
        connLock.lock()
        let conns = Array(connections.values)
        connections.removeAll()
        connLock.unlock()
        for c in conns { c.requestClose() }
        listener.cancel()
    }
}

// ---------------------------------------------------------------------------
// UDP multicast (POSIX sockets)
// ---------------------------------------------------------------------------

func makeMulticastReceiveSocket() -> Int32 {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return -1 }
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = PORT.bigEndian
    addr.sin_addr = in_addr(s_addr: INADDR_ANY)
    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { close(fd); return -1 }

    var mreq = ip_mreq()
    _ = inet_pton(AF_INET, MULTICAST_ADDR, &mreq.imr_multiaddr)
    mreq.imr_interface = in_addr(s_addr: INADDR_ANY)
    setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    return fd
}

func sendMulticast(_ info: DeviceInfo) {
    guard let payload = try? JSONEncoder().encode(info) else { return }
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var ttl: UInt8 = 2
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = PORT.bigEndian
    _ = inet_pton(AF_INET, MULTICAST_ADDR, &addr.sin_addr)

    payload.withUnsafeBytes { raw in
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = sendto(fd, raw.baseAddress, payload.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

func getLocalIP() -> String {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return "127.0.0.1" }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(1).bigEndian
    _ = inet_pton(AF_INET, MULTICAST_ADDR, &addr.sin_addr)
    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else { return "127.0.0.1" }
    var localAddr = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let r = withUnsafeMutablePointer(to: &localAddr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(fd, sa, &len)
        }
    }
    guard r == 0 else { return "127.0.0.1" }
    var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    var sinAddr = localAddr.sin_addr
    inet_ntop(AF_INET, &sinAddr, &host, socklen_t(INET_ADDRSTRLEN))
    return String(cString: host)
}

// ---------------------------------------------------------------------------
// HTTPS client (ignore self-signed certs)
// ---------------------------------------------------------------------------

// LocalSend peers require mutual TLS, so we must present our own certificate too.
var globalClientIdentity: SecIdentity?

final class InsecureSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodClientCertificate, let identity = globalClientIdentity {
            completionHandler(.useCredential,
                              URLCredential(identity: identity, certificates: nil, persistence: .none))
        } else if method == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

func makeInsecureSession(requestTimeout: TimeInterval) -> URLSession {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = requestTimeout
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 4
    return URLSession(configuration: config, delegate: InsecureSessionDelegate(), delegateQueue: queue)
}

// Fix #6: separate sessions so per-call timeouts are not capped by the session default.
let shortSession    = makeInsecureSession(requestTimeout: 5)     // peer replies
let insecureSession = makeInsecureSession(requestTimeout: 30)    // probes / default
let longSession     = makeInsecureSession(requestTimeout: 300)   // prepare-upload (receiver may be prompting)
let uploadSession   = makeInsecureSession(requestTimeout: 120)   // idle timeout between bytes, not total

func httpsRequest(method: String, url: URL, body: Data? = nil, contentType: String? = nil,
                  timeout: TimeInterval = 30) -> (status: Int, body: Data)? {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    request.httpBody = body
    let session: URLSession = timeout <= 5 ? shortSession : (timeout > 30 ? longSession : insecureSession)
    let semaphore = DispatchSemaphore(value: 0)
    var result: (Int, Data)?
    let task = session.dataTask(with: request) { data, response, error in
        if let http = response as? HTTPURLResponse {
            result = (http.statusCode, data ?? Data())
        } else if error == nil {
            result = (0, data ?? Data())
        }
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + timeout + 5)
    return result
}

func uploadFile(scheme: String, ip: String, port: Int, sessionId: String, fileId: String, token: String,
                filePath: String) -> Int? {
    let fileName = (filePath as NSString).lastPathComponent
    let mime = guessMimeType(fileName)
    let encSession = percentEncodeQueryValue(sessionId)
    let encFileId = percentEncodeQueryValue(fileId)
    let encToken = percentEncodeQueryValue(token)
    let urlString = "\(scheme)://\(ip):\(port)/api/localsend/v2/upload"
        + "?sessionId=\(encSession)&fileId=\(encFileId)&token=\(encToken)"
    guard let url = URL(string: urlString) else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 120)
    request.httpMethod = "POST"
    request.setValue(mime, forHTTPHeaderField: "Content-Type")

    let semaphore = DispatchSemaphore(value: 0)
    var status: Int?
    let task = uploadSession.uploadTask(with: request, fromFile: URL(fileURLWithPath: filePath)) { _, response, _ in
        if let http = response as? HTTPURLResponse { status = http.statusCode }
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()   // no total cutoff; URLSession's idle timeout reports stalls
    return status
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

func discover(alias: String, certificate: Certificate, timeout: Double) -> [DiscoveredDevice] {
    let registry = DeviceRegistry(ownFingerprint: certificate.fingerprint)
    var tempServer: LocalSendHTTPServer?
    var listenPort = Int(PORT)

    for tryPort in [Int(PORT), Int(PORT) + 1, Int(PORT) + 2, Int(PORT) + 3] {
        let deviceInfoHandler: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void = { request, respond in
            if request.method == "POST", request.path.contains("/register") || request.path.contains("/info") {
                if let info = try? JSONDecoder().decode(DeviceInfo.self, from: request.body) {
                    registry.add(DiscoveredDevice(ip: request.remoteIP, info: info))
                }
                respond(HTTPResponse.ok)
                return
            }
            if request.method == "GET", request.path.contains("/info") {
                respond(.codable(200, deviceInfo(alias: alias, fingerprint: certificate.fingerprint, port: tryPort)))
                return
            }
            respond(HTTPResponse.text(404, "Not found"))
        }
        do {
            let server = try LocalSendHTTPServer(port: UInt16(tryPort), certificate: certificate, handler: deviceInfoHandler)
            if server.startAndWait() {
                tempServer = server
                listenPort = tryPort
                break
            }
            server.stop()
        } catch { continue }
    }

    let sock = makeMulticastReceiveSocket()
    guard sock >= 0 else {
        tempServer?.stop()
        return []
    }
    defer { close(sock) }

    let announcement = deviceInfo(alias: alias, fingerprint: certificate.fingerprint,
                                  port: tempServer != nil ? listenPort : Int(PORT), announce: true)
    sendMulticast(announcement)

    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(timeout)
    var nextResend = Date().addingTimeInterval(0.5)
    var resends = 0

    while Date() < deadline {
        let remainingMs = max(0, Int(deadline.timeIntervalSinceNow * 1000))
        var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, Int32(min(remainingMs, 200)))
        if r > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(sock, &buffer, buffer.count, 0, sa, &len)
                }
            }
            if n > 0, let info = try? JSONDecoder().decode(DeviceInfo.self, from: Data(buffer[0..<n])) {
                var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sinAddr = addr.sin_addr
                inet_ntop(AF_INET, &sinAddr, &host, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: host)
                registry.add(DiscoveredDevice(ip: ip, info: info))
            }
        }
        if Date() >= nextResend && resends < 3 {
            sendMulticast(announcement)
            resends += 1
            nextResend = Date().addingTimeInterval(0.5)
        }
    }

    tempServer?.stop()
    return registry.all()
}

// ---------------------------------------------------------------------------
// send command
// ---------------------------------------------------------------------------

func probeDevice(ip: String, port: Int) -> DeviceInfo? {
    let cleanIP = normalizeIP(ip)
    for scheme in ["https", "http"] {
        for path in ["/api/localsend/v2/info", "/api/localsend/v1/info"] {
            guard let url = URL(string: "\(scheme)://\(cleanIP):\(port)\(path)") else { continue }
            if let (status, body) = httpsRequest(method: "GET", url: url, timeout: 5), status == 200,
               var info = try? JSONDecoder().decode(DeviceInfo.self, from: body) {
                info.scheme = scheme   // the info response doesn't include the scheme
                return info
            }
        }
    }
    return nil
}

func cmdSend(files: [String], to: String?, ip: String?, alias: String) {
    let certificate = generateSelfSignedCert()

    var resolvedFiles: [String] = []
    for p in files {
        let abs = (p as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: abs, isDirectory: &isDir), !isDir.boolValue else {
            exitWithError("Error: \(abs) is not a file")
        }
        resolvedFiles.append(abs)
    }

    var target: DiscoveredDevice?

    if let directIP = ip {
        let cleanIP = normalizeIP(directIP)
        guard let info = probeDevice(ip: cleanIP, port: Int(PORT)) else {
            exitWithError("Could not reach device at \(cleanIP):\(PORT)")
        }
        logInfo("Connected to \(info.alias)")
        target = DiscoveredDevice(ip: cleanIP, info: info)
    } else {
        logInfo("Discovering devices...")
        let devices = discover(alias: alias, certificate: certificate, timeout: 3.0)
        if devices.isEmpty {
            errPrint("No devices found. Make sure LocalSend is running on another device on the same network.")
            exit(1)
        }

        if let targetName = to {
            let needle = targetName.lowercased()
            let matches = devices.filter { $0.info.alias.lowercased().contains(needle) }
            if matches.isEmpty {
                errPrint("No device matching '\(targetName)'. Available devices:")
                for d in devices { errPrint("  - \(d.info.alias) (\(d.ip))") }
                exit(1)
            }
            if matches.count > 1 {
                errPrint("Multiple devices match '\(targetName)':")
                for d in matches { errPrint("  - \(d.info.alias) (\(d.ip))") }
                exit(1)
            }
            target = matches[0]
        } else {
            logInfo("\nFound \(devices.count) device(s):\n")
            for (i, d) in devices.enumerated() {
                logInfo("  [\(i + 1)] \(d.info.alias)  (\(d.info.typeText), \(d.info.modelText), \(d.ip))")
            }
            if devices.count == 1 {
                target = devices[0]
            } else {
                print("\nSelect device [1-\(devices.count)]: ", terminator: "")
                fflush(stdout)
                guard let raw = readLine(), let choice = Int(raw.trimmingCharacters(in: .whitespaces)),
                      choice >= 1, choice <= devices.count else {
                    exitWithError("Invalid selection.")
                }
                target = devices[choice - 1]
            }
        }
    }

    guard let target else { exitWithError("No target selected") }
    let targetIP = normalizeIP(target.ip)
    let targetPort = target.info.port
    let scheme = target.info.scheme.isEmpty ? "https" : target.info.scheme
    logInfo("\nSending to \(target.info.alias)...")

    var filesMeta: [String: FileMeta] = [:]
    var idToPath: [String: String] = [:]
    for path in resolvedFiles {
        let fid = UUID().uuidString
        let name = (path as NSString).lastPathComponent
        let size = fileSize(path)
        filesMeta[fid] = FileMeta(id: fid, fileName: name, size: size,
                                  fileType: guessMimeType(name), sha256: nil, preview: nil)
        idToPath[fid] = path
    }

    let prepareBody = PrepareUploadRequest(
        info: deviceInfo(alias: alias, fingerprint: certificate.fingerprint),
        files: filesMeta
    )

    guard let url = URL(string: "\(scheme)://\(targetIP):\(targetPort)/api/localsend/v2/prepare-upload"),
          let bodyData = try? JSONEncoder().encode(prepareBody) else {
        exitWithError("Failed to build prepare-upload request")
    }
    // Fix #6: the receiver may be waiting on a human to answer "Accept?".
    guard let (status, respBody) = httpsRequest(method: "POST", url: url, body: bodyData,
                                                contentType: "application/json", timeout: 300) else {
        exitWithError("prepare-upload request failed")
    }

    switch status {
    case 204:
        logInfo("Receiver indicated nothing to transfer.")
        return
    case 403:
        exitWithError("Transfer declined by receiver.")
    case 409:
        exitWithError("Receiver is busy with another transfer.")
    case 200:
        break
    default:
        exitWithError("prepare-upload failed (HTTP \(status)): \(String(data: respBody, encoding: .utf8) ?? "")")
    }

    guard let resp = try? JSONDecoder().decode(PrepareUploadResponse.self, from: respBody) else {
        exitWithError("Failed to decode prepare-upload response")
    }
    let sessionId = resp.sessionId

    var uploaded = 0
    for (fid, tokenOpt) in resp.files {
        guard let token = tokenOpt else {
            logInfo("  Skipped: \(filesMeta[fid]?.fileName ?? fid) (declined by receiver)")
            continue
        }
        guard let path = idToPath[fid] else { continue }
        let name = (path as NSString).lastPathComponent
        let size = fileSize(path)
        logInfo("  Uploading: \(name) (\(size) bytes)...")
        if let st = uploadFile(scheme: scheme, ip: targetIP, port: targetPort, sessionId: sessionId,
                               fileId: fid, token: token, filePath: path) {
            logInfo("    Result: \(st == 200 ? "done." : "HTTP \(st)")")
            if st == 200 { uploaded += 1 }
        } else {
            errPrint("    Result: failed.")
        }
    }
    logInfo("\n\(uploaded)/\(resp.files.count) file(s) sent.")
    if uploaded != resp.files.count { exit(1) }
}

// ---------------------------------------------------------------------------
// receive command
// ---------------------------------------------------------------------------

private var activeServer: LocalSendHTTPServer?
private var signalSources: [DispatchSourceSignal] = []
private let listenerStopLock = NSLock()
private var listenerShouldStop = false
private var listenerSocketFD: Int32 = -1

private func setListenerStopping() {
    listenerStopLock.lock()
    listenerShouldStop = true
    let fd = listenerSocketFD
    listenerSocketFD = -1
    listenerStopLock.unlock()
    if fd >= 0 {
        close(fd)
    }
}

private func shouldStopListener() -> Bool {
    listenerStopLock.lock()
    defer { listenerStopLock.unlock() }
    return listenerShouldStop
}

func installSignalHandlers() {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    for sig in [SIGINT, SIGTERM] {
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            logInfo("\nStopped.")
            setListenerStopping()
            activeServer?.stop()
            _ = try? logFileHandle?.close()
            logFileHandle = nil
            exit(0)
        }
        src.resume()
        signalSources.append(src)
    }
}

func cmdReceive(saveDirArg: String, autoAccept: Bool, alias: String) {
    let certificate = generateSelfSignedCert()
    let expandedDir = (saveDirArg as NSString).expandingTildeInPath
    let saveDir = (expandedDir as NSString).standardizingPath
    do {
        try FileManager.default.createDirectory(atPath: saveDir, withIntermediateDirectories: true)
    } catch {
        exitWithError("Failed to create save directory \(saveDir): \(error)")
    }

    var listenPort = Int(PORT)
    let registry = DeviceRegistry(ownFingerprint: certificate.fingerprint)

    var serverOpt: LocalSendHTTPServer?
    var stateOpt: ReceiveState?

    for tryPort in [Int(PORT), Int(PORT) + 1, Int(PORT) + 2] {
        // 1. Create the state FIRST
        let state = ReceiveState(alias: alias, fingerprint: certificate.fingerprint,
                                 listenPort: tryPort, saveDir: saveDir,
                                 autoAccept: autoAccept, registry: registry)

        // 2. Define the handler SECOND, capturing `state` directly (no data race!)
        let handler: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void = { request, respond in
            switch (request.method, request.path) {
            case ("GET", "/api/localsend/v2/info"), ("GET", "/api/localsend/v1/info"):
                respond(.codable(200, deviceInfo(alias: alias, fingerprint: certificate.fingerprint,
                                                 port: state.listenPort)))

            case ("POST", "/api/localsend/v2/register"):
                if let info = try? JSONDecoder().decode(DeviceInfo.self, from: request.body) {
                    registry.add(DiscoveredDevice(ip: request.remoteIP, info: info))
                }
                respond(HTTPResponse.ok)

            case ("POST", "/api/localsend/v2/prepare-upload"), ("POST", "/api/localsend/v1/send-request"):
                handlePrepareUpload(request: request, state: state, respond: respond, v2: request.path.contains("v2"))

            case ("POST", "/api/localsend/v2/upload"), ("POST", "/api/localsend/v1/send"):
                respond(HTTPResponse.text(403, "Invalid session"))

            case ("POST", "/api/localsend/v2/cancel"), ("POST", "/api/localsend/v1/cancel"):
                let sid = request.query["sessionId"] ?? ""
                var cancelled = false
                state.lock.lock()
                if let current = state.session, !sid.isEmpty, current == sid {
                    state.session = nil
                    state.fileTokens = [:]
                    state.fileMeta = [:]
                    cancelled = true
                }
                state.lock.unlock()
                if cancelled { logInfo("\nTransfer cancelled by sender.") }
                respond(HTTPResponse.ok)

            default:
                respond(HTTPResponse.text(404, "Not found"))
            }
        }

        // 3. Create the server with the handler
        do {
            let candidate = try LocalSendHTTPServer(port: UInt16(tryPort), certificate: certificate, handler: handler)
            candidate.receiveState = state
            if candidate.startAndWait() {
                serverOpt = candidate
                stateOpt = state
                listenPort = tryPort
                break
            }
            candidate.stop()
        } catch { continue }
    }

    guard let server = serverOpt, let state = stateOpt else {
        exitWithError("Could not bind any listen port")
    }
    
    // We still assign to activeServer for the signal handler to call .stop() on it
    activeServer = server

    let listenerThread = Thread {
        multicastListenerLoop(state: state, registry: registry, alias: alias,
                              fingerprint: certificate.fingerprint, listenPort: listenPort)
    }
    listenerThread.start()

    sendMulticast(deviceInfo(alias: alias, fingerprint: certificate.fingerprint,
                             port: listenPort, announce: true))

    let localIP = getLocalIP()
    logInfo("Listening on https://\(localIP):\(listenPort)")
    logInfo("Alias: \(alias)")
    logInfo("Saving files to: \(saveDir)")
    if autoAccept { logInfo("Auto-accept mode: ON") }
    logInfo("Press Ctrl+C to stop.\n")

    installSignalHandlers()
    dispatchMain()
}

func handlePrepareUpload(request: HTTPRequest, state: ReceiveState,
                         respond: @escaping (HTTPResponse) -> Void, v2: Bool) {
    guard let body = try? JSONDecoder().decode(PrepareUploadRequest.self, from: request.body) else {
        respond(HTTPResponse.text(400, "Bad request"))
        return
    }
    if body.files.isEmpty {
        respond(HTTPResponse.text(204))
        return
    }
    let senderName = body.info.alias

    // RACE CONDITION PREVENTION: If two devices try to send files at the exact same
    // millisecond, we must lock the session *before* we pause to ask the user "Accept? [Y/n]".
    // Otherwise, both senders would get 200 OK and overwrite each other's tokens.
    // We use a random marker so a malicious peer can't guess the session ID to bypass the prompt.
    let pendingMarker = "pending-" + UUID().uuidString
    state.lock.lock()
    if state.session != nil {
        state.lock.unlock()
        respond(HTTPResponse.text(409, "Busy"))
        return
    }
    state.session = pendingMarker
    state.lock.unlock()

    func releasePending() {
        state.lock.lock()
        if state.session == pendingMarker { state.session = nil }
        state.lock.unlock()
    }

    let totalSize = body.files.values.reduce(0) { $0 + $1.size }
    logInfo("\nIncoming transfer from \(senderName):")
    for (_, meta) in body.files {
        logInfo("  - \(meta.fileName) (\(meta.size) bytes)")
    }
    logInfo("  Total: \(totalSize) bytes, \(body.files.count) file(s)")

    if !state.autoAccept {
        if isatty(STDIN_FILENO) == 0 {
            releasePending()
            errPrint("Non-interactive stdin without --yes/-y; declining transfer.")
            respond(.json(403, ["message": "Non-interactive receiver requires --yes"]))
            return
        }

        var accepted = false
        var gotInput = false
        let promptSem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            print("Accept? [Y/n] ", terminator: "")
            fflush(stdout)
            if let raw = readLine() {
                gotInput = true
                let answer = raw.trimmingCharacters(in: .whitespaces).lowercased()
                accepted = answer.isEmpty || answer == "y"
            }
            promptSem.signal()
        }
        promptSem.wait()

        if !gotInput || !accepted {
            releasePending()
            respond(.json(403, ["message": "Declined"]))
            logInfo("Declined.")
            return
        }
    }

    let sessionId = UUID().uuidString
    var fileTokens: [String: String] = [:]
    for fid in body.files.keys {
        fileTokens[fid] = UUID().uuidString
    }

    state.lock.lock()
    guard state.session == pendingMarker else {
        state.lock.unlock()
        respond(HTTPResponse.text(409, "Busy"))
        return
    }
    state.session = sessionId
    state.fileTokens = fileTokens
    state.fileMeta = body.files
    state.receivedCount = 0
    // FIX: Only expect the files we actually accepted (generated tokens for)
    state.expectedCount = fileTokens.count
    state.sessionCreatedAt = Date()
    state.lock.unlock()
    
    if v2 {
        respond(.codable(200, PrepareUploadResponse(sessionId: sessionId, files: fileTokens)))
    } else {
        respond(.json(200, fileTokens))
    }
    logInfo("Accepted. Waiting for files...")
}

func multicastListenerLoop(state: ReceiveState, registry: DeviceRegistry, alias: String,
                           fingerprint: String, listenPort: Int) {
    let sock = makeMulticastReceiveSocket()
    guard sock >= 0 else { return }
    listenerStopLock.lock()
    if listenerShouldStop {
        listenerStopLock.unlock()
        close(sock)
        return
    }
    listenerSocketFD = sock
    listenerStopLock.unlock()

    defer {
        listenerStopLock.lock()
        let currentFD = listenerSocketFD
        if currentFD == sock {
            listenerSocketFD = -1
        }
        listenerStopLock.unlock()
        if currentFD == sock {
            close(sock)
        }
    }

    var buffer = [UInt8](repeating: 0, count: 4096)
    while !shouldStopListener() {
        var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, 250)
        if shouldStopListener() { break }
        guard r > 0, (pfd.revents & Int16(POLLIN)) != 0 else { continue }

        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(sock, &buffer, buffer.count, 0, sa, &len)
            }
        }
        guard n > 0, let info = try? JSONDecoder().decode(DeviceInfo.self, from: Data(buffer[0..<n])) else { continue }
        guard !info.fingerprint.isEmpty, info.fingerprint != fingerprint else { continue }

        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sinAddr = addr.sin_addr
        inet_ntop(AF_INET, &sinAddr, &host, socklen_t(INET_ADDRSTRLEN))
        let senderIP = normalizeIP(String(cString: host))
        registry.add(DiscoveredDevice(ip: senderIP, info: info))

        // Fix #9: only answer real announcements (prevents reply ping-pong).
        guard info.announce == true else { continue }

        let reply = deviceInfo(alias: alias, fingerprint: fingerprint, port: state.listenPort)
        let senderPort = info.port
        let senderScheme = info.scheme.isEmpty ? "https" : info.scheme

        // Fix #9: reply off the poll loop with a short timeout, and fall back to multicast on any failure.
        DispatchQueue.global().async {
            var ok = false
            if let url = URL(string: "\(senderScheme)://\(senderIP):\(senderPort)/api/localsend/v2/register"),
               let body = try? JSONEncoder().encode(reply),
               let (status, _) = httpsRequest(method: "POST", url: url, body: body,
                                              contentType: "application/json", timeout: 2) {
                ok = (status == 200)
            }
            if !ok {
                sendMulticast(deviceInfo(alias: alias, fingerprint: fingerprint,
                                         port: state.listenPort, announce: false))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// discover command
// ---------------------------------------------------------------------------

func cmdDiscover(timeout: Double, jsonOutput: Bool, alias: String) {
    let certificate = generateSelfSignedCert()
    if !jsonOutput {
        logInfo("Scanning for \(String(format: "%.0f", timeout))s...")
    }
    let devices = discover(alias: alias, certificate: certificate, timeout: timeout)

    if jsonOutput {
        let out: [[String: Any]] = devices.map { d in
            [
                "alias": d.info.alias,
                "ip": d.ip,
                "port": d.info.port,
                "protocol": d.info.scheme,
                "deviceType": d.info.typeText,
                "deviceModel": d.info.modelText,
                "version": d.info.version,
                "fingerprint": d.info.fingerprint,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return
    }

    if devices.isEmpty {
        logInfo("No devices found.")
        return
    }

    logInfo("\nFound \(devices.count) device(s):\n")
    for d in devices {
        logInfo("  \(d.info.alias)")
        logInfo("    IP: \(d.ip):\(d.info.port) (\(d.info.scheme))")
        logInfo("    Type: \(d.info.typeText), Model: \(d.info.modelText)")
        logInfo("    Protocol: v\(d.info.version)")
        let prefix = String(d.info.fingerprint.prefix(16))
        logInfo("    Fingerprint: \(prefix)...")
        logInfo("")
    }
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

func printHelp() {
    print("""
    localsend-cli — Send and receive files via the LocalSend v2 protocol.

    Usage: localsend-cli [--alias NAME] [--log-file PATH] <command>

    Commands:
      send <files...> [--to NAME] [--ip IP]   Send files to a device
      receive [--save-dir DIR] [-y|--yes]     Listen for incoming transfers
      discover [-t SECONDS] [--json]          List nearby LocalSend devices
    """)
}

var globalAlias: String?
var globalLogFile: String?

let arguments = Array(CommandLine.arguments.dropFirst())
var idx = 0

while idx < arguments.count, arguments[idx].hasPrefix("--"), arguments[idx] != "--" {
    let arg = arguments[idx]
    if arg == "--alias" {
        guard idx + 1 < arguments.count else { exitWithError("--alias requires a value") }
        globalAlias = arguments[idx + 1]
        idx += 2
    } else if arg == "--log-file" {
        guard idx + 1 < arguments.count else { exitWithError("--log-file requires a value") }
        globalLogFile = arguments[idx + 1]
        idx += 2
    } else {
        break
    }
}

configureLogFile(globalLogFile)

let rest = Array(arguments[idx...])
guard let command = rest.first else {
    printHelp()
    exit(1)
}

let alias = globalAlias ?? hostname()

func parseFlag(_ name: String, _ args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    
    // FIX: Ignore flags that appear after "--"
    if let dashDashIndex = args.firstIndex(of: "--"), dashDashIndex < i {
        return nil
    }
    
    guard i + 1 < args.count else { exitWithError("\(name) requires a value") }
    let value = args[i + 1]
    args.removeSubrange(i...i + 1)
    return value
}

func parseBoolFlag(_ names: [String], _ args: inout [String]) -> Bool {
    var found = false
    var i = 0
    while i < args.count {
        // FIX: Stop parsing flags entirely once "--" is encountered
        if args[i] == "--" {
            break
        }
        if names.contains(args[i]) {
            args.remove(at: i)
            found = true
            // Don't increment `i` because the array shifted left
        } else {
            i += 1
        }
        // Also remove the "--" itself so it doesn't get passed as a filename
        if i < args.count && args[i] == "--" {
            args.remove(at: i)
        }
    }
    return found
}

switch command {
case "send":
    var args = Array(rest.dropFirst())
    let to = parseFlag("--to", &args)
    let ip = parseFlag("--ip", &args)
    guard !args.isEmpty else { exitWithError("send requires at least one file") }
    cmdSend(files: args, to: to, ip: ip, alias: alias)

case "receive":
    var args = Array(rest.dropFirst())
    let saveDir = parseFlag("--save-dir", &args) ?? "~/Downloads"
    let yes = parseBoolFlag(["-y", "--yes"], &args)
    cmdReceive(saveDirArg: saveDir, autoAccept: yes, alias: alias)

case "discover":
    var args = Array(rest.dropFirst())
    let timeoutStr = parseFlag("-t", &args) ?? parseFlag("--timeout", &args)
    let timeout = Double(timeoutStr ?? "3.0") ?? 3.0
    let jsonOutput = parseBoolFlag(["--json"], &args)
    cmdDiscover(timeout: timeout, jsonOutput: jsonOutput, alias: alias)

case "help", "--help", "-h":
    printHelp()

default:
    printHelp()
    exit(1)
}

