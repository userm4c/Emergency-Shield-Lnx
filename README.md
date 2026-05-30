# 🛡️ Emergency Shield Lnx — ESL

> **Status:** Operational
> **Goal:** Data Integrity, Power Management & Remote Control

Transforma notebooks em servidores resilientes, usando a bateria interna como um UPS inteligente com monitoramento progressivo, alarme contínuo e controle remoto completo via [ntfy](https://ntfy.sh).

---

## 🚀 Funcionalidades

### Monitoramento de Energia
- **Detecção instantânea de queda de AC** via regra udev (sem esperar o timer)
- **Alertas progressivos** a cada 10% de descarga (90% → threshold de hibernação)
- **Hibernação automática** no nível configurável (padrão: 30%), com fallback para poweroff
- **Triagem de rede** — diferencia queda geral de energia de desconexão de cabo via ping ao gateway
- **Dreno rápido** — alerta se a taxa de descarga ultrapassar o limite configurável (%/min)
- **Temperatura da bateria** — alerta se exceder o limite em °C (quando o hardware expõe o sensor)
- **Saúde da bateria** — notificação semanal se a capacidade cair abaixo do limite configurável
- **Suporte a múltiplas baterias** (BAT0 + BAT1, etc.) com cálculo combinado de carga

### Alarme Sonoro
- Loop contínuo via serviço systemd dedicado (`esl-alarme.service`) — para automaticamente quando o AC volta
- **Modo silencioso** configurável por horário (padrão: 22h–7h) — notificações push continuam ativas
- **Modo teste** via comando remoto (`TESTAR_ALARME`)

### Controle Remoto via ntfy
Serviço listener (`esl-comandos.service`) sempre ativo, com 27 comandos agrupados em 5 categorias:

| Categoria | Exemplos |
|---|---|
| 🔔 Alarme | `PARAR_ALARME`, `MUDO [min]`, `TESTAR_ALARME [seg]` |
| 📋 Informações | `PING`, `STATUS`, `DISCO`, `PROCESSOS`, `HISTORICO`, `LOGS`, `UPDATES` |
| 🌐 Rede | `IP_EXTERNO`, `PING_HOST [host]`, `DNS [dominio]`, `QUEM_CONECTADO`, `CONEXOES` |
| 🐳 Docker | `STATUS_DOCKER`, `REINICIAR_SERVICOS`, `REINICIAR_CONTAINER [nome]`, `LOGS_CONTAINER [nome]` |
| ⚡ Energia | `HIBERNAR`, `REINICIAR`, `AGENDAR_REINICIO [HH:MM]`, `DESLIGAR`, `LIMPAR_KERNELS` |

> Envie `AJUDA` pelo ntfy para ver a lista completa a qualquer momento.

### Proteção de Dados
- Para serviços Docker Compose e systemd antes de hibernar
- Executa `sync` antes do hibernate
- **Retomada automática** ao acordar — reinicia os serviços parados e envia confirmação

### Logs e Histórico
- Log texto rotacionado automaticamente (padrão: 500KB, mantém últimas 100 linhas)
- **Histórico JSON** em newline-delimited format — compatível com `jq`, Grafana e similares
- Updates do sistema verificados diariamente com deduplicação por hash MD5

---

## 📁 Estrutura de Arquivos

```
Emergency-Shield-Lnx/
├── esl.sh                  # Script principal de monitoramento
├── esl.conf                # Configurações do usuário (não sobrescrito pelo git pull)
├── esl-alarme.sh           # Alarme em loop contínuo
├── esl-alarme.service      # Unit systemd do alarme
├── esl-comandos.sh         # Listener de 27 comandos via ntfy
├── esl-comandos.service    # Unit systemd do listener
└── install.sh              # Instalador automatizado
```

---

## 🛠️ Instalação

```bash
git clone https://github.com/userm4c/Emergency-Shield-Lnx.git
cd Emergency-Shield-Lnx
cp esl.conf esl.conf  # já existe — edite antes de instalar
sudo bash install.sh
```

O `install.sh` cuida de tudo: dependências, permissões, detecção de hardware, criação dos units systemd, regra udev e ativação dos serviços.

---

## ⚙️ Configuração (`esl.conf`)

Edite o arquivo **antes** de instalar. Após a instalação, `git pull` não sobrescreve suas configurações.

| Variável | Padrão | Descrição |
|---|---|---|
| `LOGFILE` | — | Caminho do arquivo de log |
| `ESL_HISTORY` | — | Caminho do histórico JSON |
| `NTFY_TOPIC` | — | Tópico ntfy para notificações e comandos |
| `DOCKER_COMPOSE_DIRS` | `""` | Diretórios com docker-compose a parar/retomar |
| `SERVICOS_GERENCIADOS` | `""` | Serviços systemd a parar antes do hibernate |
| `LIMITE_HIBERNACAO` | `30` | % de bateria para hibernar |
| `LIMITE_DRENO_RAPIDO` | `2` | Taxa de descarga anormal em %/min |
| `LIMITE_TEMP_BATERIA` | `45` | Temperatura máxima da bateria em °C |
| `LIMITE_SAUDE_BATERIA` | `70` | Saúde mínima da bateria em % |
| `HORA_SILENCIO_INICIO` | `22` | Início do modo silencioso |
| `HORA_SILENCIO_FIM` | `7` | Fim do modo silencioso |
| `LOG_MAX_KB` | `500` | Tamanho máximo do log antes de rotacionar |

---

## 📱 Notificações Push

1. Baixe o app **ntfy** (Android / iOS)
2. Inscreva-se no tópico definido em `NTFY_TOPIC`
3. Use o mesmo tópico para enviar comandos remotos

---

## 🔧 Comandos Úteis de Manutenção

```bash
# Ver logs do ESL em tempo real
journalctl -fu emergency-shield.service

# Ver logs do listener de comandos
journalctl -fu esl-comandos.service

# Reiniciar o listener após atualizar esl-comandos.sh
sudo systemctl restart esl-comandos.service

# Testar o script manualmente
sudo rm -f /tmp/emergencia.lock && sudo bash -x ~/Emergency-Shield-Lnx/esl.sh

# Verificar espaço em /boot
df -h /boot
```

---

*Developed by UserM4C*
