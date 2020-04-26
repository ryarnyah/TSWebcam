//
//  ViewController.swift
//  TSWebcam
//
//  Created by Ryar Nyah on 23/04/2020.
//  Copyright © 2020 HCK. All rights reserved.
//

import UIKit
import AVFoundation
import HaishinKit

class ViewController: UIViewController {
    
    private var tsSocketStream: TSSocketStream!
    
    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        get {
            return .landscapeLeft
        }
    }
    
    private var aVCaptureVideoPreviewLayer: AVCaptureVideoPreviewLayer = AVCaptureVideoPreviewLayer()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tsSocketStream = TSSocketStream()
        aVCaptureVideoPreviewLayer.frame.size = view.frame.size
        view.layer.addSublayer(aVCaptureVideoPreviewLayer)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        tsSocketStream.attachCamera(DeviceUtil.device(withPosition: .back))
        tsSocketStream.attachAudio(AVCaptureDevice.default(for: AVMediaType.audio))
        
        tsSocketStream.start()
        
        aVCaptureVideoPreviewLayer.session = tsSocketStream.mixer.session
        aVCaptureVideoPreviewLayer.connection?.videoOrientation = .landscapeLeft
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        tsSocketStream.stop()
    }
}

