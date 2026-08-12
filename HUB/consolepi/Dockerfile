FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    CONSOLEPI_HOME=/etc/ConsolePi \
    PATH=/etc/ConsolePi/venv/bin:/etc/ConsolePi/src:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
    build-essential \
       git \
       python3 \
    python3-dev \
       python3-pip \
       python3-venv \
       virtualenv \
    libffi-dev \
    libssl-dev \
   openssh-client \
   openssh-server \
   iptables \
       iproute2 \
       iputils-ping \
       net-tools \
       sudo \
       less \
       nano \
    && rm -rf /var/lib/apt/lists/*

# Clone ConsolePi and prepare venv-based install similar to non-Pi flow.
RUN git clone https://github.com/Pack3tL0ss/ConsolePi.git ${CONSOLEPI_HOME} \
    && python3 -m venv ${CONSOLEPI_HOME}/venv \
    && ${CONSOLEPI_HOME}/venv/bin/pip install --no-cache-dir --upgrade pip \
    && ${CONSOLEPI_HOME}/venv/bin/pip install --no-cache-dir --prefer-binary --upgrade -r ${CONSOLEPI_HOME}/installer/requirements.txt \
    && cp ${CONSOLEPI_HOME}/src/consolepi.sh /etc/profile.d/consolepi.sh \
   && cp ${CONSOLEPI_HOME}/ConsolePi.yaml.example /etc/ConsolePi.yaml \
   && mkdir -p /var/run/sshd

RUN useradd -m -s /bin/bash consolepi \
   && mkdir -p /home/consolepi/.ssh \
   && chown -R consolepi:consolepi /home/consolepi/.ssh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /root
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
