#!/bin/bash
# Não usar set -e: vários comandos retornam não-zero intencionalmente
# (ping, kill, modo_silencioso) e set -e encerraria o script prematuramente.
set -uo pipefail

# ==============================================================================
# PROJETO: Emergency Shield Lnx
# AUTOR: UserM4C
# DESCRIÇÃO: Monitoramento de energia com alertas progressivos e proteção de dados.
# ==============================================================================

# --- CARREGA CONFIGURAÇÃO EXTERNA ---
CONFIG_FILE="$(dirname "$0")/esl.conf"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "ERRO: esl.conf não encontrado em $(dirname "$0"). Abortando." >&2
    exit 1
fi

# --- TRAVA DE EXECUÇÃO ---
LOCKFILE="/tmp/emergencia.lock"
[ -e "$LOCKFILE" ] && exit 0
touch "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT INT TERM

# --- DETECÇÃO AUTOMÁTICA DE HARDWARE ---
AC_NAME=$(ls /sys/class/power_supply/ | grep -E 'AC|ADP|ACAD' | head -n 1)

# Suporte a múltiplas baterias (soma energia de BAT0 + BAT1, etc.)
BAT_NAMES=$(ls /sys/class/power_supply/ | grep -E '^BAT')
BAT_NAME=$(echo "$BAT_NAMES" | head -n 1)  # fallback para funções que usam uma única bateria

# --- FUNÇÕES AUXILIARES ---

# Leitura dinâmica do status AC (evita valor desatualizado)
get_ac_status() {
    cat /sys/class/power_supply/"$AC_NAME"/online 2>/dev/null || echo "1"
}

# Calcula carga combinada de todas as baterias detectadas
get_bateria() {
    local total_energy=0 total_full=0 bat energy full
    for bat in $BAT_NAMES; do
        energy=$(cat /sys/class/power_supply/"$bat"/energy_now 2>/dev/null || echo 0)
        full=$(cat /sys/class/power_supply/"$bat"/energy_full 2>/dev/null || echo 0)
        total_energy=$(( total_energy + energy ))
        total_full=$(( total_full + full ))
    done
    if [ "$total_full" -gt 0 ]; then
        echo $(( total_energy * 100 / total_full ))
    else
        # Fallback para capacity simples
        cat /sys/class/power_supply/"$BAT_NAME"/capacity 2>/dev/null || echo 100
    fi
}

# Leitura inicial
STATUS_AC=$(get_ac_status)
CARGA_BATERIA=$(get_bateria)

# --- VERIFICAÇÃO DE DEPENDÊNCIAS ---
verificar_dependencias() {
    local faltando=()
    for cmd in curl amixer speaker-test; do
        command -v "$cmd" &>/dev/null || faltando+=("$cmd")
    done
    if [ ${#faltando[@]} -gt 0 ]; then
        registrar_evento "AVISO" "Dependências não encontradas: ${faltando[*]}. Algumas funções podem falhar."
    fi
}

# --- UPDATES DO SISTEMA ---

UPDATE_FILE="/tmp/esl_update.sent"
UPDATE_CACHE="/tmp/esl_update_cache.txt"

verificar_updates() {
    # Roda no máximo uma vez por dia
    local agora ultima
    agora=$(date +%s)
    ultima=0
    [ -f "$UPDATE_FILE" ] && ultima=$(stat -c %Y "$UPDATE_FILE" 2>/dev/null || echo 0)
    [ $(( agora - ultima )) -lt 86400 ] && return

    # Atualiza a lista de pacotes silenciosamente
    apt-get update -qq 2>/dev/null || return

    # Conta pacotes com upgrade disponível
    local total seguranca lista
    total=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || echo 0)
    seguranca=$(apt-get -s upgrade 2>/dev/null | grep '^Inst' | grep -ci 'security' || echo 0)
    lista=$(apt-get -s upgrade 2>/dev/null | grep '^Inst' | awk '{print $2}' | head -10 | tr '\n' ',' | sed 's/,$//')

    [ "$total" -eq 0 ] && { touch "$UPDATE_FILE"; return; }

    # Verifica se já notificou para exatamente esses pacotes
    local hash_atual
    hash_atual=$(echo "$lista" | md5sum | cut -d' ' -f1)
    if [ -f "$UPDATE_CACHE" ] && [ "$(cat "$UPDATE_CACHE")" = "$hash_atual" ]; then
        return
    fi

    echo "$hash_atual" > "$UPDATE_CACHE"
    touch "$UPDATE_FILE"

    local corpo="$total pacote(s) disponível(is)"
    [ "$seguranca" -gt 0 ] && corpo="$corpo ($seguranca de segurança)"
    corpo="$corpo: $lista"
    [ "$total" -gt 10 ] && corpo="${corpo}... e mais."

    local prioridade="default"
    [ "$seguranca" -gt 0 ] && prioridade="high"

    registrar_evento "INFO" "Updates disponíveis: $corpo"
    enviar_notificacao "🔔 UPDATES DISPONÍVEIS" "$corpo" "$prioridade"
}

# --- LOG E HISTÓRICO ---

rotar_log() {
    [ -f "$LOGFILE" ] || return
    local tamanho
    tamanho=$(du -k "$LOGFILE" | cut -f1)
    if [ "$tamanho" -gt "$LOG_MAX_KB" ]; then
        tail -n 100 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
    fi
}

# Registra no log de texto e no histórico JSON
registrar_evento() {
    local nivel=$1
    local mensagem=$2
    local timestamp
    timestamp=$(date -Iseconds)

    # Log texto
    echo "$timestamp - [$nivel] $mensagem" >> "$LOGFILE"

    # Histórico JSON (append de objeto por linha — newline-delimited JSON)
    local json_entry
    json_entry=$(printf '{"timestamp":"%s","nivel":"%s","bateria":%s,"ac":%s,"mensagem":"%s"}' \
        "$timestamp" "$nivel" "$CARGA_BATERIA" "$STATUS_AC" "$mensagem")
    echo "$json_entry" >> "$ESL_HISTORY"
}

# --- NOTIFICAÇÕES ---

enviar_notificacao() {
    local titulo=$1
    local corpo=$2
    local prioridade=${3:-default}
    curl -s \
        -H "Title: $titulo" \
        -H "Priority: $prioridade" \
        -d "$corpo" \
        "https://ntfy.sh/$NTFY_TOPIC" > /dev/null || true
}

# --- ALARME SONORO ---

parar_alarme() {
    systemctl stop esl-alarme.service 2>/dev/null || true
}

disparar_alarme_background() {
    if modo_silencioso; then
        return
    fi
    # Evita disparar múltiplos processos de alarme
    if systemctl is-active --quiet esl-alarme.service; then
        return
    fi
    systemctl start esl-alarme.service 2>/dev/null || true
}

# Retorna 0 (verdadeiro) se estiver dentro do horário silencioso
modo_silencioso() {
    local hora
    hora=$(date +%-H)
    if [ "$hora" -ge "$HORA_SILENCIO_INICIO" ] || [ "$hora" -lt "$HORA_SILENCIO_FIM" ]; then
        return 0
    fi
    return 1
}

# --- TEMPO RESTANTE ---

calcular_tempo_restante() {
    local energy_now power_now
    energy_now=$(cat /sys/class/power_supply/"$BAT_NAME"/energy_now 2>/dev/null || echo "")
    power_now=$(cat /sys/class/power_supply/"$BAT_NAME"/power_now 2>/dev/null || echo "")
    if [ -n "$energy_now" ] && [ -n "$power_now" ] && [ "$power_now" -gt 0 ]; then
        awk -v e="$energy_now" -v p="$power_now" 'BEGIN { printf "~%d min restantes", (e * 60) / p }'
    fi
}

# --- DETECÇÃO DE DRENO RÁPIDO ---

DRENO_FILE="/tmp/esl_dreno.txt"

verificar_dreno_rapido() {
    local agora carga_agora
    agora=$(date +%s)
    carga_agora=$(get_bateria)

    if [ -f "$DRENO_FILE" ]; then
        local ts_antes carga_antes delta_t delta_carga taxa
        ts_antes=$(cut -d: -f1 "$DRENO_FILE")
        carga_antes=$(cut -d: -f2 "$DRENO_FILE")
        delta_t=$(( agora - ts_antes ))
        delta_carga=$(( carga_antes - carga_agora ))

        if [ "$delta_t" -gt 0 ] && [ "$delta_carga" -gt 0 ]; then
            # taxa em %/min, multiplicada por 100 para evitar floats no bash
            taxa=$(( delta_carga * 60 * 100 / delta_t ))
            local limite_x100=$(( LIMITE_DRENO_RAPIDO * 100 ))
            if [ "$taxa" -gt "$limite_x100" ]; then
                local taxa_fmt
                taxa_fmt=$(awk -v t="$taxa" 'BEGIN { printf "%.1f", t/100 }')
                if [ ! -f /tmp/esl_dreno_alerta.sent ]; then
                    registrar_evento "ALERTA" "Dreno rápido detectado: ${taxa_fmt}%/min. Bateria em ${carga_agora}%."
                    enviar_notificacao "⚡ DRENO RÁPIDO" "Descarga anormal: ${taxa_fmt}%/min. Bateria em ${carga_agora}%." "high"
                    touch /tmp/esl_dreno_alerta.sent
                fi
            else
                rm -f /tmp/esl_dreno_alerta.sent
            fi
        fi
    fi

    # Atualiza referência
    echo "${agora}:${carga_agora}" > "$DRENO_FILE"
}

# --- TEMPERATURA DA BATERIA ---

verificar_temp_bateria() {
    local temp temp_c bat
    for bat in $BAT_NAMES; do
        temp=$(cat /sys/class/power_supply/"$bat"/temp 2>/dev/null || echo "")
        [ -z "$temp" ] && continue
        temp_c=$(( temp / 10 ))
        if [ "$temp_c" -gt "$LIMITE_TEMP_BATERIA" ]; then
            if [ ! -f "/tmp/esl_temp_${bat}.sent" ]; then
                registrar_evento "ALERTA" "Temperatura da bateria $bat: ${temp_c}°C (limite: ${LIMITE_TEMP_BATERIA}°C)."
                enviar_notificacao "🌡️ TEMPERATURA ALTA" "Bateria $bat em ${temp_c}°C. Verifique ventilação." "high"
                touch "/tmp/esl_temp_${bat}.sent"
            fi
        else
            rm -f "/tmp/esl_temp_${bat}.sent"
        fi
    done
}

# --- SAÚDE DA BATERIA ---

HEALTH_FILE="/tmp/esl_health.sent"

verificar_saude_bateria() {
    local energy_full energy_design bat saude
    local saude_min=100

    for bat in $BAT_NAMES; do
        energy_full=$(cat /sys/class/power_supply/"$bat"/energy_full 2>/dev/null || echo "")
        energy_design=$(cat /sys/class/power_supply/"$bat"/energy_full_design 2>/dev/null || echo "")
        [ -z "$energy_full" ] || [ -z "$energy_design" ] || [ "$energy_design" -eq 0 ] && continue
        saude=$(( energy_full * 100 / energy_design ))
        [ "$saude" -lt "$saude_min" ] && saude_min=$saude
    done

    if [ "$saude_min" -lt "$LIMITE_SAUDE_BATERIA" ]; then
        local agora ultima
        agora=$(date +%s)
        ultima=0
        [ -f "$HEALTH_FILE" ] && ultima=$(stat -c %Y "$HEALTH_FILE")
        if [ $(( agora - ultima )) -gt 604800 ]; then
            registrar_evento "AVISO" "Saúde da bateria: ${saude_min}% da capacidade original."
            enviar_notificacao "🔋 SAÚDE DA BATERIA" "Capacidade atual: ${saude_min}% da original. Considere substituir." "low"
            touch "$HEALTH_FILE"
        fi
    fi
}

# --- GERENCIAMENTO DE SERVIÇOS ---

SERVICES_FILE="/tmp/esl_services_stopped.txt"

parar_servicos() {
    > "$SERVICES_FILE"
    if command -v docker &>/dev/null; then
        for dir in $DOCKER_COMPOSE_DIRS; do
            if [ -d "$dir" ]; then
                (cd "$dir" && docker compose stop > /dev/null 2>&1)
                echo "COMPOSE:$dir" >> "$SERVICES_FILE"
                registrar_evento "INFO" "Compose em $dir parado antes do hibernate."
            fi
        done
    fi
    for svc in $SERVICOS_GERENCIADOS; do
        if systemctl is-active --quiet "$svc"; then
            echo "SYSTEMD:$svc" >> "$SERVICES_FILE"
            systemctl stop "$svc"
            registrar_evento "INFO" "Serviço $svc parado antes do hibernate."
        fi
    done
}

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
    registrar_evento "INFO" "HIBERNATE CONCLUÍDO. Serviços retomados:${retomados}. Carga: ${CARGA_BATERIA}%."
    enviar_notificacao "✅ SISTEMA RETOMADO" "Acordou do hibernate. Carga: $CARGA_BATERIA%. Serviços:${retomados}." "default"
}

# --- HIBERNAÇÃO ---

executar_hibernacao() {
    local motivo=$1
    registrar_evento "CRÍTICO" "$motivo Hibernando. Carga: ${CARGA_BATERIA}%."
    disparar_alarme_background
    enviar_notificacao "🚨 SISTEMA CRÍTICO" "$motivo Hibernando para preservar integridade." "urgent"
    sleep 5
    parar_alarme
    parar_servicos
    sync && systemctl hibernate || systemctl poweroff
}

# ==============================================================================
# INICIALIZAÇÃO
# ==============================================================================

rotar_log
verificar_dependencias
retomar_servicos
verificar_saude_bateria
verificar_temp_bateria
verificar_updates

# ==============================================================================
# LÓGICA PRINCIPAL
# ==============================================================================

if [ "$STATUS_AC" -eq 0 ]; then

    # Verifica conectividade com o gateway para distinguir queda geral de desconexão de cabo
    sleep 10
    GATEWAY=$(ip route | awk '/default/ {print $3; exit}')
    if [ -z "$GATEWAY" ] || ! ping -c 3 -W 3 "$GATEWAY" > /dev/null 2>&1; then
        executar_hibernacao "Roteador inacessível e sem energia. Queda geral detectada."
        exit 0
    fi

    TEMPO_RESTANTE=$(calcular_tempo_restante)

    # Verifica dreno rápido durante operação em bateria
    verificar_dreno_rapido

    # 1. Alerta imediato de remoção do cabo
    if [ ! -f /tmp/cabo_removido.sent ]; then
        disparar_alarme_background
        CORPO="O servidor passou a operar via bateria. Carga: $CARGA_BATERIA%."
        [ -n "$TEMPO_RESTANTE" ] && CORPO="$CORPO $TEMPO_RESTANTE."
        registrar_evento "ALERTA" "ENERGIA INTERROMPIDA. Operando via bateria. Carga: ${CARGA_BATERIA}%."
        enviar_notificacao "⚠️ ENERGIA INTERROMPIDA" "$CORPO" "high"
        touch /tmp/cabo_removido.sent
    fi

    # 2. Hibernação crítica (threshold configurável)
    if [ "$CARGA_BATERIA" -le "$LIMITE_HIBERNACAO" ]; then
        executar_hibernacao "Bateria em ${CARGA_BATERIA}% (limite: ${LIMITE_HIBERNACAO}%)."

    # 3. Alertas progressivos (90% → threshold+10%)
    else
        for threshold in 90 80 70 60 50 40; do
            # Só alerta thresholds acima do limite de hibernação
            [ "$threshold" -le "$LIMITE_HIBERNACAO" ] && continue
            if [ "$CARGA_BATERIA" -le "$threshold" ]; then
                FILE_CHECK="/tmp/alerta_${threshold}.sent"
                if [ ! -f "$FILE_CHECK" ]; then
                    CORPO="A carga do servidor desceu para $CARGA_BATERIA%."
                    [ -n "$TEMPO_RESTANTE" ] && CORPO="$CORPO $TEMPO_RESTANTE."
                    registrar_evento "ALERTA" "Bateria caiu para ${CARGA_BATERIA}% (limite ${threshold}%)."
                    enviar_notificacao "🔋 STATUS BATERIA" "$CORPO" "default"
                    touch "$FILE_CHECK"
                fi
            fi
        done
    fi

else

    # Energia voltou: notifica e limpa marcadores
    if [ -f /tmp/cabo_removido.sent ]; then
        registrar_evento "INFO" "ENERGIA RESTAURADA. AC reconectado. Carga: ${CARGA_BATERIA}%."
        enviar_notificacao "✅ ENERGIA RESTAURADA" "AC reconectado. Carga atual: $CARGA_BATERIA%." "default"
    fi

    parar_alarme
    rm -f /tmp/cabo_removido.sent /tmp/alerta_*.sent /tmp/esl_dreno_alerta.sent
    rm -f "$DRENO_FILE"

fi
