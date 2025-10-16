//
//  CameraManager.swift
//  EasyShareCamera
//
//  Created by EasyShareCamera on 2025/10/13.
//

import Foundation
import AVFoundation
import SwiftUI
import Photos
import Combine

/// カメラの操作を管理するクラス
class CameraManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var isSessionRunning = false
    @Published var isRecording = false
    @Published var hasPermission = false
    @Published var alertError: AlertError?
    @Published var capturedImage: UIImage?
    
    // MARK: - Private Properties
    let captureSession = AVCaptureSession()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var photoOutput = AVCapturePhotoOutput()
    private var movieOutput = AVCaptureMovieFileOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private var settings: CameraSettings
    
    // MARK: - Computed Properties
    var captureDevice: AVCaptureDevice? {
        return videoDeviceInput?.device
    }
    
    // MARK: - Initializer
    init(settings: CameraSettings) {
        self.settings = settings
        super.init()
        configure()
    }
    
    // MARK: - Public Methods
    
    /// カメラの初期設定
    func configure() {
        // カメラ権限があるときのみキャプチャセッションを構築する
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        print("🎥 [CameraManager] configure() - authorization status: \(status.rawValue)")
        switch status {
        case .authorized:
            print("🎥 [CameraManager] Already authorized, setting up session")
            DispatchQueue.main.async { self.hasPermission = true }
            sessionQueue.async { self.configureCaptureSession() }
        case .notDetermined:
            print("🎥 [CameraManager] Requesting camera access...")
            AVCaptureDevice.requestAccess(for: .video) { granted in
                print("🎥 [CameraManager] Access granted: \(granted)")
                DispatchQueue.main.async {
                    self.hasPermission = granted
                }
                if granted {
                    self.sessionQueue.async { self.configureCaptureSession() }
                }
            }
        case .denied, .restricted:
            print("🎥 [CameraManager] Camera access denied or restricted")
            DispatchQueue.main.async { self.hasPermission = false }
        @unknown default:
            print("🎥 [CameraManager] Unknown authorization status")
            DispatchQueue.main.async { self.hasPermission = false }
        }
    }
    
    /// カメラセッションを開始
    func startSession() {
        print("🎥 [CameraManager] startSession() called")
        sessionQueue.async {
            if !self.captureSession.isRunning {
                print("🎥 [CameraManager] Starting capture session...")
                self.captureSession.startRunning()
                
                // セッション開始後にズーム倍率キャッシュをリセット
                self.resetZoomFactorsCache()
                
                DispatchQueue.main.async {
                    self.isSessionRunning = true
                    print("🎥 [CameraManager] Session is now running")
                }
                
                // セッション起動後にカメラ設定を適用（セッション未起動時の設定はエラーの原因）
                self.applyCameraSettings()
            } else {
                print("🎥 [CameraManager] Session already running")
            }
        }
    }
    
    /// カメラセッションを停止
    func stopSession() {
        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
                DispatchQueue.main.async {
                    self.isSessionRunning = false
                }
            }
        }
    }
    
    /// 写真を撮影
    func capturePhoto() {
        let photoSettings = AVCapturePhotoSettings()
        
        // フラッシュ設定
        if captureDevice?.hasFlash == true {
            photoSettings.flashMode = settings.flashMode
        }
        
        // 高品質設定: target は iOS 17 なので maxPhotoDimensions を使う
        let maxDims = photoOutput.maxPhotoDimensions
        photoSettings.maxPhotoDimensions = maxDims
        
        photoOutput.capturePhoto(with: photoSettings, delegate: self)
    }
    
    /// 動画録画を開始/停止
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    /// 設定をカメラデバイスに適用
    func applyCameraSettings() {
        guard let device = captureDevice else { return }
        
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                
                // ISO設定
                if device.isExposureModeSupported(.custom) {
                    let exposureDuration = CMTime(seconds: self.settings.exposureDuration, preferredTimescale: 1000000)
                    device.setExposureModeCustom(duration: exposureDuration, iso: self.settings.isoValue, completionHandler: nil)
                }
                
                // フォーカス設定
                if device.isFocusModeSupported(self.settings.focusMode) {
                    device.focusMode = self.settings.focusMode
                    if self.settings.focusMode == .locked {
                        if #available(iOS 10.0, *), device.isLockingFocusWithCustomLensPositionSupported {
                            device.setFocusModeLocked(lensPosition: self.settings.lensPosition, completionHandler: nil)
                            print("🎥 [CameraManager] Focus locked with lens position: \(self.settings.lensPosition)")
                        } else {
                            device.focusMode = .locked
                        }
                    }
                }
                
                // ホワイトバランス設定
                if device.isWhiteBalanceModeSupported(self.settings.whiteBalanceMode) {
                    device.whiteBalanceMode = self.settings.whiteBalanceMode
                }
                
                // フレームレート設定（スローモーション対応）
                self.configureFrameRate(for: device)
                
                // ===== ズーム設定（UI倍率→デバイス倍率 マッピング対応） =====
                let minZoom = device.minAvailableVideoZoomFactor
                let maxZoom = device.maxAvailableVideoZoomFactor
                let uiRequested = self.settings.zoomFactor
                let requestedDeviceZoom = self.toDeviceZoom(from: uiRequested, device: device)
                
                print("🎥 [CameraManager] applyCameraSettings - UI requested=\(uiRequested)x -> device=\(requestedDeviceZoom)x, range=\(minZoom)~\(maxZoom)")
                
                let safeDeviceZoom = max(minZoom, min(maxZoom, requestedDeviceZoom))
                device.videoZoomFactor = safeDeviceZoom
                
                let appliedUIZoom = self.toUIZoom(fromDeviceZoom: safeDeviceZoom, device: device)
                print("🎥 [CameraManager] applyCameraSettings - Applied device zoom=\(safeDeviceZoom)x (UI ~ \(appliedUIZoom)x)")
                
                device.unlockForConfiguration()
                
                // 設定を保存
                DispatchQueue.main.async {
                    self.settings.zoomFactor = appliedUIZoom
                    self.settings.saveSettings()
                }
                
            } catch {
                DispatchQueue.main.async {
                    self.alertError = AlertError(message: "カメラ設定の適用に失敗しました: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// 動画録画開始
    func startRecording() {
        guard !isRecording else { return }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let videoURL = documentsPath.appendingPathComponent("video_\(Date().timeIntervalSince1970).mov")
        
        movieOutput.startRecording(to: videoURL, recordingDelegate: self)
        
        DispatchQueue.main.async {
            self.isRecording = true
        }
    }
    
    /// 動画録画停止
    func stopRecording() {
        guard isRecording else { return }
        
        movieOutput.stopRecording()
        
        DispatchQueue.main.async {
            self.isRecording = false
        }
    }
    
    /// ズーム操作（UI倍率で受け取り、デバイス倍率に変換して適用）
    func zoom(by uiFactor: CGFloat) {
        guard let device = captureDevice else { return }
        
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                
                let minZoom = device.minAvailableVideoZoomFactor
                let maxZoom = min(device.maxAvailableVideoZoomFactor, 20.0) // 上限を少し上げる
                
                let requestedDeviceZoom = self.toDeviceZoom(from: uiFactor, device: device)
                print("🎥 [CameraManager] Zoom request (UI): \(uiFactor)x -> device: \(requestedDeviceZoom)x, device range: \(minZoom) ~ \(maxZoom)")
                
                // デバイス種別による制限調整
                let actualMaxZoom: CGFloat
                if device.deviceType == .builtInUltraWideCamera {
                    // 超広角の場合、UI 0.5x〜3x程度 = device 1x〜6x程度まで許可
                    actualMaxZoom = min(maxZoom, 6.0)
                } else {
                    actualMaxZoom = maxZoom
                }
                
                let safeDeviceZoom = max(minZoom, min(actualMaxZoom, requestedDeviceZoom))
                device.videoZoomFactor = safeDeviceZoom
                
                let appliedUIZoom = self.toUIZoom(fromDeviceZoom: safeDeviceZoom, device: device)
                print("🎥 [CameraManager] ✅ Zoom set: device=\(safeDeviceZoom)x (UI ~ \(appliedUIZoom)x)")
                
                device.unlockForConfiguration()
                
                DispatchQueue.main.async {
                    self.settings.zoomFactor = appliedUIZoom
                    self.settings.saveSettings()
                }
            } catch {
                print("🎥 [CameraManager] ❌ Zoom operation failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.alertError = AlertError(message: "ズーム操作に失敗しました: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// フォーカスポイント設定
    func setFocusPoint(_ point: CGPoint) {
        guard let device = captureDevice else { return }
        
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                
                device.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async {
                    self.alertError = AlertError(message: "フォーカス設定に失敗しました: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // キャッシュされたズーム倍率
    private var cachedZoomFactors: [CGFloat]?
    
    /// ズーム倍率キャッシュをリセット（セッション変更時など）
    func resetZoomFactorsCache() {
        cachedZoomFactors = nil
        print("🎥 [CameraManager] Zoom factors cache reset")
    }
    
    /// 利用可能なズーム倍率のリストを取得（UI倍率ベース／キャッシュ）
    func getAvailableZoomFactors() -> [CGFloat] {
        // 既にキャッシュされている場合はそれを返す
        if let cached = cachedZoomFactors { return cached }
        
        guard let device = captureDevice else {
            cachedZoomFactors = [1.0]
            return [1.0]
        }
        
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = min(device.maxAvailableVideoZoomFactor, 10.0) // UIとしての実用上限
        
        print("🎥 [CameraManager] Device: \(device.localizedName)")
        print("🎥 [CameraManager] Device type: \(device.deviceType.rawValue)")
        print("🎥 [CameraManager] Zoom range: \(minZoom) ~ \(device.maxAvailableVideoZoomFactor) (limited to \(maxZoom))")
        print("🎥 [CameraManager] Is virtual device: \(device.isVirtualDevice)")
        
        var candidatesUI: [CGFloat] = []
        if device.deviceType == .builtInUltraWideCamera {
            // UI上は 0.5x, 1.0x, 2.0x, 3.0x, 6.0x などを提供（必要に応じて調整）
            candidatesUI = [0.5, 1.0, 2.0, 3.0, 6.0]
            print("🎥 [CameraManager] Ultra Wide Camera: providing UI zoom options: \(candidatesUI)")
        } else if device.isVirtualDevice {
            if #available(iOS 15.0, *), let switchOver = device.virtualDeviceSwitchOverVideoZoomFactors as? [CGFloat] {
                // UIの1.0xは deviceの1.0x と等価。切替点をUIにも反映（0.5x はVirtualでは保証しない）
                candidatesUI = [1.0] + switchOver.map { $0 }
                print("🎥 [CameraManager] Virtual device switch-over zoom factors: \(switchOver)")
            } else {
                candidatesUI = [1.0, 2.0, 3.0]
            }
        } else {
            candidatesUI = [1.0, 2.0, 3.0]
        }
        
        // デバイスで実際に使えるものだけを残す（UI→deviceに写像して判定）
        let availableUI = candidatesUI.filter { ui in
            let dev = self.toDeviceZoom(from: ui, device: device)
            let ok = dev >= (minZoom - 0.01) && dev <= (maxZoom + 0.01)
            if ok { print("🎥 [CameraManager] ✅ \(ui)x (device ~ \(dev)x) is supported") }
            else { print("🎥 [CameraManager] ❌ \(ui)x (device ~ \(dev)x) is not supported (device range: \(minZoom)~\(maxZoom))") }
            return ok
        }.sorted()
        
        print("🎥 [CameraManager] Final available UI zoom factors: \(availableUI)")
        cachedZoomFactors = availableUI
        return availableUI
    }
}

// MARK: - Private Methods
private extension CameraManager {
    
    /// カメラ権限をチェック
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            hasPermission = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.hasPermission = granted
                }
            }
        case .denied, .restricted:
            hasPermission = false
        @unknown default:
            hasPermission = false
        }
    }
    
    /// キャプチャセッションの設定
    func configureCaptureSession() {
        print("🎥 [CameraManager] configureCaptureSession() - starting configuration")
        captureSession.beginConfiguration()
        
        // セッション品質設定（超広角アクセスのため inputPriority を試す）
        if captureSession.canSetSessionPreset(.inputPriority) {
            captureSession.sessionPreset = .inputPriority
            print("🎥 [CameraManager] Session preset set to: inputPriority (for ultra-wide access)")
        } else if captureSession.canSetSessionPreset(settings.videoQuality) {
            captureSession.sessionPreset = settings.videoQuality
            print("🎥 [CameraManager] Session preset set to: \(settings.videoQuality.rawValue)")
        }
        
        // ビデオデバイス設定: 超広角カメラアクセスのため Physical Ultra Wide Camera を優先
        // iOS 18のVirtual Deviceでは0.5xズームがサポートされないため
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera,   // 超広角カメラを最優先
            .builtInTripleCamera,      // iPhone 13 Pro, 14 Pro など
            .builtInDualWideCamera,    // iPhone 13, 14 など
            .builtInDualCamera,        // iPhone 12 Pro など
            .builtInWideAngleCamera    // 古い機種用
        ]
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .back
        )
        
        // 利用可能なデバイスを全てログ出力
        print("🎥 [CameraManager] Available devices:")
        for (index, device) in discoverySession.devices.enumerated() {
            print("🎥 [CameraManager] Device \(index): \(device.localizedName) (type: \(device.deviceType.rawValue))")
            print("🎥 [CameraManager] - Zoom range: \(device.minAvailableVideoZoomFactor) ~ \(device.maxAvailableVideoZoomFactor)")
        }
        
        guard let videoDevice = discoverySession.devices.first else {
            print("🎥 [CameraManager] ❌ Failed to get video device")
            DispatchQueue.main.async {
                self.alertError = AlertError(message: "カメラデバイスが見つかりません")
            }
            return
        }
        
        print("🎥 [CameraManager] Got video device: \(videoDevice.localizedName) (type: \(videoDevice.deviceType.rawValue))")
        print("🎥 [CameraManager] Zoom range: \(videoDevice.minAvailableVideoZoomFactor) ~ \(videoDevice.maxAvailableVideoZoomFactor)")
        print("🎥 [CameraManager] Device capabilities:")
        print("🎥 [CameraManager] - hasFlash: \(videoDevice.hasFlash)")
        print("🎥 [CameraManager] - hasTorch: \(videoDevice.hasTorch)")
        print("🎥 [CameraManager] - isVirtualDevice: \(videoDevice.isVirtualDevice)")
        
        // iOS 15以降：virtualDeviceSwitchOverVideoZoomFactors を確認
        if #available(iOS 15.0, *) {
            if videoDevice.isVirtualDevice {
                if let switchOverFactors = videoDevice.virtualDeviceSwitchOverVideoZoomFactors as? [CGFloat] {
                    print("🎥 [CameraManager] - virtualDeviceSwitchOverVideoZoomFactors: \(switchOverFactors)")
                } else {
                    print("🎥 [CameraManager] - virtualDeviceSwitchOverVideoZoomFactors: nil or empty")
                }
            }
        }
        
        if #available(iOS 13.0, *) {
            print("🎥 [CameraManager] - constituentDevices count: \(videoDevice.constituentDevices.count)")
            for (index, device) in videoDevice.constituentDevices.enumerated() {
                print("🎥 [CameraManager] - Component \(index): \(device.localizedName) (type: \(device.deviceType.rawValue))")
                print("🎥 [CameraManager] - Component zoom: \(device.minAvailableVideoZoomFactor) ~ \(device.maxAvailableVideoZoomFactor)")
            }
        }
        
        do {
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            
            if captureSession.canAddInput(videoDeviceInput) {
                captureSession.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
                print("🎥 [CameraManager] ✅ Video input added successfully")
            } else {
                print("🎥 [CameraManager] ❌ Cannot add video input to session")
            }
        } catch {
            print("🎥 [CameraManager] ❌ Failed to create video input: \(error)")
            DispatchQueue.main.async {
                self.alertError = AlertError(message: "カメラデバイスの設定に失敗しました: \(error.localizedDescription)")
            }
            return
        }
        
        // 写真出力設定
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
            print("🎥 [CameraManager] ✅ Photo output added")
            // iOS 17 をターゲットにしているので deprecated なフラグは不要。
            // 最大フォト解像度を参照しておく（将来的な設定に備える）
            _ = photoOutput.maxPhotoDimensions
        }
        
        // 動画出力設定
        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
            print("🎥 [CameraManager] ✅ Movie output added")
        }
        
        captureSession.commitConfiguration()
        print("🎥 [CameraManager] ✅ Session configuration committed")
        
        // デバイス設定を検証・調整
        settings.validateAndAdjustSettings(for: videoDeviceInput!.device)
        
        // ここでは applyCameraSettings() を呼ばず、セッション開始後に適用する
    }
    
    // UltraWide用のUI倍率→デバイス倍率 変換
    func toDeviceZoom(from uiZoom: CGFloat, device: AVCaptureDevice) -> CGFloat {
        if device.deviceType == .builtInUltraWideCamera {
            // UltraWideの基準: UI 0.5x == device 1.0x → device = ui * 2
            return max(1.0, uiZoom * 2.0)
        }
        return uiZoom
    }
    
    // UltraWide用のデバイス倍率→UI倍率 逆変換（ログ/保存用）
    func toUIZoom(fromDeviceZoom deviceZoom: CGFloat, device: AVCaptureDevice) -> CGFloat {
        if device.deviceType == .builtInUltraWideCamera {
            // device 1.0x == UI 0.5x → ui = device / 2
            return max(0.5, deviceZoom / 2.0)
        }
        return deviceZoom
    }
    
    // フレームレート設定（スローモーション対応）
    private func configureFrameRate(for device: AVCaptureDevice) {
        // 現在の機種の対応状況をログ出力
        let maxFrameRate = getMaxFrameRate(for: device)
        print("🎥 [CameraManager] Device: \(device.localizedName)")
        print("🎥 [CameraManager] Max supported frame rate: \(maxFrameRate)fps")
        
        // スローモーションモードでない場合は通常のフレームレート
        guard settings.captureMode == .slowMotion else {
            // 通常モードでは30fpsまたは60fps（デバイスが対応していれば）
            let normalFrameRate = maxFrameRate >= 60 ? 60.0 : 30.0
            print("🎥 [CameraManager] Setting normal mode frame rate: \(normalFrameRate)fps")
            setFrameRate(for: device, fps: normalFrameRate)
            return
        }
        
        // スローモーション用に最高フレームレートを設定
        print("🎥 [CameraManager] Setting slow motion frame rate: \(maxFrameRate)fps")
        setFrameRate(for: device, fps: maxFrameRate)
    }
    
    // デバイスの最高フレームレートを取得
    private func getMaxFrameRate(for device: AVCaptureDevice) -> Double {
        var maxFrameRate: Double = 30.0
        
        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate > maxFrameRate {
                    maxFrameRate = range.maxFrameRate
                }
            }
        }
        
        print("🎥 [CameraManager] Max supported frame rate: \(maxFrameRate)fps")
        return maxFrameRate
    }
    
    // 指定フレームレートを設定
    private func setFrameRate(for device: AVCaptureDevice, fps: Double) {
        guard let format = findFormat(for: device, withFrameRate: fps) else {
            print("🎥 [CameraManager] ❌ No format found for \(fps)fps, trying fallback")
            // フォールバック: より低いフレームレートを試す
            if fps > 60 {
                setFrameRate(for: device, fps: 60)
            } else if fps > 30 {
                setFrameRate(for: device, fps: 30)
            }
            return
        }
        
        do {
            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            
            // 設定されたフォーマットの詳細をログ出力
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            print("🎥 [CameraManager] ✅ Frame rate set to \(fps)fps")
            print("🎥 [CameraManager] ✅ Video format: \(dimensions.width)x\(dimensions.height)")
            
        } catch {
            print("🎥 [CameraManager] ❌ Failed to set frame rate: \(error)")
        }
    }
    
    // 指定フレームレートをサポートするフォーマットを検索
    private func findFormat(for device: AVCaptureDevice, withFrameRate fps: Double) -> AVCaptureDevice.Format? {
        var bestFormat: AVCaptureDevice.Format?
        var bestResolution = 0
        
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let resolution = Int(dimensions.width * dimensions.height)
            
            for range in format.videoSupportedFrameRateRanges {
                if range.minFrameRate <= fps && fps <= range.maxFrameRate {
                    // より高解像度のフォーマットを優先
                    if bestFormat == nil || resolution > bestResolution {
                        bestFormat = format
                        bestResolution = resolution
                    }
                }
            }
        }
        
        if let format = bestFormat {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            print("🎥 [CameraManager] Found best format for \(fps)fps: \(dimensions.width)x\(dimensions.height)")
        }
        
        return bestFormat
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.alertError = AlertError(message: "写真撮影に失敗しました: \(error.localizedDescription)")
            }
            return
        }
        
        guard let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else {
            DispatchQueue.main.async {
                self.alertError = AlertError(message: "画像データの生成に失敗しました")
            }
            return
        }
        
        // 写真を保存
        PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAsset(from: image)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    self.capturedImage = image
                } else {
                    self.alertError = AlertError(message: "写真の保存に失敗しました: \(error?.localizedDescription ?? "不明なエラー")")
                }
            }
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate
extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.alertError = AlertError(message: "動画録画に失敗しました: \(error.localizedDescription)")
            }
            return
        }
        
        // 動画を写真ライブラリに保存
        PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if !success {
                    self.alertError = AlertError(message: "動画の保存に失敗しました: \(error?.localizedDescription ?? "不明なエラー")")
                }
            }
            
            // 一時ファイルを削除
            try? FileManager.default.removeItem(at: outputFileURL)
        }
    }
}

// MARK: - Supporting Types

struct AlertError: Equatable {
    let message: String
}
