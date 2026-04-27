#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  PVE Alerts Installer
#  Backup + SMART → Telegram
#  Uso: bash <(curl -s https://raw.githubusercontent.com/SEU-USER/pve-alerts/main/install.sh)
# ═══════════════════════════════════════════════════════════════

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="/opt/pve-alerts"
SERVICE_NAME="pve-webhook"
CRON_FILE="/var/spool/cron/crontabs/root"

print_banner() {
    echo -e "${CYAN}"
    echo "  ██████╗ ██╗   ██╗███████╗     █████╗ ██╗     ███████╗██████╗ ████████╗███████╗"
    echo "  ██╔══██╗██║   ██║██╔════╝    ██╔══██╗██║     ██╔════╝██╔══██╗╚══██╔══╝██╔════╝"
    echo "  ██████╔╝██║   ██║█████╗      ███████║██║     █████╗  ██████╔╝   ██║   ███████╗"
    echo "  ██╔═══╝ ╚██╗ ██╔╝██╔══╝      ██╔══██║██║     ██╔══╝  ██╔══██╗   ██║   ╚════██║"
    echo "  ██║      ╚████╔╝ ███████╗    ██║  ██║███████╗███████╗██║  ██║   ██║   ███████║"
    echo "  ╚═╝       ╚═══╝  ╚══════╝    ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝"
    echo -e "${NC}"
    echo -e "${BOLD}  Backup + SMART → Telegram Installer${NC}"
    echo -e "  ─────────────────────────────────────\n"
}

step() { echo -e "\n${BLUE}▶ $1${NC}"; }
ok()   { echo -e "${GREEN}  ✔ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $1${NC}"; }
err()  { echo -e "${RED}  ✘ $1${NC}"; }
ask()  { echo -e "${CYAN}  → $1${NC}"; }

# ── Verificar root ────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    err "Execute como root: sudo bash install.sh"
    exit 1
fi

print_banner

# ── Detectar tipo de servidor ─────────────────────────────────────
step "Detectando ambiente..."
SERVER_TYPE="PVE"
if command -v proxmox-backup-manager &>/dev/null; then
    SERVER_TYPE="PBS"
    ok "Proxmox Backup Server detectado"
elif command -v pvesh &>/dev/null; then
    SERVER_TYPE="PVE"
    ok "Proxmox VE detectado"
else
    warn "Servidor Proxmox não detectado — continuando mesmo assim"
fi

# ── Verificar dependências ────────────────────────────────────────
step "Verificando dependências..."
if ! command -v python3 &>/dev/null; then
    err "Python3 não encontrado!"
    exit 1
fi
ok "Python3: $(python3 --version)"

if ! command -v smartctl &>/dev/null; then
    warn "smartmontools não encontrado — instalando..."
    apt-get install -y smartmontools -q
fi
ok "smartmontools: $(smartctl --version | head -1)"

if ! command -v curl &>/dev/null; then
    apt-get install -y curl -q
fi
ok "curl disponível"

# ── Coletar configurações ─────────────────────────────────────────
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Configuração do Telegram${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
echo -e "  💡 Como obter o Token: fale com @BotFather no Telegram"
echo -e "  💡 Como obter o Chat ID: após criar o bot, acesse:"
echo -e "     https://api.telegram.org/bot<TOKEN>/getUpdates\n"

while true; do
    ask "Cole o Telegram Bot Token:"
    read -r BOT_TOKEN
    BOT_TOKEN=$(echo "$BOT_TOKEN" | tr -d ' ')
    if [[ "$BOT_TOKEN" =~ ^[0-9]+:.{20,}$ ]]; then
        ok "Token válido"
        break
    else
        err "Token inválido. Formato esperado: 123456789:ABCdef..."
    fi
done

while true; do
    ask "Cole o Telegram Chat ID (grupo/canal):"
    read -r CHAT_ID
    CHAT_ID=$(echo "$CHAT_ID" | tr -d ' ')
    if [[ "$CHAT_ID" =~ ^-?[0-9]+$ ]]; then
        ok "Chat ID válido"
        break
    else
        err "Chat ID inválido. Deve ser um número (ex: -1002506894644)"
    fi
done

echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Configurações opcionais${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

ask "Porta do webhook [padrão: 9090]:"
read -r WEBHOOK_PORT
WEBHOOK_PORT=${WEBHOOK_PORT:-9090}
ok "Porta: $WEBHOOK_PORT"

ask "Horário do relatório SMART diário [padrão: 07]:"
read -r SMART_HOUR
SMART_HOUR=${SMART_HOUR:-7}
ok "SMART diário às ${SMART_HOUR}h"

# ── Testar token antes de instalar ────────────────────────────────
step "Testando conexão com Telegram..."
TG_TEST=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe")
if echo "$TG_TEST" | grep -q '"ok":true'; then
    BOT_NAME=$(echo "$TG_TEST" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result']['username'])" 2>/dev/null)
    ok "Bot conectado: @${BOT_NAME}"
else
    err "Token inválido ou sem conexão com Telegram!"
    echo "  Resposta: $TG_TEST"
    exit 1
fi

# ── Criar diretório ───────────────────────────────────────────────
step "Criando estrutura de diretórios..."
mkdir -p "$INSTALL_DIR"
ok "Diretório: $INSTALL_DIR"

# ── Criar webhook.py ──────────────────────────────────────────────
step "Criando webhook middleware..."
cat > "$INSTALL_DIR/webhook.py" << PYEOF
#!/usr/bin/env python3
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import urlopen, Request
from datetime import datetime
import json, re, logging

TELEGRAM_BOT_TOKEN = "${BOT_TOKEN}"
TELEGRAM_CHAT_ID   = "${CHAT_ID}"
LISTEN_PORT        = ${WEBHOOK_PORT}
LISTEN_HOST        = "0.0.0.0"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

def detect_status(severity, title, message):
    text = (severity + title + message).lower()
    if any(w in text for w in ["failed","falhou","error","erro","unsuccessful"]): return "❌","FALHOU"
    if any(w in text for w in ["success","ok","completed","concluído","finished","successful"]): return "✅","OK"
    if any(w in text for w in ["warning","warn","aviso"]): return "⚠️","AVISO"
    return "ℹ️","INFO"

def detect_job_type(title, message):
    text = (title + message).lower()
    if "sync"    in text: return "🔄 Sync"
    if "backup"  in text: return "💾 Backup"
    if "prune"   in text: return "🗑️ Prune"
    if "verify"  in text: return "🔍 Verify"
    if "garbage" in text: return "♻️ GC"
    return "📦 Job"

def parse_backup_summary(message):
    info = {}
    for line in message.splitlines():
        line = line.strip()
        m = re.match(r'^(\d+)\s+(\S+)\s+(ok|failed)\s+(\S+)\s+([\d.]+ \w+)', line)
        if m:
            info["vmid"] = m.group(1)
            info["name"] = m.group(2)
            info["time"] = m.group(4)
            info["size"] = m.group(5)
        mt = re.search(r'transferred ([\d.]+ \w+)', line, re.IGNORECASE)
        if mt: info["transferred"] = mt.group(1)
        ms = re.search(r'write: ([\d.]+ \w+/s)', line, re.IGNORECASE)
        if ms: info["speed"] = ms.group(1)
        mr = re.search(r'reused ([\d.]+ \w+) \((\d+)%\)', line, re.IGNORECASE)
        if mr: info["reused"] = f"{mr.group(1)} ({mr.group(2)}%)"
    return info

def format_message(payload):
    severity = str(payload.get("severity", "unknown")).lower()
    title    = str(payload.get("title",    payload.get("subject", "Notificação")))
    message  = str(payload.get("message",  payload.get("body", "")))
    hostname = str(payload.get("hostname", payload.get("host", "")))
    ts       = payload.get("timestamp", "")
    time_str = ""
    if ts:
        try:    time_str = datetime.fromtimestamp(int(ts)).strftime("%d/%m/%Y %H:%M")
        except: time_str = str(ts)
    status_emoji, status_label = detect_status(severity, title, message)
    job_type = detect_job_type(title, message)
    bk = parse_backup_summary(message)
    lines = [
        f"{status_emoji} <b>{job_type} — {status_label}</b>",
        f"🖥️ <code>{hostname}</code>" + (f"   🕐 {time_str}" if time_str else ""),
    ]
    if bk:
        detail = []
        if "name"        in bk: detail.append(f"🖥 {bk['name']} ({bk.get('vmid','')})")
        if "time"        in bk: detail.append(f"⏱ {bk['time']}")
        if "transferred" in bk: detail.append(f"📊 {bk['transferred']}")
        if "reused"      in bk: detail.append(f"♻️ {bk['reused']}")
        if "speed"       in bk: detail.append(f"⚡ {bk['speed']}")
        if detail: lines.append(" | ".join(detail))
    if status_label == "FALHOU":
        for line in message.splitlines():
            line = line.strip()
            if any(w in line.lower() for w in ["failed","error","client error","falhou"]):
                lines.append(f"💬 <i>{line[:120]}</i>")
                break
    return "\n".join(lines)

def send_telegram(text):
    url  = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    data = json.dumps({"chat_id": TELEGRAM_CHAT_ID, "text": text,
                       "parse_mode": "HTML", "disable_web_page_preview": True}).encode()
    req  = Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urlopen(req, timeout=10) as r:
            logging.info(f"Telegram OK: {r.status}")
    except Exception as e:
        logging.error(f"Telegram ERRO: {e}")

class WebhookHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        logging.info(f"{self.client_address[0]} - {fmt % args}")
    def do_GET(self):
        self._respond(200, {"status": "running"}) if self.path == "/health" else self._respond(404, {})
    def do_POST(self):
        if self.path != "/webhook":
            self._respond(404, {}); return
        try:
            length = int(self.headers.get("Content-Length", 0))
            raw    = self.rfile.read(length).decode("utf-8", errors="replace")
            logging.info(f"Payload raw: {raw[:400]}")
            payload = {}
            if raw.strip():
                try:
                    payload = json.loads(raw)
                except json.JSONDecodeError:
                    cleaned = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', '', raw)
                    try:
                        payload = json.loads(cleaned)
                    except Exception:
                        for key in ("severity","title","hostname","message","timestamp"):
                            m = re.search(rf'"{key}"\s*:\s*"(.*?)"(?=\s*[,}}])', cleaned, re.DOTALL)
                            if m: payload[key] = m.group(1)
            msg = format_message(payload)
            send_telegram(msg)
            self._respond(200, {"status": "ok"})
        except Exception as e:
            logging.error(f"Erro: {e}")
            self._respond(500, {"status": "error", "detail": str(e)})
    def _respond(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

if __name__ == "__main__":
    server = HTTPServer((LISTEN_HOST, LISTEN_PORT), WebhookHandler)
    logging.info(f"Middleware rodando em {LISTEN_HOST}:{LISTEN_PORT}")
    try:    server.serve_forever()
    except KeyboardInterrupt: pass
PYEOF
ok "webhook.py criado"

# ── Criar smart-monitor.sh ────────────────────────────────────────
step "Criando script de monitoramento SMART..."
cat > "$INSTALL_DIR/smart-monitor.sh" << SHEOF
#!/bin/bash
TELEGRAM_BOT_TOKEN="${BOT_TOKEN}"
TELEGRAM_CHAT_ID="${CHAT_ID}"
HOSTNAME=\$(hostname)

CRITICAL_ATTRS=(
    "5:Reallocated_Sectors"
    "187:Uncorrectable_Errors"
    "188:Command_Timeout"
    "196:Reallocation_Events"
    "197:Pending_Sectors"
    "198:Uncorrectable_Sectors"
    "199:UDMA_CRC_Errors"
)

send_telegram() {
    local text="\$1"
    curl -s -X POST "https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\": \"\${TELEGRAM_CHAT_ID}\", \"text\": \$(echo "\$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'), \"parse_mode\": \"HTML\"}" > /dev/null 2>&1
}

DISKS=\$(lsblk -d -o NAME,TYPE | awk '\$2=="disk"{print "/dev/"\$1}')
ALERTS=""
SUMMARY_OK=""
HAS_PROBLEM=0

for DISK in \$DISKS; do
    DISK_NAME=\$(basename "\$DISK")
    MODEL=\$(smartctl -i "\$DISK" 2>/dev/null | grep -E "^Device Model|^Product" | awk -F: '{print \$2}' | tr -d ' ' | head -1)
    TEMP=\$(smartctl -A "\$DISK" 2>/dev/null | grep -i "Temperature_Celsius\|Airflow_Temperature" | awk '{print \$10}' | head -1)
    SMART_HEALTH=\$(smartctl -H "\$DISK" 2>/dev/null | grep -i "overall-health\|result" | awk -F: '{print \$2}' | tr -d ' ')
    SMART_ATTRS=\$(smartctl -A "\$DISK" 2>/dev/null)
    DISK_PROBLEMS=""

    if [ "\$SMART_HEALTH" != "PASSED" ] && [ "\$SMART_HEALTH" != "OK" ] && [ -n "\$SMART_HEALTH" ]; then
        DISK_PROBLEMS+="  ⚠️ Saúde: <b>\${SMART_HEALTH}</b>\n"
        HAS_PROBLEM=1
    fi

    for ATTR_DEF in "\${CRITICAL_ATTRS[@]}"; do
        ATTR_ID="\${ATTR_DEF%%:*}"
        ATTR_NAME="\${ATTR_DEF##*:}"
        RAW=\$(echo "\$SMART_ATTRS" | awk -v id="\$ATTR_ID" '\$1==id {print \$NF}' | head -1)
        if [ -n "\$RAW" ] && [ "\$RAW" -gt 0 ] 2>/dev/null; then
            DISK_PROBLEMS+="  🔴 \${ATTR_NAME}: <b>\${RAW}</b>\n"
            HAS_PROBLEM=1
        fi
    done

    DISK_INFO="💽 <b>\${DISK_NAME}</b>"
    [ -n "\$MODEL" ] && DISK_INFO+=" — <code>\${MODEL}</code>"
    [ -n "\$TEMP" ]  && DISK_INFO+=" 🌡️\${TEMP}°C"

    if [ -n "\$DISK_PROBLEMS" ]; then
        ALERTS+="\${DISK_INFO}\n\${DISK_PROBLEMS}\n"
    else
        SUMMARY_OK+="\${DISK_INFO}  ✅ \${SMART_HEALTH:-OK}\n"
    fi
done

if [ "\$HAS_PROBLEM" -eq 1 ]; then
    MSG="🚨 <b>SMART ALERT — \${HOSTNAME}</b>\n\n\${ALERTS}⏰ \$(date '+%d/%m/%Y %H:%M')"
    send_telegram "\$(echo -e "\$MSG")"
else
    MSG="✅ <b>SMART OK — \${HOSTNAME}</b>\n\n\${SUMMARY_OK}⏰ \$(date '+%d/%m/%Y %H:%M')"
    send_telegram "\$(echo -e "\$MSG")"
fi
SHEOF
chmod +x "$INSTALL_DIR/smart-monitor.sh"
ok "smart-monitor.sh criado"

# ── Criar serviço systemd ─────────────────────────────────────────
step "Criando serviço systemd..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Proxmox/PBS → Telegram Webhook Middleware
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/webhook.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME" &>/dev/null
sleep 2

if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "Serviço $SERVICE_NAME ativo e rodando"
else
    err "Serviço falhou ao iniciar! Verifique: journalctl -u $SERVICE_NAME -n 20"
    exit 1
fi

# ── Configurar cron SMART ─────────────────────────────────────────
step "Configurando cron do SMART..."
touch "$CRON_FILE"
CRON_LINE="0 ${SMART_HOUR} * * * ${INSTALL_DIR}/smart-monitor.sh >> /var/log/smart-monitor.log 2>&1"
if grep -q "smart-monitor" "$CRON_FILE" 2>/dev/null; then
    sed -i '/smart-monitor/d' "$CRON_FILE"
fi
echo "$CRON_LINE" >> "$CRON_FILE"
ok "Cron agendado: todo dia às ${SMART_HOUR}h"

# ── Teste final ───────────────────────────────────────────────────
step "Executando testes..."

# Teste webhook
WEBHOOK_RESP=$(curl -s -X POST "http://localhost:${WEBHOOK_PORT}/webhook" \
    -H "Content-Type: application/json" \
    -d "{\"severity\":\"info\",\"title\":\"PVE Alerts instalado com sucesso!\",\"hostname\":\"$(hostname)\",\"message\":\"Sistema de alertas configurado e funcionando.\",\"timestamp\":\"$(date +%s)\"}")

if echo "$WEBHOOK_RESP" | grep -q '"ok"'; then
    ok "Webhook funcionando — mensagem de teste enviada ao Telegram!"
else
    warn "Webhook retornou resposta inesperada: $WEBHOOK_RESP"
fi

# Teste SMART
echo -e "  Rodando verificação SMART..."
"$INSTALL_DIR/smart-monitor.sh"
ok "SMART executado — verifique o Telegram"

# ── Instruções finais ─────────────────────────────────────────────
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  ✅ Instalação concluída com sucesso!${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

echo -e "${BOLD}  Próximo passo — Configurar Notification Target no Proxmox:${NC}\n"

if [ "$SERVER_TYPE" = "PBS" ]; then
    echo -e "  ${CYAN}PBS:${NC} Configuration → Notifications → Endpoints → Add → Webhook"
else
    echo -e "  ${CYAN}PVE:${NC} Datacenter → Notifications → Endpoints → Add → Webhook"
fi

echo -e "
  ┌─────────────────────────────────────────────────────┐
  │  Method: POST                                       │
  │  URL:    http://127.0.0.1:${WEBHOOK_PORT}/webhook              │
  │                                                     │
  │  Header: Content-Type: application/json             │
  │                                                     │
  │  Body:                                              │
  │  {                                                  │
  │    \"severity\":  \"{{ severity }}\",                  │
  │    \"title\":     \"{{ title }}\",                     │
  │    \"hostname\":  \"{{ host }}\",                      │
  │    \"timestamp\": \"{{ timestamp }}\",                 │
  │    \"message\":   \"{{ message }}\"                    │
  │  }                                                  │
  └─────────────────────────────────────────────────────┘
"
echo -e "  ${BOLD}Comandos úteis:${NC}"
echo -e "  • Ver logs:       ${CYAN}journalctl -u pve-webhook -f${NC}"
echo -e "  • Status:         ${CYAN}systemctl status pve-webhook${NC}"
echo -e "  • Testar SMART:   ${CYAN}${INSTALL_DIR}/smart-monitor.sh${NC}"
echo -e "  • Desinstalar:    ${CYAN}systemctl disable --now pve-webhook && rm -rf ${INSTALL_DIR}${NC}\n"
