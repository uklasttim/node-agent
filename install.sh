#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo mkdir -p /opt/node-probe
sudo mkdir -p /etc/node-probe

sudo cp "$ROOT_DIR/agent.sh" /opt/node-probe/agent.sh
sudo chmod +x /opt/node-probe/agent.sh

if [[ ! -f /etc/node-probe/agent.env ]]; then
  sudo cp "$ROOT_DIR/agent.env.example" /etc/node-probe/agent.env
  echo "已复制配置到 /etc/node-probe/agent.env，请编辑后再启动服务"
fi

sudo cp "$ROOT_DIR/node-probe.service" /etc/systemd/system/node-probe.service

sudo systemctl daemon-reload
sudo systemctl enable node-probe.service

echo "安装完成。编辑 /etc/node-probe/agent.env 后执行：sudo systemctl restart node-probe.service"
