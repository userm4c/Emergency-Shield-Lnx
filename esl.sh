#!/bin/bash

# ==============================================================================
# PROJETO: Emergency Shield Lnx
# AUTOR: UserM4C
# DESCRIÇÃO: Monitoramento de energia com alertas progressivos a cada 10%.
# ==============================================================================

# Trava de execução com TRAP
LOCKFILE="/tmp/emergencia.lock"
[ -e $LOCKFILE ] && exit 0
touch $LOCKFILE
trap "rm -f $LOCKFILE" EXIT

# --- CONFIGURAÇÕES PERSONALIZÁVEIS ---
AC_NAME=$(ls /sys/class/power_supply/ | grep -E 'AC|ADP|ACAD' | head -n 1)
STATUS_AC=$(cat /sys/class/power_supply/$AC_NAME/online)
CARGA_BATERIA=$(cat /sys/class/power_supply/BAT0/capacity)

LOGFILE="/home/SEU_USUARIO/emergencia.log"
NTFY_TOPIC="seu_topico_secreto_aqui"

# --- FUNÇÕES ---

enviar_notificacao() {
    local titulo=$1
    local corpo=$2
    curl -H "Title: $titulo" -d "$corpo" "ntfy.sh/$NTFY_TOPIC"
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
    
    # Verifica rede
    INTERFACE_ATIVA=$(ip link show up | grep -v "lo" | grep "LOWER_UP")
    if [ -z "$INTERFACE_ATIVA" ]; then
        echo "$(date) - CRÍTICO: Sem rede e sem energia. Protegendo..." >> $LOGFILE
        sync && systemctl hibernate
        exit 0
    fi

    # 1. Alerta Imediato de Remoção do Cabo
    if [ ! -f /tmp/cabo_removido.sent ]; then
        tocar_alarme
        enviar_notificacao "ENERGIA INTERROMPIDA" "O servidor passou a operar via bateria. Carga: $CARGA_BATERIA%"
        touch /tmp/cabo_removido.sent
    fi

    # 2. Hibernação Crítica (30%)
    if [ "$CARGA_BATERIA" -le 30 ]; then
        echo "$(date) - LIMITE CRÍTICO: 30%. Hibernando." >> $LOGFILE
        tocar_alarme
        enviar_notificacao "SISTEMA CRÍTICO" "Bateria em $CARGA_BATERIA%. Hibernando para preservar integridade."
        sleep 5
        sync && systemctl hibernate

    # 3. Alertas Progressivos (a cada 10%)
    else
        # Esta lógica verifica se a carga é múltiplo de 10 (90, 80, 70, etc)
        # E usa um arquivo de controle específico para aquele nível
        if (( CARGA_BATERIA % 10 == 0 )); then
            FILE_CHECK="/tmp/alerta_${CARGA_BATERIA}.sent"
            if [ ! -f "$FILE_CHECK" ]; then
                echo "$(date) - ALERTA: Bateria caiu para $CARGA_BATERIA%." >> $LOGFILE
                enviar_notificacao "STATUS BATERIA" "A carga do servidor desceu para $CARGA_BATERIA%."
                touch "$FILE_CHECK"
            fi
        fi
    fi
else
    # Energia voltou: Limpa todos os marcadores de alerta
    rm -f /tmp/cabo_removido.sent /tmp/alerta_*.sent
fi
