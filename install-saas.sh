#!/bin/bash
# ╔════════════════════════════════════════════╗
# ║        PVE SaaS — Script de Instalação     ║
# ╚════════════════════════════════════════════╝
set -euo pipefail

INSTALL_DIR="/opt/pve-saas"
SERVICE="pve-saas"
REPO="https://raw.githubusercontent.com/redsolucoesti-boop/bkpproxmox/main/panel"

# ── Cores ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✔${NC} $1"; }
info() { echo -e "${CYAN}▶${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
fail() { echo -e "${RED}✖ ERRO:${NC} $1"; exit 1; }

# ── Verificações ──
[[ $EUID -ne 0 ]] && fail "Execute como root: sudo bash install.sh"

info "Atualizando pacotes..."
apt-get update -qq

info "Instalando dependências do sistema..."
apt-get install -y -qq python3 python3-pip python3-venv sqlite3 curl

# ── Diretórios ──
mkdir -p "$INSTALL_DIR/templates" "$INSTALL_DIR/static"

# ── Download dos arquivos ──
info "Baixando arquivos do painel..."
curl -fsSL -o "$INSTALL_DIR/main.py"              "$REPO/main.py"
curl -fsSL -o "$INSTALL_DIR/requirements.txt"     "$REPO/requirements.txt"
curl -fsSL -o "$INSTALL_DIR/templates/index.html" "$REPO/templates/index.html"

# ── Ambiente virtual Python ──
info "Criando ambiente virtual Python..."
python3 -m venv "$INSTALL_DIR/venv"

info "Instalando dependências Python..."
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt"

# ── Permissões ──
chmod 750 "$INSTALL_DIR"
chmod 640 "$INSTALL_DIR/main.py"

# ── Serviço systemd ──
info "Criando serviço systemd..."
cat > /etc/systemd/system/$SERVICE.service <<EOF
[Unit]
Description=PVE SaaS Panel
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python -m uvicorn main:app --host 127.0.0.1 --port 8000 --workers 2
Restart=on-failure
RestartSec=5s
# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF

# ── Ajusta dono dos arquivos para www-data ──
chown -R www-data:www-data "$INSTALL_DIR"

# ── Ativa e inicia ──
systemctl daemon-reload
systemctl enable --now "$SERVICE"

# ── Verifica se iniciou ──
sleep 2
if systemctl is-active --quiet "$SERVICE"; then
  ok "Serviço iniciado com sucesso"
else
  fail "Serviço não iniciou. Verifique: journalctl -u $SERVICE -n 50"
fi

# ── Nginx reverso (opcional) ──
echo ""
echo -e "${YELLOW}Deseja configurar Nginx como proxy reverso? (recomendado) [s/N]${NC}"
read -r USE_NGINX
if [[ "${USE_NGINX,,}" == "s" ]]; then
  apt-get install -y -qq nginx
  cat > /etc/nginx/sites-available/pve-saas <<'NGINX'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass         http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 60s;
        client_max_body_size 2M;
    }
}
NGINX
  ln -sf /etc/nginx/sites-available/pve-saas /etc/nginx/sites-enabled/pve-saas
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
  ok "Nginx configurado"
fi

# ── Resumo ──
IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         ✅  PVE SaaS Instalado!          ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  URL:  http://${IP}:8000"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Login padrão:"
echo -e "${GREEN}║${NC}    Usuário: ${CYAN}admin${NC}"
echo -e "${GREEN}║${NC}    Senha:   ${RED}ChangeMe123!${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${YELLOW}║  ⚠ Troque a senha imediatamente!         ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "  Logs:   journalctl -u $SERVICE -f"
echo "  Status: systemctl status $SERVICE"
echo ""
