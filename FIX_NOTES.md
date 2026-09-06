# ESP32-CAM Robot motor crash + network fixes

## Motor-start crash fix (Guru Meditation / Double exception)

This revision removes the unsafe motor-start path that could crash immediately
after `Command: FORWARD`.

- Keep the ESP32 brownout detector enabled; the firmware no longer disables it.
- Replace the 255-duty startup kick with a six-step PWM soft start that never
  exceeds the requested speed or configured speed ceiling.
- Stagger simultaneous left/right starts by about 24 ms to reduce the shared
  supply current step.
- Give all four TB6612 direction inputs fixed LEDC channels instead of
  relying on runtime `analogWrite()` allocation: right motor 10-11, left motor
  12-13. Camera channel 0 and flash channel 7 remain separate.

  Channels 8-11 were **not** separate, which was the real motor-start crash.
  The Arduino core fixes group and timer per channel (`group = chan / 8`,
  `timer = (chan / 2) % 4`), so channels 8 and 9 -- the left motor -- sat on
  low-speed timer 0, and `esp_camera_init()` reprograms exactly that timer to
  20 MHz at 1-bit duty resolution for XCLK. From the first camera init onward,
  `ledcWrite()` on the left motor kept succeeding while every non-zero duty
  saturated a 1-bit comparator and held the pin HIGH. The soft start ramped
  through values that were all already full scale, so the left motor took an
  instantaneous full-current step on every command and browned the board out
  (`rst:0xc`, no backtrace, sometimes knocking the OV2640 off the SCCB bus
  first). The right motor on timer 1 was untouched and never once misbehaved
  -- that asymmetry is the signature. Changing the left speed setting did
  nothing, because 71 and 146 saturate one bit identically.

  `static_assert`s now fail the build if any motor or flash channel lands on
  the camera's timer, and `verifyMotorLedcTimers()` reads the timer frequency
  back after every `esp_camera_init()` -- at boot and after each in-place
  sensor recovery -- logging what it found and stopping the motors and
  reprogramming if a future core or camera version moves a timer anyway.
- Serialize motor LEDC writes with a FreeRTOS mutex so HTTP commands, the motion
  timeout, and OTA shutdown cannot interleave bridge states across CPU cores.
- Pull the shared PWMA/PWMB GPIO12 enable LOW whenever the robot is stopped.
- Fail safe with the bridge disabled if motor LEDC setup or mutex allocation
  fails.
- Add `esp32cam-debug` plus launcher option `d` for a symbol-rich debug
  build/flash/monitor workflow.
- Correct launcher and documentation references from `m1` to `m2`.

Hardware still matters: if a debug build reports a clean `Brownout detector was
triggered` reset when the motors start, improve the 5 V supply, grounding and
decoupling rather than disabling brownout protection.

## Network fallback fix

This version addresses the fallback-AP symptom where `192.168.4.1` answers
`ping` but TCP port 80 times out.

## Changes

- Stop the timed-out STA association before starting the fallback AP.
- Do **not** immediately call `WiFi.begin()` again when fallback AP comes up.
  Normal-Wi-Fi retries are left to `serviceWiFiFallback()`, which already
  pauses retries while an AP client is connected.
- Check and log the return value from `httpd_start()` for port 80 and port 81.
- Only print `BOOT: Robot web server ready` when the control HTTP server really
  started and all control routes registered.
- Log route-registration failures and free heap for HTTP startup diagnostics.
- Reduce HTTP socket allowances so the control UI keeps priority over MJPEG.
- Regenerate `index_html_gz.h`; the UI is now served as ~34 KB gzip instead of
  the stale ~149 KB uncompressed fallback.

## Expected serial lines after flashing

```
BOOT: Fallback AP started; SSID ESP32-Robot-XXXX
BOOT: Fallback AP IP 192.168.4.1
BOOT: UI served gzipped; 34477 bytes instead of 148713
BOOT: Starting HTTP and camera-stream servers
HTTP: control server listening on port 80; free heap ...
HTTP: stream server listening on port 81; free heap ...
BOOT: Robot web server ready
```

Then connect to the fallback SSID and test:

```
curl -v --connect-timeout 3 http://192.168.4.1/
```

If port 80 still cannot start, the serial console now prints the exact ESP-IDF
error code and free heap instead of falsely reporting the server as ready.
