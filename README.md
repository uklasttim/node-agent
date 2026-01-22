# Node Probe Agent

## 安装

```bash
cd node-agent
sudo ./install.sh
sudo nano /etc/node-probe/agent.env
sudo systemctl restart node-probe.service
```

## Docker 部署

```bash
cd node-agent
cp agent.env.example agent.env
docker pull ghcr.io/uklasttim/server_status/node-agent:latest
docker compose up -d --build
```

说明：
- 默认使用 `network_mode: host` 和 `pid: host`，读取宿主机真实指标
- `PROC_ROOT` 设为 `/host/proc`，并挂载 `/proc:/host/proc:ro`
- 若不想使用 host 模式，可移除上述配置，但将采集容器内指标

## Docker Run 直接启动

```bash
docker run -d --name node-probe \
  --network host --pid host \
  -v /proc:/host/proc:ro \
  -v node-probe-state:/var/lib/node-probe \
  -e report_url="https://your-worker.example.workers.dev/report" \
  -e report_token="replace_with_token" \
  -e node_name="香港01" \
  -e proc_root="/host/proc" \
  -e log_level="info" \
  ghcr.io/uklasttim/server_status/node-agent:latest
```

说明：环境变量支持大小写（如 `node_name` / `NODE_NAME`）。
若需限制容器日志大小，请在 Docker daemon 配置 `log-opts`。

## GitHub Actions + GHCR

仓库已内置 CI：`.github/workflows/node-agent-ghcr.yml`  
推送到 `main/master` 会自动构建并推送镜像到：
`ghcr.io/uklasttim/server_status/node-agent:latest`

## 卸载

```bash
sudo systemctl stop node-probe.service
sudo systemctl disable node-probe.service
sudo rm -f /etc/systemd/system/node-probe.service
sudo rm -rf /opt/node-probe /etc/node-probe
sudo systemctl daemon-reload
```

## 配置项

- `NODE_NAME` 节点名称
- `NODE_ID` 节点唯一 ID（必填）
- `REPORT_URL` Cloudflare Worker 上报地址，例如 `https://xxx.workers.dev/report`
- `REPORT_TOKEN` 上报鉴权 token
- `REPORT_INTERVAL_SECONDS` 上报间隔秒数（可设为 1 实现更实时）
- `REPORT_TIMEOUT_SECONDS` 上报超时秒数
- `PROC_ROOT` 读取指标的 /proc 根目录（容器模式可设为 `/host/proc`）
- `STATE_DIR` 流量状态文件目录

## 指标说明

- 流量：来自 `/proc/net/dev`，按接口汇总（忽略 `lo`）
- 总流量：持久化累计（重启不清零）
- CPU：基于 `/proc/stat` 两次采样计算，单位 `permille`（千分比）
- 内存：`/proc/meminfo` 的 `MemTotal` 与 `MemAvailable`
- Swap：`/proc/meminfo` 的 `SwapTotal` 与 `SwapFree`
- 负载：`/proc/loadavg` 的 1/5/15
- 运行时间：`/proc/uptime`
- 磁盘：`df -k /` 的根分区，含 inode 信息
- 系统信息：CPU 型号、系统版本、内核版本

## 状态查看

```bash
sudo systemctl status node-probe.service
journalctl -u node-probe.service -n 100 --no-pager
```

## 快速验证

```bash
curl -H "authorization: Bearer ${REPORT_TOKEN}" \
  "https://xxx.workers.dev/nodes"
```
