/*
 * Water Drop Trigger System for Milk Crown Photography
 * 
 * フォトカプラで水滴を検知し、赤色LEDと白色LED照明を点灯させて
 * iPhoneのカメラに撮影開始のトリガーを送るシステム
 * 
 * ハードウェア:
 * - Arduino Uno / Nano / ESP32 など
 * - フォトカプラ（水滴検知用）
 * - 赤色LED（高輝度推奨）- トリガー用
 * - 白色LED（高輝度推奨）- 照明用
 * - 抵抗 220Ω x2（LED用）
 * 
 * 接続:
 * - フォトカプラ出力 → D2（INPUT_PULLUP）
 * - 赤色LED → D13（内蔵LED）+ D9（外部LED、PWM）
 * - 白色LED → D10（PWM）
 * 
 * 動作:
 * 1. フォトカプラが水滴を検知（LOW信号）
 * 2. 赤色LEDを点灯（トリガー用）
 * 3. 白色LEDを点灯（撮影照明用）
 * 4. 一定時間後に消灯
 * 5. 次の検知に備える
 */

// ピン定義
const int PHOTOCOUPLER_PIN = 2;      // フォトカプラ入力ピン
const int RED_LED_PIN = 13;          // 赤色LED出力ピン（内蔵LED）
const int EXTERNAL_RED_LED_PIN = 9;  // 外部赤色LED（PWM対応ピン）
const int WHITE_LED_PIN = 10;        // 白色LED（照明用、PWM対応ピン）

// タイミング設定
const unsigned long LED_ON_DURATION = 5000;  // LED点灯時間（5秒）
const unsigned long DEBOUNCE_DELAY = 50;     // チャタリング防止（50ms）
const unsigned long COOLDOWN_TIME = 1000;    // クールダウン時間（1秒）

// LED輝度設定（0-255）
const int RED_LED_BRIGHTNESS = 255;    // 赤色LED輝度（最大）
const int WHITE_LED_BRIGHTNESS = 255;  // 白色LED輝度（最大）

// 状態変数
bool isTriggered = false;
unsigned long triggerTime = 0;
unsigned long lastDebounceTime = 0;
bool lastButtonState = HIGH;
bool buttonState = HIGH;

void setup() {
  // シリアル通信初期化（デバッグ用）
  Serial.begin(115200);
  Serial.println("========================================");
  Serial.println("Water Drop Trigger System v2.0");
  Serial.println("with White LED Lighting");
  Serial.println("========================================");
  Serial.println("Waiting for water drop detection...");
  
  // ピンモード設定
  pinMode(PHOTOCOUPLER_PIN, INPUT_PULLUP);  // プルアップ抵抗を有効化
  pinMode(RED_LED_PIN, OUTPUT);
  pinMode(EXTERNAL_RED_LED_PIN, OUTPUT);
  pinMode(WHITE_LED_PIN, OUTPUT);
  
  // 初期状態：全LED消灯
  digitalWrite(RED_LED_PIN, LOW);
  analogWrite(EXTERNAL_RED_LED_PIN, 0);
  analogWrite(WHITE_LED_PIN, 0);
  
  // 起動確認（LEDを3回点滅）
  Serial.println("System check...");
  for (int i = 0; i < 3; i++) {
    // 赤色LED点滅
    digitalWrite(RED_LED_PIN, HIGH);
    analogWrite(EXTERNAL_RED_LED_PIN, RED_LED_BRIGHTNESS);
    delay(150);
    digitalWrite(RED_LED_PIN, LOW);
    analogWrite(EXTERNAL_RED_LED_PIN, 0);
    delay(150);
    
    // 白色LED点滅
    analogWrite(WHITE_LED_PIN, WHITE_LED_BRIGHTNESS);
    delay(150);
    analogWrite(WHITE_LED_PIN, 0);
    delay(150);
  }
  
  Serial.println("========================================");
  Serial.println("System ready!");
  Serial.println("Red LED: Trigger signal for iPhone");
  Serial.println("White LED: Lighting for 240fps shooting");
  Serial.println("========================================");
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
      turnOffAllLEDs();
      
      // クールダウン時間を待つ
      delay(COOLDOWN_TIME);
      
      // 次の検知に備える
      isTriggered = false;
      Serial.println("----------------------------------------");
      Serial.println("Ready for next detection");
      Serial.println("----------------------------------------");
    }
  }
}

// 水滴検知時の処理
void triggerWaterDrop() {
  isTriggered = true;
  triggerTime = millis();
  
  // 赤色LEDを最大輝度で点灯（トリガー用）
  digitalWrite(RED_LED_PIN, HIGH);
  analogWrite(EXTERNAL_RED_LED_PIN, RED_LED_BRIGHTNESS);
  
  // 白色LEDを最大輝度で点灯（照明用）
  analogWrite(WHITE_LED_PIN, WHITE_LED_BRIGHTNESS);
  
  // シリアル出力
  Serial.println("");
  Serial.println("========================================");
  Serial.println("🔴 WATER DROP DETECTED!");
  Serial.println("========================================");
  Serial.println("✅ Red LED ON   - iPhone trigger signal");
  Serial.println("💡 White LED ON - 240fps lighting");
  Serial.print("⏱️  Timestamp: ");
  Serial.print(millis());
  Serial.println(" ms");
  Serial.println("========================================");
  Serial.println("Recording should start now...");
}

// 全LED消灯
void turnOffAllLEDs() {
  digitalWrite(RED_LED_PIN, LOW);
  analogWrite(EXTERNAL_RED_LED_PIN, 0);
  analogWrite(WHITE_LED_PIN, 0);
  
  Serial.println("");
  Serial.println("🔴 Red LED OFF");
  Serial.println("💡 White LED OFF");
  Serial.println("Recording should be completed");
}
