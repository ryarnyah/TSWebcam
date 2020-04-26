import AVFoundation
/**
 - seealso: https://en.wikipedia.org/wiki/Packetized_elementary_stream
 */
protocol PESPacketHeader {
    var startCode: Data { get set }
    var streamID: UInt8 { get set }
    var packetLength: UInt16 { get set }
    var optionalPESHeader: PESOptionalHeader? { get set }
    var data: Data { get set }
}

// MARK: -
enum PESPTSDTSIndicator: UInt8 {
    case none = 0
    case onlyPTS = 1
    case forbidden = 2
    case bothPresent = 3
}

// MARK: -
struct PESOptionalHeader {
    static let fixedSectionSize: Int = 3
    static let defaultMarkerBits: UInt8 = 2

    var markerBits: UInt8 = PESOptionalHeader.defaultMarkerBits
    var scramblingControl: UInt8 = 0
    var priority: Bool = false
    var dataAlignmentIndicator: Bool = false
    var copyright: Bool = false
    var originalOrCopy: Bool = false
    var PTSDTSIndicator: UInt8 = PESPTSDTSIndicator.none.rawValue
    var ESCRFlag: Bool = false
    var ESRateFlag: Bool = false
    var DSMTrickModeFlag: Bool = false
    var additionalCopyInfoFlag: Bool = false
    var CRCFlag: Bool = false
    var extentionFlag: Bool = false
    var PESHeaderLength: UInt8 = 0
    var optionalFields = Data()
    var stuffingBytes = Data()

    init() {
    }

    init?(data: Data) {
        self.data = data
    }

    mutating func setTimestamp(_ timestamp: CMTime, presentationTimeStamp: CMTime, decodeTimeStamp: CMTime) {
        let base = Double(timestamp.seconds)
        if presentationTimeStamp != CMTime.invalid {
            PTSDTSIndicator |= 0x02
        }
        if decodeTimeStamp != CMTime.invalid {
            PTSDTSIndicator |= 0x01
        }
        if (PTSDTSIndicator & 0x02) == 0x02 {
            let PTS = UInt64((presentationTimeStamp.seconds - base) * Double(TSTimestamp.resolution))
            optionalFields += TSTimestamp.encode(PTS, PTSDTSIndicator << 4)
        }
        if (PTSDTSIndicator & 0x01) == 0x01 {
            let DTS = UInt64((decodeTimeStamp.seconds - base) * Double(TSTimestamp.resolution))
            optionalFields += TSTimestamp.encode(DTS, 0x01 << 4)
        }
        PESHeaderLength = UInt8(optionalFields.count)
    }
}

extension PESOptionalHeader: DataConvertible {
    // MARK: DataConvertible
    var data: Data {
        get {
            var bytes = Data([0x00, 0x00])
            bytes[0] |= markerBits << 6
            bytes[0] |= scramblingControl << 4
            bytes[0] |= (priority ? 1 : 0) << 3
            bytes[0] |= (dataAlignmentIndicator ? 1 : 0) << 2
            bytes[0] |= (copyright ? 1 : 0) << 1
            bytes[0] |= (originalOrCopy ? 1 : 0)
            bytes[1] |= PTSDTSIndicator << 6
            bytes[1] |= (ESCRFlag ? 1 : 0) << 5
            bytes[1] |= (ESRateFlag ? 1 : 0) << 4
            bytes[1] |= (DSMTrickModeFlag ? 1 : 0) << 3
            bytes[1] |= (additionalCopyInfoFlag ? 1 : 0) << 2
            bytes[1] |= (CRCFlag ? 1 : 0) << 1
            bytes[1] |= extentionFlag ? 1 : 0
            return ByteArray()
                .writeBytes(bytes)
                .writeUInt8(PESHeaderLength)
                .writeBytes(optionalFields)
                .writeBytes(stuffingBytes)
                .data
        }
        set {
            let buffer = ByteArray(data: newValue)
            do {
                let bytes: Data = try buffer.readBytes(PESOptionalHeader.fixedSectionSize)
                markerBits = (bytes[0] & 0b11000000) >> 6
                scramblingControl = bytes[0] & 0b00110000 >> 4
                priority = (bytes[0] & 0b00001000) == 0b00001000
                dataAlignmentIndicator = (bytes[0] & 0b00000100) == 0b00000100
                copyright = (bytes[0] & 0b00000010) == 0b00000010
                originalOrCopy = (bytes[0] & 0b00000001) == 0b00000001
                PTSDTSIndicator = (bytes[1] & 0b11000000) >> 6
                ESCRFlag = (bytes[1] & 0b00100000) == 0b00100000
                ESRateFlag = (bytes[1] & 0b00010000) == 0b00010000
                DSMTrickModeFlag = (bytes[1] & 0b00001000) == 0b00001000
                additionalCopyInfoFlag = (bytes[1] & 0b00000100) == 0b00000100
                CRCFlag = (bytes[1] & 0b00000010) == 0b00000010
                extentionFlag = (bytes[1] & 0b00000001) == 0b00000001
                PESHeaderLength = bytes[2]
                optionalFields = try buffer.readBytes(Int(PESHeaderLength))
            } catch {
                logger.error("\(buffer)")
            }
        }
    }
}

extension PESOptionalHeader: CustomDebugStringConvertible {
    // MARK: CustomDebugStringConvertible
    var debugDescription: String {
        Mirror(reflecting: self).debugDescription
    }
}

// MARK: -
struct PacketizedElementaryStream: PESPacketHeader {
    static let untilPacketLengthSize: Int = 6
    static let startCode = Data([0x00, 0x00, 0x01])

    // swiftlint:disable function_parameter_count
    static func create(_ bytes: UnsafePointer<UInt8>?, count: UInt32, presentationTimeStamp: CMTime, decodeTimeStamp: CMTime, timestamp: CMTime, config: Any?, randomAccessIndicator: Bool) -> PacketizedElementaryStream? {
        if let config: AudioSpecificConfig = config as? AudioSpecificConfig {
            return PacketizedElementaryStream(bytes: bytes, count: count, presentationTimeStamp: presentationTimeStamp, decodeTimeStamp: decodeTimeStamp, timestamp: timestamp, config: config)
        }
        if let config: AVCConfigurationRecord = config as? AVCConfigurationRecord {
            return PacketizedElementaryStream(bytes: bytes, count: count, presentationTimeStamp: presentationTimeStamp, decodeTimeStamp: decodeTimeStamp, timestamp: timestamp, config: randomAccessIndicator ? config : nil)
        }
        return nil
    }

    var startCode: Data = PacketizedElementaryStream.startCode
    var streamID: UInt8 = 0
    var packetLength: UInt16 = 0
    var optionalPESHeader: PESOptionalHeader?
    var data = Data()

    var payload: Data {
        get {
            ByteArray()
                .writeBytes(startCode)
                .writeUInt8(streamID)
                .writeUInt16(packetLength)
                .writeBytes(optionalPESHeader?.data ?? Data())
                .writeBytes(data)
                .data
        }
        set {
            let buffer = ByteArray(data: newValue)
            do {
                startCode = try buffer.readBytes(3)
                streamID = try buffer.readUInt8()
                packetLength = try buffer.readUInt16()
                optionalPESHeader = PESOptionalHeader(data: try buffer.readBytes(buffer.bytesAvailable))
                if let optionalPESHeader: PESOptionalHeader = optionalPESHeader {
                    buffer.position = PacketizedElementaryStream.untilPacketLengthSize + 3 + Int(optionalPESHeader.PESHeaderLength)
                } else {
                    buffer.position = PacketizedElementaryStream.untilPacketLengthSize
                }
                data = try buffer.readBytes(buffer.bytesAvailable)
            } catch {
                logger.error("\(buffer)")
            }
        }
    }

    init?(_ payload: Data) {
        self.payload = payload
        if startCode != PacketizedElementaryStream.startCode {
            return nil
        }
    }

    init?(bytes: UnsafePointer<UInt8>?, count: UInt32, presentationTimeStamp: CMTime, decodeTimeStamp: CMTime, timestamp: CMTime, config: AudioSpecificConfig?) {
        guard let bytes = bytes, let config = config else {
            return nil
        }
        data.append(contentsOf: config.adts(Int(count)))
        data.append(bytes, count: Int(count))
        optionalPESHeader = PESOptionalHeader()
        optionalPESHeader?.dataAlignmentIndicator = true
        optionalPESHeader?.setTimestamp(
            timestamp,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: CMTime.invalid
        )
        let length = data.count + optionalPESHeader!.data.count
        if length < Int(UInt16.max) {
            packetLength = UInt16(length)
        } else {
            return nil
        }
    }

    init?(bytes: UnsafePointer<UInt8>?, count: UInt32, presentationTimeStamp: CMTime, decodeTimeStamp: CMTime, timestamp: CMTime, config: AVCConfigurationRecord?) {
        guard let bytes = bytes else {
            return nil
        }
        if let config: AVCConfigurationRecord = config {
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x09, 0x10])
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            data.append(contentsOf: config.sequenceParameterSets[0])
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            data.append(contentsOf: config.pictureParameterSets[0])
        } else {
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x09, 0x30])
        }
        if let stream = AVCFormatStream(bytes: bytes, count: count) {
            data.append(stream.toByteStream())
        }
        optionalPESHeader = PESOptionalHeader()
        optionalPESHeader?.dataAlignmentIndicator = true
        optionalPESHeader?.setTimestamp(
            timestamp,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: decodeTimeStamp
        )
        let length = data.count + optionalPESHeader!.data.count
        if length < Int(UInt16.max) {
            packetLength = UInt16(length)
        }
    }

    func arrayOfPackets(_ PID: UInt16, PCR: UInt64?) -> [TSPacket] {
        let payload: Data = self.payload
        var packets: [TSPacket] = []

        // start
        var packet = TSPacket()
        packet.PID = PID
        if let PCR: UInt64 = PCR {
            packet.adaptationFieldFlag = true
            packet.adaptationField = TSAdaptationField()
            packet.adaptationField?.PCRFlag = true
            packet.adaptationField?.PCR = TSProgramClockReference.encode(PCR, 0)
            packet.adaptationField?.compute()
        }
        packet.payloadUnitStartIndicator = true
        let position: Int = packet.fill(payload, useAdaptationField: true)
        packets.append(packet)

        // middle
        let r: Int = (payload.count - position) % 184
        for index in stride(from: payload.startIndex.advanced(by: position), to: payload.endIndex.advanced(by: -r), by: 184) {
            var packet = TSPacket()
            packet.PID = PID
            packet.payloadFlag = true
            packet.payload = payload.subdata(in: index..<index.advanced(by: 184))
            packets.append(packet)
        }

        switch r {
        case 0:
            break
        case 183:
            let remain: Data = payload.subdata(in: payload.endIndex - r..<payload.endIndex - 1)
            var packet = TSPacket()
            packet.PID = PID
            packet.adaptationFieldFlag = true
            packet.adaptationField = TSAdaptationField()
            packet.adaptationField?.compute()
            _ = packet.fill(remain, useAdaptationField: true)
            packets.append(packet)
            packet = TSPacket()
            packet.PID = PID
            packet.adaptationFieldFlag = true
            packet.adaptationField = TSAdaptationField()
            packet.adaptationField?.compute()
            _ = packet.fill(Data([payload[payload.count - 1]]), useAdaptationField: true)
            packets.append(packet)
        default:
            let remain: Data = payload.subdata(in: payload.count - r..<payload.count)
            var packet = TSPacket()
            packet.PID = PID
            packet.adaptationFieldFlag = true
            packet.adaptationField = TSAdaptationField()
            packet.adaptationField?.compute()
            _ = packet.fill(remain, useAdaptationField: true)
            packets.append(packet)
        }

        return packets
    }

    mutating func append(_ data: Data) -> Int {
        self.data.append(data)
        return data.count
    }
}

extension PacketizedElementaryStream: CustomDebugStringConvertible {
    // MARK: CustomDebugStringConvertible
    var debugDescription: String {
        Mirror(reflecting: self).debugDescription
    }
}
