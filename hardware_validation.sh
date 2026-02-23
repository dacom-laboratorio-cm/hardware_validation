#!/bin/bash

# ==============================================================================
# Script de Validação de Hardware - Workstation Zen 4 / RTX Pro 6000
# Formato: Bash / Requisito: Root/Sudo
# ==============================================================================

# Cores para saída
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

LOG_DIR="./test_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
FINAL_REPORT="$LOG_DIR/Relatorio_Final.md"

echo -e "${GREEN}Iniciando Procedimentos de Teste...${NC}"

# 1. Verificação de Root
if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}Por favor, execute como root (sudo).${NC}"
  exit
fi

# 2. Instalação de Dependências
echo "Instalando ferramentas necessárias..."
apt update && apt install -y stress-ng p7zip-full lm-sensors smartmontools nvme-cli curl wget pandoc texlive-latex-base > /dev/null

# 3. Verificação de Ambiente (Hardware e Kernel)
echo "--- 1. VERIFICAÇÃO DE AMBIENTE ---" | tee -a "$FINAL_REPORT"
echo "Kernel Version:" >> "$FINAL_REPORT"
uname -a | tee -a "$FINAL_REPORT"
echo -e "\nDiscos e Particionamento (lsblk):" >> "$FINAL_REPORT"
lsblk -f | tee -a "$FINAL_REPORT"
echo -e "\nGPU Status (NVIDIA):" >> "$FINAL_REPORT"
nvidia-smi | tee -a "$FINAL_REPORT"

# 4. Saúde do Armazenamento (SMART)
echo -e "\n--- 2. SAÚDE DO ARMAZENAMENTO ---" | tee -a "$FINAL_REPORT"
echo "Verificando SSD e HDD..."
DEVS=$(lsblk -dn -o NAME | grep -E "sd|nvme")
for dev in $DEVS; do
    echo "Relatório para /dev/$dev:" >> "$FINAL_REPORT"
    smartctl -a "/dev/$dev" | grep -E "Model Family|Device Model|Power On Hours|Total_Written|Raw_Read_Error_Rate" >> "$FINAL_REPORT"
    echo "-----------------------------------" >> "$FINAL_REPORT"
done

# 5. Benchmarking CPU/RAM (7-Zip)
echo -e "\n--- 3. BENCHMARK CPU E RAM (7-ZIP) ---" | tee -a "$FINAL_REPORT"
echo "Executando 7z benchmark..."
7z b >> "$FINAL_REPORT"

# 6. Monitoramento de Sensores (Background)
# Inicia log de temperatura em background durante os testes pesados
(while true; do date; sensors; nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader; sleep 60; done) > "$LOG_DIR/thermal_logs.txt" &
SENSOR_PID=$!

# 7. Prova de Estabilidade (Stress-ng) - 60 Minutos
echo -e "\n--- 4. TESTE DE ESTRESSE TÉRMICO (STRESS-NG) ---" | tee -a "$FINAL_REPORT"
echo "Iniciando estresse por 60 minutos. Aguarde..."
stress-ng --cpu 48 --io 4 --vm 2 --vm-bytes 128G --timeout 60m --metrics-brief >> "$FINAL_REPORT" 2>&1

# 8. Benchmarking GPU (Blender CLI)
echo -e "\n--- 5. BENCHMARK GPU (BLENDER OPTIX) ---" | tee -a "$FINAL_REPORT"
if ! command -v blender-benchmark-cli &> /dev/null; then
    echo "Baixando Blender Benchmark CLI..."
    wget -O blender-benchmark-cli.tar.gz "https://opendata.blender.org/download/blender-benchmark-cli-3.1.0-linux.tar.gz"
    tar -xvf blender-benchmark-cli.tar.gz
    chmod +x blender-benchmark-cli
fi

echo "Executando cenas: Monster, Junkshop, Classroom..."
./blender-benchmark-cli benchmark --device-type OPTIX monster junkshop classroom >> "$FINAL_REPORT"

# Finaliza monitoramento de sensores
kill $SENSOR_PID

# 9. Consolidação de Temperaturas Máximas
echo -e "\n--- 6. RESUMO TÉRMICO ---" | tee -a "$FINAL_REPORT"
echo "Temperaturas Máximas Registradas:" >> "$FINAL_REPORT"
grep "Package id 0:" "$LOG_DIR/thermal_logs.txt" | awk '{print $4}' | sort -n | tail -1 | xargs echo "CPU Max Temp:" >> "$FINAL_REPORT"
cat "$LOG_DIR/thermal_logs.txt" | grep -v "CPU" | grep -E "^[0-9]+$" | sort -n | tail -1 | xargs echo "GPU Max Temp:" >> "$FINAL_REPORT"

# 10. Geração do PDF
echo "Convertendo relatório para PDF..."
pandoc "$FINAL_REPORT" -o "$LOG_DIR/Relatorio_Final.pdf"

echo -e "${GREEN}Testes concluídos! Relatório disponível em: $LOG_DIR/Relatorio_Final.pdf${NC}"
