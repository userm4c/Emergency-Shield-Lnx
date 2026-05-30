#!/bin/bash
set -euo pipefail

# ==============================================================================
# PROJETO: Emergency Shield Lnx — Instalador
# Automatiza a instalação, configuração e ativação do ESL via systemd.
# Execute com: sudo bash install.sh
# ==============================================================================

ESL_DIR="$(cd "$(dirname "$0")" && pwd)"
ESL_SCRIPT="$ESL_DIR/esl.sh"
ESL_CONF="$ESL_DIR/esl.conf"
ALARME_SCRIPT="$ESL_DIR/esl-alarme.sh"
COMANDOS_SCRIPT="$ESL_DIR/esl-comandos.sh"
SERVICE_FILE="/etc/systemd/system/emergency-shield.service"
TIMER_FILE="/etc/systemd/system/emergency-shield.timer"
ALARME_SERVICE="/etc/systemd/system/esl-alarme.service"
COMANDOS_SERVICE="/etc/systemd/system/esl-comandos.service"
UDEV_RULE="/etc/udev/rules.d/99-emergency-shield.rules"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
erro()    { echo -e "${RED}[ERRO]${NC}  $*"; exit 1; }

echo ""
echo -e "${CYAN}────────────────────────────────────────────${NC}"
echo -e "${CYAN}│    Emergency Shield Lnx — Instalador     │${NC}"
echo -e "${CYAN}────────────────────────────────────────────${NC}"
echo ""

# --- VERIFICAÇÕES INICIAIS ---

[ "$EUID" -ne 0 ] && erro "Execute como root: sudo bash install.sh"
[ ! -f "$ESL_SCRIPT" ]    && erro "esl.sh não encontrado em $ESL_DIR"
[ ! -f "$ESL_CONF" ]      && erro "esl.conf não encontrado em $ESL_DIR. Configure-o antes de instalar."
[ ! -f "$ALARME_SCRIPT" ] && erro "esl-alarme.sh não encontrado em $ESL_DIR"
[ ! -f "$COMANDOS_SCRIPT" ] && erro "esl-comandos.sh não encontrado em $ESL_DIR"

# --- DEPENDÊNCIAS ---

info "Verificando dependências..."
FALTANDO=()
for cmd in curl amixer speaker-test ping ip; do
    command -v "$cmd" &>/dev/null || FALTANDO+=("$cmd")
done

if [ ${#FALTANDO[@]} -gt 0 ]; then
    warn "Dependências ausentes: ${FALTANDO[*]}"
    read -rp "  Instalar automaticamente? [s/N] " resp
    if [[ "$resp" =~ ^[sS]$ ]]; then
        apt-get update -qq
        apt-get install -y alsa-utils curl iputils-ping iproute2
        ok "Dependências instaladas."
    else
        warn "Instale manualmente antes de usar o ESL: apt install alsa-utils curl"
    fi
else
    ok "Todas as dependências encontradas."
fi

# --- PERMISSÃO DE EXECUÇÃO ---

info "Definindo permissão de execução nos scripts..."
chmod +x "$ESL_SCRIPT" "$ALARME_SCRIPT" "$COMANDOS_SCRIPT"
ok "chmod +x aplicado."

# --- DETECTA ADAPTADOR AC ---

info "Detectando adaptador AC..."
AC_NAME=$(ls /sys/class/power_supply/ | grep -E 'AC|ADP|ACAD' | head -n 1 || true)
if [ -z "$AC_NAME" ]; then
    warn "Adaptador AC não detectado automaticamente. A regra udev não será criada."
    AC_NAME=""
else
    ok "Adaptador AC detectado: $AC_NAME"
fi

# --- DETECTA BATERIAS ---

info "Detectando baterias..."
BAT_LIST=$(ls /sys/class/power_supply/ | grep -E '^BAT' || true)
if [ -z "$BAT_LIST" ]; then
    warn "Nenhuma bateria detectada. O ESL pode não funcionar corretamente neste hardware."
else
    ok "Baterias detectadas: $(echo "$BAT_LIST" | tr '\n' ' ')"
fi

# --- CRIA SERVIÇO SYSTEMD PRINCIPAL ---

info "Criando $SERVICE_FILE..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Emergency Shield Lnx
After=network.target

[Service]
Type=oneshot
ExecStart=$ESL_SCRIPT
StandardOutput=journal
StandardError=journal
EOF
ok "Serviço principal criado."

# --- CRIA TIMER SYSTEMD ---

info "Criando $TIMER_FILE..."
cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Executa Emergency Shield a cada minuto

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
ok "Timer systemd criado."

# --- CRIA SERVIÇO DO ALARME ---

info "Criando $ALARME_SERVICE..."
cat > "$ALARME_SERVICE" <<EOF
[Unit]
Description=Emergency Shield Lnx - Alarme Sonoro
After=sound.target

[Service]
Type=simple
ExecStart=$ALARME_SCRIPT
Restart=no
EOF
ok "Serviço de alarme criado."

# --- CRIA SERVIÇO DO LISTENER DE COMANDOS ---

info "Criando $COMANDOS_SERVICE..."
cat > "$COMANDOS_SERVICE" <<EOF
[Unit]
Description=Emergency Shield Lnx - Listener de Comandos
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$COMANDOS_SCRIPT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
ok "Serviço de comandos criado."

# --- CRIA REGRA UDEV (detecção instantânea) ---

if [ -n "$AC_NAME" ]; then
    info "Criando regra udev para detecção instantânea do AC ($AC_NAME)..."
    cat > "$UDEV_RULE" <<EOF
SUBSYSTEM=="power_supply", KERNEL=="$AC_NAME", RUN+="/bin/systemctl --no-block start emergency-shield.service"
EOF
    udevadm control --reload-rules
    ok "Regra udev criada e carregada."
else
    warn "Pulando criação da regra udev (adaptador AC não detectado)."
fi

# --- ATIVA E INICIA ---

info "Recarregando daemon e ativando serviços..."
systemctl daemon-reload
systemctl enable --now emergency-shield.timer
systemctl enable --now esl-comandos.service
ok "Timer e listener de comandos ativados."

# --- STATUS FINAL ---

echo ""
echo -e "${GREEN}────────────────────────────────────────────${NC}"
echo -e "${GREEN}│      Instalação concluída com êxito!     │${NC}"
echo -e "${GREEN}────────────────────────────────────────────${NC}"
echo ""
echo -e "  Script:    ${CYAN}$ESL_SCRIPT${NC}"
echo -e "  Config:    ${CYAN}$ESL_CONF${NC}"
echo -e "  Alarme:    ${CYAN}$ALARME_SCRIPT${NC}"
echo -e "  Comandos:  ${CYAN}$COMANDOS_SCRIPT${NC}"
echo -e "  Serviço:   ${CYAN}$SERVICE_FILE${NC}"
echo -e "  Timer:     ${CYAN}$TIMER_FILE${NC}"
[ -n "$AC_NAME" ] && echo -e "  udev:      ${CYAN}$UDEV_RULE${NC}"
echo ""
echo -e "  Status do timer:"
systemctl status emergency-shield.timer --no-pager | grep -E 'Active|Trigger' | sed 's/^/    /'
echo -e "  Status do listener de comandos:"
systemctl status esl-comandos.service --no-pager | grep -E 'Active' | sed 's/^/    /'
echo ""
echo -e "  ${YELLOW}Lembre-se de configurar NTFY_TOPIC e LOGFILE no esl.conf antes do uso em produção.${NC}"
echo ""
