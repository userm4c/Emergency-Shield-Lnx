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

LOGFILE="/home/SEU_USUARIO/esl.log"
NTFY_TOPIC="seu_topico_secreto_aqui"

# Diretórios com docker-compose.yml a parar/retomar (separados por espaço)
DOCKER_COMPOSE_DIRS=""

# Serviços systemd a parar antes de hibernar (separados por espaço)
SERVICOS_GERENCIADOS=""

# Horário do modo silencioso — alarme sonoro desativado neste intervalo
HORA_SILENCIO_INICIO=22
HORA_SILENCIO_FIM=7

# Tamanho máximo do log antes de rotacionar (KB)
LOG_MAX_KB=500

# Arquivos de controle internos
SERVICES_FILE="/tmp/esl_services_stopped.txt"
HEALTH_FILE="/tmp/esl_health.sent"

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

# Retorna 0 (verdadeiro) se estiver dentro do horário silencioso
modo_silencioso() {
    local hora
    hora=$(date +%-H)
    [ "$hora" -ge "$HORA_SILENCIO_INICIO" ] || [ "$hora" -lt "$HORA_SILENCIO_FIM" ]
}

# Calcula tempo restante com base em energy_now/power_now do kernel
calcular_tempo_restante() {
    local energy_now power_now
    energy_now=$(cat /sys/class/power_supply/$BAT_NAME/energy_now 2>/dev/null)
    power_now=$(cat /sys/class/power_supply/$BAT_NAME/power_now 2>/dev/null)
    if [ -n "$energy_now" ] && [ -n "$power_now" ] && [ "$power_now" -gt 0 ]; then
        awk -v e="$energy_now" -v p="$power_now" 'BEGIN { printf "~%d min restantes", (e * 60) / p }'
    fi
}

# Para stacks Docker Compose e serviços systemd, registrando o que foi parado
parar_servicos() {
    > "$SERVICES_FILE"
    if command -v docker &>/dev/null; then
        for dir in $DOCKER_COMPOSE_DIRS; do
            if [ -d "$dir" ]; then
                (cd "$dir" && docker compose stop > /dev/null 2>&1)
                echo "COMPOSE:$dir" >> "$SERVICES_FILE"
                echo "$(date) - Compose em $dir parado antes do hibernate." >> "$LOGFILE"
            fi
        done
    fi
    for svc in $SERVICOS_GERENCIADOS; do
        if systemctl is-active --quiet "$svc"; then
            echo "SYSTEMD:$svc" >> "$SERVICES_FILE"
            systemctl stop "$svc"
            echo "$(date) - Serviço $svc parado antes do hibernate." >> "$LOGFILE"
        fi
    done
}

# Retoma os serviços registrados em SERVICES_FILE após acordar do hibernate
retomar_servicos() {
    [ -f "$SERVICES_FILE" ] || return
    local retomados=""
    while IFS= read -r line; do
        local tipo="${line%%:*}"
        local valor="${line#*:}"
        if [ "$tipo" = "COMPOSE" ]; then
            (cd "$valor" && docker compose up -d > /dev/null 2>&1)
            retomados="${retomados} $(basename "$valor")"
        elif [ "$tipo" = "SYSTEMD" ]; then
            systemctl start "$valor"
            retomados="${retomados} $valor"
        fi
    done < "$SERVICES_FILE"
    rm -f "$SERVICES_FILE"
    echo "$(date) - HIBERNATE CONCLUÍDO: Serviços retomados:${retomados}. Carga: ${CARGA_BATERIA}%." >> "$LOGFILE"
    enviar_notificacao "SISTEMA RETOMADO" "Acordou do hibernate. Carga: $CARGA_BATERIA%. Serviços retomados:${retomados}." "default"
}

# Notifica uma vez por semana se a saúde da bateria estiver abaixo de 70%
verificar_saude_bateria() {
    local energy_full energy_design
    energy_full=$(cat /sys/class/power_supply/$BAT_NAME/energy_full 2>/dev/null)
    energy_design=$(cat /sys/class/power_supply/$BAT_NAME/energy_full_design 2>/dev/null)
    [ -z "$energy_full" ] || [ -z "$energy_design" ] || [ "$energy_design" -eq 0 ] && return
    local saude=$(( energy_full * 100 / energy_design ))
    if [ "$saude" -lt 70 ]; then
        local agora ultima
        agora=$(date +%s)
        ultima=0
        [ -f "$HEALTH_FILE" ] && ultima=$(stat -c %Y "$HEALTH_FILE")
        if [ $(( agora - ultima )) -gt 604800 ]; then
            enviar_notificacao "SAÚDE DA BATERIA" "Capacidade atual: ${saude}% da original. Considere substituir a bateria." "low"
            touch "$HEALTH_FILE"
        fi
    fi
}

# Mantém o log abaixo de LOG_MAX_KB preservando as últimas 100 linhas
rotar_log() {
    [ -f "$LOGFILE" ] || return
    local tamanho
    tamanho=$(du -k "$LOGFILE" | cut -f1)
    if [ "$tamanho" -gt "$LOG_MAX_KB" ]; then
        tail -n 100 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
    fi
}

# --- INICIALIZAÇÃO ---

rotar_log
retomar_servicos        # retoma serviços se o sistema acabou de acordar do hibernate
verificar_saude_bateria

# --- LÓGICA DE EMERGÊNCIA ---

if [ "$STATUS_AC" -eq 0 ]; then

    # Verifica se o roteador está acessível.
    # Pingar o gateway distingue queda geral de energia (roteador offline)
    # de simples desconexão de cabo (roteador continua respondendo),
    # evitando hibernação indevida durante oscilações momentâneas do AC.
    # Aguarda o NIC estabilizar após a oscilação AC→bateria antes de pingar
    sleep 10
    GATEWAY=$(ip route | awk '/default/ {print $3; exit}')
    if [ -z "$GATEWAY" ] || ! ping -c 3 -W 3 "$GATEWAY" > /dev/null 2>&1; then
        echo "$(date) - CRÍTICO: Roteador inacessível e sem energia. Queda geral detectada. Protegendo..." >> "$LOGFILE"
        modo_silencioso || tocar_alarme
        enviar_notificacao "QUEDA GERAL DE ENERGIA" "Roteador inacessível. Hibernando para preservar integridade." "urgent"
        sleep 3
        parar_servicos
        sync && systemctl hibernate || systemctl poweroff
        exit 0
    fi

    TEMPO_RESTANTE=$(calcular_tempo_restante)

    # 1. Alerta imediato de remoção do cabo
    if [ ! -f /tmp/cabo_removido.sent ]; then
        modo_silencioso || tocar_alarme
        CORPO="O servidor passou a operar via bateria. Carga: $CARGA_BATERIA%."
        [ -n "$TEMPO_RESTANTE" ] && CORPO="$CORPO $TEMPO_RESTANTE."
        echo "$(date) - ENERGIA INTERROMPIDA: Operando via bateria. Carga: ${CARGA_BATERIA}%." >> "$LOGFILE"
        enviar_notificacao "ENERGIA INTERROMPIDA" "$CORPO" "high"
        touch /tmp/cabo_removido.sent
    fi

    # 2. Hibernação crítica (30%)
    if [ "$CARGA_BATERIA" -le 30 ]; then
        echo "$(date) - LIMITE CRÍTICO: ${CARGA_BATERIA}%. Hibernando." >> "$LOGFILE"
        modo_silencioso || tocar_alarme
        enviar_notificacao "SISTEMA CRÍTICO" "Bateria em $CARGA_BATERIA%. Hibernando para preservar integridade." "urgent"
        sleep 5
        parar_servicos
        sync && systemctl hibernate || systemctl poweroff

    # 3. Alertas progressivos (90% → 40%)
    # Usa <= por threshold em vez de % 10 == 0, garantindo que níveis
    # não sejam pulados em caso de dreno rápido entre execuções do timer.
    else
        for threshold in 90 80 70 60 50 40; do
            if [ "$CARGA_BATERIA" -le "$threshold" ]; then
                FILE_CHECK="/tmp/alerta_${threshold}.sent"
                if [ ! -f "$FILE_CHECK" ]; then
                    CORPO="A carga do servidor desceu para $CARGA_BATERIA%."
                    [ -n "$TEMPO_RESTANTE" ] && CORPO="$CORPO $TEMPO_RESTANTE."
                    echo "$(date) - ALERTA: Bateria caiu para ${CARGA_BATERIA}% (limite ${threshold}%)." >> "$LOGFILE"
                    enviar_notificacao "STATUS BATERIA" "$CORPO" "default"
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
