#!/bin/bash

# ==============================================================================
# PROJETO: Emergency Shield Lnx
# AUTOR: UserM4C
# DESCRIÇÃO: Monitoramento de energia com alertas progressivos a cada 10%.
# ==============================================================================

# Trava de execução com TRAP
LOCKFILE="/tmp/emergencia.lock"
[ -e "$LOCKFILE" ] && exit 0
touch "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# --- CONFIGURAÇÕES PERSONALIZÁVEIS ---
AC_NAME=$(ls /sys/class/power_supply/ | grep -E 'AC|ADP|ACAD' | head -n 1)
BAT_NAME=$(ls /sys/class/power_supply/ | grep -E '^BAT' | head -n 1)
STATUS_AC=$(cat /sys/class/power_supply/$AC_NAME/online)
CARGA_BATERIA=$(cat /sys/class/power_supply/$BAT_NAME/capacity)

LOGFILE="/home/SEU_USUARIO/emergencia.log"
NTFY_TOPIC="seu_topico_secreto_aqui"

# --- FUNÇÕES ---

enviar_notificacao() {
    local titulo=$1
    local corpo=$2
    local prioridade=${3:-default}
    curl -s -H "Title: $titulo" -H "Priority: $prioridade" -d "$corpo" "https://ntfy.sh/$NTFY_TOPIC"
}

tocar_alarme() {
    amixer set Master 100% unmute > /dev/null
    for i in {1..3}; do
        speaker-test -t sine -f 1000 -l 1 & sleep 0.5; kill $!
        sleep 0.2
    done &
}

# --- LÓGICA DE EMERGÊNCIA ---

if [ "$STATUS_AC" -eq 0 ]; then

    # Verifica se o roteador está acessível.
    # Pingar o gateway distingue queda geral de energia (roteador offline)
    # de simples desconexão de cabo (roteador continua respondendo),
    # evitando hibernação indevida durante oscilações momentâneas do AC.
    GATEWAY=$(ip route | awk '/default/ {print $3; exit}')
    if [ -z "$GATEWAY" ] || ! ping -c 2 -W 2 "$GATEWAY" > /dev/null 2>&1; then
        echo "$(date) - CRÍTICO: Roteador inacessível e sem energia. Queda geral detectada. Protegendo..." >> "$LOGFILE"
        tocar_alarme
        enviar_notificacao "QUEDA GERAL DE ENERGIA" "Roteador inacessível. Hibernando para preservar integridade." "urgent"
        sleep 3
        sync && systemctl hibernate || systemctl poweroff
        exit 0
    fi

    # 1. Alerta imediato de remoção do cabo
    if [ ! -f /tmp/cabo_removido.sent ]; then
        tocar_alarme
        enviar_notificacao "ENERGIA INTERROMPIDA" "O servidor passou a operar via bateria. Carga: $CARGA_BATERIA%." "high"
        touch /tmp/cabo_removido.sent
    fi

    # 2. Hibernação crítica (30%)
    if [ "$CARGA_BATERIA" -le 30 ]; then
        echo "$(date) - LIMITE CRÍTICO: ${CARGA_BATERIA}%. Hibernando." >> "$LOGFILE"
        tocar_alarme
        enviar_notificacao "SISTEMA CRÍTICO" "Bateria em $CARGA_BATERIA%. Hibernando para preservar integridade." "urgent"
        sleep 5
        sync && systemctl hibernate || systemctl poweroff

    # 3. Alertas progressivos (90% → 40%)
    # Usa <= por threshold em vez de % 10 == 0, garantindo que níveis
    # não sejam pulados em caso de dreno rápido entre execuções do timer.
    else
        for threshold in 90 80 70 60 50 40; do
            if [ "$CARGA_BATERIA" -le "$threshold" ]; then
                FILE_CHECK="/tmp/alerta_${threshold}.sent"
                if [ ! -f "$FILE_CHECK" ]; then
                    echo "$(date) - ALERTA: Bateria caiu para ${CARGA_BATERIA}% (limite ${threshold}%)." >> "$LOGFILE"
                    enviar_notificacao "STATUS BATERIA" "A carga do servidor desceu para $CARGA_BATERIA%." "default"
                    touch "$FILE_CHECK"
                fi
            fi
        done
    fi

else
    # Energia voltou: notifica (se havia sido removida) e limpa os marcadores
    if [ -f /tmp/cabo_removido.sent ]; then
        echo "$(date) - ENERGIA RESTAURADA: AC reconectado. Carga: ${CARGA_BATERIA}%." >> "$LOGFILE"
        enviar_notificacao "ENERGIA RESTAURADA" "AC reconectado. Carga atual: $CARGA_BATERIA%." "default"
    fi
    rm -f /tmp/cabo_removido.sent /tmp/alerta_*.sent
fi
