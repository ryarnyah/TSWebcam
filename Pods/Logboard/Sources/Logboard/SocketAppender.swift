import Foundation

public class SocketAppender: LogboardAppender {
    private var socket: NetSocket = NetSocket()

    public init() {
    }

    public func connect(_ name: String, port: Int) {
        socket.connect(withName: name, port: port)
    }

    public func close() {
        socket.close(isDisconnected: false)
    }

    public func append(_ logboard: Logboard, level: Logboard.Level, message: [Any], file: StaticString, function: StaticString, line: Int) {
        let strings: [String] = [
            Logboard.dateFormatter.string(from: Date()),
            level.description,
            logboard.identifier,
            file.description,
            String(line),
            function.description,
            message.map({ String(describing: $0) }).joined(separator: "")
        ]
        if let data: Data = (strings.joined(separator: "\t") + "\r\n\r\n").data(using: .utf8) {
            socket.doOutput(data: data)
        }
    }

    public func append(_ logboard: Logboard, level: Logboard.Level, format: String, arguments: CVarArg, file: StaticString, function: StaticString, line: Int) {
        let strings: [String] = [
            Logboard.dateFormatter.string(from: Date()),
            level.description,
            logboard.identifier,
            file.description,
            String(line),
            function.description,
            String(format: format, arguments)
        ]
        if let data: Data = (strings.joined(separator: "\t") + "\r\n\r\n").data(using: .utf8) {
            socket.doOutput(data: data)
        }
    }
}

class NetSocket: NSObject {
    static let defaultTimeout: Int64 = 15 // sec
    static let defaultWindowSizeC: Int = Int(UInt16.max)

    var inputBuffer: Data = Data()
    var timeout: Int64 = NetSocket.defaultTimeout
    var connected: Bool = false
    var windowSizeC: Int = NetSocket.defaultWindowSizeC
    var securityLevel: StreamSocketSecurityLevel = .none

    var inputStream: InputStream?
    var outputStream: OutputStream?
    var inputQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.NetSocket.input")

    private var buffer: UnsafeMutablePointer<UInt8>?
    private var runloop: RunLoop?
    private let outputQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.NetSocket.output")
    private var timeoutHandler: (() -> Void)?

    func connect(withName: String, port: Int) {
        inputQueue.async {
            var readStream: Unmanaged<CFReadStream>?
            var writeStream: Unmanaged<CFWriteStream>?
            CFStreamCreatePairWithSocketToHost(
                kCFAllocatorDefault,
                withName as CFString,
                UInt32(port),
                &readStream,
                &writeStream
            )
            self.inputStream = readStream!.takeRetainedValue()
            self.outputStream = writeStream!.takeRetainedValue()
            self.initConnection()
        }
    }

    @discardableResult
    final func doOutput(data: Data, locked: UnsafeMutablePointer<UInt32>? = nil) -> Int {
        outputQueue.async {
            data.withUnsafeBytes { (buffer: UnsafePointer<UInt8>) -> Void in
                self.doOutputProcess(buffer, maxLength: data.count)
            }
            if locked != nil {
                OSAtomicAnd32Barrier(0, locked!)
            }
        }
        return data.count
    }

    final func doOutputProcess(_ data: Data) {
        data.withUnsafeBytes { (buffer: UnsafePointer<UInt8>) -> Void in
            doOutputProcess(buffer, maxLength: data.count)
        }
    }

    final func doOutputProcess(_ buffer: UnsafePointer<UInt8>, maxLength: Int) {
        guard let outputStream: OutputStream = outputStream else {
            return
        }
        var total: Int = 0
        while total < maxLength {
            let length: Int = outputStream.write(buffer.advanced(by: total), maxLength: maxLength - total)
            if length <= 0 {
                break
            }
            total += length
        }
    }

    func close(isDisconnected: Bool) {
        outputQueue.async {
            guard let runloop: RunLoop = self.runloop else {
                return
            }
            self.deinitConnection(isDisconnected: isDisconnected)
            self.runloop = nil
            CFRunLoopStop(runloop.getCFRunLoop())
        }
    }

    func close() {
        close(isDisconnected: false)
    }

    func listen() {
    }

    func initConnection() {
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: windowSizeC)
        buffer?.initialize(repeating: 0, count: windowSizeC)

        timeoutHandler = didTimeout
        inputBuffer.removeAll(keepingCapacity: false)

        guard let inputStream: InputStream = inputStream, let outputStream: OutputStream = outputStream else {
            return
        }

        runloop = .current

        inputStream.delegate = self
        inputStream.schedule(in: runloop!, forMode: RunLoop.Mode.default)
        inputStream.setProperty(securityLevel.rawValue, forKey: .socketSecurityLevelKey)

        outputStream.delegate = self
        outputStream.schedule(in: runloop!, forMode: RunLoop.Mode.default)
        outputStream.setProperty(securityLevel.rawValue, forKey: .socketSecurityLevelKey)

        inputStream.open()
        outputStream.open()

        if 0 < timeout {
            outputQueue.asyncAfter(deadline: .now() + Double(timeout * Int64(NSEC_PER_SEC)) / Double(NSEC_PER_SEC)) {
                guard let timeoutHandler: (() -> Void) = self.timeoutHandler else {
                    return
                }
                timeoutHandler()
            }
        }

        runloop?.run()
        connected = false
    }

    func deinitConnection(isDisconnected: Bool) {
        inputStream?.close()
        inputStream?.remove(from: runloop!, forMode: RunLoop.Mode.default)
        inputStream?.delegate = nil
        inputStream = nil
        outputStream?.close()
        outputStream?.remove(from: runloop!, forMode: RunLoop.Mode.default)
        outputStream?.delegate = nil
        outputStream = nil
        buffer?.deinitialize(count: windowSizeC)
        buffer?.deallocate()
        buffer = nil
    }

    func didTimeout() {
    }

    private func doInput() {
        guard let inputStream: InputStream = inputStream, let buffer: UnsafeMutablePointer<UInt8> = buffer else {
            return
        }
        let length: Int = inputStream.read(buffer, maxLength: windowSizeC)
        if 0 < length {
            inputBuffer.append(buffer, count: length)
            listen()
        }
    }
}

extension NetSocket: StreamDelegate {
    // MARK: StreamDelegate
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        //  1 = 1 << 0
        case .openCompleted:
            guard let inputStream = inputStream, let outputStream = outputStream,
                inputStream.streamStatus == .open && outputStream.streamStatus == .open else {
                    break
            }
            if aStream == inputStream {
                timeoutHandler = nil
                connected = true
            }
        //  2 = 1 << 1
        case .hasBytesAvailable:
            if aStream == inputStream {
                doInput()
            }
        //  4 = 1 << 2
        case .hasSpaceAvailable:
            break
        //  8 = 1 << 3
        case .errorOccurred:
            close(isDisconnected: true)
        // 16 = 1 << 4
        case .endEncountered:
            close(isDisconnected: true)
        default:
            break
        }
    }
}
