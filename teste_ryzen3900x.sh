#!/bin/bash

# ==============================================================================
# Script de Validação de Hardware - SERVIDOR DELTA (Ryzen 3900X / RTX 3060)
# ==============================================================================

LOG_DIR="./test_results_delta_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
FINAL_REPORT="$LOG_DIR/Relatorio_Delta.md"

echo "--- 1. IDENTIFICAÇÃO DO HARDWARE (DELTA) ---" | tee -a "$FINAL_REPORT"
echo "CPU: AMD Ryzen 9 3900X (12C/24T)" >> "$FINAL_REPORT"
echo "Placa-Mãe: ASUS TUF GAMING X570-PLUS_BR" >> "$FINAL_REPORT"
echo "RAM: 64GB (4x16GB) Asgard DDR4 3200MT/s (Non-ECC)" >> "$FINAL_REPORT"
echo "GPU: NVIDIA GeForce RTX 3060 12GB (Ampere)" >> "$FINAL_REPORT"
uname -a >> "$FINAL_REPORT"

# 2. Saúde do Disco (Ajustado para buscar SSDs comuns e HDDs)
echo -e "\n--- 2. SAÚDE DO ARMAZENAMENTO ---" >> "$FINAL_REPORT"
smartctl -a /dev/nvme0n1 | grep -E "Model Number|Total Units Written|Power On Hours" >> "$FINAL_REPORT" 2>/dev/null
# Adicione outros discos conforme necessário (ex: /dev/sda)

# 3. Teste de Estresse Ajustado (24 Threads / 48GB RAM)
echo -e "\n--- 3. TESTE DE ESTRESSE (60 MINUTOS) ---" | tee -a "$FINAL_REPORT"
echo "Iniciando carga: 24 threads de CPU + 48GB de RAM..."
stress-ng --cpu 24 --io 2 --vm 2 --vm-bytes 48G --timeout 60m --metrics-brief >> "$FINAL_REPORT" 2>&1

# 4. Benchmark CPU/RAM (7-Zip)
echo -e "\n--- 4. BENCHMARK 7-ZIP (INTEGRIDADE DE MEMÓRIA) ---" >> "$FINAL_REPORT"
7z b >> "$FINAL_REPORT"

# 5. Benchmark GPU (Blender com OptiX)
echo -e "\n--- 5. BENCHMARK GPU (BLENDER OPTIX) ---" >> "$FINAL_REPORT"
# O comando assume que o blender-benchmark-cli já foi baixado
if [ -f "./blender-benchmark-cli" ]; then
    ./blender-benchmark-cli benchmark --device-type OPTIX monster junkshop classroom >> "$FINAL_REPORT"
else
    echo "Blender Benchmark CLI não encontrado na pasta atual." >> "$FINAL_REPORT"
fi

# 6. Monitoramento Térmico (Resumo)
echo -e "\n--- 6. SENSORES TÉRMICOS ---" >> "$FINAL_REPORT"
sensors >> "$FINAL_REPORT"
nvidia-smi >> "$FINAL_REPORT"

# Geração do PDF (Requer pandoc e texlive-latex-base)
pandoc "$FINAL_REPORT" -o "$LOG_DIR/Relatorio_Delta.pdf"
echo "Concluído. Relatório em $LOG_DIR/Relatorio_Delta.pdf"
