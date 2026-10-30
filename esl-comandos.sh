#!/bin/bash
# ==============================================================================
# PROJETO: Emergency Shield Lnx — Listener de Comandos via ntfy
# Fica conectado ao tópico ntfy e executa comandos recebidos.
# ==============================================================================

CONFIG_FILE="$(dirname "$0")/esl.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ERRO: esl.conf não encontrado." >&2
    exit 1
fi

# --- FUNÇÕES AUXILIARES ---

responder() {
    local mensagem=$1
    curl -s \
        -H "Title: 🖥️ ESL Resposta" \
        -H "Priority: default" \
        -d "$mensagem" \
        "https://ntfy.sh/$NTFY_TOPIC" > /dev/null || true
}

get_ac_status() {
    cat /sys/class/power_supply/"$AC_NAME"/online 2>/dev/null || echo "1"
}

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
        cat /sys/class/power_supply/"$BAT_NAME"/capacity 2>/dev/null || echo "?"
    fi
}

# --- DETECÇÃO DE HARDWARE ---

AC_NAME=$(ls /sys/class/power_supply/ | grep -E 'AC|ADP|ACAD' | head -n 1)
BAT_NAMES=$(ls /sys/class/power_supply/ | grep -E '^BAT')
BAT_NAME=$(echo "$BAT_NAMES" | head -n 1)

# --- HANDLERS DE COMANDOS ---

cmd_ping() {
    local uptime_str
    uptime_str=$(uptime -p 2>/dev/null || uptime)
    responder "🟢 PONG — Servidor respondendo.
Hora: $(date '+%d/%m/%Y %H:%M:%S')
Uptime: $uptime_str"
}

cmd_status() {
    local ac bateria ip temp uso_cpu uso_mem

    ac=$(get_ac_status)
    [ "$ac" -eq 1 ] && ac_str="✅ Conectado" || ac_str="⚠️ Desconectado"

    bateria=$(get_bateria)

    ip=$(hostname -I | awk '{print $1}')

    temp=$(cat /sys/class/power_supply/"$BAT_NAME"/temp 2>/dev/null || echo "")
    if [ -n "$temp" ]; then
        temp_str="$(awk -v t="$temp" 'BEGIN{printf "%.1f°C", t/10}')"
    else
        temp_str="N/D"
    fi

    uso_cpu=$(top -bn1 | grep -E "^%?.*CPU" | awk '{
        for(i=1;i<=NF;i++) if($i~/id,?$/ || $(i+1)~/id,?$/) { gsub(/,/,".",$i); printf "%.0f", 100-$i; exit }
    }')
    uso_mem=$(free | awk '/^Mem/ {printf "%.0f%%", $3/$2*100}')

    responder "💻 STATUS DO SERVIDOR
——————————————————
⚡ Energia: $ac_str
🔋 Bateria: ${bateria}%
🖥️ CPU: ${uso_cpu}%
💾 RAM: $uso_mem
🌐 IP local: $ip
🕐 Hora: $(date '+%d/%m/%Y %H:%M:%S')"
}

cmd_parar_alarme() {
    systemctl stop esl-alarme.service 2>/dev/null || true
    responder "🔕 Alarme parado manualmente."
}

cmd_mudo() {
    local minutos=${1:-30}
    systemctl stop esl-alarme.service 2>/dev/null || true
    ( sleep $(( minutos * 60 )) && rm -f /tmp/esl_mudo.lock ) &
    touch /tmp/esl_mudo.lock
    responder "🔇 Alarme silenciado por ${minutos} minutos."
}

cmd_logs() {
    local ultimas
    ultimas=$(tail -20 "$LOGFILE" 2>/dev/null || echo "Log vazio ou não encontrado.")
    responder "📋 ÚLTIMAS ENTRADAS DO LOG:
——————————————————
$ultimas"
}

cmd_hibernar() {
    responder "😴 Iniciando hibernação em 10 segundos..."
    sleep 10
    systemctl hibernate || systemctl poweroff
}

cmd_desligar() {
    responder "🔴 Desligando servidor em 10 segundos..."
    sleep 10
    systemctl poweroff
}

cmd_reiniciar() {
    responder "🔄 Reiniciando servidor em 10 segundos..."
    sleep 10
    systemctl reboot
}

cmd_agendar_reinicio() {
    local horario=$1
    if [ -z "$horario" ]; then
        responder "❌ Informe o horário. Ex: AGENDAR_REINICIO 23:30"
        return
    fi
    if ! echo "$horario" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
        responder "❌ Formato inválido. Use HH:MM. Ex: AGENDAR_REINICIO 23:30"
        return
    fi
    shutdown -c 2>/dev/null || true
    shutdown -r "$horario"
    responder "✅ Reinício agendado para $horario."
}

cmd_cancelar_reinicio() {
    if shutdown -c 2>/dev/null; then
        responder "✅ Reinício cancelado."
    else
        responder "ℹ️ Nenhum reinício agendado."
    fi
}

cmd_limpar_kernels() {
    local antes depois removidos
    antes=$(dpkg --list | grep -c linux-image || echo 0)
    responder "🧹 Removendo kernels antigos, aguarde..."
    apt-get autoremove --purge -y 2>/dev/null
    depois=$(dpkg --list | grep -c linux-image || echo 0)
    removidos=$(( antes - depois ))
    local espaco
    espaco=$(df -h /boot | awk 'NR==2 {print $4}')
    if [ "$removidos" -gt 0 ]; then
        responder "✅ $removidos kernel(s) antigo(s) removido(s). Espaço livre em /boot: $espaco"
    else
        responder "ℹ️ Nenhum kernel antigo para remover. Espaço livre em /boot: $espaco"
    fi
}

cmd_status_docker() {
    if ! command -v docker &>/dev/null; then
        responder "❌ Docker não encontrado neste servidor."
        return
    fi
    local status
    status=$(docker ps --format "{{.Names}}: {{.Status}}" 2>/dev/null)
    if [ -z "$status" ]; then
        status="Nenhum container em execução."
    fi
    responder "🐳 CONTAINERS DOCKER:
——————————————————
$status"
}

cmd_reiniciar_servicos() {
    if ! command -v docker &>/dev/null; then
        responder "❌ Docker não encontrado."
        return
    fi
    local subidos=""
    for dir in $DOCKER_COMPOSE_DIRS; do
        if [ -d "$dir" ]; then
            (cd "$dir" && docker compose up -d > /dev/null 2>&1)
            subidos="${subidos} $(basename "$dir")"
        fi
    done
    responder "✅ Serviços reiniciados:${subidos}"
}

cmd_parar_servicos() {
    if ! command -v docker &>/dev/null; then
        responder "❌ Docker não encontrado."
        return
    fi
    local parados=""
    for dir in $DOCKER_COMPOSE_DIRS; do
        if [ -d "$dir" ]; then
            (cd "$dir" && docker compose stop > /dev/null 2>&1)
            parados="${parados} $(basename "$dir")"
        fi
    done
    responder "✅ Serviços parados:${parados}"
}

cmd_testar_alarme() {
    local segundos=${1:-5}
    responder "🔔 Testando alarme por ${segundos} segundos..."
    systemctl stop esl-alarme.service 2>/dev/null || true
    systemd-run --unit=esl-alarme-teste \
        --setenv=ESL_TESTE=1 \
        --setenv=ESL_TESTE_SEG="$segundos" \
        /home/m4c/Emergency-Shield-Lnx/esl-alarme.sh 2>/dev/null || \
    ESL_TESTE=1 ESL_TESTE_SEG="$segundos" /home/m4c/Emergency-Shield-Lnx/esl-alarme.sh &
    sleep $(( segundos + 1 ))
    systemctl stop esl-alarme-teste.service 2>/dev/null || true
    responder "✅ Teste do alarme concluído."
}

cmd_updates() {
    responder "🔍 Verificando updates, aguarde..."
    apt-get update -qq 2>/dev/null || true
    local total seguranca lista
    total=$(apt-get -s upgrade 2>/dev/null | grep -c "^Inst" || echo 0)
    seguranca=$(apt-get -s upgrade 2>/dev/null | grep "^Inst" | grep -ci "security" || echo 0)
    lista=$(apt-get -s upgrade 2>/dev/null | grep "^Inst" | awk '{print $2}' | head -15 | tr '\n' ',' | sed 's/,$//')
    if [ "$total" -eq 0 ]; then
        responder "✅ Sistema atualizado. Nenhum pacote pendente."
    else
        local corpo="$total pacote(s) disponível(is)"
        [ "$seguranca" -gt 0 ] && corpo="$corpo ($seguranca de segurança)"
        [ -n "$lista" ] && corpo="$corpo:
$lista"
        [ "$total" -gt 15 ] && corpo="$corpo
...e mais."
        responder "🔔 UPDATES DISPONÍVEIS:
——————————————————
$corpo"
    fi
}

cmd_ip_externo() {
    local ip
    ip=$(curl -s https://api.ipify.org 2>/dev/null || curl -s https://ifconfig.me 2>/dev/null || echo "Não foi possível obter o IP externo.")
    responder "🌐 IP EXTERNO: $ip"
}

cmd_ping_host() {
    local host=${1:-8.8.8.8}
    if ping -c 3 -W 3 "$host" > /dev/null 2>&1; then
        local ms
        ms=$(ping -c 3 -W 3 "$host" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
        responder "✅ PING $host: OK (média ${ms}ms)"
    else
        responder "❌ PING $host: Sem resposta."
    fi
}

cmd_dns() {
    local dominio=${1:-google.com}
    if ! command -v dig &>/dev/null && ! command -v nslookup &>/dev/null; then
        responder "❌ dig/nslookup não encontrados. Instale dnsutils."
        return
    fi
    local resultado
    if command -v dig &>/dev/null; then
        resultado=$(dig +short "$dominio" 2>/dev/null | head -5)
    else
        resultado=$(nslookup "$dominio" 2>/dev/null | awk '/^Address/ && !/#53/ {print $2}' | head -5)
    fi
    [ -z "$resultado" ] && resultado="Sem resposta."
    responder "🔍 DNS $dominio:
$resultado"
}

cmd_disco() {
    local uso
    uso=$(df -h --output=target,size,used,avail,pcent 2>/dev/null | grep -v tmpfs | grep -v udev)
    responder "💿 USO DE DISCO:
——————————————————
$uso"
}

cmd_processos() {
    local lista
    lista=$(ps aux --sort=-%cpu 2>/dev/null | awk 'NR==1 || NR<=6 {printf "%-20s %5s %5s\n", $11, $3, $4}' | head -6)
    responder "⚙️ TOP PROCESSOS (CPU/MEM):
——————————————————
$(echo "$lista" | awk 'NR==1{print "PROCESSO             %CPU  %MEM"} NR>1{print}')"
}

cmd_historico() {
    local hist
    if [ ! -f "$ESL_HISTORY" ]; then
        responder "📋 Histórico ainda não gerado."
        return
    fi
    hist=$(tail -10 "$ESL_HISTORY" 2>/dev/null | python3 -c "
import sys, json
lines = sys.stdin.readlines()
out = []
for l in lines:
    try:
        d = json.loads(l)
        out.append('{} [{}] {}'.format(d.get('timestamp','')[:16].replace('T',' '), d.get('nivel',''), d.get('mensagem','')))
    except:
        pass
print('\n'.join(out))
" 2>/dev/null)
    [ -z "$hist" ] && hist="Histórico vazio."
    responder "📋 HISTÓRICO DE EVENTOS:
——————————————————
$hist"
}

cmd_reiniciar_container() {
    local nome=$1
    if [ -z "$nome" ]; then
        responder "❌ Informe o nome do container. Ex: REINICIAR_CONTAINER pihole"
        return
    fi
    if ! command -v docker &>/dev/null; then
        responder "❌ Docker não encontrado."
        return
    fi
    if docker restart "$nome" > /dev/null 2>&1; then
        responder "✅ Container $nome reiniciado."
    else
        responder "❌ Falha ao reiniciar $nome. Verifique se o nome está correto."
    fi
}

cmd_logs_container() {
    local nome=$1
    if [ -z "$nome" ]; then
        responder "❌ Informe o nome do container. Ex: LOGS_CONTAINER pihole"
        return
    fi
    if ! command -v docker &>/dev/null; then
        responder "❌ Docker não encontrado."
        return
    fi
    local logs
    logs=$(docker logs --tail 20 "$nome" 2>&1)
    [ -z "$logs" ] && logs="Sem logs disponíveis."
    responder "📋 LOGS $nome (últimas 20 linhas):
——————————————————
$logs"
}

cmd_quem_conectado() {
    local usuarios
    usuarios=$(who 2>/dev/null)
    [ -z "$usuarios" ] && usuarios="Nenhum usuário logado."
    local ultimos
    ultimos=$(last -n 5 2>/dev/null | head -5)
    responder "👤 USUÁRIOS CONECTADOS:
——————————————————
$usuarios

🔑 ÚLTIMOS ACESSOS:
$ultimos"
}

cmd_conexoes() {
    local conex
    conex=$(ss -tunp 2>/dev/null | grep ESTAB | awk '{print $1, $5, $6}' | head -15)
    [ -z "$conex" ] && conex="Nenhuma conexão ativa."
    responder "🔌 CONEXÕES ATIVAS:
——————————————————
$conex"
}

cmd_ajuda() {
    responder "📋 COMANDOS DISPONÍVEIS:
——————————————————
🔔 ALARME
PARAR_ALARME — Para o alarme imediatamente
MUDO [min] — Silencia por X min (padrão: 30)
TESTAR_ALARME [seg] — Toca por X seg (padrão: 5)

📋 INFORMAÇÕES
PING — Verifica se o servidor responde
STATUS — Energia, bateria, CPU, RAM, IP
DISCO — Uso de disco por partição
PROCESSOS — Top 5 processos por CPU
HISTORICO — Últimos eventos do ESL
LOGS — Últimas 20 linhas do log
UPDATES — Verifica pacotes disponíveis

🌐 REDE
IP_EXTERNO — Retorna o IP público atual
PING_HOST [host] — Testa conectividade
DNS [dominio] — Resolve domínio via Pi-hole
QUEM_CONECTADO — Usuários logados
CONEXOES — Conexões de rede ativas

🐳 DOCKER
STATUS_DOCKER — Lista containers em execução
REINICIAR_SERVICOS — Sobe todos os compose
PARAR_SERVICOS — Para todos os compose
REINICIAR_CONTAINER [nome] — Reinicia um container
LOGS_CONTAINER [nome] — Logs de um container

⚡ ENERGIA
HIBERNAR — Hiberna o servidor
REINICIAR — Reinicia o servidor
AGENDAR_REINICIO [HH:MM] — Agenda reinício para o horário
CANCELAR_REINICIO — Cancela reinício agendado
DESLIGAR — Desliga o servidor
LIMPAR_KERNELS — Remove kernels antigos do sistema

AJUDA — Exibe esta mensagem"
}

# --- LOOP PRINCIPAL: escuta o tópico ntfy via SSE ---

echo "$(date) - ESL Comandos iniciado. Ouvindo tópico: $NTFY_TOPIC" >> "$LOGFILE"

while true; do
    curl -s --no-buffer \
        "https://ntfy.sh/$NTFY_TOPIC/json" | \
    while IFS= read -r linha; do
        [ -z "$linha" ] && continue
        echo "$linha" | grep -q '"event":"message"' || continue

        comando=$(echo "$linha" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('message','').strip().upper())
except:
    pass
" 2>/dev/null)

        [ -z "$comando" ] && continue

        echo "$(date) - [COMANDO] Recebido: $comando" >> "$LOGFILE"

        arg=$(echo "$comando" | awk '{print $2}')
        comando=$(echo "$comando" | awk '{print $1}')

        case "$comando" in
            PING)               cmd_ping ;;
            STATUS)             cmd_status ;;
            PARAR_ALARME)       cmd_parar_alarme ;;
            MUDO)               cmd_mudo "$arg" ;;
            LOGS)               cmd_logs ;;
            HIBERNAR)           cmd_hibernar ;;
            DESLIGAR)           cmd_desligar ;;
            REINICIAR)          cmd_reiniciar ;;
            AGENDAR_REINICIO)   cmd_agendar_reinicio "$arg" ;;
            CANCELAR_REINICIO)  cmd_cancelar_reinicio ;;
            LIMPAR_KERNELS)     cmd_limpar_kernels ;;
            STATUS_DOCKER)      cmd_status_docker ;;
            REINICIAR_SERVICOS) cmd_reiniciar_servicos ;;
            PARAR_SERVICOS)     cmd_parar_servicos ;;
            TESTAR_ALARME)      cmd_testar_alarme "$arg" ;;
            UPDATES)            cmd_updates ;;
            IP_EXTERNO)         cmd_ip_externo ;;
            PING_HOST)          cmd_ping_host "$arg" ;;
            DNS)                cmd_dns "$arg" ;;
            DISCO)              cmd_disco ;;
            PROCESSOS)          cmd_processos ;;
            HISTORICO)          cmd_historico ;;
            REINICIAR_CONTAINER) cmd_reiniciar_container "$arg" ;;
            LOGS_CONTAINER)     cmd_logs_container "$arg" ;;
            QUEM_CONECTADO)     cmd_quem_conectado ;;
            CONEXOES)           cmd_conexoes ;;
            AJUDA)              cmd_ajuda ;;
            *)
                echo "$(date) - [COMANDO] Desconhecido: $comando" >> "$LOGFILE"
                ;;
        esac
    done

    # Se o curl cair (sem internet, timeout), aguarda e reconecta
    echo "$(date) - [COMANDOS] Conexão ntfy perdida. Reconectando em 30s..." >> "$LOGFILE"
    sleep 30
done
