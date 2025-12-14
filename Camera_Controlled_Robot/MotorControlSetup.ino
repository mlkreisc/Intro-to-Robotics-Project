/*
  ManualPulseControl_dbg.ino (tuned)
  Debug pulse-jog controller for Motor Carrier (tuned for less aggressive corrections).
  Commands:
    q / a : Motor 1 (Base)   + / -
    w / s : Motor 2 (Elbow)  + / -
    e / d : Motor 3 (gripper)  close / open
    r / f : Motor 4 (Shoulder) + / -
    x     : stop all motors immediately
*/

#include <ArduinoMotorCarrier.h>

// TUNED: reduce base duty to make each correction smaller (elbow kept at 60)
const int DUTY_M1 = 50; // base duty (reduced from 60)
const int DUTY_M2 = 60; // shoulder/elbow (keep >= 60 if that's your measured min)
const int DUTY_M3 = 60; // wrist
const int DUTY_M4 = 40; // gripper

// TUNED: shorten pulse duration so each jog is smaller
const unsigned long PULSE_MS_M1 = 50;
const unsigned long PULSE_MS_M2 = 50;
const unsigned long PULSE_MS_M3 = 100;
const unsigned long PULSE_MS_M4 = 50;

void allStop() {
  M1.setDuty(0);
  M2.setDuty(0);
  M3.setDuty(0);
  M4.setDuty(0);
}

void pulseMotor(int motor, int duty, unsigned long ms) {
  // set duty (signed)
  switch (motor) {
    case 1: M1.setDuty(duty); break;
    case 2: M2.setDuty(duty); break;
    case 3: M3.setDuty(duty); break;
    case 4: M4.setDuty(duty); break;
  }
  unsigned long t0 = millis();
  while (millis() - t0 < ms) {
    // if an emergency 'x' arrives, break out
    if (Serial.available()) {
      char c = Serial.read();
      if (c == 'x' || c == 'X') {
        allStop();
        return;
      }
    }
    delay(1);
  }
  // stop
  switch (motor) {
    case 1: M1.setDuty(0); break;
    case 2: M2.setDuty(0); break;
    case 3: M3.setDuty(0); break;
    case 4: M4.setDuty(0); break;
  }
}

void setup() {
  Serial.begin(115200);
  while (!Serial && (millis() < 2000)) { /*wait a moment*/ }
  if (!controller.begin()) {
    Serial.println("Motor Carrier not found.");
    while (1) { delay(200); }
  }
  controller.reboot();
  delay(300);
  allStop();
  Serial.println("ManualPulseControl_dbg ready. Commands: q/a w/s e/d r/f x");
}

void loop() {
  if (Serial.available()) {
    char c = Serial.read();
    // Echo (for debugging)
    Serial.print("CMD:");
    Serial.println(c);

    switch (c) {
      case 'q': pulseMotor(1, +DUTY_M1, PULSE_MS_M1); break;
      case 'a': pulseMotor(1, -DUTY_M1, PULSE_MS_M1); break;
      case 'w': pulseMotor(2, +DUTY_M2, PULSE_MS_M2); break;
      case 's': pulseMotor(2, -DUTY_M2, PULSE_MS_M2); break;
      case 'e': pulseMotor(3, +DUTY_M3, PULSE_MS_M3); break;
      case 'd': pulseMotor(3, -DUTY_M3, PULSE_MS_M3); break;
      case 'r': pulseMotor(4, +DUTY_M4, PULSE_MS_M4); break;
      case 'f': pulseMotor(4, -DUTY_M4, PULSE_MS_M4); break;
      case 'x':
      case 'X':
        allStop();
        Serial.println("STOP");
        break;
      default:
        Serial.print("Unknown:");
        Serial.println(c);
        break;
    }
  }
}