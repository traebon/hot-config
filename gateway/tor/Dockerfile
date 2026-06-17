FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends tor && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN chown -R debian-tor:debian-tor /var/lib/tor

USER debian-tor

CMD ["tor", "-f", "/etc/tor/torrc"]
