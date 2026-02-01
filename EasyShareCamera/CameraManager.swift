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

/// カメラの操作を管理するクラス
class CameraManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isSessionRunning = false
    @Published var isRecording = false
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
    private var isArmed = false
    private var recordingStartTime: Date?
    
    // 撮影設定（30cm落下、240fps）
    private let dropHeight: Double = 0.3  // 30cm
    private let targetFrameRate: Int32 = 240
    private let recordingDuration: Double = 4.0  // 前後2秒ずつ
    
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
    
    // MARK: - Private Methods
    
    /// キャプチャセッションをセットアップ
    private func setupCaptureSession() {
        captureSession.beginConfiguration()
        
        // 高品質プリセット
        if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }
        
        // カメラデバイスを追加
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
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
    
    /// 240fps設定
    private func configure240FPS(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            
            // 240fpsをサポートするフォーマットを検索
            var bestFormat: AVCaptureDevice.Format?
            var bestFrameRate: AVFrameRateRange?
            
            for format in device.formats {
                for range in format.videoSupportedFrameRateRanges {
                    if range.maxFrameRate >= Double(targetFrameRate) {
                        // 解像度が高いほど優先
                        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        let currentBest = bestFormat.map { CMVideoFormatDescriptionGetDimensions($0.formatDescription) }
                        
                        if bestFormat == nil ||
                           (dimensions.width * dimensions.height) > ((currentBest?.width ?? 0) * (currentBest?.height ?? 0)) {
                            bestFormat = format
                            bestFrameRate = range
                        }
                    }
                }
            }
            
            if let format = bestFormat, let frameRate = bestFrameRate {
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
                
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                print("✅ [CameraManager] 240fps configured: \(dimensions.width)x\(dimensions.height)")
            } else {
                print("⚠️ [CameraManager] 240fps not supported, using default")
            }
            
            // 露出とフォーカスを固定（ミルククラウン撮影では変動を避ける）
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            
            device.unlockForConfiguration()
            
        } catch {
            print("❌ [CameraManager] Failed to configure 240fps: \(error)")
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
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isArmed, !isRecording else { return }
        
        // 赤色LED検知
        if let result = redLightDetector.detectRedLight(from: sampleBuffer), result.isDetected {
            isArmed = false
            redLightDetector.isEnabled = false
            
            print("🔴 [CameraManager] RED LIGHT DETECTED! Starting recording...")
            
            // 録画開始
            DispatchQueue.main.async {
                self.startRecording()
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
            DispatchQueue.main.async {
                self.alertError = AlertError(message: "録画エラー: \(error.localizedDescription)")
            }
            return
        }
        
        // 写真ライブラリに保存
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized else {
                print("⚠️ [CameraManager] Photo library access denied")
                return
            }
            
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
            }) { success, error in
                if success {
                    print("✅ [CameraManager] Video saved to photo library")
                } else if let error = error {
                    print("❌ [CameraManager] Failed to save video: \(error.localizedDescription)")
                }
                
                // 一時ファイルを削除
                try? FileManager.default.removeItem(at: outputFileURL)
            }
        }
    }
}

// MARK: - AlertError

struct AlertError: Identifiable {
    let id = UUID()
    let message: String
}
