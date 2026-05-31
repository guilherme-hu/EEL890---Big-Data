# Plano de Adaptação dos Scripts ETL (valviessejoao)

A análise dos scripts ETL de `valviessejoao` revelou diversas inconsistências estruturais e arquiteturais quando comparados aos padrões já estabelecidos para as frotas `gupessanha` e `p-rique`, além de divergências com o modelo central do DW.

Abaixo estão listadas as mudanças que devem ser aplicadas nos scripts de extração, transformação e carga para que entrem em conformidade com o ecossistema do consórcio.

## 1. Problemas na Carga (ETL Load) e Conflito com o DW
- **Inconsistência:** O script `etl_valviessejoao_carga.sql` possui comandos `CREATE TABLE IF NOT EXISTS` para as tabelas do Data Warehouse (`dim_cliente`, `dim_tempo`, `fato_locacao`, etc.).
- **Solução:** O DW é único e centralizado, sendo criado exclusivamente pelo script `DW.sql`. O script de carga de `valviessejoao` deve **apenas** conter as *Procedures* de carga (ex: `sp_valviessejoao_carga_dim_cliente`) que executam as instruções de `INSERT ... ON DUPLICATE KEY UPDATE` (SCD Tipo 1) nas tabelas já existentes do schema `dw`. O DDL de criação do DW deve ser inteiramente removido do script de carga.

## 2. Nomenclatura do Schema de Staging
- **Inconsistência:** Os scripts de `valviessejoao` criam e utilizam um banco de dados intermediário chamado `dw_staging`.
- **Solução:** O consórcio utiliza o schema global chamado **`staging`**. Todas as referências a `dw_staging` nos scripts de extração, transformação e carga devem ser alteradas para `staging`.

## 3. Nomenclatura das Tabelas da Camada Bruta (Raw Staging)
- **Inconsistência:** As tabelas brutas recebem nomes genéricos como `stg_cliente` ou `stg_locacao`.
- **Solução:** Para evitar colisão e manter a organização visual, deve-se prefixar a origem. Renomear para `stg_valviessejoao_cliente`, `stg_valviessejoao_locacao`, etc.

## 4. Uso de Tabelas Conformadas Centralizadas (Staging Conformado)
- **Inconsistência:** A transformação grava seus dados em tabelas isoladas usando o prefixo `trf_` (ex: `trf_dim_cliente`, `trf_fato_locacao`).
- **Solução:** Na nossa arquitetura, a área de conformação é compartilhada. Todos os ETLs tratam e enviam os dados para as **mesmas** tabelas conformadas globais prefixadas com `stg_conf_` (ex: `stg_conf_dim_cliente`, `stg_conf_fato_locacao`), diferenciadas unicamente pelo campo `nk_frota_origem`. O script de transformação deve ser alterado para fazer `INSERT` nessas tabelas da área `staging`, em vez de criar tabelas `trf_` próprias.

## 5. Arquitetura de Extração Orientada a Eventos (Triggers)
- **Inconsistência:** O script de extração (`etl_valviessejoao_extracao.sql`) usa Triggers apenas para as tabelas de fatos (`RESERVA` e `LOCACAO`), mas utiliza Procedures (`CALL sp_extrai_dimensoes()`) e eventos temporais para capturar as dimensões (clientes, veículos, pátios).
- **Solução:** O padrão estabelecido (já aplicado no gupessanha e p-rique) exige o uso de Triggers `AFTER INSERT` e `AFTER UPDATE` direto no OLTP para **todas** as tabelas da fonte, replicando os dados de forma instantânea para a área bruta do staging (`stg_valviessejoao_*`).

## 6. Tratamento de Erros e Tabela de Rejeitos Central
- **Inconsistência:** Os gatilhos de transformação não fazem uso de nenhuma política de qualidade de dados (Data Quality).
- **Solução:** O script de transformação deve identificar falhas de integridade (ex: chaves nulas, datas invertidas, status inválido) e desviar os registros corrompidos inserindo-os na tabela de auditoria global do projeto: `staging.stg_rejeitos_etl`, salvando o payload do erro em formato JSON.

## Resumo das Ações Esperadas
1. Deletar os `CREATE TABLE` referentes ao DW no script de carga.
2. Trocar `dw_staging` por `staging`.
3. Renomear tabelas brutas para `stg_valviessejoao_*`.
4. Direcionar os gatilhos de transformação para inserir nas tabelas `stg_conf_*` compartilhadas.
5. Criar Triggers de extração para as entidades de dimensão (Cliente, Veículo, Grupo, Pátio).
6. Implementar a inserção de erros na `stg_rejeitos_etl` durante as regras de negócio da Transformação.
