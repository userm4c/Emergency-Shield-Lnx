# Emergency Shield Lnx — Melhorias e Modificações

> Documento gerado para registro das evoluções feitas no projeto original de [UserM4C](https://github.com/userm4c/Emergency-Shield-Lnx).

---

## Estrutura de Arquivos

O projeto original era composto por um único arquivo `esl.sh`. Após as modificações, a estrutura passou a ser:

```
Emergency-Shield-Lnx/
├── esl.sh                  # Script principal de monitoramento
├── esl.conf                # Configurações separadas (novo)
├── esl-alarme.sh           # Script do alarme em loop (novo)
├── esl-alarme.service      # Unit systemd do alarme (novo)
├── esl-comandos.sh         # Listener de comandos via ntfy (novo)
├── esl-comandos.service    # Unit systemd dos comandos (novo)
└── install.sh              # Instalador automatizado (novo)
```

---

## 1. Arquivo de Configuração Separado (`esl.conf`)

**Motivação:** as variáveis personalizáveis estavam hardcoded no `esl.sh`, o que tornava atualizações via `git pull` arriscadas.

**Solução:** todas as variáveis do usuário foram movidas para `esl.conf`, carregado com `source` no início do script. Agora é possível atualizar o script sem perder configurações.

**Variáveis disponíveis:**
- `LOGFILE` e `ESL_HISTORY` — caminhos dos arquivos de log
- `NTFY_TOPIC` — tópico de notificações push
- `DOCKER_COMPOSE_DIRS` — diretórios com docker-compose a gerenciar
- `SERVICOS_GERENCIADOS` — serviços systemd a parar antes do hibernate
- `LIMITE_HIBERNACAO` — nível de bateria para hibernar (padrão: 30%)
- `LIMITE_DRENO_RAPIDO` — taxa de descarga anormal em %/min (padrão: 2)
- `LIMITE_TEMP_BATERIA` — temperatura máxima da bateria em °C (padrão: 45)
- `LIMITE_SAUDE_BATERIA` — saúde mínima da bateria em % (padrão: 70)
- `HORA_SILENCIO_INICIO` e `HORA_SILENCIO_FIM` — intervalo sem alarme sonoro
- `LOG_MAX_KB` — tamanho máximo do log antes de rotacionar (padrão: 500KB)

---

## 2. Correções de Robustez no `esl.sh`

### `set -e` removido
O `set -euo pipefail` original causava encerramento silencioso do script sempre que qualquer comando retornava não-zero — incluindo `ping`, `kill`, e a lógica booleana do `modo_silencioso`. Substituído por `set -uo pipefail`.

### Leitura dinâmica de status
As variáveis `STATUS_AC` e `CARGA_BATERIA` eram lidas uma única vez no início e nunca atualizadas. Substituídas pelas funções `get_ac_status()` e `get_bateria()`, chamadas dinamicamente.

### Suporte a múltiplas baterias
A função `get_bateria()` agora detecta automaticamente todas as baterias (`BAT0`, `BAT1`, etc.) e soma `energy_now` / `energy_full` para calcular a carga real combinada.

### LOCKFILE com trap estendido
O trap de limpeza do `/tmp/emergencia.lock` foi estendido para `EXIT INT TERM`, evitando que o arquivo fique travado após encerramento abrupto.

### Verificação de dependências
Adicionada a função `verificar_dependencias()` que verifica se `curl`, `amixer` e `speaker-test` estão instalados, registrando aviso no log caso contrário.

### Rotação de log
Adicionada a função `rotar_log()` que mantém o log abaixo do limite definido em `LOG_MAX_KB`, preservando as últimas 100 linhas ao rotacionar.

### Histórico em JSON
Cada evento agora gera uma entrada em `esl_history.json` no formato newline-delimited JSON, compatível com `jq`, Grafana e outras ferramentas de análise.

### `modo_silencioso()` reescrito
A função foi reescrita com `if/then/return` explícitos para evitar comportamento imprevisível com operadores booleanos encadeados.

---

## 3. Alarme em Loop Contínuo

**Problema original:** o alarme tocava 3 bipes e parava, independente do status da energia.

**Solução:** o alarme foi separado em um script e serviço próprios (`esl-alarme.sh` + `esl-alarme.service`), que roda como processo independente do systemd. O loop continua enquanto o AC estiver desconectado e para automaticamente quando a energia é restaurada.

**Modo teste:** o `esl-alarme.sh` aceita a variável de ambiente `ESL_TESTE=1` para tocar por um tempo fixo (`ESL_TESTE_SEG`) sem verificar o status do AC — usado pelo comando `TESTAR_ALARME`.

---

## 4. Novas Verificações Automáticas

### Dreno rápido
Monitora a taxa de descarga da bateria em %/min. Se ultrapassar `LIMITE_DRENO_RAPIDO`, envia alerta urgente. Usa arquivo de referência `/tmp/esl_dreno.txt` para calcular a variação entre execuções.

### Temperatura da bateria
Lê `/sys/class/power_supply/BATx/temp` de todas as baterias detectadas. Alerta se ultrapassar `LIMITE_TEMP_BATERIA`. (Nem todo hardware expõe esse arquivo.)

### Saúde da bateria
Compara `energy_full` com `energy_full_design` para calcular a capacidade real restante. Notifica com prioridade baixa se abaixo de `LIMITE_SAUDE_BATERIA`, com intervalo mínimo de 7 dias entre notificações.

### Updates do sistema
Roda `apt-get update` + `apt-get -s upgrade` uma vez por dia. Notifica quando há pacotes disponíveis, com prioridade alta para updates de segurança. Usa hash MD5 da lista para evitar notificações repetidas para os mesmos pacotes.

---

## 5. Listener de Comandos via ntfy (`esl-comandos.sh`)

Serviço que fica conectado ao endpoint SSE do ntfy (`/json`) e executa comandos recebidos no mesmo tópico. Roda como serviço systemd com `Restart=always`.

### Comandos disponíveis

#### Alarme
| Comando | Descrição |
|---|---|
| `PARAR_ALARME` | Para o alarme imediatamente |
| `MUDO [min]` | Silencia o alarme por X minutos (padrão: 30) |
| `TESTAR_ALARME [seg]` | Toca o alarme por X segundos (padrão: 5) |

#### Informações
| Comando | Descrição |
|---|---|
| `PING` | Verifica se o servidor responde, retorna uptime |
| `STATUS` | Energia, bateria, CPU, RAM, IP local e hora |
| `DISCO` | Uso de disco por partição |
| `PROCESSOS` | Top 5 processos por CPU |
| `HISTORICO` | Últimos 10 eventos do esl_history.json |
| `LOGS` | Últimas 20 linhas do esl.log |
| `UPDATES` | Verifica pacotes disponíveis para atualização |

#### Rede
| Comando | Descrição |
|---|---|
| `IP_EXTERNO` | Retorna o IP público atual |
| `PING_HOST [host]` | Testa conectividade com um host específico |
| `DNS [dominio]` | Resolve um domínio |
| `QUEM_CONECTADO` | Lista usuários logados e últimos acessos |
| `CONEXOES` | Conexões de rede ativas |

#### Docker
| Comando | Descrição |
|---|---|
| `STATUS_DOCKER` | Lista containers em execução |
| `REINICIAR_SERVICOS` | Sobe todos os docker-compose |
| `PARAR_SERVICOS` | Para todos os docker-compose |
| `REINICIAR_CONTAINER [nome]` | Reinicia um container específico |
| `LOGS_CONTAINER [nome]` | Últimas 20 linhas do log de um container |

#### Energia e Sistema
| Comando | Descrição |
|---|---|
| `HIBERNAR` | Hiberna o servidor (10s de delay) |
| `REINICIAR` | Reinicia o servidor (10s de delay) |
| `AGENDAR_REINICIO [HH:MM]` | Agenda reinício para o horário informado |
| `CANCELAR_REINICIO` | Cancela reinício agendado |
| `DESLIGAR` | Desliga o servidor (10s de delay) |
| `LIMPAR_KERNELS` | Remove kernels antigos via apt autoremove |
| `AJUDA` | Exibe lista de comandos disponíveis |

---

## 6. Instalador Automatizado (`install.sh`)

Script que automatiza toda a instalação:
- Verifica e instala dependências (`alsa-utils`, `curl`, `iputils-ping`, `iproute2`)
- Define permissões de execução
- Detecta automaticamente o adaptador AC e as baterias
- Cria os arquivos de unit systemd (`emergency-shield.service`, `emergency-shield.timer`, `esl-alarme.service`, `esl-comandos.service`)
- Cria regra udev para detecção instantânea de mudança no AC
- Ativa e inicia todos os serviços

**Uso:**
```bash
sudo bash install.sh
```

---

## Comandos Úteis de Manutenção

```bash
# Reiniciar o listener de comandos após atualizar esl-comandos.sh
sudo systemctl restart esl-comandos.service

# Recarregar configurações do systemd após editar arquivos .service
sudo systemctl daemon-reload

# Ver logs do ESL em tempo real
journalctl -fu emergency-shield.service

# Ver logs do listener de comandos
journalctl -fu esl-comandos.service

# Testar o script manualmente
sudo rm -f /tmp/emergencia.lock && sudo bash -x ~/Emergency-Shield-Lnx/esl.sh

# Verificar espaço em /boot
df -h /boot

# Listar kernels instalados
dpkg --list | grep linux-image
```

---

*Última atualização: maio de 2026*
