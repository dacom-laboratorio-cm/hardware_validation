#!/bin/bash

# ==============================================================================
# Script de Validação de Hardware - SERVIDOR DELTA (V4 - Link Blender Corrigido)
# ==============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

LOG_DIR="./test_results_delta_$(date +%Y%m%d_%H%M%S)"
FINAL_REPORT_MD="$LOG_DIR/Relatorio_Delta.md"
BLENDER_URL="https://download.blender.org/release/BlenderBenchmark2.0/launcher/benchmark-launcher-3.1.0-linux.tar.gz"

if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}Erro: Execute como root (sudo).${NC}"
  exit 1
fi

mkdir -p "$LOG_DIR"

# 1. Instalação de Dependências (Incluindo pacotes extras de PDF)
echo -e "${GREEN}>>> 1. Instalando dependências e pacotes LaTeX para PDF...${NC}"
apt update
apt install -y stress-ng p7zip-full smartmontools lm-sensors nvme-cli wget curl \
               pandoc texlive-latex-base texlive-latex-extra texlive-fonts-recommended \
               nvidia-utils-550 > /dev/null

# 2. Verificação de GPU
echo -e "${GREEN}>>> 2. Verificando integridade da GPU...${NC}"
if ! nvidia-smi &> /dev/null; then
    echo -e "${RED}AVISO: Driver NVIDIA com erro (Mismatch). REINICIE O SERVIDOR.${NC}"
fi

{
    echo "# RELATÓRIO TÉCNICO DE HARDWARE - SERVIDOR DELTA"
    echo "Executado em: $(date)"
    echo "---"
    echo "## 1. IDENTIFICAÇÃO DO SISTEMA"
    echo "- **CPU:** AMD Ryzen 9 3900X (12C/24T)"
    echo "- **GPU:** $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo 'Erro: Driver Mismatch ou GPU Ausente')"
    echo "- **Kernel:** $(uname -r)"
    
    echo -e "\n## 2. SAÚDE DOS DISCOS (S.M.A.R.T)"
    for dev in $(lsblk -dn -o NAME | grep -v "loop"); do
        echo "### Disco: /dev/$dev"
        smartctl -i -A "/dev/$dev" | grep -E "Model|Number|Hours|Written|Percentage|Status" || echo "SMART indisponível"
        echo -e "\n"
    done
} > "$FINAL_REPORT_MD"

# 3. Teste de Estresse (60 min)
echo -e "${GREEN}>>> 3. Iniciando Estresse Térmico (60 min)...${NC}"
(while true; do 
    sensors | grep -E "Tctl|Package" | awk '{print $2}' | tr -d '+' | tr -d '°C' >> "$LOG_DIR/cpu_temp.log"
    nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null >> "$LOG_DIR/gpu_temp.log"
    sleep 60
done) &
MONITOR_PID=$!

stress-ng --cpu 24 --io 2 --vm 2 --vm-bytes 48G --timeout 60m --metrics-brief >> "$FINAL_REPORT_MD" 2>&1

kill $MONITOR_PID

# 4. Benchmark 7-Zip (CPU/RAM)
echo -e "${GREEN}>>> 4. Executando Benchmark 7-Zip...${NC}"
echo -e "\n## 3. BENCHMARK 7-ZIP (INTEGRIDADE)" >> "$FINAL_REPORT_MD"
7z b >> "$FINAL_REPORT_MD"

# 5. Benchmark GPU (Link fornecido pelo usuário)
echo -e "${GREEN}>>> 5. Preparando Blender Benchmark...${NC}"
if [ ! -f "./blender-benchmark-cli" ]; then
    wget "$BLENDER_URL" -O blender_pkg.tar.gz
    # O pacote launcher contém o executável dentro de uma pasta
    tar -xzf blender_pkg.tar.gz
    # Localiza o executável cli dentro da pasta extraída
    find . -name "blender-benchmark-cli" -exec cp {} . \;
    chmod +x blender-benchmark-cli
fi

if [ -f "./blender-benchmark-cli" ]; then
    echo "Iniciando renderização de cenas (Monster, Junkshop, Classroom)..."
    echo -e "\n## 4. BENCHMARK GPU (BLENDER OPTIX)" >> "$FINAL_REPORT_MD"
    ./blender-benchmark-cli benchmark --device-type OPTIX monster junkshop classroom >> "$FINAL_REPORT_MD" 2>&1
else
    echo -e "${RED}Erro: Não foi possível configurar o Blender Benchmark CLI.${NC}"
fi

# 6. Resumo Térmico e Geração de PDF
echo -e "${GREEN}>>> 6. Finalizando Relatório e Gerando PDF...${NC}"
CPU_MAX=$(sort -n "$LOG_DIR/cpu_temp.log" | tail -1)
GPU_MAX=$(sort -n "$LOG_DIR/gpu_temp.log" | tail -1)

{
    echo -e "\n## 5. RESUMO TÉRMICO"
    echo "- Temperatura Máxima CPU: ${CPU_MAX}°C"
    echo "- Temperatura Máxima GPU: ${GPU_MAX:-'N/A'}°C"
    if (( $(echo "$CPU_MAX > 94" | bc -l) )); then
        echo "  - **ALERTA:** A CPU atingiu o limite de 95°C durante o teste."
    fi
} >> "$FINAL_REPORT_MD"

# Conversão para PDF
pandoc "$FINAL_REPORT_MD" -o "$LOG_DIR/Relatorio_Final_Delta.pdf"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Sucesso! Relatório gerado: $LOG_DIR/Relatorio_Final_Delta.pdf${NC}"
else
    echo -e "${RED}Erro ao gerar PDF. O relatório em Markdown está disponível em $FINAL_REPORT_MD${NC}"
fi
