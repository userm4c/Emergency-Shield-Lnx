#!/bin/bash
# Serviço de alarme independente do ESL.
# Roda em loop até a energia ser restaurada.
# Modo teste: ESL_TESTE=1 toca por N segundos ignorando o status do AC.

AC_NAME=$(ls /sys/class/power_supply/ | grep -E 'AC|ADP|ACAD' | head -n 1)

amixer -c 1 set Master 100% unmute > /dev/null 2>&1 || true

if [ "${ESL_TESTE:-0}" = "1" ]; then
    # Modo teste: toca por ESL_TESTE_SEG segundos e para
    fim=$(( $(date +%s) + ${ESL_TESTE_SEG:-5} ))
    while [ "$(date +%s)" -lt "$fim" ]; do
        speaker-test -D plughw:1,0 -t sine -f 1000 -l 1 > /dev/null 2>&1 &
        spk_pid=$!
        sleep 0.8
        kill "$spk_pid" 2>/dev/null || true
        wait "$spk_pid" 2>/dev/null || true
        sleep 0.3
    done
else
    # Modo normal: toca enquanto AC estiver desconectado
    while [ "$(cat /sys/class/power_supply/$AC_NAME/online 2>/dev/null)" = "0" ]; do
        speaker-test -D plughw:1,0 -t sine -f 1000 -l 1 > /dev/null 2>&1 &
        spk_pid=$!
        sleep 0.8
        kill "$spk_pid" 2>/dev/null || true
        wait "$spk_pid" 2>/dev/null || true
        sleep 0.3
    done
fi
