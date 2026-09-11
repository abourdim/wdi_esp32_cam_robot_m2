# ESP32-CAM Robot

A Wi-Fi controlled ESP32-CAM robot with live camera streaming, independent motor PWM control, synchronized motor experiments, camera settings, Wi-Fi fallback AP mode, browser OTA firmware updates, debug/event logging, log export, and a UART0 USB serial console.

Since **v2.0** it also has a **Games** view, where the camera stops being a camera and becomes the robot's only sensor: it follows a torch, follows a line of tape, follows a coloured card, and measures how fast it turns by watching the picture slide past. Covering the lens with a hand stops it.

## Current feature set

### Motor control

- Motor driver: **TB6612FNG / SparkFun ROB-14450**
- **GPIO12 → PWMA + PWMB** (the two PWM inputs are tied together in the schematic)
- **GPIO2 → AIN1**, **GPIO13 → AIN2**
- **GPIO15 → BIN1**, **GPIO14 → BIN2**
- **STBY → +5V** (hard-wired enabled)
- Motor A / J6 is treated as **left**; Motor B / J7 as **right**
- Full PWM range for each motor: **0 to 255**
- A single **Speed** control on the drive screen, which moves both motors together and keeps whatever difference is set in Settings
- Independent left/right speed sliders, in **Settings -> Robot -> Motor trim**
- Exact **-1 / +1** PWM buttons, beside those sliders
- **Sync motors** checkbox, also in Motor trim:
  - When enabled, changing either motor changes both motors to the same PWM value.
  - Enabling Sync uses the current left motor value as the initial reference.
  - The drive screen does not need it: one Speed control moves both by design.
- **Wheel direction** flags, one per wheel, for a chassis wired with a motor's leads the other way round
- Gentle PWM soft start that ramps only to the requested motor PWM.
- Forward, left, right, and stop controls.
- The PCB uses a TB6612FNG H-bridge, and the browser controls are forward, backward, left, right, and stop. Reverse drives the opposite direction input; the wheels are always brought to a stop before crossing between forward and reverse.

### Wheel direction

Chassis are assembled by hand, and some come back with a motor's leads the
other way round. That wheel then runs backwards for the same H-bridge inputs:
forward and backward swap, and so do left and right, because the turn commands
share the forward polarity.

**Settings -> Robot -> Wheel direction** has a checkbox per wheel. Lift the
wheels off the table, press forward, and tick whichever wheel turns the wrong
way. The flags are stored on the robot and reported in `/status`, so the fix
follows the robot rather than the browser that made it.

The correction is applied in one place -- the only function that knows left
from right -- so the soft start, the direction-change pause, the motion
timeout and replay all stay unaware that any wheel is inverted. Changing a
flag stops the robot first, because it is a direction reversal like any other.

### Hold to drive, and the motion timeout

The direction buttons drive only while they are held. Because every command is
a plain fire-and-forget request, any single one of them can be lost -- and the
one that matters is the **stop**. A dropped stop used to leave a wheel turning
until some later command happened to get through.

So the robot no longer relies on hearing the stop:

- A held button **repeats its command every 250 ms**.
- If the robot hears no motion command for **600 ms**, it stops the motors
  itself and logs `SAFETY: motion timeout; motors stopped`.
- The release sends stop **twice**, 150 ms apart.
- Losing window focus, hiding the tab, or leaving the page also stops.

A lost packet, a closed laptop, a browser that never reported the release, or
a robot that drives out of Wi-Fi range now all end the same way: the motors
stop within about half a second.

Keepalive repeats are not written to the event log -- several entries a second
would bury everything else -- so a held button still shows as one command.

At very low PWM values a motor may buzz without turning. This is useful for experiments because students can identify each motor's real starting threshold. Do not leave a stalled motor powered for long periods.

## Motor power hardware

The schematic uses a **TB6612FNG** dual H-bridge module (SparkFun ROB-14450). Its two PWM-enable inputs, PWMA and PWMB, are both connected to **GPIO12**. To retain independent left/right speed control without changing the PCB, firmware holds GPIO12 high and PWM-modulates one direction input per motor:

- Motor A / J6 (left): AIN1 = GPIO2 (PWM), AIN2 = GPIO13 (low for forward)
- Motor B / J7 (right): BIN1 = GPIO15 (PWM), BIN2 = GPIO14 (low for forward)
- PWMA + PWMB: GPIO12 high while moving, low while stopped
- STBY: tied to +5V

The TB6612FNG is bidirectional hardware, and both directions are used: forward puts PWM on IN1 and holds IN2 idle, reverse does the opposite. All four direction pins use fixed low-speed LEDC channels: the right motor on 10-11 and the left motor on 12-13. The channel number is not free choice -- the Arduino core derives the group and timer from it as `group = chan / 8` and `timer = (chan / 2) % 4`, and `esp_camera_init()` reprograms low-speed timer 0 to 20 MHz at 1-bit resolution for XCLK. Channels 8 and 9 land on that timer, so the left motor used to lose its 8-bit duty resolution the moment the camera came up: every non-zero `ledcWrite()` saturated and pinned the pin HIGH, defeating the soft start and browning the board out on the first left-motor command. `static_assert`s on the channel numbers and a `verifyMotorLedcTimers()` read-back after every camera init now hold that line.

## Camera

The ESP32-CAM serves an MJPEG stream on port **81**.

### Overlays on the video

**Bottom left** -- the workshop-diy.org mark, held at 30% opacity. A
watermark, not a readout. On a narrow frame the wordmark drops and the logo
stays.

**Bottom right** -- three readouts: frame rate, signal strength, and what the
robot thinks its motors are doing. Also 30% **at rest**, but they come up to
full the moment one of them matters:

- the robot is moving (`RIGHT 220/0`, blue)
- the signal is at or below -75 dBm (amber) -- the earliest honest warning
  that you are driving out of range, since the video outlasts the commands
- the dead man's switch has just fired (`TIMEOUT`, red, three seconds)

That last one is the point of the whole row: the motion timeout used to stop
the robot and explain itself only in an event log nobody reads mid-drive.

The frame rate is measured on the robot, because a browser reports a multipart
image as loaded once, on the first frame, and cannot count them. Signal is the
station RSSI in normal Wi-Fi, and on the fallback AP it is how well the robot
hears *your* device -- the number that actually matters there. Motion is drawn
the instant you press or release a button and then corrected by the robot's
own view, which is exactly how a lost command becomes visible.

All of it rides the stream health check that already runs every three seconds.
No extra requests.

**Top left** -- the stream status, when there is something to say. It is never
dimmed; it is the one overlay that is asking you to do something.

These are page elements beside the image, not pixels in it. So they stay
upright at every display rotation, because rotation transforms the image
alone, and anything that saves or records the stream directly gets clean
frames. Burning a watermark into the video would mean decoding, drawing and
re-encoding every frame on the ESP32, which would cost far more frame rate
than the mark is worth.

### Header

A sticky bar across the top: the logo, the robot name, and `workshop-diy.org`
with the running firmware's build stamp beside it. On the right, three pills --
**Settings**, **Debug**, and a link indicator that reads `Live` (green),
`No video` (amber) or `Offline` (red, pulsing) from the same health check.

The sidebar toggles used to float in the top corners, on top of the video. The
header sits above the sidebars deliberately, so the pill that opened one is
still there to close it. On narrow screens the two toggle labels drop to
icons; the link pill keeps its text.

The logo is defined once as an SVG `symbol` and referenced by both the header
and the watermark. Two inline copies would cost 3.5 KB twice.

### Video stream behavior

- Defaults are **VGA at JPEG quality 12** with two frame buffers when PSRAM is
  present, and **QVGA** when it is not. Quality 12 rather than 10 because the
  Wi-Fi link, not the sensor, sets the frame rate.
- The camera always hands over its **newest** frame. Queued frames would arrive
  a capture late, which looks like lag even when the frame rate is fine.
- Wi-Fi modem sleep is switched off. Left on, the radio parks between beacons
  and the picture stutters.
- **One viewer at a time.** A second browser is told the stream is in use
  rather than being left with a picture that never arrives.
- The page **reconnects on its own**. If the stream drops or simply stops --
  a failed capture and a reboot both end it without any error the browser can
  see -- the page notices within a few seconds and re-opens it. A short message
  in the corner of the video says what is happening.
- The stream **pauses while its browser tab is hidden**, so a forgotten tab
  does not hold the single viewer slot or spend radio time on frames nobody is
  watching. It resumes when the tab comes back.
- The debug sidebar shows the frame rate the robot is actually sending, and
  how many streams have ended since boot. A viewer coming and going is normal;
  a count that climbs on its own is a link that keeps dropping.
- Opening a stream is not logged. A stream that ends is, once, with how long
  it lasted -- a browser that keeps reconnecting would otherwise fill the
  64-event history with pairs of lines and push out whatever caused it.

The Settings sidebar provides:

- Resolution:
  - QQVGA 160x120
  - QVGA 320x240
  - VGA 640x480
  - SVGA 800x600
  - XGA 1024x768
  - SXGA 1280x1024
  - UXGA 1600x1200
- Display rotation:
  - 0 degrees
  - 90 degrees clockwise
  - 180 degrees
  - 270 degrees clockwise
- JPEG quality
- Brightness
- Contrast
- Saturation
- Vertical flip
- Horizontal mirror
- Reset camera defaults

High resolutions require PSRAM.

### Rotation behavior

Vertical flip and horizontal mirror are sensor settings. They are applied by the camera.

The 0/90/180/270 **Display rotation** setting rotates the stream in the browser. This avoids expensive real-time JPEG decoding, rotation, and re-encoding on the ESP32.

The selected rotation is stored in the browser with `localStorage`, so it is remembered by that browser.

## Web user interface

The video sits at the top. Under it are three views, chosen in the header:
**Drive**, **Program** and **Games**. The video stays above all three, so a
program or a game can be watched while it runs.

### Drive

In order down the screen: the four arrows with **STOP** in the middle of them,
one **Speed** control, and **Light**.

The layout is deliberate. The control a child uses every second sits directly
under the thing they have to watch, so on a phone the picture and the arrows
are on screen together and driving never means scrolling. STOP is in the
centre of the pad, where a thumb already is and reachable from any arrow, with
the pad's gap widened so that reaching for it and missing lands on background
rather than on a direction. Releasing an arrow stops the robot anyway -- STOP
is the backup, not the only way.

**Speed** moves both motors and preserves the trim set in Settings. Its
ceiling is the speed limit minus that trim, so the faster wheel lands exactly
on the limit instead of being quietly clipped.

**Light** switches the flash LED. Its brightness lives in Settings -> Camera,
so turning the light on with brightness at zero would be a control that
visibly does nothing: the page says so instead, and the notice clears as soon
as either half of that changes.

The page also has two collapsible sidebars.

### Left sidebar: Settings

Three collapsible sections. Camera is open on arrival; the other two stay shut
until you want them.

**Camera** -- the camera controls listed above.

**Robot** -- everything that differs from robot to robot: name, speed limit,
wheel direction, motor trim (the Sync checkbox and the two per-motor sliders),
and the measured wake-up numbers. It matches what the robot stores in NVS.

**Wi-Fi** -- scan for networks and join one.

**USB Serial console**

- Serial baud selector
- Select port / Connect / Disconnect
- Live UART capture terminal
- Auto-scroll
- Clear capture
- Save capture
- Command entry

**Firmware update (OTA)**

- Firmware build date/time of the running firmware
- OTA password
- Firmware .bin picker
- Upload, with a progress bar

The split is by what you are doing: Settings is what you change on the robot,
Debug is what you watch while driving it. The build stamp sits in the OTA card
because it is what tells you an upload actually took -- upload, wait for the
reboot, check the date changed.

### Right sidebar: Robot Debug

Shows:

- Motion state
- Left/right target PWM
- Left/right current output PWM
- Network mode
- Station status
- SSID
- Robot IP
- AP clients
- Wi-Fi RSSI
- Uptime
- Stream frame rate, or "no viewer"
- Latest debug message
- 64-event retained event history
- Export debug log
- Clear debug log

Newest debug events are shown at the top.

## Record and replay

The header has two views of the same column, **Drive** and **Program**. The
video stays above both, so a program can be watched while it runs.

Press **Record**, drive the robot by hand, press **Stop**. What you did is now
a list of instructions in the Program view:

```
1   0.0s   Forward
2   1.4s   Stop
3   0.6s   Right
4   0.5s   Stop
```

Press **Play** and the robot does it again. Change a pause, delete a line,
play it again -- that is the whole point. A child drives first and reads their
own program second, which is a gentler route into programming than starting
from an empty editor.

Three slots keep programs **on the robot**, not in the browser, so a program
follows the robot round the classroom rather than the tablet that recorded it.
The robot does not replay on its own yet -- a browser still has to press Play.

### How it works, and why it is safe

Every command the page sends already passes through the same three functions,
so a recording is just those calls with the pause before each one written
down. Playback calls the same functions -- which means a replayed drive sends
the same 250 ms keepalives a held button does, and is governed by the same
600 ms motion timeout. A program cannot drive the robot in a way a child
could not.

It stops on **Stop**, on leaving the page, on switching tabs, and on the
window losing focus. A replay that is interrupted always sends a stop.

Repeats are not recorded as steps: a held button repeats itself four times a
second and a dragged slider fires continuously, and neither is a new
instruction.

## Games

Four activities in which the camera is the robot's sensor rather than a
picture for a person. One at a time, chosen with the Torch / Turn / Line /
Card buttons, because only one may drive the robot.

While a game runs, the strip of picture it is reading is drawn **on the
video**, over the pixels it came from, with the readout in the telemetry line.
That is the point of the games rather than a debug aid: a child can see what
the robot is deciding from, so "why did it turn there?" is answered by
looking.

Every game sends its commands the same way a held button does, at the same
250 ms cadence and under the same 600 ms motion timeout. A game cannot ask the
robot for anything a finger could not. Each stops on its own button, on
switching game, on leaving the Games view, on the window losing focus and on
the tab being hidden -- always sending a stop on the way out.

Frames come from `/capture` on port 80, not the stream on port 81. The stream
is a different origin, and drawing it into a canvas taints the canvas so the
pixels cannot be read back.

### A hand over the lens stops the robot

Whichever game is running. Telling a covered lens from an unlit room needs
three things at once: the frame is dark, it is flat -- a covering leaves no
highlight anywhere -- and it is a *change* from a lit picture, because
starting in the dark is not somebody covering anything. It reads the whole
frame rather than the band the game is sampling, since a dim room nearly
always has a window or a lamp somewhere in view.

Two frames must agree, so one bad grab cannot stop a robot mid-game, and it
will not fire again until the lens has seen daylight. It does not resume by
itself: press Start again.

### Follow the torch

Reads a strip across the middle of the picture, averages the brightness of
each half, and turns towards the brighter one. Dim the room, shine a phone
torch, walk backwards. If it drives away from the torch the picture is
mirrored -- turn off Mirror in Settings, or check Wheel direction.

### How fast does it turn?

The robot spins itself for two seconds each way and measures how far the
picture slid, frame against frame, converting columns per second into degrees
per second through the lens's field of view. Each run adds a row: requested
speed, left, right, and the gap between them.

The gap is the lesson. The two numbers should match and will not, because the
motors are not identical -- the same truth the wake-up numbers teach, with the
robot measuring itself this time. Below a wheel's threshold the picture does
not move at all and the answer is zero.

It measures turning and not forward speed, and that is a limit of the optics
rather than an omission. Driving forward makes the picture expand from the
centre instead of sliding, and how fast it expands depends on how far away the
furniture is. Metres per second would need the camera pointed at the floor, or
one calibration drive over a known distance. The degrees are worked out from a
catalogue figure for the lens, so they are comparable between wheels rather
than laboratory-accurate.

### Follow the line

Dark tape on a pale floor. It reads a strip along the bottom of the picture --
the floor just in front of the wheels -- finds the darkest part, and steers to
keep it centred. A checkbox handles a pale line on a dark floor, which is the
same problem upside down.

The threshold is relative to the darkest and brightest column in that strip
rather than a fixed number, so a grey floor in a dim room works as well as
white paper under a lamp, and the line's position is the centre of mass of the
dark part weighted by darkness, so fat tape and thin tape both report their
middle.

It stops rather than guessing, and says which of four things it hit: too dark
to see the floor, nothing that looks like tape, a dark patch too wide to be a
line, or more than one patch and no way to tell which was meant. That last one
matters more than it sounds: it looks for a single connected run of dark
columns, because a lens vignette darkens both edges and averages to dead
centre -- a confident wrong answer a child cannot debug.

Turn the Speed down first. Fast is how a line follower loses the corner.

### Follow the card

Show the robot a brightly coloured card, then hold it to one side and it turns
that way.

It is a card and not a hand on purpose. Recognising a hand needs a model this
page cannot load -- it is served from the robot, with no internet -- and the
shortcut people reach for instead, testing pixels for skin colour, works for
some children and not others. A card works for everyone, and a child can
disprove "it follows my hand" by hiding the card and waving.

**Show it the card** learns the colour rather than assuming one, so any card
the room has will do. It learns the median column of the middle of the view,
not the average: a card never fills that window exactly, and averaging blends
the floor in, producing a colour that matches neither. Colours are compared as
chromaticity -- each channel over the sum of the three -- so the match
survives the card moving into shade. A white or grey card is refused, because
there is nothing in it to find later.

Expect to re-learn the card during a session: the camera adjusts its own
colours as the room changes, and the card drifts with them. At four decisions
a second it answers a moment after you move, so it works better held still to
one side than waved like a steering wheel.

## Photos

**Photo** on the strip under the video grabs a single frame from `/capture`
and adds it to **Photos**, where each one has a Save button. They live in the
browser for the session only; saving is how one is kept. A few VGA stills
would be most of a browser's storage quota, so they are deliberately not
persisted.

`/capture` is served by the control server on port 80, so it answers while the
stream server on 81 is busy, and it returns whatever the camera is seeing at
that moment.

## Find the wake-up number

Settings -> Robot -> **Measure them** starts a guided activity. It powers one
wheel at a time, starting at 20 out of 255 and stepping up by 5, and asks
whether the wheel is turning. When the child says it is, that number is the
motor's starting threshold, and it is saved on the robot.

The two motors will disagree, often by 20 or 30. That difference is the lesson:
identical parts are not identical, and it is why the robot pulls to one side.

The activity reuses the existing steering commands to run one wheel at a time:
testing the left wheel uses the right-turn command, and testing the right wheel
uses the left-turn command. The activity hides that detail. It also restores
the driving speeds it found when it started, so a class does not end up
wondering why the robot got slow.

## Robot name and speed limit

Settings -> Robot:

- **Name** -- shown in the header and the browser tab, and used for photo and
  log filenames. Stored on the robot, so every browser sees the same name.
- **Speed limit** -- a ceiling on motor PWM, enforced in the firmware rather
  than the browser, so it holds however the command arrives. The soft-start
  ramp never exceeds the requested value or this ceiling. Anything already
  above a new ceiling is brought down to it immediately.
- **Wheel direction** -- one checkbox per wheel, for a chassis wired the other
  way round. See Wheel direction above.
- **Motor trim** -- the Sync checkbox and the two per-motor sliders. This is
  calibration, done once per robot; the drive screen's Speed control slides
  both together and keeps whatever difference is set here.

## Saved settings

Settings are split by who owns them.

### On the robot, in flash

Camera resolution, JPEG quality, brightness, contrast, saturation, flip and
mirror; motor speeds; the two wheel-direction flags; LED brightness and
on/off. These describe the robot, not your browser, so they live in NVS and
come back after a power cycle.

Putting them in the browser instead would break in two ways: a phone and a
laptop would restore two different sets of values and overwrite each other,
and a robot rebooted without the right browser open would come back on
firmware defaults.

Writes are **held for four seconds after the last change**. The camera and
motor controls send on every slider movement, and committing to flash at that
rate would be hundreds of writes for one drag.

A resolution saved on a board with PSRAM is not restored onto a board without
it; the allocation would fail and take the stream with it.

### In the browser, in localStorage

Display rotation, serial baud, terminal auto-scroll, which Settings sections
are open, and which view and which game were last chosen. Per-viewer
preferences the robot has no opinion about.

The section state is saved when you click a section header, not when the
`<details>` element toggles. Browsers reinstate `<details>` state from session
history after the page loads, and saving on the toggle event would record the
browser's restoration instead of your choice.

### Never saved

The OTA password.

### The page no longer overwrites the robot

The page used to send its own slider defaults to the robot on every load, so
opening a second tab reset the motor speeds and the LED under whoever was
driving. It now reads all three from the robot and adopts them, and never
overwrites a control you have already touched in that session.

## Editing the web UI

The whole browser UI is one raw string literal, `INDEX_HTML`, inside
`wdi_esp32_cam_robot_m2.ino`, so the sketch still opens in the Arduino IDE with
no extra steps.

That literal is about 70 KB, and it travels over the same Wi-Fi link as the
video. The firmware therefore serves a gzipped copy of it -- about 15 KB --
which is generated into `index_html_gz.h` by:

```bash
python tools/gzip_ui.py
```

Run that after changing the HTML, CSS, or JavaScript, and commit the generated
header alongside the sketch.

If you forget, nothing breaks: the firmware compares the length and hash of the
literal it was built with against the ones recorded in the header, and falls
back to serving the page uncompressed. The debug log says so at boot:

`WARN: UI gzip asset is stale; serving N bytes uncompressed. Re-run tools/gzip_ui.py`

## UART0 / USB serial console

ESP32-CAM UART0:

- Baud: **115200**
- Data bits: 8
- Parity: none
- Stop bits: 1

### Wiring

| ESP32-CAM | USB-TTL adapter |
|---|---|
| U0T / GPIO1 | RX |
| U0R / GPIO3 | TX |
| GND | GND |

Use a **3.3V TTL-compatible** serial adapter. Do not connect RS-232 voltage levels directly to the ESP32.

The console accepts:

- `help`
- `status`
- `log`
- `camera`
- `stop`

`stop` performs an emergency motor stop.

### Browser Web Serial limitation

Chrome/Edge Web Serial requires a secure context. A page opened directly from:

`http://192.168.x.x`

is normally not considered a secure context, so direct COM-port access may be blocked even though the robot UI itself works.

A standalone helper is included:

`ESP32_Robot_USB_Serial_Console.html`

For reliable Web Serial access, serve it from localhost:

```bash
python -m http.server 8000
```

Then open:

`http://localhost:8000/ESP32_Robot_USB_Serial_Console.html`

in Chrome or Edge.

## Choosing a network

The credentials in the sketch are only defaults, used the first time. A network
picked in **Settings -> Wi-Fi** is stored on the robot, so moving it between a
workshop and a classroom no longer means reflashing it.

1. Connect to the robot's fallback AP and open `192.168.4.1`.
2. Settings -> Wi-Fi -> **Scan for networks**.
3. Pick one from the list, type the password, **Save and connect**.
4. The page watches for the outcome and reports the new address.

The access point stays up throughout, including while the attempt is running
and after it fails, so it is not possible to lock yourself out of the robot
from the robot's own interface.

Some things worth knowing:

- **A scan disturbs the video.** The scan and the access point share one
  radio. That is why scanning is a button and never something on a timer, and
  why the robot **refuses to scan while it is moving** -- a scan blocks the
  control server for several seconds, which would starve the motion keepalive
  and trip the safety timeout mid-manoeuvre.
- **Joining a network may drop you briefly**, because it moves the radio to
  that network's channel.
- **The password is stored in plain text** and travels over the AP link. The
  AP is WPA2, but its passphrase is in this readme. Treat this as convenience,
  not security.
- The attempt runs from the main loop rather than inside the request, because
  the reply has to leave before the radio moves.

## What the LED is telling you

GPIO4 is the module's flash LED, and it is the robot's only indicator. Every
status pattern runs at a few percent of full scale -- it is painful to look at
near full brightness, and this is a high-power LED on a board that browns out
easily.

The patterns differ by **rhythm** rather than by count. Nobody reliably counts
blinks across a room; everybody notices fast against slow.

| What you see | What it means |
| --- | --- |
| Three short flashes, immediately on power-up | The CPU is running. If these appear, the board booted and anything that goes wrong next is software. |
| A fast blip, four times a second | Trying the configured Wi-Fi. This is the ten-second window, and the blip is the dot the serial console prints, for somebody without a cable. |
| Two long marks | Joined the configured network. |
| Long, short, long | The configured network was unavailable, so the fallback access point is up. This is the normal case in a workshop, not a fault. |
| Short flashes in groups, after the two long marks | The last group of the address it was given, one digit at a time: 137 is one flash, three flashes, seven flashes. Zero is a single long mark. Set `LED_ANNOUNCE_IP` to false to switch it off. |
| One dim pulse a second | Running, joined to the configured network. |
| One dim pulse every five seconds | Running on the fallback access point, or still unjoined. |
| A glow that gets steadily brighter | Firmware is being written. **Do not cut the power.** It rises with the upload and is a glow rather than a blink so it cannot be mistaken for anything above. |

The heartbeat yields to the light: switch the flash LED on from the page and
the pulsing stops until you switch it off again. Boot status does not yield,
because nobody has asked for the light yet at that point in the startup.

## Wi-Fi behavior

At boot the robot:

1. Tries the configured Wi-Fi network for 10 seconds.
2. If successful, it runs in normal STA mode.
3. If it cannot connect, it creates its own fallback access point.
4. While fallback AP mode is active, it periodically retries the configured Wi-Fi.

### Fallback AP

- SSID: `ESP32-Robot-XXXX`
- Password: `88888888`
- Default AP address: `http://192.168.4.1`

`XXXX` is generated from part of the ESP32 chip ID so several classroom robots can have different SSIDs.

If normal Wi-Fi works, the robot is usually reached at the DHCP address shown in the debug sidebar or UART console.

### Retries while the fallback AP is in use

The access point and the station share one radio and one channel, and the
station is the one that picks it. Retrying the configured Wi-Fi therefore
means a scan and an association that stalls AP traffic for a second or two,
and can throw AP clients off outright -- it used to cut the video and swallow
motor commands every 30 seconds while someone was driving.

So while **any client is connected to the fallback AP, the retries stop**, and
the log says so once:

`NET: Wi-Fi retry paused while the fallback AP is in use`

They resume when the last client disconnects. The consequence is worth knowing:
if you stay connected to the fallback AP, the robot will not rejoin the
configured network on its own. Disconnect for a minute, or reboot it, once the
normal network is back.

With nobody connected, retries **back off** from 30 seconds, doubling to a
five-minute cap, and reset once the configured network is joined. Each attempt
logs the interval for the next one.


## Debug event system

The ESP32 keeps the newest **64 events** in a circular buffer.

Examples:

- Boot started
- Camera initialized
- Wi-Fi connection state
- Fallback AP start
- Motor commands
- Motion timeout stops
- PWM changes
- Camera settings
- OTA start/success/failure
- Serial emergency stop

The browser requests only events newer than the last event ID it has seen.

This prevents fast button events from being lost between status polls.

## Export debug log

The Debug sidebar can save a `.txt` file containing:

- Current robot state
- PWM targets and outputs
- Network state
- SSID/IP
- Wi-Fi RSSI
- Uptime
- Build timestamp
- Latest message
- Event history, newest first

The export uses Windows-friendly CRLF line endings and UTF-8 text.

## OTA firmware update

The Debug sidebar contains a browser OTA uploader.

OTA password:

`88888888`

Before OTA works, the ESP32 must be flashed once by USB using an OTA-capable partition scheme.

A suitable Arduino IDE choice is typically:

`Minimal SPIFFS (1.9MB APP with OTA / 190KB SPIFFS)`

Exact wording may vary with the ESP32 Arduino core version.

### OTA workflow

1. Compile the current sketch in Arduino IDE.
2. Use **Sketch -> Export Compiled Binary**.
3. Select the main application file:
   - `YourSketch.ino.bin`
4. Do not select:
   - `*.bootloader.bin`
   - `*.partitions.bin`
   - `*.merged.bin`
5. Open the robot Debug sidebar.
6. Enter OTA password `88888888`.
7. Select the application `.ino.bin`.
8. Upload.
9. Motors are stopped before firmware writing.
10. After a successful update, the ESP32 reboots.

## Arduino sketch folder rule

This is important.

Arduino compiles **every `.ino` file in the same sketch folder**.

Do not put multiple complete versions of this robot firmware in the same directory.

Correct:

```text
ESP32_Robot_Complete/
  ESP32_Robot_Complete.ino
```

Incorrect:

```text
ESP32_Robot_Complete/
  ESP32_Robot_Complete.ino
  old_robot.ino
  test_robot.ino
```

The incorrect layout causes errors such as:

- redefinition of `ssid`
- redefinition of `setup()`
- redefinition of `loop()`
- redefinition of camera handlers
- redefinition of OTA variables

Keep old firmware versions in separate folders or rename them to `.txt`.

## Recommended Arduino settings

Typical settings for AI-Thinker ESP32-CAM:

- Board: AI Thinker ESP32-CAM
- Upload speed: 115200 if higher speeds are unreliable
- CPU frequency: 240 MHz
- Flash frequency: 40 MHz
- OTA-capable partition scheme
- Correct COM port

For USB flashing, GPIO0 normally needs to be held low during boot, depending on the programmer/adapter arrangement.

## Upload troubleshooting

If flashing connects at low speed and then fails after switching to a high baud rate, reduce **Upload Speed** to 115200.

Disconnect or stop motors during firmware upload and use a stable 5V supply.

## Network troubleshooting

If the robot cannot join configured Wi-Fi:

- Check SSID spelling
- Check password
- Check 2.4 GHz availability
- Check signal level
- Check router/AP security compatibility

The debug log reports status such as:

- connected
- SSID not found
- connection/authentication failed
- connection lost
- disconnected

If STA mode fails, connect directly to the fallback `ESP32-Robot-XXXX` network and open `192.168.4.1`.

## Camera troubleshooting

If higher resolutions fail:

- Confirm PSRAM is detected.
- Try VGA or QVGA.
- Increase JPEG quality number to reduce image size.
- Check power stability.
- Lower resolution if the camera stream becomes slow.

Remember: a lower JPEG quality number means higher image quality and generally larger JPEG frames.

## Security notes

The current educational configuration uses `88888888` for:

- Fallback AP password
- OTA password

This is convenient for a workshop/classroom but should be changed for an untrusted environment.

The robot control page is HTTP, not HTTPS.

Anyone who can reach the robot network may be able to control the robot unless additional authentication is added.

## The launcher

`launch.sh` is a menu for the whole build cycle: check and install PlatformIO,
build, flash over USB, open a serial monitor, clean, push firmware over Wi-Fi,
and export a `.bin` for the browser uploader.

Every action prints the command it is about to run before running it, in the
short form worth learning -- `pio run`, not the full path to the executable.
A menu that hides its work teaches nothing, and a child who can read the OTA
line can send firmware to a robot from any terminal.

Two entries open a browser instead:

- **w** -- the robot's own page. Press Enter to accept `192.168.4.1`, the
  address the fallback AP always serves on, or type the address it was given
  by a router. The sketch registers no mDNS name, so this is by IP.
- **h** -- `README.html`, the USB serial console page, or the project on
  GitHub.

Both go through one helper that tries `xdg-open`, `open`, `cmd`'s `start` and
finally PowerShell, and prints the address if none of them work rather than
failing silently. Local files are converted with `cygpath` under Git Bash,
because `cmd` cannot follow a `/d/work/...` path.

The two entries are letters, so the numbered options the rest of this document
refers to are unchanged.

## Main files

- `wdi_esp32_cam_robot_m2.ino` - the complete firmware, including the whole web UI
- `index_html_gz.h` - the gzipped copy of that UI, regenerated by `tools/gzip_ui.py`
- `tools/gzip_ui.py` - run it after every UI edit, or the robot serves the old page
- `launch.sh` - build, flash, monitor, OTA, and open the robot's page
- `platformio.ini` - board, partition scheme and build flags
- `ESP32_Robot_USB_Serial_Console.html` - standalone localhost Web Serial terminal
- `readme.md` - this documentation
- `README.html` - browser-friendly version of the documentation

## Suggested classroom experiments

- Find the minimum PWM where each unloaded wheel starts.
- Compare the left and right starting thresholds.
- Enable Sync and compare straight-line behavior.
- Intentionally offset one motor by 1-10 PWM counts and observe steering.
- Compare camera quality versus streaming responsiveness.
- Compare Wi-Fi RSSI with stream smoothness.
- Compare motor behavior with wheels lifted versus robot on the floor.
- Measure the turn rate at several speeds and plot requested against actual.
- Compare the left and right turn rates, and explain the gap.
- Find the speed below which the turn rate measures zero, and compare it with
  the wake-up numbers.
- Time a lap of a taped course, then try to beat it by trimming the motors.
- Work out what the line follower is actually seeing, then fool it on purpose.
- Add encoders/Hall sensors later and compare requested PWM with actual RPM.

## Future extensions

Useful next steps:

- Left/right wheel encoders
- Live RPM
- Wheel linear speed in m/s
- Distance estimation
- Closed-loop speed control
- Battery voltage monitoring
- Authentication for robot controls
- Downloadable CSV experiment data, starting with the turn-rate rows
- Repeat blocks in the Program view, so a square is one corner four times
- A notice when the requested speed is below a measured wake-up number
- Metres per second, from a single calibration drive over a known distance
