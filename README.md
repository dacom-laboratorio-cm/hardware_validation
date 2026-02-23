# 🚀 Workstation Hardware Validation & Burn-in Suite

Este repositório contém um script de automação em Bash desenvolvido para a homologação técnica de workstations de alta performance, especificamente configuradas com arquitetura **AMD Zen 4** e GPUs **NVIDIA RTX Pro 6000 (Blackwell)**.

O objetivo deste conjunto de testes é garantir a estabilidade do hardware, a eficiência do sistema de refrigeração líquida, a integridade da memória ECC e o desempenho nominal dos componentes sob carga máxima.

## 📋 Índice
- [Objetivos do Teste](#objetivos-do-teste)
- [Pré-requisitos](#pré-requisitos)
- [Componentes Testados](#componentes-testados)
- [Como Executar](#como-executar)
- [Estrutura do Relatório](#estrutura-do-relatório)
- [Critérios de Aceite](#critérios-de-aceite)

## 🎯 Objetivos do Teste
O script realiza uma bateria de testes rigorosos divididos em cinco fases:
1.  **Verificação de Software/Ambiente:** Validação do Kernel Linux (6.8+) e drivers NVIDIA.
2.  **Estresse Térmico (Burn-in):** 60 minutos de carga total em CPU, RAM e I/O.
3.  **Benchmark de Processamento:** Validação de MIPS (CPU) e detecção de erros em memória RDIMM ECC.
4.  **Performance Gráfica (CUDA/OptiX):** Renderização via Blender nas cenas padrão da indústria.
5.  **Saúde do Armazenamento:** Verificação de integridade e tempo de uso de SSDs e HDDs via S.M.A.R.T.

## 💻 Pré-requisitos
*   **Sistema Operacional:** Ubuntu 22.04 LTS ou superior (recomendado 24.04 para suporte nativo ao Kernel 6.8).
*   **Drivers:** NVIDIA Production Branch instalados e funcionais.
*   **Privilégios:** Acesso de superusuário (`sudo`).
*   **Conexão com Internet:** Necessária para baixar o Blender Benchmark CLI e dependências de software.

## 🛠 Componentes Testados
*   **CPU:** Processador AMD Zen 4 (24 núcleos/48 threads).
*   **GPU:** NVIDIA RTX Pro 6000 Blackwell.
*   **RAM:** 128GB+ RDIMM ECC.
*   **Storage:** SSD NVMe 2TB + HDD 20TB Enterprise.
*   **PSU:** Fonte de 1300W (validada através do consumo de pico durante o stress-ng).

## 🚀 Como Executar

1.  **Clonar ou Baixar o Script:**
    ```bash
    chmod +x hardware_validation.sh
    ```

2.  **Executar os Testes:**
    Recomenda-se executar o script dentro de uma sessão `screen` ou `tmux`, pois o teste de estresse dura 60 minutos.
    ```bash
    sudo ./hardware_validation.sh
    ```

3.  **Acompanhamento:**
    O script exibirá o progresso no terminal e salvará todos os logs em uma pasta datada (ex: `test_results_20231027_103000/`).

## 📊 Estrutura do Relatório
Ao final da execução, o script gera automaticamente um relatório consolidado em **PDF** contendo:
*   Logs de saída de todos os comandos de sistema.
*   Tabelas de desempenho (MIPS e Samples/min).
*   Gráfico/Resumo de temperaturas máximas atingidas.
*   Status de saúde dos discos (Zero horas de uso).

## ✅ Critérios de Aceite
Para que o equipamento seja considerado **APROVADO**, ele deve cumprir:
*   **Estabilidade:** Zero reinicializações ou travamentos durante os 60 minutos de `stress-ng`.
*   **Memória:** Zero erros detectados no benchmark do 7-Zip (indicativo de falha na ECC).
*   **Térmico:** CPU e GPU não devem atingir o limite de *thermal throttling* (Geralmente < 95°C para Zen 4 e < 85°C para GPU).
*   **Discos:** O log do `smartctl` deve indicar "Power On Hours" próximo a 0 e zero "Bad Sectors".
*   **Performance:** Os scores do Blender devem estar dentro de uma margem de +/- 5% em relação aos benchmarks oficiais da arquitetura Blackwell.

---
**Aviso:** Este teste submete o hardware a condições extremas de carga e calor. Certifique-se de que o equipamento esteja em local ventilado antes de iniciar.
