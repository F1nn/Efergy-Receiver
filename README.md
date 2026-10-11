# Efergy Engage / e2CT receiver using GNU Radio and bladeRF

A live, headless **433 MHz FSK receiver and decoder** for the Efergy Engage / e2CT wireless electricity-monitoring transmitter. Built in **GNU Radio Companion (GRC)** and tested with a **Nuand bladeRF 2.0** on a **Raspberry Pi 4 Model B** running Debian 13 (64-bit).

The receiver decodes Efergy packets, validates their checksums, measures RF signal quality, and publishes results over **MQTT** with **automatic Home Assistant discovery**. It supports multiple transmitter IDs without preconfiguring them.

## Features

- Live bladeRF reception; **no IQ recording or offline playback required**.
- FSK demodulation, pulse-width decoding, framing and 8-bit checksum validation.
- Adaptive, noise-relative packet detection with hysteresis and pre-trigger buffering.
- Device ID, current (A), battery status, learn flag and configurable transmitter interval (6, 12 or 18 seconds).
- Per-packet **RSSI, noise floor and SNR**, plus measured FSK tone frequencies and deviation.
- Per-transmitter estimated reception percentage and missed packets.
- Automatic discovery of multiple transmitters, with separate MQTT topics, Home Assistant entities and a **fixed 45-second RF availability timeout** per transmitter.
- Headless operation as a systemd service; low CPU utilisation after optimising idle-sample processing with NumPy.

## Hardware and software

| Item | Tested setup |
|---|---|
| Transmitter | Efergy Engage / e2CT sensor |
| SDR | Nuand bladeRF 2.0, RX antenna connected |
| Host | Raspberry Pi 4 Model B, Debian 13 Trixie (aarch64) |
| GNU Radio | 3.10.12.0 |
| SDR integration | gr-osmosdr 0.2.0.0, libbladeRF |
| Messaging | Paho MQTT, MQTT broker (tested with Home Assistant) |

An antenna suited to approximately 433 MHz is required. The implementation is built around the bladeRF source; other GNU Radio-supported SDRs may work with source-block changes and retesting.

Install the main packages on Debian/Raspberry Pi OS:

```bash
sudo apt update
sudo apt install -y gnuradio gr-osmosdr bladerf python3-numpy python3-paho-mqtt mosquitto-clients
```

Check device access with `bladeRF-cli -p`. Development can be done through VNC with `gnuradio-companion`; the deployed receiver requires no graphical desktop.

## Signal-processing flowgraph

```text
Osmocom Source / bladeRF      433.530 MHz, 1 MS/s, complex IQ
          |
          v
Frequency Xlating FIR         low-pass 150 kHz, transition 40 kHz,
          |                   decimation 2 -> 500 kS/s
          |
          +--> Complex to Mag² --> Moving Average (500 samples, scale 1/500)
          |                                      | float power
          |                                      +---------------------+
          v                                                            |
Quadrature Demod (gain 1.0)                                             |
          | float instantaneous frequency                              |
          v                                                            |
Float Low Pass Filter (20 kHz cutoff) ---+------------------------+      |
          |                              |                        |      |
          v                              |                        |      |
Binary Slicer                            |                        |      |
          | byte pulse levels            |                        |      |
          +------------------------------+------------------------+------+ 
                                         |
                      Embedded Python Efergy Decoder
                        in0 = byte sliced pulses
                        in1 = float smoothed power
                        in2 = float demodulated FSK
                                         |
                                PMT `packet` message
                                         v
                        Embedded Python MQTT Publisher
                                         |
                         MQTT broker / Home Assistant
```

All three decoder stream inputs run at **500 kS/s**. The third input is the *filtered float demodulation signal*, **before** Binary Slicer; it is used for FSK-frequency estimates. No Throttle block is used with the hardware SDR source.

The Efergy decoder and MQTT publisher are **Embedded Python Blocks** within the `.grc` project. In GRC, save changes and press **F5** to regenerate the runnable Python script; do not edit the generated script as the source of truth.

## Protocol notes

The observed transmission is FSK with pulse-width encoding. Nominal pulse widths are around **64 µs** (short), **136 µs** (long) and **500 µs** (synchronisation). A decoded packet contains **64 bits / 8 bytes**; the final byte is an additive checksum of the preceding seven bytes, modulo 256.

The decoder publishes only accepted packets after framing and checksum validation. Checksums are useful for rejecting noise and unrelated RF activity, but they are not cryptographic authentication.

The radio measurements are **relative to the receiver's digital full scale (dBFS)**, not calibrated dBm at the antenna input. FSK tone frequencies are estimates from the filtered demodulated waveform. Estimated missed packets and reception rate are inferred from gaps between accepted packets; the protocol has no sequence number. Those counters reset when the receiver restarts.

## MQTT topic structure

With the receiver ID derived from the operating system hostname and topic prefix `engage`:

```text
efergy/events                                         # all valid packets, JSON
engage/receivers/<HOSTNAME>/availability              # receiver MQTT online/offline
engage/receivers/<HOSTNAME>/sensors/<ID>/state        # each sensor's packet JSON
engage/receivers/<HOSTNAME>/sensors/<ID>/rf_availability
homeassistant/<component>/engage_<HOSTNAME>_<ID>_<entity>/config
```

`<HOSTNAME>` comes from the host operating system, and `<ID>` comes from the transmitted packet, so newly encountered transmitters are handled automatically. Discovery messages and availability statuses are retained; ordinary packet events are not. MQTT receiver connectivity and RF sensor reception have independent availability states. A sensor is marked RF-offline after **45 seconds without a valid packet** and restored on the next valid packet. On startup, the MQTT publisher subscribes to its own retained sensor availability records. Previously known sensors are marked RF-offline until a fresh valid packet is received, preventing stale online statuses after a receiver restart.

Example *illustrative* sensor payload (exact optional fields depend on decoder version):

```json
{
  "model": "Efergy-e2CT",
  "id": 55082,
  "current": 7.318,
  "battery_ok": true,
  "interval": 6,
  "learn": false,
  "mic": "CHECKSUM",
  "checksum_ok": true,
  "raw": "0b2ad740751803dc",
  "rssi": -4.57,
  "noise": -42.12,
  "snr": 37.55,
  "rf_power_unit": "dBFS",
  "freq1": 433.4924,
  "freq2": 433.5765,
  "fsk_deviation_khz": 42.1,
  "reception_rate": 100.0,
  "packets_missed_est": 0
}
```

Home Assistant MQTT discovery adds current, battery, last-received time, packet count and checksum status, plus RF diagnostics (RSSI, SNR, noise, frequencies, deviation, reception percentage and estimated missed packets). **No manual sensor definitions in `configuration.yaml` are needed** if MQTT discovery is enabled.

Note: two physically different transmitters using the *same transmitted sensor ID* cannot be uniquely separated on one receiver solely by protocol ID.

## MQTT credentials

Do **not** commit passwords in `.grc` files or generated `.py` files. The current deployment obtains MQTT credentials from environment variables.

Example `/etc/engage-receiver.env`:

```ini
ENGAGE_MQTT_USER=your_mqtt_user
ENGAGE_MQTT_PASSWORD=your_mqtt_password
```

```bash
sudo chmod 600 /etc/engage-receiver.env
```

In GRC, use an unconnected **Import** block with `import os`; enter these expressions as the MQTT publisher's user/password parameter values:

```python
os.environ.get("ENGAGE_MQTT_USER", "")
os.environ.get("ENGAGE_MQTT_PASSWORD", "")
```

The embedded MQTT block defaults to `localhost`, empty credentials and the system hostname; the GRC parameters override these defaults (including the broker hostname). Missing credentials allow GRC validation, but successful broker authentication may require configuring them. Runtime credentials must be set for successful broker authentication. Treat the `.grc` file as sensitive if it still contains any old embedded credentials.

## Headless operation with systemd

Configure the GRC **Options** block for **No GUI** and **Run to Completion**. Disable diagnostic Qt sinks and Message Debug for normal operation. Generate the Python script with **F5**.

Example service (adjust paths and username; this example assumes a checkout at `/home/pi/engage-receiver`):

```ini
# /etc/systemd/system/engage-receiver.service
[Unit]
Description=GNU Radio Engage E2CT Receiver
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/engage-receiver
EnvironmentFile=/etc/engage-receiver.env
ExecStart=/usr/bin/python3 -u /home/pi/engage-receiver/engage_receiver.py
Restart=on-failure
RestartSec=5
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now engage-receiver
systemctl status engage-receiver
journalctl -u engage-receiver -f -o cat
```

When running manually, **stop the systemd service first** so two instances don't compete for the bladeRF:

```bash
sudo systemctl stop engage-receiver
# Make credentials available to the shell, then:
python3 -u engage_receiver.py
# Stop with Ctrl+C, then:
sudo systemctl start engage-receiver
```

For regular operation, the logs contain a concise `PKT` line per valid reception and a periodic summary; debug mode can expose streaming rate, detector thresholds, candidate captures and decode failures.

## Licence

This project is released under the [MIT License](LICENSE).
