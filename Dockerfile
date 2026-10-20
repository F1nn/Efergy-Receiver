# GNU Radio receiver for the Efergy Engage/e2CT transmitter.
# Debian 13 provides GNU Radio 3.10 and Paho MQTT 2.x on amd64/arm64.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    gnuradio \
    gr-osmosdr \
    bladerf \
    rtl-sdr \
    python3-numpy \
    python3-paho-mqtt \
    python3-libgpiod \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/engage-receiver
COPY engage_receiver.grc ./

# Generate runnable Python and both embedded Python blocks without a GUI.
RUN grcc -d /opt/engage-receiver /opt/engage-receiver/engage_receiver.grc

CMD ["python3", "-u", "/opt/engage-receiver/engage_receiver.py"]
