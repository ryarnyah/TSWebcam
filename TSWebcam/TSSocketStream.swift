//
//  TSSocketService.swift
//  TSWebcam
//
//  Created by Ryar Nyah on 23/04/2020.
//  Copyright © 2020 HCK. All rights reserved.
//

import AVFoundation
import HaishinKit
import CocoaAsyncSocket

class TSSocketStream: NetStream {
    private(set) var name: String?
    private lazy var tsWriter = TSWriter()
    var netService: Foundation.NetService = NetService(domain: "local", type: "_webcam._tcp.", name: "v4l2x")
    private var sockets: [String: GCDAsyncSocket?] = [String: GCDAsyncSocket?]()
    private var port: Int = 8088

    private func disconnect() {
        // Ensure all sockets are closed
        for socket in self.sockets {
            let key = socket.key
            guard let socket = socket.value else {
                continue
            }
            socket.disconnect()
            self.sockets[key] = Optional<GCDAsyncSocket>.none
        }
    }
    
    private func tryConnect() {
        lockQueue.async {
            // Connect
            for socketAddress in self.sockets {
                if socketAddress.value != nil {
                    continue
                }
                let socket = GCDAsyncSocket(delegate: self, delegateQueue: self.lockQueue)
                
                guard let _ = try? socket.connect(toHost: socketAddress.key, onPort: UInt16(self.port)) else {
                    // Let's retry later
                    self.disconnect()
                    return
                }
                self.sockets[socketAddress.key] = socket
            }
        }
    }
    
    func stop() {
        lockQueue.async {
            self.mixer.stopRunning()
            self.tsWriter.stopRunning()
        }
    }

    func start() {
        
        self.captureSettings = [
            .sessionPreset: AVCaptureSession.Preset.hd1280x720, // input video width/height
            .continuousAutofocus: true, // use camera autofocus mode
            .preferredVideoStabilizationMode: AVCaptureVideoStabilizationMode.auto
        ]
        self.videoSettings = [
            .width: 1280, // video output width
            .height: 720, // video output height
            .bitrate: 1000 * 1024, // video output bitrate
        ]
        
        self.tsWriter.delegate = self
        self.tsWriter.expectedMedias = [.video, .audio]
        self.netService.delegate = self
        self.netService.resolve(withTimeout: TimeInterval(60))
        self.netService.schedule(in: RunLoop.current, forMode: RunLoop.Mode.common)
        
        lockQueue.async {
            self.tsWriter.startRunning()
            self.mixer.startEncoding(delegate: self.tsWriter)
            self.mixer.startRunning()
            self.orientation = .landscapeLeft
        }
    }
    
    override open func attachCamera(_ camera: AVCaptureDevice?, onError: ((NSError) -> Void)? = nil) {
        super.attachCamera(camera, onError: onError)
    }

    override open func attachAudio(_ audio: AVCaptureDevice?, automaticallyConfiguresApplicationAudioSession: Bool = true, onError: ((NSError) -> Void)? = nil) {
        super.attachAudio(audio, automaticallyConfiguresApplicationAudioSession: automaticallyConfiguresApplicationAudioSession, onError: onError)
    }
}

extension TSSocketStream: TSWriterDelegate {
    func didOutput(_ data: Data) {
        for socket in sockets {
            guard let socket = socket.value, socket.isConnected else {
                continue
            }
            socket.write(data, withTimeout: TimeInterval(10), tag: 0)
        }
    }
}

extension TSSocketStream: GCDAsyncSocketDelegate {
    func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
        lockQueue.asyncAfter(deadline: .now() + 10, execute: {
            self.disconnect()
            self.tryConnect()
        })
    }
}


extension TSSocketStream: Foundation.NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: Foundation.NetService) {
        lockQueue.async {
            //First try using hostname
            if sender.hostName != nil {
                print("Resolved \(sender.hostName!) : \(sender.port)")
                if !self.sockets.keys.contains(sender.hostName!) {
                    self.sockets[sender.hostName!] = Optional<GCDAsyncSocket>.none
                }
            }
            // If not try using IPV4 Address
            else if sender.addresses != nil {
                self.port = sender.port
                for address in self.resolveIPs(sender.addresses!) {
                    print("Resolved \(address) : \(sender.port)")
                    if !self.sockets.keys.contains(sender.hostName!) {
                        self.sockets[sender.hostName!] = Optional<GCDAsyncSocket>.none
                    }
                }
            }
            
            self.tryConnect()
        }
    }
    
    // Find an IPv4 address from the service address data
    private func resolveIPs(_ addresses: [Data]) -> [String] {
      var results: [String] = []

        for addr in addresses {
            let data = addr as NSData
            var storage = sockaddr_storage()
            data.getBytes(&storage, length: MemoryLayout<sockaddr_storage>.size)
            
            if Int32(storage.ss_family) == AF_INET {
                var addr = withUnsafePointer(to: &storage) {
                  $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee
                  }
                }
                var ipAddressString = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if let ip = String(cString: inet_ntop(AF_INET, &addr.sin_addr, &ipAddressString, socklen_t(INET_ADDRSTRLEN)), encoding: .ascii) {
                    results.append(ip)
                }
            }
        }

      return results
    }
}
