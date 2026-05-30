-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)

-- =============================================================================
-- 02_amarelo_transform.sql
-- Transformação ETL — Staging Bruto → Staging Conformado (Amarelo)
--
-- Execução: após 01_amarelo_extract.sql, antes de 03_amarelo_load.sql
-- Banco: staging_dw
--
-- Objetivo:
--   Limpar, padronizar e conformar os dados do OLTP Amarelo para que fiquem
--   alinhados ao vocabulário e estrutura do DW integrado. Cada tabela
--   'stg_amar_t_*' é a versão pronta para carga no DW.
--
-- Principais transformações:
--   1. Endereço    → Deduplica por (cidade, estado, país); expande UF para
--                    nome completo; insere 'Não Informado' como fallback.
--   2. Cliente     → Unifica nome (PF usa nome_pf, PJ usa razao_social);
--                    normaliza tipo_cliente; resolve cidade/estado do endereço.
--   3. Veículo     → Padroniza mecanização; garante valor default para A/C.
--   4. Grupo       → Renomeia de 'Categoria' para vocabulário DW.
--   5. Pátio       → Repassa capacidade (pode ser NULL, aceito no DW).
--   6. Reserva     → Calcula duração prevista; padroniza status.
--   7. Locação     → Extrai apenas a parte DATE dos DATETIME; trata NULLs.
--   8. Inventário  → Repasse direto do staging bruto.
-- =============================================================================

USE staging_dw;

-- =============================================================================
-- T1. ENDEREÇOS CONFORMADOS
-- =============================================================================
-- Deduplica (cidade, estado, pais). O OLTP Amarelo armazena apenas UF (sigla),
-- sem campo de país. Expande UF para o nome completo do estado e usa 'Brasil'
-- como valor padrão de país para toda a frota Amarelo.
-- Registros com cidade NULL ou UF NULL são mapeados para 'Não Informado'.
-- =============================================================================
DROP TABLE IF EXISTS stg_amar_t_endereco;

CREATE TABLE stg_amar_t_endereco AS
SELECT DISTINCT
    TRIM(cidade)    AS cidade,
    -- Converte sigla UF para nome do estado por extenso (padrão DW)
    CASE uf
        WHEN 'AC' THEN 'Acre'               WHEN 'AL' THEN 'Alagoas'
        WHEN 'AP' THEN 'Amapá'              WHEN 'AM' THEN 'Amazonas'
        WHEN 'BA' THEN 'Bahia'              WHEN 'CE' THEN 'Ceará'
        WHEN 'DF' THEN 'Distrito Federal'   WHEN 'ES' THEN 'Espírito Santo'
        WHEN 'GO' THEN 'Goiás'              WHEN 'MA' THEN 'Maranhão'
        WHEN 'MT' THEN 'Mato Grosso'        WHEN 'MS' THEN 'Mato Grosso do Sul'
        WHEN 'MG' THEN 'Minas Gerais'       WHEN 'PA' THEN 'Pará'
        WHEN 'PB' THEN 'Paraíba'            WHEN 'PR' THEN 'Paraná'
        WHEN 'PE' THEN 'Pernambuco'         WHEN 'PI' THEN 'Piauí'
        WHEN 'RJ' THEN 'Rio de Janeiro'     WHEN 'RN' THEN 'Rio Grande do Norte'
        WHEN 'RS' THEN 'Rio Grande do Sul'  WHEN 'RO' THEN 'Rondônia'
        WHEN 'RR' THEN 'Roraima'            WHEN 'SC' THEN 'Santa Catarina'
        WHEN 'SP' THEN 'São Paulo'          WHEN 'SE' THEN 'Sergipe'
        WHEN 'TO' THEN 'Tocantins'
        ELSE COALESCE(TRIM(uf), 'Não Informado')
    END             AS estado,
    'Brasil'        AS pais
FROM stg_amar_endereco
WHERE cidade IS NOT NULL
  AND uf     IS NOT NULL;

-- Garante existência do endereço 'Não Informado' para uso como fallback
-- quando clientes ou pátios possuem endereço incompleto no OLTP
INSERT INTO stg_amar_t_endereco (cidade, estado, pais)
SELECT 'Não Informado', 'Não Informado', 'Brasil'
WHERE NOT EXISTS (
    SELECT 1 FROM stg_amar_t_endereco
    WHERE cidade = 'Não Informado'
      AND estado = 'Não Informado'
);


-- =============================================================================
-- T2. CLIENTES CONFORMADOS
-- =============================================================================
DROP TABLE IF EXISTS stg_amar_t_cliente;

CREATE TABLE stg_amar_t_cliente AS
SELECT
    'AMARELO'                           AS frota_origem,
    c.id_cliente,
    -- Normaliza tipo: garante maiúsculas e remove espaços
    UPPER(TRIM(c.tipo_cliente))         AS tipo_cliente,
    -- Unifica nome: PF usa nome_pf, PJ usa razao_social
    CASE
        WHEN UPPER(TRIM(c.tipo_cliente)) = 'PF'
            THEN TRIM(c.nome_pf)
        WHEN UPPER(TRIM(c.tipo_cliente)) = 'PJ'
            THEN TRIM(c.razao_social)
        ELSE COALESCE(TRIM(c.nome_pf), TRIM(c.razao_social), 'Não Informado')
    END                                 AS nome,
    -- Resolve endereço para lookup posterior em Dim_Endereco
    -- Se a cidade ou UF do cliente for nulo, aponta para 'Não Informado'
    COALESCE(TRIM(e.cidade), 'Não Informado')  AS cidade,
    CASE
        WHEN e.uf IS NOT NULL THEN
            CASE e.uf
                WHEN 'AC' THEN 'Acre'               WHEN 'AL' THEN 'Alagoas'
                WHEN 'AP' THEN 'Amapá'              WHEN 'AM' THEN 'Amazonas'
                WHEN 'BA' THEN 'Bahia'              WHEN 'CE' THEN 'Ceará'
                WHEN 'DF' THEN 'Distrito Federal'   WHEN 'ES' THEN 'Espírito Santo'
                WHEN 'GO' THEN 'Goiás'              WHEN 'MA' THEN 'Maranhão'
                WHEN 'MT' THEN 'Mato Grosso'        WHEN 'MS' THEN 'Mato Grosso do Sul'
                WHEN 'MG' THEN 'Minas Gerais'       WHEN 'PA' THEN 'Pará'
                WHEN 'PB' THEN 'Paraíba'            WHEN 'PR' THEN 'Paraná'
                WHEN 'PE' THEN 'Pernambuco'         WHEN 'PI' THEN 'Piauí'
                WHEN 'RJ' THEN 'Rio de Janeiro'     WHEN 'RN' THEN 'Rio Grande do Norte'
                WHEN 'RS' THEN 'Rio Grande do Sul'  WHEN 'RO' THEN 'Rondônia'
                WHEN 'RR' THEN 'Roraima'            WHEN 'SC' THEN 'Santa Catarina'
                WHEN 'SP' THEN 'São Paulo'          WHEN 'SE' THEN 'Sergipe'
                WHEN 'TO' THEN 'Tocantins'
                ELSE TRIM(e.uf)
            END
        ELSE 'Não Informado'
    END                                 AS estado,
    'Brasil'                            AS pais
FROM stg_amar_cliente         c
LEFT JOIN stg_amar_endereco   e ON c.id_endereco = e.id_endereco;


-- =============================================================================
-- T3. VEÍCULOS CONFORMADOS
-- =============================================================================
DROP TABLE IF EXISTS stg_amar_t_veiculo;

CREATE TABLE stg_amar_t_veiculo AS
SELECT
    'AMARELO'                                       AS frota_origem,
    v.id_veiculo,
    UPPER(TRIM(v.placa))                            AS placa,
    TRIM(v.marca)                                   AS marca,
    TRIM(v.modelo)                                  AS modelo,
    -- Padroniza mecanização para vocabulário comum entre frotas
    CASE
        WHEN v.tipo_cambio IS NULL                          THEN 'Não Informado'
        WHEN UPPER(v.tipo_cambio) LIKE '%AUTO%'             THEN 'Automático'
        WHEN UPPER(v.tipo_cambio) LIKE '%MANU%'             THEN 'Manual'
        WHEN UPPER(v.tipo_cambio) LIKE '%CVT%'              THEN 'CVT'
        ELSE TRIM(v.tipo_cambio)
    END                                             AS mecanizacao,
    -- Garante 0 quando NULL (veículo sem registro = sem ar condicionado)
    COALESCE(v.possui_ar_condicionado, 0)           AS tem_ar_condicionado,
    v.id_categoria                                  AS id_categoria
FROM stg_amar_veiculo v;


-- =============================================================================
-- T4. GRUPOS CONFORMADOS (Categoria → Dim_Grupo)
-- =============================================================================
DROP TABLE IF EXISTS stg_amar_t_grupo;

CREATE TABLE stg_amar_t_grupo AS
SELECT
    'AMARELO'                           AS frota_origem,
    c.id_categoria                      AS id_grupo,
    TRIM(c.nome_categoria)              AS nome_grupo,
    -- Valor 0.00 como fallback para categorias sem diária cadastrada
    COALESCE(c.valor_diaria_base, 0.00) AS valor_diaria
FROM stg_amar_categoria c;


-- =============================================================================
-- T5. PÁTIOS CONFORMADOS
-- =============================================================================
DROP TABLE IF EXISTS stg_amar_t_patio;

CREATE TABLE stg_amar_t_patio AS
SELECT
    'AMARELO'                   AS frota_origem,
    p.id_patio,
    TRIM(p.nome_patio)          AS nome_patio,
    -- Capacidade pode ser NULL (pátios sem limite cadastrado — aceito no DW)
    p.capacidade                AS capacidade_vagas
FROM stg_amar_patio p;


-- =============================================================================
-- T6. RESERVAS CONFORMADAS
-- =============================================================================
DROP TABLE IF EXISTS stg_amar_t_reserva;

CREATE TABLE stg_amar_t_reserva AS
SELECT
    'AMARELO'                               AS frota_origem,
    r.id_reserva,
    r.id_cliente,
    r.id_categoria                          AS id_grupo,
    r.id_patio_previsto_retirada            AS id_patio_retirada,
    r.id_patio_previsto_devolucao           AS id_patio_fim,
    -- Extrai apenas DATE do DATETIME para lookup em Dim_Tempo
    DATE(r.data_hora_reserva)               AS data_reserva,
    DATE(r.data_previsao_retirada)          AS data_prev_retirada,
    DATE(r.data_previsao_devolucao)         AS data_prev_devolucao,
    -- Calcula duração prevista em dias (campo do Fato_Reserva)
    DATEDIFF(
        DATE(r.data_previsao_devolucao),
        DATE(r.data_previsao_retirada)
    )                                       AS duracao_prevista_dias,
    COALESCE(r.valor_previsto, 0.00)        AS valor_previsto,
    -- Padroniza status para vocabulário DW: Ativa, Cancelada, Convertida
    CASE
        WHEN UPPER(TRIM(r.status_reserva))
            IN ('ATIVO','ATIVA','ACTIVE','ABERTA')          THEN 'Ativa'
        WHEN UPPER(TRIM(r.status_reserva))
            IN ('CANCELADO','CANCELADA','CANCEL')           THEN 'Cancelada'
        WHEN UPPER(TRIM(r.status_reserva))
            IN ('CONVERTIDO','CONVERTIDA','CONCLUIDO',
                'CONCLUIDA','CONVERTED','COMPLETED',
                'FINALIZADO','FINALIZADA')                  THEN 'Convertida'
        ELSE COALESCE(TRIM(r.status_reserva), 'Não Informado')
    END                                     AS status_reserva
FROM stg_amar_reserva r
-- Filtra registros inválidos: reservas sem datas ficam fora do DW
WHERE r.data_previsao_retirada  IS NOT NULL
  AND r.data_previsao_devolucao IS NOT NULL
  -- Garante que devolução prevista seja posterior ou igual à retirada
  AND r.data_previsao_devolucao >= r.data_previsao_retirada;


-- =============================================================================
-- T7. LOCAÇÕES CONFORMADAS
-- =============================================================================
DROP TABLE IF EXISTS stg_amar_t_locacao;

CREATE TABLE stg_amar_t_locacao AS
SELECT
    'AMARELO'                                       AS frota_origem,
    l.id_locacao,
    l.id_cliente,
    l.id_veiculo,
    l.id_categoria                                  AS id_grupo,
    l.id_patio_real_retirada                        AS id_patio_retirada,
    -- Pátio de devolução: NULL quando locação ainda em aberto
    l.id_patio_real_devolucao                       AS id_patio_devolucao,
    -- Extrai apenas DATE para lookup em Dim_Tempo
    DATE(l.data_hora_retirada_real)                 AS data_retirada,
    DATE(l.data_previsao_devolucao)                 AS data_prev_devolucao,
    -- NULL quando veículo ainda não foi devolvido
    DATE(l.data_hora_devolucao_real)                AS data_real_devolucao,
    -- Valor final: NULL enquanto locação em aberto (atualizado na devolução)
    l.valor_total_final                             AS valor_final
FROM stg_amar_locacao l
-- Apenas locações com data de retirada registrada são válidas para o fato
WHERE l.data_hora_retirada_real IS NOT NULL;


-- =============================================================================
-- T8. INVENTÁRIO DE PÁTIO CONFORMADO
-- =============================================================================
DROP TABLE IF EXISTS stg_amar_t_inventario;

CREATE TABLE stg_amar_t_inventario AS
SELECT
    'AMARELO'       AS frota_origem,
    id_veiculo,
    id_patio,
    id_categoria    AS id_grupo,
    dt_snapshot
FROM stg_amar_inventario_patio;