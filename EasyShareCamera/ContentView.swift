//
//  ContentView.swift
//  EasyShareCamera
//
//  ミルククラウン撮影用のメインUI
//

import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @State private var showInfo = false
    
    var body: some View {
        ZStack {
            // カメラプレビュー
            CameraPreviewView(cameraManager: cameraManager)
                .edgesIgnoringSafeArea(.all)
            
            // オーバーレイUI
            VStack {
                // 上部：情報表示
                HStack {
                    Spacer()
                    
                    Button(action: { showInfo.toggle() }) {
                        Image(systemName: "info.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding()
                }
                
                Spacer()
                
                // 中央：ステータス表示
                if cameraManager.isRecording {
                    VStack(spacing: 16) {
                        Text("録画中...")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                        
                        ProgressView(value: cameraManager.recordingProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .red))
                            .frame(width: 200)
                        
                        Text("\(Int(cameraManager.recordingProgress * 100))%")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(16)
                }
                
                Spacer()
                
                // 下部：コントロールボタン
                VStack(spacing: 20) {
                    // ARMボタン
                    Button(action: {
                        cameraManager.armCapture()
                    }) {
                        HStack {
                            Image(systemName: "target")
                            Text("撮影準備")
                                .fontWeight(.bold)
                        }
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 16)
                        .background(Color.green)
                        .cornerRadius(12)
                    }
                    .disabled(cameraManager.isRecording)
                    
                    // キャンセルボタン
                    Button(action: {
                        cameraManager.disarmCapture()
                    }) {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("キャンセル")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(8)
                    }
                    .disabled(cameraManager.isRecording)
                }
                .padding(.bottom, 50)
            }
        }
        .onAppear {
            cameraManager.startSession()
        }
        .onDisappear {
            cameraManager.stopSession()
        }
        .sheet(isPresented: $showInfo) {
            InfoView()
        }
        .alert(item: $cameraManager.alertError) { error in
            Alert(
                title: Text("エラー"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

// MARK: - Camera Preview View

struct CameraPreviewView: UIViewRepresentable {
    let cameraManager: CameraManager
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        
        let previewLayer = cameraManager.getPreviewLayer()
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewLayer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            DispatchQueue.main.async {
                previewLayer.frame = uiView.bounds
            }
        }
    }
}

// MARK: - Info View

struct InfoView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // アプリ説明
                    Section {
                        Text("EasyShareCamera")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("ミルククラウン撮影システム")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .padding(.bottom)
                    
                    // 使い方
                    Section {
                        Text("使い方")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            InfoRow(number: "1", text: "カメラを三脚に固定し、ミルククラウンが発生する位置を画面中央に合わせます")
                            InfoRow(number: "2", text: "赤色LEDを撮影領域に配置します（水滴検知センサーと連動）")
                            InfoRow(number: "3", text: "「撮影準備」ボタンをタップします")
                            InfoRow(number: "4", text: "水滴を落とすと、赤色LEDが点灯し、自動的に録画が開始されます")
                            InfoRow(number: "5", text: "録画は4秒間自動で行われ、写真ライブラリに保存されます")
                        }
                    }
                    .padding(.bottom)
                    
                    // 技術仕様
                    Section {
                        Text("技術仕様")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            SpecRow(label: "落下高さ", value: "30cm")
                            SpecRow(label: "落下時間", value: "約247ms")
                            SpecRow(label: "フレームレート", value: "240fps")
                            SpecRow(label: "録画時間", value: "4秒")
                            SpecRow(label: "総フレーム数", value: "960フレーム")
                            SpecRow(label: "検知方式", value: "赤色LED光学検知")
                        }
                    }
                    .padding(.bottom)
                    
                    // 注意事項
                    Section {
                        Text("注意事項")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("• 撮影環境は暗めにし、赤色LEDを明確に検知できるようにしてください")
                            Text("• 赤色LED以外の強い光源（赤い照明など）は避けてください")
                            Text("• カメラは必ず固定してください（手持ち撮影は非推奨）")
                            Text("• 初回撮影前に写真ライブラリへのアクセスを許可してください")
                        }
                        .font(.callout)
                        .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Helper Views

struct InfoRow: View {
    let number: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Color.blue)
                .clipShape(Circle())
            
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SpecRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.body)
                .fontWeight(.medium)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
}
