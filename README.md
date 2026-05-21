# 🛡️ Emergency-Shield-Lnx - ESL

> **Status:** Operational
> **Goal:** Data Integrity & Power Management

Este script transforma notebooks em servidores resilientes, utilizando a bateria interna como um UPS (Nobreak) inteligente com monitoramento progressivo.

## 🚀 Funcionalidades
* **Monitoramento AC:** Detecta instantaneamente a perda de energia externa.
* **Alertas Progressivos:** Notificações via Push a cada 10% de queda na bateria (90%, 80%, 70%...).
* **Triagem de Rede:** Diferencia quedas de energia gerais de desconexões acidentais de cabo.
* **Alerta Sonoro:** Alarme intermitente via `amixer` e `speaker-test` em eventos críticos.
* **Notificações em Tempo Real:** Integração total com `ntfy.sh`.
* **Proteção de Dados:** Executa `sync` e `hibernate` automaticamente ao atingir 30% de bateria. Fallback para `poweroff` caso o hibernate falhe.
* **Notificação de Restauração:** Alerta quando a energia AC é reconectada, informando a carga atual da bateria.

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
   Edite o arquivo `esl.sh` e altere as variáveis `LOGFILE` e `NTFY_TOPIC`.

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

## 📱 Notificações Push
Para receber os alertas no seu smartphone:
1. Baixe o app **ntfy** (disponível para Android e iOS).
2. Inscreva-se no tópico que você definiu na variável `NTFY_TOPIC`.

---
*Developed by UserM4C - Hacker do Bem*
