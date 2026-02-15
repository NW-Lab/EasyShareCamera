//
//  CameraManager.swift
//  EasyShareCamera
//
//  30cm落下の水滴を240fps撮影するカメラマネージャー
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
    @Published private(set) var isArmed = false
    @Published private(set) var lastRecordedURL: URL?
    @Published var hasPermission = false
    @Published var alertError: AlertError?
    @Published var recordingProgress: Double = 0.0
    
    // MARK: - Properties
    
    let captureSession = AVCaptureSession()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let videoDataQueue = DispatchQueue(label: "camera.videodata.queue")
    
    // 赤色LED検知
    private let redLightDetector = RedLightDetector()
    private var recordingStartTime: Date?
    private var isContinuousMode = false
    private var isPreviewEnabled = false
    private var isSaveToPhotoLibraryEnabled = true
    private var desiredZoomFactor: CGFloat = 1.0
    private var isFocusLocked = false
    private var focusMode: FocusMode = .auto
    private var focusPosition: Float = 0.5
    
    // 撮影設定（30cm落下、240fps）
    private var dropHeight: Double = 0.3  // 30cm
    private let targetFrameRate: Int32 = 240
    private var recordingDuration: Double = 4.0  // 前後2秒ずつ
    private let preImpactOffset: Double = 0.5
    
    // MARK: - Computed Properties
    
    var captureDevice: AVCaptureDevice? {
        return videoDeviceInput?.device
    }
    
    var calculatedDropTime: Double {
        let gravity = 9.81  // m/s²
        return sqrt(2.0 * dropHeight / gravity)  // 約0.247秒
    }
    
    // MARK: - Initializer
    
    override init() {
        super.init()
        checkPermissions()
    }
    
    // MARK: - Public Methods
    
    /// カメラ権限をチェック
    func checkPermissions() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            DispatchQueue.main.async { self.hasPermission = true }
            sessionQueue.async { self.setupCaptureSession() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { self.hasPermission = granted }
                if granted {
                    self.sessionQueue.async { self.setupCaptureSession() }
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async { self.hasPermission = false }
        @unknown default:
            DispatchQueue.main.async { self.hasPermission = false }
        }
    }
    
    /// カメラセッションを開始
    func startSession() {
        sessionQueue.async {
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
                DispatchQueue.main.async {
                    self.isSessionRunning = true
                }
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
    
    /// 撮影を準備（赤色LED検知を有効化）
    func armCapture() {
        guard !isRecording else { return }
        
        isArmed = true
        redLightDetector.isEnabled = true
        redLightDetector.reset()
        
        print("✅ [CameraManager] Armed - Waiting for red LED trigger...")
        print("📊 [CameraManager] Drop height: \(dropHeight)m, Drop time: \(String(format: "%.3f", calculatedDropTime))s")
    }
    
    /// 撮影をキャンセル
    func disarmCapture() {
        isArmed = false
        redLightDetector.isEnabled = false
        
        print("🛑 [CameraManager] Disarmed")
    }
    
    /// テスト録画開始
    func startTestRecording() {
        guard !isRecording else { return }
        
        isArmed = false
        redLightDetector.isEnabled = false
        startRecording()
    }
    
    /// プレビューレイヤーを取得
    func getPreviewLayer() -> AVCaptureVideoPreviewLayer {
        if let existing = previewLayer {
            return existing
        }
        
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer
        return layer
    }
    
    /// 撮影モードを更新
    func updateCaptureMode(isContinuous: Bool) {
        isContinuousMode = isContinuous
    }

    /// 落下距離を更新（cm指定）
    func updateDropHeightCentimeters(_ centimeters: Double) {
        let clamped = min(max(centimeters, 15.0), 50.0)
        dropHeight = clamped / 100.0
    }

    /// 撮影時間を更新（秒指定）
    func updateRecordingDurationSeconds(_ seconds: Double) {
        let clamped = min(max(seconds, 1.0), 4.0)
        recordingDuration = clamped
    }

    /// 録画プレビューの有効/無効を更新
    func updatePreviewEnabled(_ isEnabled: Bool) {
        isPreviewEnabled = isEnabled
    }

    /// 写真ライブラリ保存の有効/無効を更新
    func updateSaveToPhotoLibraryEnabled(_ isEnabled: Bool) {
        isSaveToPhotoLibraryEnabled = isEnabled
    }

    /// 光学倍率を更新
    func updateZoomFactor(_ factor: Double) {
        desiredZoomFactor = CGFloat(max(1.0, factor))
        applyZoomAndFocusIfPossible()
    }

    /// フォーカス固定を更新
    func updateFocusLocked(_ locked: Bool) {
        isFocusLocked = locked
        applyZoomAndFocusIfPossible()
    }

    /// フォーカスモードを更新
    func updateFocusMode(isManual: Bool) {
        focusMode = isManual ? .manual : .auto
        applyZoomAndFocusIfPossible()
    }

    /// フォーカス位置を更新（0.0 - 1.0）
    func updateFocusPosition(_ position: Float) {
        focusPosition = min(max(position, 0.0), 1.0)
        applyZoomAndFocusIfPossible()
    }

    /// 光学倍率の最大値を取得
    func maxZoomFactor() -> Double {
        guard let device = captureDevice else { return 5.0 }
        return Double(min(device.activeFormat.videoMaxZoomFactor, 5.0))
    }

    /// 直近の録画ファイルを削除
    func clearLastRecording() {
        if let url = lastRecordedURL {
            try? FileManager.default.removeItem(at: url)
        }
        lastRecordedURL = nil
    }
    
    // MARK: - Private Methods
    
    /// キャプチャセッションをセットアップ
    private func setupCaptureSession() {
        captureSession.beginConfiguration()
        
        // 高品質プリセット
        if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }
        
        // カメラデバイスを追加
        guard let videoDevice = selectCaptureDevice(),
              let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(videoDeviceInput) else {
            print("❌ [CameraManager] Failed to add video input")
            captureSession.commitConfiguration()
            return
        }
        
        captureSession.addInput(videoDeviceInput)
        self.videoDeviceInput = videoDeviceInput
        
        // 240fps設定
        configure240FPS(for: videoDevice)
        applyZoomAndFocusIfPossible()
        
        // ムービー出力を追加
        let movieOutput = AVCaptureMovieFileOutput()
        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
            self.movieOutput = movieOutput
            
            // 高速撮影用の接続設定
            if let connection = movieOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off  // スローモーションでは手ブレ補正をオフ
                }
            }
        }
        
        // ビデオデータ出力を追加（赤色検知用）
        let videoDataOutput = AVCaptureVideoDataOutput()
        videoDataOutput.setSampleBufferDelegate(self, queue: videoDataQueue)
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        
        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
            self.videoDataOutput = videoDataOutput
        }
        
        captureSession.commitConfiguration()
        
        print("✅ [CameraManager] Capture session configured for 240fps")
    }
    
    private func selectCaptureDevice() -> AVCaptureDevice? {
        if let telephoto = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) {
            return telephoto
        }
        if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            return wide
        }
        return nil
    }
    
    /// 240fps設定
    private func configure240FPS(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()

            // 240fpsをサポートするフォーマットを検索
            var bestFormat: AVCaptureDevice.Format?

            for format in device.formats {
                for range in format.videoSupportedFrameRateRanges {
                    if range.maxFrameRate >= Double(targetFrameRate) {
                        // 解像度が高いほど優先
                        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        let currentBest = bestFormat.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }

                        if bestFormat == nil ||
                           (dimensions.width * dimensions.height) > ((currentBest?.width ?? 0) * (currentBest?.height ?? 0)) {
                            bestFormat = format
                        }
                    }
                }
            }

            if let format = bestFormat {
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))

                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                print("✅ [CameraManager] 240fps configured: \(dimensions.width)x\(dimensions.height)")
            } else {
                print("⚠️ [CameraManager] 240fps not supported, using default")
            }

            applyFocusConfiguration(for: device)

            device.unlockForConfiguration()

        } catch {
            print("❌ [CameraManager] Failed to configure 240fps: \(error)")
        }
    }

    private func applyZoomAndFocusIfPossible() {
        sessionQueue.async {
            guard let device = self.captureDevice else { return }
            do {
                try device.lockForConfiguration()
                let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 5.0)
                let clamped = min(max(self.desiredZoomFactor, 1.0), maxZoom)
                device.videoZoomFactor = clamped
                self.applyFocusConfiguration(for: device)
                device.unlockForConfiguration()
            } catch {
                print("⚠️ [CameraManager] Failed to apply zoom/focus: \(error)")
            }
        }
    }

    private func applyFocusConfiguration(for device: AVCaptureDevice) {
        if focusMode == .manual, device.isFocusModeSupported(.locked) {
            device.setFocusModeLocked(lensPosition: focusPosition, completionHandler: nil)
            return
        }
        if isFocusLocked {
            if device.isFocusModeSupported(.locked) {
                device.setFocusModeLocked(lensPosition: device.lensPosition, completionHandler: nil)
            }
        } else if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }
    
    /// 録画を開始
    private func startRecording() {
        guard let movieOutput = movieOutput, !movieOutput.isRecording else { return }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let timestamp = Int(Date().timeIntervalSince1970)
        let videoURL = documentsPath.appendingPathComponent("milkcrown_\(timestamp).mov")
        
        // 既存ファイルを削除
        try? FileManager.default.removeItem(at: videoURL)
        
        movieOutput.startRecording(to: videoURL, recordingDelegate: self)
        recordingStartTime = Date()
        
        DispatchQueue.main.async {
            self.isRecording = true
        }
        
        // 指定時間後に自動停止
        DispatchQueue.main.asyncAfter(deadline: .now() + recordingDuration) { [weak self] in
            self?.stopRecording()
        }
        
        // 進捗表示
        startProgressTimer()
        
        print("🎬 [CameraManager] Recording started: \(videoURL.lastPathComponent)")
    }
    
    /// 録画を停止
    private func stopRecording() {
        guard let movieOutput = movieOutput, movieOutput.isRecording else { return }
        
        movieOutput.stopRecording()
        
        print("🛑 [CameraManager] Recording stopped")
    }
    
    /// 進捗タイマー
    private func startProgressTimer() {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self,
                  let startTime = self.recordingStartTime,
                  self.isRecording else {
                timer.invalidate()
                return
            }
            
            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(1.0, elapsed / self.recordingDuration)
            
            DispatchQueue.main.async {
                self.recordingProgress = progress
            }
            
            if progress >= 1.0 {
                timer.invalidate()
            }
        }
    }
    
    /// 着地時刻の0.5秒前から録画する
    private func scheduleRecordingRelativeToImpact() {
        let delay = max(0.0, calculatedDropTime - preImpactOffset)
        if delay > 0 {
            print("⏱️ [CameraManager] Recording will start in \(String(format: "%.3f", delay))s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startRecording()
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isArmed, !isRecording else { return }

        // 赤色LED検知
        if let result = redLightDetector.detectRedLight(from: sampleBuffer), result.isDetected {
            isArmed = false
            redLightDetector.isEnabled = false

            print("🔴 [CameraManager] RED LIGHT DETECTED! Scheduling recording...")

            // 着地時刻の0.5秒前から録画
            DispatchQueue.main.async {
                self.scheduleRecordingRelativeToImpact()
            }
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingProgress = 0.0
        }
        
        if let error = error {
            print("❌ [CameraManager] Recording error: \(error.localizedDescription)")
            let message = String(
                format: NSLocalizedString("録画エラー: %@", comment: "Recording error message"),
                error.localizedDescription
            )
            DispatchQueue.main.async {
                self.alertError = AlertError(message: message)
            }
            return
        }
        
        // 写真ライブラリに保存
        if isSaveToPhotoLibraryEnabled {
            PHPhotoLibrary.requestAuthorization { status in
                guard status == .authorized else {
                    print("⚠️ [CameraManager] Photo library access denied")
                    self.handlePostRecording(outputFileURL: outputFileURL)
                    return
                }
                
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
                }) { [weak self] success, error in
                    guard let self = self else { return }
                    
                    if success {
                        print("✅ [CameraManager] Video saved to photo library")
                    } else if let error = error {
                        print("❌ [CameraManager] Failed to save video: \(error.localizedDescription)")
                    }
                    
                    self.handlePostRecording(outputFileURL: outputFileURL)
                }
            }
        } else {
            handlePostRecording(outputFileURL: outputFileURL)
        }
    }

    private func handlePostRecording(outputFileURL: URL) {
        if isPreviewEnabled {
            schedulePreview(for: outputFileURL, retries: 10)
        } else {
            // 一時ファイルを削除
            try? FileManager.default.removeItem(at: outputFileURL)
        }
        
        if self.isContinuousMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.armCapture()
            }
        }
    }

    private func schedulePreview(for url: URL, retries: Int) {
        if isFileReady(at: url) {
            DispatchQueue.main.async {
                self.lastRecordedURL = url
            }
            return
        }

        guard retries > 0 else {
            print("⚠️ [CameraManager] Preview file not ready: \(url.lastPathComponent)")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.schedulePreview(for: url, retries: retries - 1)
        }
    }

    private func isFileReady(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return false }
        guard size.intValue > 0 else { return false }

        let asset = AVURLAsset(url: url)
        return asset.isPlayable && !asset.duration.isIndefinite
    }
}

// MARK: - AlertError

struct AlertError: Identifiable {
    let id = UUID()
    let message: String
}

private enum FocusMode {
    case auto
    case manual
}
