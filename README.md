# 🛡️ Emergency-Shield-Lnx - ESL

> **Status:** Operational
> **Goal:** Data Integrity & Power Management

Este script transforma notebooks em servidores resilientes, utilizando a bateria interna como um UPS (Nobreak) inteligente com monitoramento progressivo.

## 🚀 Funcionalidades
* **Monitoramento AC:** Detecta instantaneamente a perda de energia externa.
* **Alertas Progressivos:** Notificações via Push a cada 10% de queda na bateria (90%, 80%, 70%...), com estimativa de tempo restante em cada alerta.
* **Triagem de Rede:** Diferencia quedas de energia gerais de desconexões acidentais de cabo via ping ao gateway.
* **Alerta Sonoro:** Alarme intermitente via `amixer` e `speaker-test` em eventos críticos.
* **Modo Silencioso:** Alarme sonoro desativado automaticamente em horário configurável (padrão: 22h–7h). Notificação push continua ativa.
* **Notificações em Tempo Real:** Integração total com `ntfy.sh`, com prioridade por severidade (`urgent` / `high` / `default`).
* **Proteção de Dados:** Para serviços Docker e systemd antes de hibernar. Executa `sync` e `hibernate` ao atingir 30% de bateria. Fallback para `poweroff` caso o hibernate falhe.
* **Retomada Automática:** Ao acordar do hibernate, reinicia os serviços que foram parados e envia notificação de confirmação.
* **Notificação de Restauração:** Alerta quando a energia AC é reconectada, informando a carga atual da bateria.
* **Saúde da Bateria:** Notifica semanalmente se a capacidade máxima estiver abaixo de 70% da capacidade original.
* **Rotação de Log:** Mantém o arquivo de log abaixo de 500 KB automaticamente.

## 🛠️ Instalação e Configuração

1. **Instale as dependências:**
   ```bash
   sudo apt update && sudo apt install alsa-utils curl
   ```

2. **Clone o repositório:**
   ```bash
   git clone https://github.com/userm4c/Emergency-Shield-Lnx.git
   cd Emergency-Shield-Lnx
   ```

3. **Configure o script:**
   Edite o arquivo `esl.sh` e ajuste as variáveis na seção `CONFIGURAÇÕES PERSONALIZÁVEIS`:

   | Variável | Descrição |
   |---|---|
   | `LOGFILE` | Caminho do arquivo de log |
   | `NTFY_TOPIC` | Tópico do ntfy.sh para notificações push |
   | `DOCKER_COMPOSE_DIRS` | Caminhos absolutos dos diretórios com `docker-compose.yml` a parar/retomar (separados por espaço) |
   | `SERVICOS_GERENCIADOS` | Serviços systemd a parar antes de hibernar (separados por espaço) |
   | `HORA_SILENCIO_INICIO` | Início do modo silencioso (padrão: `22`) |
   | `HORA_SILENCIO_FIM` | Fim do modo silencioso (padrão: `7`) |
   | `LOG_MAX_KB` | Tamanho máximo do log em KB antes de rotacionar (padrão: `500`) |

4. **Torne-o executável:**
   ```bash
   chmod +x esl.sh
   ```

5. **Automação (Systemd):**
   Crie um serviço e um timer para executar o script a cada minuto:

   `/etc/systemd/system/emergency-shield.service`
   ```ini
   [Unit]
   Description=Emergency Shield Lnx

   [Service]
   Type=oneshot
   ExecStart=/caminho/para/esl.sh
   ```

   `/etc/systemd/system/emergency-shield.timer`
   ```ini
   [Unit]
   Description=Executa Emergency Shield a cada minuto

   [Timer]
   OnBootSec=1min
   OnUnitActiveSec=1min

   [Install]
   WantedBy=timers.target
   ```

   Ative e inicie o timer:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now emergency-shield.timer
   ```

6. **Detecção Instantânea (udev):**
   Por padrão, o timer verifica o estado do AC a cada minuto. Para detecção imediata ao desconectar o carregador, crie uma regra udev que dispara o serviço em tempo real:

   Descubra o nome do seu adaptador AC:
   ```bash
   ls /sys/class/power_supply/
   ```
   Geralmente `AC`, `ADP1` ou `ACAD`. Use esse nome na regra abaixo:

   ```bash
   sudo nano /etc/udev/rules.d/99-emergency-shield.rules
   ```
   ```
   SUBSYSTEM=="power_supply", KERNEL=="ADP1", RUN+="/bin/systemctl --no-block start emergency-shield.service"
   ```
   > Substitua `ADP1` pelo nome do seu adaptador.

   Ative a regra:
   ```bash
   sudo udevadm control --reload-rules
   ```

   O timer continua rodando como fallback para monitorar a bateria durante o uso.

## 📱 Notificações Push
Para receber os alertas no seu smartphone:
1. Baixe o app **ntfy** (disponível para Android e iOS).
2. Inscreva-se no tópico que você definiu na variável `NTFY_TOPIC`.

---
*Developed by UserM4C*
