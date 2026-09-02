# ESP32-CAM Robot network fix

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
