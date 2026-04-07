# Hardware Validation and Burn-in Suite

Script Bash para validacao de hardware de servidor/workstation com:

- inventario completo de componentes (marca/modelo quando disponivel)
- comparacao de conformidade contra catalogo enviado em PDF
- benchmark e stress de CPU, RAM, disco e GPU
- relatorio final somente em Markdown

## Objetivos

O fluxo automatiza as etapas abaixo:

1. Extracao de texto do catalogo PDF (com fallback OCR quando necessario).
2. Inventario de CPU, placa mae/BIOS, memoria, GPU, discos (incluindo horas), NIC e observacao de PSU.
3. Comparacao detectado vs catalogo com status por componente.
4. Stress e benchmark com captura de evidencias em logs.
5. Geracao de relatorio final em Markdown.

## Requisitos

- Ubuntu/Debian com apt-get
- Permissao de root (sudo)
- Internet para instalacao de dependencias e download do Blender Benchmark CLI

Dependencias instaladas automaticamente pelo script:

- stress-ng, p7zip-full, fio
- lm-sensors, smartmontools, nvme-cli
- dmidecode, lshw, pciutils, ethtool
- poppler-utils (pdftotext/pdfinfo), tesseract-ocr, ocrmypdf

## Como executar

1. Dar permissao de execucao:

```bash
chmod +x hardware_validation.sh
```

2. Executar com catalogo PDF:

```bash
sudo ./hardware_validation.sh --catalogo-pdf /caminho/catalogo.pdf
```

3. Opcionalmente ajustar duracao e pasta de saida:

```bash
sudo ./hardware_validation.sh \
  --catalogo-pdf /caminho/catalogo.pdf \
  --duracao 120 \
  --saida ./test_results_custom
```

## Execucao remota via SSH

Existe um wrapper para executar a validacao em um host remoto usando SSH:

```bash
chmod +x hardware_validation_remote.sh
```

Exemplo basico:

```bash
./hardware_validation_remote.sh \
  --host 10.10.10.50 \
  --user admin \
  --catalogo-pdf ./catalogo_servidor.pdf
```

Exemplo com chave SSH, porta customizada e duracao:

```bash
./hardware_validation_remote.sh \
  --host servidor.lab.local \
  --user root \
  --port 2222 \
  --key ~/.ssh/id_rsa \
  --catalogo-pdf ./catalogo_servidor.pdf \
  --duracao 120 \
  --saida-local ./remote_results
```

Observacoes do modo remoto:

- O wrapper envia [hardware_validation.sh](hardware_validation.sh) e o catalogo PDF para um diretorio temporario remoto.
- A execucao remota usa sudo por padrao (use --sem-sudo para desativar).
- A instalacao automatica de driver NVIDIA fica ativa por padrao quando houver GPU NVIDIA sem driver funcional.
- Se o driver NVIDIA for instalado/atualizado, o script encerra solicitando reboot do servidor para continuar.
- Ao final, os artefatos de resultado sao baixados para o diretorio local definido em --saida-local.

## Saidas geradas

O script cria um diretorio de resultados com:

- Relatorio_Final.md
- inventario_detectado.md
- comparacao_catalogo.md
- catalogo_extraido.txt e catalogo_extraido.normalizado.txt
- benchmark_7z.log, stress_ng.log, fio.log, blender_gpu.log
- thermal_logs.txt

## Observacoes importantes

- O criterio de comparacao e exato por conteudo normalizado.
- Em ambiente sem GPU NVIDIA, o benchmark de GPU e marcado como SKIP justificado.
- A deteccao de PSU via software pode ser limitada; o relatorio destaca esta restricao.
- Stress de longa duracao pode elevar temperatura de forma significativa. Use ambiente ventilado.
