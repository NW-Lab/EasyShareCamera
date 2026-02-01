/*
 * Water Drop Trigger System for Milk Crown Photography
 * 
 * フォトカプラで水滴を検知し、赤色LEDを点灯させて
 * iPhoneのカメラに撮影開始のトリガーを送るシステム
 * 
 * ハードウェア:
 * - Arduino Uno / Nano / ESP32 など
 * - フォトカプラ（水滴検知用）
 * - 赤色LED（高輝度推奨）
 * - 抵抗 220Ω（LED用）
 * 
 * 接続:
 * - フォトカプラ出力 → D2（INPUT_PULLUP）
 * - 赤色LED → D13（内蔵LEDと並列可）
 * 
 * 動作:
 * 1. フォトカプラが水滴を検知（LOW信号）
 * 2. 赤色LEDを点灯
 * 3. 一定時間後に消灯
 * 4. 次の検知に備える
 */

// ピン定義
const int PHOTOCOUPLER_PIN = 2;   // フォトカプラ入力ピン
const int RED_LED_PIN = 13;       // 赤色LED出力ピン（内蔵LED）
const int EXTERNAL_LED_PIN = 9;   // 外部赤色LED（PWM対応ピン）

// タイミング設定
const unsigned long LED_ON_DURATION = 5000;  // LED点灯時間（5秒）
const unsigned long DEBOUNCE_DELAY = 50;     // チャタリング防止（50ms）
const unsigned long COOLDOWN_TIME = 1000;    // クールダウン時間（1秒）

// 状態変数
bool isTriggered = false;
unsigned long triggerTime = 0;
unsigned long lastDebounceTime = 0;
bool lastButtonState = HIGH;
bool buttonState = HIGH;

void setup() {
  // シリアル通信初期化（デバッグ用）
  Serial.begin(115200);
  Serial.println("Water Drop Trigger System");
  Serial.println("Waiting for water drop detection...");
  
  // ピンモード設定
  pinMode(PHOTOCOUPLER_PIN, INPUT_PULLUP);  // プルアップ抵抗を有効化
  pinMode(RED_LED_PIN, OUTPUT);
  pinMode(EXTERNAL_LED_PIN, OUTPUT);
  
  // 初期状態：LED消灯
  digitalWrite(RED_LED_PIN, LOW);
  analogWrite(EXTERNAL_LED_PIN, 0);
  
  // 起動確認（LEDを3回点滅）
  for (int i = 0; i < 3; i++) {
    digitalWrite(RED_LED_PIN, HIGH);
    analogWrite(EXTERNAL_LED_PIN, 255);
    delay(200);
    digitalWrite(RED_LED_PIN, LOW);
    analogWrite(EXTERNAL_LED_PIN, 0);
    delay(200);
  }
  
  Serial.println("System ready!");
}

void loop() {
  // フォトカプラの状態を読み取り
  int reading = digitalRead(PHOTOCOUPLER_PIN);
  
  // チャタリング防止
  if (reading != lastButtonState) {
    lastDebounceTime = millis();
  }
  
  if ((millis() - lastDebounceTime) > DEBOUNCE_DELAY) {
    if (reading != buttonState) {
      buttonState = reading;
      
      // フォトカプラがLOW（水滴検知）かつトリガー未発動の場合
      if (buttonState == LOW && !isTriggered) {
        triggerWaterDrop();
      }
    }
  }
  
  lastButtonState = reading;
  
  // トリガー後の処理
  if (isTriggered) {
    unsigned long elapsed = millis() - triggerTime;
    
    // LED点灯時間が経過したら消灯
    if (elapsed >= LED_ON_DURATION) {
      turnOffLED();
      
      // クールダウン時間を待つ
      delay(COOLDOWN_TIME);
      
      // 次の検知に備える
      isTriggered = false;
      Serial.println("Ready for next detection");
    }
  }
}

// 水滴検知時の処理
void triggerWaterDrop() {
  isTriggered = true;
  triggerTime = millis();
  
  // 赤色LEDを最大輝度で点灯
  digitalWrite(RED_LED_PIN, HIGH);
  analogWrite(EXTERNAL_LED_PIN, 255);
  
  // シリアル出力
  Serial.println("=================================");
  Serial.println("WATER DROP DETECTED!");
  Serial.println("Red LED ON - iPhone should start recording");
  Serial.print("Timestamp: ");
  Serial.println(millis());
  Serial.println("=================================");
}

// LED消灯
void turnOffLED() {
  digitalWrite(RED_LED_PIN, LOW);
  analogWrite(EXTERNAL_LED_PIN, 0);
  
  Serial.println("Red LED OFF");
}
