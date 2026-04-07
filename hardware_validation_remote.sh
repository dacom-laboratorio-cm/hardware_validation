#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_MAIN_SCRIPT="$SCRIPT_DIR/hardware_validation.sh"

SSH_USER=""
SSH_HOST=""
SSH_PORT="22"
SSH_KEY=""
REMOTE_BASE_DIR="/tmp"
CATALOGO_PDF=""
DURACAO_MIN="120"
LOCAL_OUTPUT_DIR="$SCRIPT_DIR/remote_results"
USE_SUDO="yes"
SUDO_PASS=""
AUTO_INSTALL_NVIDIA_DRIVER="yes"

REMOTE_RUN_ID="hardware_validation_$(date +%Y%m%d_%H%M%S)"
REMOTE_WORKDIR=""
REMOTE_RESULTS_DIR=""

info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[AVISO]${NC} $*"
}

fail() {
    echo -e "${RED}[ERRO]${NC} $*"
    exit 1
}

usage() {
    cat <<EOF
Uso:
  ./hardware_validation_remote.sh \
    --host <ip-ou-hostname> \
    --user <usuario-ssh> \
    --catalogo-pdf /caminho/catalogo.pdf \
    [--duracao 120] [--port 22] [--key /caminho/chave] \
    [--remote-base-dir /tmp] [--saida-local ./remote_results] \
    [--sem-sudo] [--sudo-pass 'senha'] [--nao-instalar-driver-nvidia]

Parametros obrigatorios:
  --host            Host remoto
  --user            Usuario SSH
  --catalogo-pdf    PDF do catalogo local (sera enviado ao host remoto)

Parametros opcionais:
  --duracao         Duracao de stress no host remoto, em minutos (default: 120)
  --port            Porta SSH (default: 22)
  --key             Chave privada SSH
  --remote-base-dir Diretorio base remoto para staging (default: /tmp)
  --saida-local     Diretorio local para salvar resultados baixados
  --sem-sudo        Executa sem sudo no host remoto
  --sudo-pass       Senha de sudo (evita prompt interativo; cuidado com seguranca)
    --nao-instalar-driver-nvidia
                                     Desativa instalacao automatica do driver NVIDIA no host remoto
  --help            Exibe esta ajuda

Exemplo:
  ./hardware_validation_remote.sh \
    --host 10.10.10.50 \
    --user admin \
    --catalogo-pdf ./catalogo_servidor.pdf \
    --duracao 120 \
    --key ~/.ssh/id_rsa
EOF
}

build_ssh_opts() {
    SSH_OPTS=("-p" "$SSH_PORT" "-o" "StrictHostKeyChecking=accept-new")
    SCP_OPTS=("-P" "$SSH_PORT" "-o" "StrictHostKeyChecking=accept-new")
    if [[ -n "$SSH_KEY" ]]; then
        SSH_OPTS+=("-i" "$SSH_KEY")
        SCP_OPTS+=("-i" "$SSH_KEY")
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                SSH_HOST="$2"
                shift 2
                ;;
            --user)
                SSH_USER="$2"
                shift 2
                ;;
            --port)
                SSH_PORT="$2"
                shift 2
                ;;
            --key)
                SSH_KEY="$2"
                shift 2
                ;;
            --remote-base-dir)
                REMOTE_BASE_DIR="$2"
                shift 2
                ;;
            --catalogo-pdf)
                CATALOGO_PDF="$2"
                shift 2
                ;;
            --duracao)
                DURACAO_MIN="$2"
                shift 2
                ;;
            --saida-local)
                LOCAL_OUTPUT_DIR="$2"
                shift 2
                ;;
            --sem-sudo)
                USE_SUDO="no"
                shift
                ;;
            --sudo-pass)
                SUDO_PASS="$2"
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

    [[ -n "$SSH_HOST" ]] || fail "Informe --host."
    [[ -n "$SSH_USER" ]] || fail "Informe --user."
    [[ -n "$CATALOGO_PDF" ]] || fail "Informe --catalogo-pdf."
    [[ -f "$CATALOGO_PDF" ]] || fail "Catalogo PDF nao encontrado: $CATALOGO_PDF"
    [[ -f "$LOCAL_MAIN_SCRIPT" ]] || fail "Script principal nao encontrado: $LOCAL_MAIN_SCRIPT"
    [[ "$DURACAO_MIN" =~ ^[0-9]+$ ]] || fail "--duracao deve ser numerico."

    if [[ "$USE_SUDO" == "no" && -n "$SUDO_PASS" ]]; then
        warn "--sudo-pass foi informado, mas --sem-sudo esta ativo. Senha sera ignorada."
    fi
}

remote_exec() {
    local cmd="$1"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$cmd"
}

remote_exec_tty() {
    local cmd="$1"
    ssh -tt "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$cmd"
}

copy_to_remote() {
    local src="$1"
    local dst="$2"
    scp "${SCP_OPTS[@]}" "$src" "${SSH_USER}@${SSH_HOST}:$dst"
}

copy_from_remote() {
    local src="$1"
    local dst="$2"
    scp "${SCP_OPTS[@]}" -r "${SSH_USER}@${SSH_HOST}:$src" "$dst"
}

prepare_remote_workspace() {
    REMOTE_WORKDIR="${REMOTE_BASE_DIR%/}/$REMOTE_RUN_ID"
    REMOTE_RESULTS_DIR="$REMOTE_WORKDIR/results"

    info "Preparando area remota em $REMOTE_WORKDIR"
    remote_exec "mkdir -p '$REMOTE_WORKDIR' '$REMOTE_RESULTS_DIR'"

    info "Enviando script e catalogo para o host remoto"
    copy_to_remote "$LOCAL_MAIN_SCRIPT" "$REMOTE_WORKDIR/hardware_validation.sh"
    copy_to_remote "$CATALOGO_PDF" "$REMOTE_WORKDIR/catalogo.pdf"

    remote_exec "chmod +x '$REMOTE_WORKDIR/hardware_validation.sh'"
}

build_remote_run_command() {
    local inner
    inner="cd '$REMOTE_WORKDIR' && ./hardware_validation.sh --catalogo-pdf '$REMOTE_WORKDIR/catalogo.pdf' --duracao '$DURACAO_MIN' --saida '$REMOTE_RESULTS_DIR'"

    if [[ "$AUTO_INSTALL_NVIDIA_DRIVER" == "yes" ]]; then
        inner+=" --instalar-driver-nvidia"
    else
        inner+=" --nao-instalar-driver-nvidia"
    fi

    if [[ "$USE_SUDO" == "yes" ]]; then
        if [[ -n "$SUDO_PASS" ]]; then
            printf "printf '%%s\\n' '%s' | sudo -S bash -lc %q" "$SUDO_PASS" "$inner"
        else
            printf "sudo bash -lc %q" "$inner"
        fi
    else
        printf "bash -lc %q" "$inner"
    fi
}

run_remote_validation() {
    local run_cmd
    run_cmd="$(build_remote_run_command)"

    info "Executando validacao remota no host ${SSH_HOST}"

    if [[ "$USE_SUDO" == "yes" ]]; then
        if [[ -n "$SUDO_PASS" ]]; then
            remote_exec "$run_cmd"
        else
            # Primeiro tenta sudo sem senha; se nao puder, roda com TTY para prompt interativo.
            if remote_exec "sudo -n true >/dev/null 2>&1"; then
                remote_exec "$run_cmd"
            else
                warn "sudo requer senha/interacao no host remoto. Abrindo sessao com TTY para prompt de senha."
                remote_exec_tty "$run_cmd"
            fi
        fi
    else
        remote_exec "$run_cmd"
    fi
}

fetch_results() {
    local local_target="$LOCAL_OUTPUT_DIR/$REMOTE_RUN_ID"
    mkdir -p "$LOCAL_OUTPUT_DIR"

    info "Baixando resultados remotos para $local_target"
    copy_from_remote "$REMOTE_RESULTS_DIR" "$local_target"

    info "Resultado local disponivel em: $local_target/results"
}

main() {
    parse_args "$@"
    build_ssh_opts
    prepare_remote_workspace
    run_remote_validation
    fetch_results

    info "Execucao remota finalizada com sucesso."
}

main "$@"
