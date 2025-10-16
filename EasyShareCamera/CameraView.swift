//
//  CameraView.swift
//  EasyShareCamera
//
//  Created by EasyShareCamera on 2025/10/13.
//

import SwiftUI
import AVFoundation

struct CameraView: View {
    @StateObject private var cameraSettings: CameraSettings
    @StateObject private var cameraManager: CameraManager
    @State private var showingMasterSettings = false
    @State private var showingLocalSettings = false
    @State private var showingAlert = false
    @State private var recordingDuration: TimeInterval = 0
    @State private var recordingTimer: Timer?
    @State private var lastZoomFactor: CGFloat = 1.0
    @State private var availableZoomFactors: [CGFloat] = []
    
    init() {
        let settings = CameraSettings()
        _cameraSettings = StateObject(wrappedValue: settings)
        _cameraManager = StateObject(wrappedValue: CameraManager(settings: settings))
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if cameraManager.hasPermission {
                cameraPreviewContent
                mainContent
            } else {
                permissionView
            }
        }
        .safeAreaInset(edge: .top) {
            // 上部に透明なスペーサーを配置
            Color.clear.frame(height: 0)
        }
        .onAppear {
            print("📱 [CameraView] onAppear - hasPermission: \(cameraManager.hasPermission)")
            lastZoomFactor = cameraSettings.zoomFactor
            
            if cameraManager.hasPermission {
                cameraManager.startSession()
                // セッション開始後にズーム倍率を取得
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if availableZoomFactors.isEmpty {
                        availableZoomFactors = cameraManager.getAvailableZoomFactors()
                    }
                }
            } else {
                print("📱 [CameraView] No camera permission yet")
            }
        }
        .onDisappear {
            print("📱 [CameraView] onDisappear")
            cameraManager.stopSession()
        }
        .alert("エラー", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(cameraManager.alertError?.message ?? "")
        }
        .onChange(of: cameraManager.alertError) { _, _ in
            showingAlert = cameraManager.alertError != nil
        }
        .onChange(of: cameraManager.hasPermission) { _, newValue in
            print("📱 [CameraView] Permission changed to: \(newValue)")
            if newValue {
                cameraManager.startSession()
                // 権限許可後にズーム倍率を取得
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if availableZoomFactors.isEmpty {
                        availableZoomFactors = cameraManager.getAvailableZoomFactors()
                    }
                }
            } else {
                cameraManager.stopSession()
            }
        }
        .onChange(of: cameraManager.isRecording) { _, isRecording in
            if isRecording {
                startRecordingTimer()
            } else {
                stopRecordingTimer()
            }
        }
        .onChange(of: cameraSettings.zoomFactor) { _, newValue in
            lastZoomFactor = newValue
        }
        .sheet(isPresented: $showingMasterSettings) {
            MasterSettingsView(settings: cameraSettings, cameraManager: cameraManager)
        }
        .sheet(isPresented: $showingLocalSettings) {
            LocalSettingsView(settings: cameraSettings, cameraManager: cameraManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // デバイス回転時にプレビューを更新
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // 少し遅延を入れてからプレビューを更新
                print("📱 [CameraView] Device orientation changed, updating preview")
            }
        }
        .ignoresSafeArea(.all)
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Camera Preview Content
    private var cameraPreviewContent: some View {
        CameraPreviewView(session: cameraManager.captureSession)
            .ignoresSafeArea()
            .clipped()
            .allowsHitTesting(true)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        guard let device = cameraManager.captureDevice else { return }
                        
                        // ピンチズームの感度を調整（より丁寧に）
                        let sensitivity: CGFloat = 0.075  // 感度をさらに下げる（0.3の1/4）
                        let dampedValue = 1.0 + (value - 1.0) * sensitivity
                        
                        // より丁寧なズーム計算
                        let newZoom = lastZoomFactor * dampedValue
                        
                        // デバイス種別を考慮した範囲制限
                        let minUIZoom: CGFloat = device.deviceType == .builtInUltraWideCamera ? 0.5 : 1.0
                        let maxUIZoom: CGFloat = 10.0
                        let clampedZoom = min(max(newZoom, minUIZoom), maxUIZoom)
                        
                        // 超広角カメラの場合、UI倍率をデバイス倍率に変換して適用
                        cameraManager.zoom(by: clampedZoom)
                    }
                    .onEnded { _ in
                        lastZoomFactor = cameraSettings.zoomFactor
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    let size = UIScreen.main.bounds.size
                    let point = CGPoint(
                        x: value.location.x / size.width,
                        y: value.location.y / size.height
                    )
                    cameraManager.setFocusPoint(point)
                }
            )
    }
    
    // MARK: - Main Content
    private var mainContent: some View {
        VStack {
            // 上部コントロール
            topControls
                .padding(.horizontal)
                .padding(.top, 10) // 上部余白を減らす（topControls内でスペーサー追加したため）
            
            Spacer()
            
            // 下部コントロール
            bottomControls
                .padding(.horizontal)
                .padding(.bottom, 40) // 下部も余白を増やす
        }
    }
    
    // MARK: - Top Controls
    private var topControls: some View {
        VStack(spacing: 0) {
            // ステータスバー分のスペーサー
            Spacer().frame(height: 20)
            
            HStack {
                // マスター設定ボタン
                Button(action: { showingMasterSettings = true }) {
                    VStack(spacing: 2) {
                        Image(systemName: "gearshape.fill")
                            .font(.title3)
                        Text("Master")
                            .font(.caption2)
                    }
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                Spacer()
                
                // 中央エリア: マスター表示とモード表示
                VStack(spacing: 4) {
                    Text("MASTER")
                        .foregroundColor(.yellow)
                        .font(.caption)
                        .bold()
                    
                    HStack(spacing: 8) {
                        Text(cameraSettings.captureMode.displayName)
                            .foregroundColor(.white)
                            .font(.headline)
                        
                        // 録画時間表示（録画中のみ）
                        if cameraManager.isRecording {
                            Text(formatDuration(recordingDuration))
                                .foregroundColor(.red)
                                .font(.headline)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.3))
                    .clipShape(Capsule())
                }
                
                Spacer()
                
                // ローカル設定ボタン
                Button(action: { showingLocalSettings = true }) {
                    VStack(spacing: 2) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title3)
                        Text("Local")
                            .font(.caption2)
                    }
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
    
    // MARK: - Bottom Controls
    private var bottomControls: some View {
        VStack(spacing: 8) {
            // ズーム倍率表示とボタン（コンパクト化）
            HStack(spacing: 8) {
                // 現在のズーム倍率表示（半透明白背景・黒文字で区別）
                Text(String(format: "%.1fx", cameraSettings.zoomFactor))
                    .foregroundColor(.black)
                    .font(.caption)
                    .bold()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.5))
                    .clipShape(Capsule())
                
                // キリの良い倍率ボタン（コンパクト化）
                ForEach(availableZoomFactors, id: \.self) { factor in
                    Button(action: {
                        cameraManager.zoom(by: factor)
                    }) {
                        Text(formatZoomFactor(factor))
                            .foregroundColor(.white)
                            .font(.caption)
                            .bold()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.white, lineWidth: abs(cameraSettings.zoomFactor - factor) < 0.1 ? 1.5 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // シャッターボタン（サイズを少し小さく）
            HStack(spacing: 0) {
                // 左側のスペーサー
                Spacer()
                
                // メインシャッターボタン（中央・小さめ）
                Button(action: mainCaptureAction) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 70, height: 70)
                        
                        if cameraManager.isRecording {
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: 24, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        } else {
                            Circle()
                                .fill(captureButtonColor)
                                .frame(width: 60, height: 60)
                        }
                    }
                }
                .scaleEffect(cameraManager.isRecording ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: cameraManager.isRecording)
                
                // 右側のスペーサー
                Spacer()
            }
        }
    }
    
    // MARK: - Permission View
    private var permissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            
            Text("カメラへのアクセスが必要です")
                .font(.title2)
                .foregroundColor(.white)
            
            Text("設定からカメラの使用を許可してください")
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            
            Button("設定を開く") {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
            }
            .foregroundColor(.blue)
            .font(.headline)
        }
        .padding()
    }
    
    // MARK: - Computed Properties
    private var captureButtonColor: Color {
        switch cameraSettings.captureMode {
        case .photo:
            return .clear
        case .video, .slowMotion:
            return .red
        }
    }
    
    // MARK: - Actions
    private func mainCaptureAction() {
        switch cameraSettings.captureMode {
        case .photo:
            cameraManager.capturePhoto()
        case .video, .slowMotion:
            cameraManager.toggleRecording()
        }
    }
    
    private func startRecordingTimer() {
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            recordingDuration += 0.1
        }
    }
    
    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingDuration = 0
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let deciseconds = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", minutes, seconds, deciseconds)
    }
    
    private func formatZoomFactor(_ factor: CGFloat) -> String {
        if factor == floor(factor) {
            return String(format: "%.0fx", factor)
        } else {
            return String(format: "%.1fx", factor)
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView(session: session)
        return view
    }
    
    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.updateLayout()
    }
}

// カスタムUIViewクラス
class CameraPreviewUIView: UIView {
    private let session: AVCaptureSession
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    init(session: AVCaptureSession) {
        self.session = session
        super.init(frame: .zero)
        setupPreviewLayer()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupPreviewLayer() {
        backgroundColor = .black
        
#if targetEnvironment(simulator)
        // Simulator: プレースホルダを表示
        let placeholder = UIImageView(image: UIImage(systemName: "camera.fill"))
        placeholder.contentMode = .center
        placeholder.tintColor = .gray
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.5),
            placeholder.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.5)
        ])
#else
        // Real device: カメラプレビューレイヤーを作成
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        
        layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer
        
        print("📱 [CameraPreviewUIView] Preview layer setup completed without orientation settings")
#endif
    }
    
    func updateLayout() {
        guard let previewLayer = previewLayer else { return }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true) // アニメーションを無効化
        previewLayer.frame = bounds
        previewLayer.setAffineTransform(.identity)
        CATransaction.commit()
        
        print("📱 [CameraPreviewUIView] Layout updated without orientation changes")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        updateLayout()
    }
}

#Preview {
    CameraView()
}
