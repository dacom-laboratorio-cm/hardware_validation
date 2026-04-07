#!/bin/bash

set -u

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DURATION_MIN=120
DEFAULT_LOG_DIR="$SCRIPT_DIR/test_results_$(date +%Y%m%d_%H%M%S)"

CATALOGO_PDF=""
DURACAO_MIN="$DEFAULT_DURATION_MIN"
LOG_DIR="$DEFAULT_LOG_DIR"
AUTO_INSTALL_NVIDIA_DRIVER="yes"

FINAL_REPORT=""
CATALOG_TEXT_RAW=""
CATALOG_TEXT_NORM=""
INVENTORY_FILE=""
COMPARE_FILE=""
THERMAL_LOG=""
SENSOR_PID=""
NVIDIA_REBOOT_REQUIRED="no"

warn() {
  echo -e "${YELLOW}[AVISO]${NC} $*"
}

info() {
  echo -e "${GREEN}[INFO]${NC} $*"
}

fail() {
  echo -e "${RED}[ERRO]${NC} $*"
  exit 1
}

usage() {
  cat <<EOF
Uso: sudo ./hardware_validation.sh --catalogo-pdf /caminho/catalogo.pdf [--duracao 120] [--saida ./resultado]

Parametros:
  --catalogo-pdf   Caminho do catalogo em PDF (obrigatorio)
  --duracao        Duracao do stress principal em minutos (default: ${DEFAULT_DURATION_MIN})
  --saida          Diretorio de saida dos logs e relatorio
  --nao-instalar-driver-nvidia
                   Desativa instalacao automatica de driver NVIDIA
  --instalar-driver-nvidia
                   Forca habilitacao da instalacao automatica de driver NVIDIA
  --help           Exibe esta ajuda
EOF
}

cleanup() {
  if [[ -n "${SENSOR_PID}" ]] && kill -0 "$SENSOR_PID" 2>/dev/null; then
    kill "$SENSOR_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT

normalize_text() {
  tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/ /g' |
    sed -E 's/[[:space:]]+/ /g' |
    sed -E 's/^ +| +$//g'
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --catalogo-pdf)
        CATALOGO_PDF="$2"
        shift 2
        ;;
      --duracao)
        DURACAO_MIN="$2"
        shift 2
        ;;
      --saida)
        LOG_DIR="$2"
        shift 2
        ;;
      --instalar-driver-nvidia)
        AUTO_INSTALL_NVIDIA_DRIVER="yes"
        shift
        ;;
      --nao-instalar-driver-nvidia)
        AUTO_INSTALL_NVIDIA_DRIVER="no"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "Parametro invalido: $1"
        ;;
    esac
  done

  [[ -z "$CATALOGO_PDF" ]] && fail "Informe --catalogo-pdf com o arquivo de catalogo."
  [[ ! -f "$CATALOGO_PDF" ]] && fail "Catalogo PDF nao encontrado: $CATALOGO_PDF"
  [[ "$DURACAO_MIN" =~ ^[0-9]+$ ]] || fail "--duracao deve ser numerico em minutos."
}

ensure_root() {
  if [[ "$EUID" -ne 0 ]]; then
    fail "Execute como root (sudo)."
  fi
}

install_dependencies() {
  info "Instalando dependencias necessarias..."
  if ! command_exists apt-get; then
    fail "Este script suporta instalacao automatica com apt-get."
  fi

  apt-get update >/dev/null
  apt-get install -y \
    stress-ng p7zip-full lm-sensors smartmontools nvme-cli fio \
    wget curl dmidecode lshw pciutils ethtool poppler-utils \
    tesseract-ocr ocrmypdf ubuntu-drivers-common >/dev/null
}

ensure_nvidia_driver_if_requested() {
  local has_nvidia_gpu="no"
  local missing_nvidia_smi="no"

  if lspci | grep -Eiq 'nvidia'; then
    has_nvidia_gpu="yes"
  fi

  if ! command_exists nvidia-smi || ! nvidia-smi >/dev/null 2>&1; then
    missing_nvidia_smi="yes"
  fi

  if [[ "$has_nvidia_gpu" == "yes" && "$missing_nvidia_smi" == "no" ]]; then
    info "GPU NVIDIA detectada com driver funcional. Nenhuma instalacao de driver sera realizada."
    return
  fi

  if [[ "$has_nvidia_gpu" == "yes" && "$missing_nvidia_smi" == "yes" ]]; then
    if [[ "$AUTO_INSTALL_NVIDIA_DRIVER" == "yes" ]]; then
      warn "GPU NVIDIA detectada sem driver funcional. Instalando driver NVIDIA mais recente..."
      if command_exists ubuntu-drivers; then
        if ubuntu-drivers autoinstall >/dev/null 2>&1; then
          NVIDIA_REBOOT_REQUIRED="yes"
          fail "Driver NVIDIA instalado/atualizado com sucesso. Reinicie o servidor para continuar o script."
        else
          fail "Falha ao instalar driver NVIDIA automaticamente. Corrija o driver e execute novamente."
        fi
      else
        fail "ubuntu-drivers nao disponivel para instalacao automatica do driver NVIDIA."
      fi
    else
      fail "GPU NVIDIA detectada sem driver funcional e instalacao automatica desativada. Remova --nao-instalar-driver-nvidia ou instale manualmente."
    fi
  fi
}

extract_catalog_text() {
  CATALOG_TEXT_RAW="$LOG_DIR/catalogo_extraido.txt"
  CATALOG_TEXT_NORM="$LOG_DIR/catalogo_extraido.normalizado.txt"
  local ocr_pdf="$LOG_DIR/catalogo_ocr.pdf"

  info "Extraindo texto do catalogo PDF..."
  if command_exists pdftotext; then
    pdftotext -layout "$CATALOGO_PDF" "$CATALOG_TEXT_RAW" 2>/dev/null || true
  fi

  if [[ ! -s "$CATALOG_TEXT_RAW" ]] || [[ $(wc -l < "$CATALOG_TEXT_RAW") -lt 15 ]]; then
    warn "Baixa extracao textual no PDF. Tentando OCR..."
    if command_exists ocrmypdf && command_exists tesseract; then
      ocrmypdf --force-ocr --skip-text "$CATALOGO_PDF" "$ocr_pdf" >/dev/null 2>&1 || true
      if [[ -f "$ocr_pdf" ]]; then
        pdftotext -layout "$ocr_pdf" "$CATALOG_TEXT_RAW" 2>/dev/null || true
      fi
    fi
  fi

  [[ -s "$CATALOG_TEXT_RAW" ]] || fail "Nao foi possivel extrair texto do PDF."
  normalize_text < "$CATALOG_TEXT_RAW" > "$CATALOG_TEXT_NORM"
}

get_disk_hours() {
  local dev_name="$1"
  local dev_path="/dev/$dev_name"

  if [[ "$dev_name" == nvme* ]]; then
    if command_exists nvme; then
      nvme smart-log "$dev_path" 2>/dev/null | awk -F: '/power_on_hours/ {gsub(/ /, "", $2); print $2; exit}'
      return
    fi
  fi

  if command_exists smartctl; then
    local hours
    hours=$(smartctl -a "$dev_path" 2>/dev/null | awk -F: '/Power On Hours/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
    if [[ -n "$hours" ]]; then
      echo "$hours"
      return
    fi

    # Fallback para atributo SMART 9 quando o campo formatado nao aparece.
    hours=$(smartctl -A "$dev_path" 2>/dev/null | awk '$1 == 9 {print $10; exit}')
    [[ -n "$hours" ]] && echo "$hours"
    return
  fi

  echo "N/A"
}

collect_inventory() {
  INVENTORY_FILE="$LOG_DIR/inventario_detectado.md"
  local cpu_vendor cpu_model cpu_cores cpu_threads
  local board_vendor board_name bios_version
  local ram_total_gb

  cpu_vendor=$(lscpu | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
  cpu_model=$(lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
  cpu_cores=$(lscpu | awk -F: '/^CPU\(s\)/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
  cpu_threads=$(lscpu | awk -F: '/Thread\(s\) per core/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')

  board_vendor=$(dmidecode -s baseboard-manufacturer 2>/dev/null || echo "N/A")
  board_name=$(dmidecode -s baseboard-product-name 2>/dev/null || echo "N/A")
  bios_version=$(dmidecode -s bios-version 2>/dev/null || echo "N/A")

  ram_total_gb=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)

  {
    echo "# Inventario Detectado"
    echo
    echo "## CPU"
    echo "- Fabricante: ${cpu_vendor:-N/A}"
    echo "- Modelo: ${cpu_model:-N/A}"
    echo "- CPUs logicas: ${cpu_cores:-N/A}"
    echo "- Threads por core: ${cpu_threads:-N/A}"
    echo
    echo "## Placa Mae e BIOS"
    echo "- Fabricante: ${board_vendor:-N/A}"
    echo "- Modelo: ${board_name:-N/A}"
    echo "- BIOS: ${bios_version:-N/A}"
    echo
    echo "## Memoria"
    echo "- RAM total (GB): ${ram_total_gb:-N/A}"
    echo "- Modulos detectados:"
    dmidecode -t memory 2>/dev/null | awk '
      /Memory Device$/ {slot=""; size=""; speed=""; type=""; locator=""; rank=""; inblk=1; next}
      inblk && /Locator:/ {locator=$2}
      inblk && /Size:/ {if ($2 != "No") size=$2 " " $3}
      inblk && /Type:/ && $2 != "Unknown" {type=$2}
      inblk && /Speed:/ && $2 != "Unknown" {speed=$2 " " $3}
      inblk && /Rank:/ {rank=$2}
      inblk && /^$/ {
        if (size != "") {
          printf("  - %s | %s | %s | %s\n", locator, size, type, speed)
        }
        inblk=0
      }
    '
    echo
    echo "## GPU"
    if lspci | grep -Eiq 'VGA|3D|Display'; then
      lspci | grep -Ei 'VGA|3D|Display' | sed 's/^/- /'
      if command_exists nvidia-smi && nvidia-smi >/dev/null 2>&1; then
        echo "- NVIDIA detalhado:"
        nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | sed 's/^/  - /'
      fi
    else
      echo "- Nao detectado"
    fi
    echo
    echo "## Discos"
    while read -r dev; do
      [[ -z "$dev" ]] && continue
      local model serial size rota tran hours
      model=$(lsblk -dn -o MODEL "/dev/$dev" 2>/dev/null | sed 's/^ *//;s/ *$//')
      serial=$(lsblk -dn -o SERIAL "/dev/$dev" 2>/dev/null | sed 's/^ *//;s/ *$//')
      size=$(lsblk -dn -o SIZE "/dev/$dev" 2>/dev/null | sed 's/^ *//;s/ *$//')
      rota=$(lsblk -dn -o ROTA "/dev/$dev" 2>/dev/null | sed 's/^ *//;s/ *$//')
      tran=$(lsblk -dn -o TRAN "/dev/$dev" 2>/dev/null | sed 's/^ *//;s/ *$//')
      hours=$(get_disk_hours "$dev")
      echo "- /dev/$dev | Modelo: ${model:-N/A} | Serial: ${serial:-N/A} | Tamanho: ${size:-N/A} | Interface: ${tran:-N/A} | ROTA: ${rota:-N/A} | Horas: ${hours:-N/A}"
    done < <(lsblk -dn -o NAME,TYPE | awk '$2 == "disk" {print $1}')
    echo
    echo "## NIC / Rede"
    if lspci | grep -Eiq 'Ethernet controller|Network controller'; then
      lspci | grep -Ei 'Ethernet controller|Network controller' | sed 's/^/- /'
    else
      echo "- Controladora de rede nao detectada"
    fi

    while read -r iface; do
      [[ "$iface" == "lo" ]] && continue
      local speed
      speed=$(ethtool "$iface" 2>/dev/null | awk -F: '/Speed/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
      echo "- Interface: $iface | Velocidade: ${speed:-N/A}"
    done < <(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1)

    echo
    echo "## PSU"
    echo "- Fonte de alimentacao geralmente nao e detectavel com confianca por software em servidores/workstations sem telemetria dedicada."
  } > "$INVENTORY_FILE"
}

start_thermal_monitor() {
  THERMAL_LOG="$LOG_DIR/thermal_logs.txt"
  (
    while true; do
      echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="
      if command_exists sensors; then
        sensors
      fi
      if command_exists nvidia-smi && nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader
      fi
      sleep 60
    done
  ) > "$THERMAL_LOG" 2>&1 &
  SENSOR_PID=$!
}

run_benchmarks() {
  info "Executando benchmark 7z (CPU/RAM)..."
  7z b > "$LOG_DIR/benchmark_7z.log" 2>&1 || warn "7z retornou codigo nao zero."

  info "Executando stress principal por ${DURACAO_MIN} minutos..."
  stress-ng --cpu 0 --io 4 --vm 2 --vm-bytes 70% --timeout "${DURACAO_MIN}m" --metrics-brief \
    > "$LOG_DIR/stress_ng.log" 2>&1 || warn "stress-ng retornou codigo nao zero."

  info "Executando benchmark de disco com fio (nao destrutivo)..."
  fio --name=validation-randrw \
    --filename="$LOG_DIR/fio_test.bin" \
    --size=2G \
    --rw=randrw \
    --rwmixread=70 \
    --bs=4k \
    --ioengine=libaio \
    --iodepth=32 \
    --direct=1 \
    --runtime=180 \
    --time_based \
    --group_reporting \
    > "$LOG_DIR/fio.log" 2>&1 || warn "fio retornou codigo nao zero."

  rm -f "$LOG_DIR/fio_test.bin"

  info "Executando benchmark de GPU (quando disponivel)..."
  if command_exists nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    local blender_bin="$SCRIPT_DIR/blender-benchmark-cli"
    local blender_pkg="$SCRIPT_DIR/blender-benchmark-cli.tar.gz"
    local blender_url="https://download.blender.org/release/BlenderBenchmark2.0/launcher/benchmark-launcher-3.1.0-linux.tar.gz"

    if [[ ! -x "$blender_bin" ]]; then
      wget -O "$blender_pkg" "$blender_url" >/dev/null 2>&1 || true
      tar -xzf "$blender_pkg" -C "$SCRIPT_DIR" >/dev/null 2>&1 || true
      find "$SCRIPT_DIR" -name blender-benchmark-cli -type f -exec cp {} "$blender_bin" \; 2>/dev/null || true
      chmod +x "$blender_bin" 2>/dev/null || true
    fi

    if [[ -x "$blender_bin" ]]; then
      "$blender_bin" benchmark --device-type OPTIX monster junkshop classroom \
        > "$LOG_DIR/blender_gpu.log" 2>&1 || warn "Benchmark GPU retornou codigo nao zero."
    else
      echo "SKIP: Blender Benchmark CLI indisponivel." > "$LOG_DIR/blender_gpu.log"
    fi
  else
    echo "SKIP: GPU NVIDIA nao detectada ou driver indisponivel." > "$LOG_DIR/blender_gpu.log"
  fi
}

get_expected_line() {
  local component="$1"
  case "$component" in
    cpu)
      grep -Ei 'cpu|processador' "$CATALOG_TEXT_RAW" | head -n 1
      ;;
    placa_mae)
      grep -Ei 'placa mae|motherboard|mainboard|baseboard' "$CATALOG_TEXT_RAW" | head -n 1
      ;;
    ram)
      grep -Ei 'memoria|ram|ddr' "$CATALOG_TEXT_RAW" | head -n 1
      ;;
    gpu)
      grep -Ei 'gpu|placa de video|video card|rtx|quadro|nvidia|amd radeon' "$CATALOG_TEXT_RAW" | head -n 1
      ;;
    disco)
      grep -Ei 'ssd|hdd|nvme|disco|armazenamento|storage' "$CATALOG_TEXT_RAW" | head -n 1
      ;;
    nic)
      grep -Ei 'ethernet|nic|rede|network' "$CATALOG_TEXT_RAW" | head -n 1
      ;;
  esac
}

contains_in_catalog_norm() {
  local text="$1"
  local norm
  norm=$(printf '%s' "$text" | normalize_text)
  [[ -z "$norm" ]] && return 1
  grep -Fq "$norm" "$CATALOG_TEXT_NORM"
}

compare_component() {
  local component="$1"
  local detected="$2"
  local expected_line status

  if [[ -z "$detected" ]] || [[ "$detected" == "N/A" ]]; then
    status="NAO_DETECTADO"
  else
    expected_line=$(get_expected_line "$component" || true)
    if [[ -z "$expected_line" ]]; then
      status="NAO_INFORMADO_NO_CATALOGO"
    elif contains_in_catalog_norm "$detected"; then
      status="OK"
    else
      status="DIVERGENTE"
    fi
  fi

  printf "| %s | %s | %s | %s |\n" "$component" "$status" "${detected:-N/A}" "${expected_line:-N/A}" >> "$COMPARE_FILE"
}

run_comparison() {
  COMPARE_FILE="$LOG_DIR/comparacao_catalogo.md"
  local cpu_model board_name ram_total gpu_name disk_model nic_model

  cpu_model=$(lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
  board_name=$(dmidecode -s baseboard-product-name 2>/dev/null || echo "N/A")
  ram_total=$(awk '/MemTotal/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo)
  gpu_name=$(lspci | grep -Ei 'VGA|3D|Display' | head -n 1 | sed 's/^.*: //')
  disk_model=$(lsblk -dn -o MODEL | sed '/^$/d' | head -n 1 | sed 's/^ *//;s/ *$//')
  nic_model=$(lspci | grep -Ei 'Ethernet controller|Network controller' | head -n 1 | sed 's/^.*: //')

  {
    echo "# Comparacao com Catalogo"
    echo
    echo "| Componente | Status | Detectado | Referencia no Catalogo |"
    echo "|---|---|---|---|"
  } > "$COMPARE_FILE"

  compare_component "cpu" "$cpu_model"
  compare_component "placa_mae" "$board_name"
  compare_component "ram" "$ram_total"
  compare_component "gpu" "$gpu_name"
  compare_component "disco" "$disk_model"
  compare_component "nic" "$nic_model"
}

thermal_summary() {
  local cpu_max gpu_max
  cpu_max=$(grep -Eo '[+]?[0-9]+(\.[0-9]+)?°C' "$THERMAL_LOG" 2>/dev/null | tr -d '+°C' | sort -n | tail -n 1)
  gpu_max=$(grep -Eo '^[0-9]+([.][0-9]+)?' "$THERMAL_LOG" 2>/dev/null | sort -n | tail -n 1)
  echo "${cpu_max:-N/A}|${gpu_max:-N/A}"
}

write_final_report() {
  FINAL_REPORT="$LOG_DIR/Relatorio_Final.md"
  local summary ok_count div_count nd_count ni_count cpu_max gpu_max
  summary=$(thermal_summary)
  cpu_max="${summary%%|*}"
  gpu_max="${summary##*|}"

  ok_count=$(grep -c '| OK |' "$COMPARE_FILE" 2>/dev/null || true)
  div_count=$(grep -c '| DIVERGENTE |' "$COMPARE_FILE" 2>/dev/null || true)
  nd_count=$(grep -c '| NAO_DETECTADO |' "$COMPARE_FILE" 2>/dev/null || true)
  ni_count=$(grep -c '| NAO_INFORMADO_NO_CATALOGO |' "$COMPARE_FILE" 2>/dev/null || true)

  {
    echo "# Relatorio Final de Validacao de Hardware"
    echo
    echo "- Data/Hora: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- Catalogo PDF: $CATALOGO_PDF"
    echo "- Duracao stress (min): $DURACAO_MIN"
    echo "- Diretorio de logs: $LOG_DIR"
    echo "- Instalacao automatica driver NVIDIA: $AUTO_INSTALL_NVIDIA_DRIVER"
    echo "- Reboot necessario apos driver NVIDIA: $NVIDIA_REBOOT_REQUIRED"
    echo
    echo "## Resumo Executivo"
    echo "- Itens OK: $ok_count"
    echo "- Itens DIVERGENTES: $div_count"
    echo "- Itens NAO_DETECTADOS: $nd_count"
    echo "- Itens NAO_INFORMADOS_NO_CATALOGO: $ni_count"
    echo "- Temperatura maxima CPU: ${cpu_max} C"
    echo "- Temperatura maxima GPU: ${gpu_max} C"
    echo
    if [[ "$div_count" -eq 0 && "$nd_count" -eq 0 ]]; then
      echo "## Conclusao"
      echo "PASS"
    else
      echo "## Conclusao"
      echo "FAIL"
    fi

    echo
    echo "## Inventario"
    cat "$INVENTORY_FILE"
    echo
    echo "## Conformidade com Catalogo"
    cat "$COMPARE_FILE"
    echo
    echo "## Evidencias de Benchmark"
    echo "### 7z (CPU/RAM)"
    echo '```text'
    tail -n 80 "$LOG_DIR/benchmark_7z.log" 2>/dev/null || true
    echo '```'
    echo
    echo "### stress-ng"
    echo '```text'
    tail -n 80 "$LOG_DIR/stress_ng.log" 2>/dev/null || true
    echo '```'
    echo
    echo "### fio (disco)"
    echo '```text'
    tail -n 80 "$LOG_DIR/fio.log" 2>/dev/null || true
    echo '```'
    echo
    echo "### blender benchmark (gpu)"
    echo '```text'
    tail -n 80 "$LOG_DIR/blender_gpu.log" 2>/dev/null || true
    echo '```'
  } > "$FINAL_REPORT"
}

main() {
  parse_args "$@"
  ensure_root

  mkdir -p "$LOG_DIR"

  info "Iniciando validacao de hardware..."
  install_dependencies
  ensure_nvidia_driver_if_requested
  extract_catalog_text
  collect_inventory

  start_thermal_monitor
  run_benchmarks
  cleanup

  run_comparison
  write_final_report

  info "Concluido. Relatorio final em Markdown: $FINAL_REPORT"
}

main "$@"
