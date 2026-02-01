# Arduino水滴トリガーシステム

フォトカプラで水滴を検知し、赤色LEDを点灯させてiPhoneに撮影トリガーを送るシステムです。

## ハードウェア構成

### 必要な部品

| 部品 | 数量 | 備考 |
|---|---|---|
| Arduino Uno / Nano | 1 | ESP32でも可 |
| フォトカプラモジュール | 1 | 赤外線LED + フォトトランジスタ |
| 高輝度赤色LED | 1 | 5mm、順方向電圧2.0V |
| 抵抗 220Ω | 1 | LED電流制限用 |
| ブレッドボード | 1 | プロトタイピング用 |
| ジャンパーワイヤー | 適量 | オス-オス、オス-メス |

### 回路図

```
                    Arduino
                   ┌─────────┐
                   │         │
フォトカプラ ────────┤ D2      │
  (OUT)            │ (INPUT) │
                   │         │
                   │     D13 ├──────┐
                   │  (内蔵LED)     │
                   │         │     LED1 (内蔵)
                   │      D9 ├──────┤
                   │   (PWM) │      │
                   │         │     LED2 (外部)
                   │     GND ├──────┴────[220Ω]───GND
                   │         │
                   │     5V  ├────── フォトカプラ VCC
                   │     GND ├────── フォトカプラ GND
                   └─────────┘
```

### 詳細な接続

#### フォトカプラ側

1. **送信側（赤外線LED）**
   - VCC → Arduino 5V
   - GND → Arduino GND
   - 水滴が通過する位置に設置

2. **受信側（フォトトランジスタ）**
   - OUT → Arduino D2
   - VCC → Arduino 5V
   - GND → Arduino GND

#### LED側

1. **内蔵LED（D13）**
   - Arduino Unoの内蔵LEDを使用
   - 追加配線不要

2. **外部赤色LED（D9）**
   - アノード（長い足）→ D9
   - カソード（短い足）→ 220Ω抵抗 → GND
   - より明るいLEDを使用することで検知精度向上

## ソフトウェアセットアップ

### 1. Arduino IDEのインストール

[Arduino公式サイト](https://www.arduino.cc/en/software)からダウンロードしてインストール。

### 2. コードのアップロード

1. Arduino IDEを起動
2. `arduino/water_drop_trigger/water_drop_trigger.ino` を開く
3. ボード選択：ツール > ボード > Arduino Uno（または使用するボード）
4. ポート選択：ツール > ポート > 接続されているポート
5. アップロードボタンをクリック

### 3. 動作確認

1. シリアルモニタを開く（ツール > シリアルモニタ）
2. ボーレートを `115200` に設定
3. 起動メッセージが表示されることを確認

```
Water Drop Trigger System
Waiting for water drop detection...
System ready!
```

## 使い方

### 1. セットアップ

1. **フォトカプラの設置**
   - 送信側と受信側を向かい合わせに配置
   - 水滴が通過する位置（30cm上）に設置
   - 光軸を正確に合わせる

2. **赤色LEDの配置**
   - iPhoneのカメラから見える位置に配置
   - 画面中央に映るように調整
   - 撮影領域全体を照らすように配置

3. **電源投入**
   - ArduinoをUSBまたは外部電源で起動
   - LEDが3回点滅すれば正常起動

### 2. 撮影フロー

1. iPhoneアプリで「撮影準備」をタップ
2. 水滴を落とす
3. フォトカプラが水滴を検知
4. 赤色LEDが点灯（5秒間）
5. iPhoneが自動的に録画開始
6. 録画完了後、LEDが消灯
7. 1秒のクールダウン後、次の撮影が可能

### 3. トラブルシューティング

#### フォトカプラが反応しない

- 光軸がずれていないか確認
- 水滴のサイズを大きくする
- フォトカプラの感度を調整

#### iPhoneが検知しない

- 赤色LEDの輝度を上げる
- LEDをカメラに近づける
- 撮影環境を暗くする
- LEDの向きを調整

#### 誤検知が多い

- `DEBOUNCE_DELAY` を増やす（50ms → 100ms）
- フォトカプラを遮光する
- 環境光の影響を減らす

## カスタマイズ

### LED点灯時間の変更

```cpp
const unsigned long LED_ON_DURATION = 5000;  // 5秒 → 任意の値（ms）
```

### クールダウン時間の変更

```cpp
const unsigned long COOLDOWN_TIME = 1000;  // 1秒 → 任意の値（ms）
```

### LED輝度の調整

```cpp
analogWrite(EXTERNAL_LED_PIN, 255);  // 255（最大） → 0-255の範囲
```

### ピン番号の変更

```cpp
const int PHOTOCOUPLER_PIN = 2;   // 任意のデジタルピン
const int EXTERNAL_LED_PIN = 9;   // PWM対応ピン（3,5,6,9,10,11）
```

## 高度な使用例

### 複数LED対応

複数のLEDを使用して撮影領域全体を照らす：

```cpp
const int LED_PINS[] = {9, 10, 11};  // 複数のLEDピン
const int NUM_LEDS = 3;

void triggerWaterDrop() {
  for (int i = 0; i < NUM_LEDS; i++) {
    analogWrite(LED_PINS[i], 255);
  }
  // ...
}
```

### Wi-Fi連携（ESP32使用時）

ESP32を使用する場合、Wi-Fi経由でiPhoneに通知を送ることも可能：

```cpp
#include <WiFi.h>
#include <WiFiUdp.h>

// Wi-Fi設定
const char* ssid = "your-ssid";
const char* password = "your-password";

// UDP設定
WiFiUDP udp;
IPAddress broadcastIP(192, 168, 1, 255);
const int udpPort = 12345;

void triggerWaterDrop() {
  // LED点灯
  digitalWrite(RED_LED_PIN, HIGH);
  
  // UDP送信（バックアップ）
  udp.beginPacket(broadcastIP, udpPort);
  udp.write((const uint8_t*)"TRIGGER", 7);
  udp.endPacket();
  
  // ...
}
```

## 物理的な配置例

```
                    30cm
                     │
                     ↓
    ┌────────────────────────────┐
    │  フォトカプラ（送信・受信） │  ← 水滴検知位置
    └────────────────────────────┘
                     │
                     │ 水滴落下
                     ↓
    ┌────────────────────────────┐
    │                            │
    │     ミルククラウン発生      │  ← 撮影対象
    │                            │
    └────────────────────────────┘
                     ↑
              赤色LED（照明）


    ┌────────────────────────────┐
    │                            │
    │        iPhone              │  ← カメラ
    │                            │
    └────────────────────────────┘
```

## 参考情報

### フォトカプラモジュールの選び方

- **検出距離**: 5-10cm程度のものが使いやすい
- **応答速度**: 1ms以下推奨
- **出力形式**: デジタル出力（HIGH/LOW）
- **推奨モジュール**: TCRT5000、ITR20001/T など

### 赤色LEDの選び方

- **輝度**: 1000mcd以上推奨
- **波長**: 620-630nm（純赤色）
- **視野角**: 広角タイプ推奨
- **推奨LED**: 5mm高輝度赤色LED、またはLEDテープ

## ライセンス

MIT License

## 作者

EasyShareCamera開発チーム
