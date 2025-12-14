#include <Wire.h>
#include <Adafruit_MotorShield.h>
#include "utility/Adafruit_MS_PWMServoDriver.h"

// --- HARDWARE SETUP ---
Adafruit_MotorShield AFMS = Adafruit_MotorShield(); 
Adafruit_DCMotor *motorGripper  = AFMS.getMotor(1); 
Adafruit_DCMotor *motorBase     = AFMS.getMotor(3); 
Adafruit_DCMotor *motorShoulder = AFMS.getMotor(4); 

// --- COMMUNICATION PINS (Method 1) ---
const int PIN_INPUT_READY = 6;  // Reads "High" from Delivery Robot
const int PIN_OUTPUT_BUSY = 7;  // Sends "High" to Delivery Robot

// Analog Sensor Pins 
const int PIN_POT_GRIPPER  = A5; 
const int PIN_POT_BASE     = A3; 
const int PIN_POT_SHOULDER = A4; 

// --- CALIBRATION LIMITS ---
// Base
const int BASE_LEFT  = 400; 
const int BASE_RIGHT = 250; 

// Gripper
const int GRIP_OPEN  = 525;
const int GRIP_CLOSE = 580;

// Shoulder Constants
const int SHOULDER_UP      = 590; 
const int SHOULDER_PICKUP  = 698; 

// --- STACKING LOGIC ---
int stackHeights[] = {695, 679, 657, 632}; 
int currentBlockIndex = 0;
const int MAX_BLOCKS = 4;

// Configuration
const int MOTOR_SPEED = 250;
const int TOLERANCE = 10; 

// --- FUNCTION PROTOTYPES ---
void setGripper(int target);
void setBase(int target);
void setShoulder(int target);
void resetArm();

void setup() {
  Serial.begin(9600);
  Serial.println("System Initializing (Handshake + Stacking)...");

  // Communication Setup
  pinMode(PIN_INPUT_READY, INPUT);
  pinMode(PIN_OUTPUT_BUSY, OUTPUT);
  digitalWrite(PIN_OUTPUT_BUSY, LOW); // Start "Not Busy"

  if (!AFMS.begin()) {
    Serial.println("Could not find Motor Shield. Check wiring.");
    while (1);
  }

  motorGripper->setSpeed(MOTOR_SPEED);
  motorBase->setSpeed(MOTOR_SPEED);
  motorShoulder->setSpeed(MOTOR_SPEED);

  // Initial Reset
  resetArm();
  delay(2000);
}

void loop() {
  Serial.println("\n--- WAITING FOR TRIGGER (Pin 6 or Type 't') ---");

  // 1. HANDSHAKE: WAIT FOR SIGNAL OR USER INPUT
  bool startSequence = false;

  while (!startSequence) {
    // Check Physical Pin
    if (digitalRead(PIN_INPUT_READY) == HIGH) {
      Serial.println(">> Triggered by PIN 6!");
      startSequence = true;
    }

    // Check Serial Monitor
    if (Serial.available() > 0) {
      char incoming = Serial.read();
      if (incoming == 't' || incoming == 'T') {
        Serial.println(">> Triggered by KEYBOARD 't'!");
        startSequence = true;
      }
    }

    delay(50); // Small delay to keep loop stable
  }

  // 2. HANDSHAKE: SET BUSY SIGNAL
  digitalWrite(PIN_OUTPUT_BUSY, HIGH);

  // --- START SEQUENCE ---

  Serial.print("--- PROCESSING BLOCK "); 
  Serial.print(currentBlockIndex + 1);
  Serial.println(" ---");

  setBase(BASE_LEFT);
  delay(500);
  // 3. PICK UP SEQUENCE 
  setShoulder(SHOULDER_PICKUP);
  delay(500);

  setGripper(GRIP_CLOSE);
  delay(500); 

  setShoulder(SHOULDER_UP);
  delay(500);

  // 4. TRANSPORT
  setBase(BASE_RIGHT);
  delay(500);

  // 5. DROP OFF SEQUENCE 
  int currentTarget = stackHeights[currentBlockIndex];
  Serial.print("Dropping at height: "); Serial.println(currentTarget);

  setShoulder(currentTarget);
  delay(500);

  setGripper(GRIP_OPEN);
  delay(500);

  setShoulder(SHOULDER_UP);
  delay(500);

  // 7. UPDATE STACK INDEX
  currentBlockIndex++;

  if (currentBlockIndex >= MAX_BLOCKS) {
    Serial.println("Stack Complete! Restarting stack counter...");
    currentBlockIndex = 0; 
  }

  // 8. HANDSHAKE: CLEAR BUSY SIGNAL
  Serial.println("Sequence Complete. Releasing Delivery Robot.");
  digitalWrite(PIN_OUTPUT_BUSY, LOW);

  // Pause to prevent double triggering
  delay(2000); 
}

// --- MOVEMENT LOGIC ---

void setGripper(int target) {
  int currentVal = analogRead(PIN_POT_GRIPPER);
  Serial.print(">>> MOVING GRIPPER to "); Serial.println(target);

  while (abs(currentVal - target) > TOLERANCE) {
    currentVal = analogRead(PIN_POT_GRIPPER);
    if (currentVal < target) {
      motorGripper->run(FORWARD); 
    } else {
      motorGripper->run(BACKWARD);
    }
    delay(50);
  }
  motorGripper->run(RELEASE);
  Serial.println(">>> Gripper Arrived.");
}

void setBase(int target) {
  int currentVal = analogRead(PIN_POT_BASE);
  Serial.print(">>> MOVING BASE to "); Serial.println(target);

  while (abs(currentVal - target) > TOLERANCE) {
    currentVal = analogRead(PIN_POT_BASE);
    if (currentVal < target) {
      motorBase->run(BACKWARD); 
    } else {
      motorBase->run(FORWARD);
    }
    delay(50); 
  }
  motorBase->run(RELEASE); 
  Serial.println(">>> Base Arrived.");
}

void setShoulder(int target) {
  int currentVal = analogRead(PIN_POT_SHOULDER);
  Serial.print(">>> MOVING SHOULDER to "); Serial.println(target);

  while (abs(currentVal - target) > TOLERANCE) {
    currentVal = analogRead(PIN_POT_SHOULDER);

    Serial.print("Shoulder: "); Serial.print(currentVal);
    Serial.print(" -> "); Serial.println(target);

    if (currentVal < target) {
      motorShoulder->run(BACKWARD); 
    } else {
      motorShoulder->run(FORWARD);
    }
    delay(50);
  }
  motorShoulder->run(RELEASE);
  Serial.println(">>> Shoulder Arrived.");
}

void resetArm() {
  Serial.println("\n*** EXECUTING RESET ***");
  currentBlockIndex = 0;

  setGripper(GRIP_OPEN);
  setShoulder(SHOULDER_UP); 
  setBase(BASE_RIGHT);
}
 