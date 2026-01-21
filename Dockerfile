FROM debian:stable-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl iputils-ping \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/node-probe
COPY agent.sh /opt/node-probe/agent.sh
RUN chmod +x /opt/node-probe/agent.sh

ENV ENV_FILE=/etc/node-probe/agent.env
ENV STATE_DIR=/var/lib/node-probe

CMD ["/opt/node-probe/agent.sh"]
