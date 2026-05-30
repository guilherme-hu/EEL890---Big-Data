-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)


SET search_path TO staging, public;


--  1) TABELAS CONFORMADAS (criar se não existirem)

-- Tabela de rejeitos — captura erros de qualidade para monitoramento e análise posterior
CREATE TABLE IF NOT EXISTS staging.stg_rejeitos_ia (
    id_rejeito      SERIAL       PRIMARY KEY,
    tabela_origem   VARCHAR(50)  NOT NULL,
    nk_frota_origem VARCHAR(10),
    nk_id_registro  INTEGER,
    motivo_rejeito  VARCHAR(500) NOT NULL,
    dados_json      TEXT,        -- snapshot do registro rejeitado
    dt_rejeito      TIMESTAMP    NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_patio (
    nk_frota_origem       VARCHAR(20)  NOT NULL,
    nk_id_patio           INTEGER      NOT NULL,
    nome_patio            VARCHAR(100) NOT NULL,
    capacidade_vagas      INTEGER      NOT NULL,  -- -1 se desconhecida
    endereco              VARCHAR(200),            -- cidade + UF + logradouro
    PRIMARY KEY (nk_frota_origem, nk_id_patio)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_grupo (
    nk_frota_origem       VARCHAR(20)   NOT NULL,
    nk_id_grupo           INTEGER       NOT NULL,
    nome_grupo            VARCHAR(80)   NOT NULL,
    valor_diaria          NUMERIC(12,2) NOT NULL,
    PRIMARY KEY (nk_frota_origem, nk_id_grupo)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_veiculo (
    nk_frota_origem       VARCHAR(20)  NOT NULL,
    nk_id_veiculo         INTEGER      NOT NULL,
    nk_id_grupo           INTEGER      NOT NULL,
    nk_id_patio_origem    INTEGER      NOT NULL,
    placa                 VARCHAR(10)  NOT NULL,
    marca                 VARCHAR(50)  NOT NULL,
    modelo                VARCHAR(60)  NOT NULL,
    mecanizacao           VARCHAR(20)  NOT NULL,  -- 'MANUAL' ou 'AUTOMATICO'
    tem_ar_condicionado   BOOLEAN      NOT NULL,
    PRIMARY KEY (nk_frota_origem, nk_id_veiculo)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_cliente (
    nk_frota_origem       VARCHAR(20)  NOT NULL,
    nk_id_cliente         INTEGER      NOT NULL,
    tipo_cliente          VARCHAR(2)   NOT NULL,  -- 'PF' ou 'PJ'
    nome                  VARCHAR(150) NOT NULL,
    endereco              VARCHAR(200),            -- cidade + UF conformados
    PRIMARY KEY (nk_frota_origem, nk_id_cliente)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_reserva (
    nk_frota_origem           VARCHAR(10)   NOT NULL,
    nk_id_reserva             INTEGER       NOT NULL,
    nk_id_cliente             INTEGER       NOT NULL,
    nk_id_grupo               INTEGER       NOT NULL,
    nk_id_patio_retirada      INTEGER       NOT NULL,
    nk_id_patio_fim           INTEGER       NOT NULL,
    data_reserva              DATE          NOT NULL,
    data_retirada_prevista    DATE          NOT NULL,
    data_devolucao_prevista   DATE          NOT NULL,
    duracao_prevista_dias     INTEGER       NOT NULL,
    valor_previsto_reserva    NUMERIC(12,2) NOT NULL,
    status_reserva            VARCHAR(20)   NOT NULL,
    PRIMARY KEY (nk_frota_origem, nk_id_reserva)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_locacao (
    nk_frota_origem           VARCHAR(10)   NOT NULL,
    nk_id_locacao             INTEGER       NOT NULL,
    nk_id_cliente             INTEGER       NOT NULL,
    nk_id_veiculo             INTEGER       NOT NULL,
    nk_id_grupo               INTEGER       NOT NULL,
    nk_id_patio_retirada      INTEGER       NOT NULL,
    nk_id_patio_devolucao     INTEGER,              -- NULL se em andamento
    data_retirada             DATE          NOT NULL,
    data_prev_devolucao       DATE          NOT NULL,
    data_real_devolucao       DATE,                 -- NULL se em andamento
    valor_final               NUMERIC(14,2) NOT NULL,
    PRIMARY KEY (nk_frota_origem, nk_id_locacao)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_snapshot_patio (
    nk_frota_origem       VARCHAR(20)  NOT NULL,
    nk_id_patio           INTEGER      NOT NULL,
    nk_id_veiculo         INTEGER      NOT NULL,
    nk_id_grupo           INTEGER      NOT NULL,
    data_snapshot         DATE         NOT NULL,
    PRIMARY KEY (nk_frota_origem, nk_id_patio, nk_id_veiculo, data_snapshot)
);



--  2) PROCEDURES DE TRANSFORMAÇÃO

--  Legenda das Transformações realizadas:
--    T1  Normalização de frota_origem: garantir 'gupessanha' em todos registros
--    T2  Tratamento de endereços incompletos (clientes e pátios)
--    T3  Conformação de tipo_cliente: 'PF'/'PJ' → vocabulário DW
--    T4  Conformação de mecanizacao: MANUAL/AUTOMATICA → DW
--    T5  Normalização de nome/razão social (trim, upper)
--    T6  Mapeamento de status de reserva → Dd_status_reserva do DW
--    T7  Cálculo de duracao_prevista e valor_previsto_reserva (sanity-check: rejeita durações negativas ou zero)
--    T8  Cálculo de valor_final da locação
--    T9  Validação de datas: rejeita registros com data_retirada posterior à data_devolucao
--    T10 Tratamento de NULLs críticos (substitui por sentinelas)
--    T11 Tratamento de capacidade de pátio nula (sentinela -1)


--  2.1) sp_gupessanha_transforma_patio
--       T2  Endereços incompletos: concatena cidade + UF; se cidade vazia usa 'NÃO INFORMADO'
--       T11 Capacidade nula → -1 (sentinela "desconhecida")
CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_transforma_patio()
LANGUAGE plpgsql AS $$
DECLARE
    v_total   INTEGER := 0;
    v_rejeit  INTEGER := 0;
BEGIN

    TRUNCATE TABLE staging.stg_conf_patio;

    INSERT INTO staging.stg_conf_patio (
        nk_frota_origem,
        nk_id_patio,
        nome_patio,
        capacidade_vagas,
        endereco
    )
    SELECT
        nk_frota_origem,
        nk_id_patio,
        -- T5: trim e title-case básico no nome
        INITCAP(TRIM(nome_patio))               AS nome_patio,
        -- T11: capacidade nula → sentinela -1
        COALESCE(capacidade_vagas, -1)           AS capacidade_vagas,
        -- T2: monta endereço conformado; substitui NULLs
        TRIM(
            COALESCE(NULLIF(TRIM(end_logradouro), ''), 'NÃO INFORMADO')
            || ', '
            || COALESCE(NULLIF(TRIM(end_cidade), ''), 'NÃO INFORMADO')
            || ' - '
            || COALESCE(NULLIF(TRIM(end_uf::TEXT), ''), 'XX')
        )                                        AS endereco
    FROM staging.stg_gupessanha_patio
    WHERE nk_frota_origem = 'gupessanha';

    GET DIAGNOSTICS v_total = ROW_COUNT;
END;
$$;


--  2.2) sp_gupessanha_transforma_grupo
--       T10 valor_diaria NULL → 0 com aviso de rejeito (DQ)
CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_transforma_grupo()
LANGUAGE plpgsql AS $$
DECLARE
    v_total INTEGER := 0;
BEGIN

    TRUNCATE TABLE staging.stg_conf_grupo;

    -- Registra rejeitos: grupos sem tarifa (qualidade de dados)
    INSERT INTO staging.stg_rejeitos_ia
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_gupessanha_grupo', nk_frota_origem, nk_id_grupo,
        'Grupo sem valor_diaria vigente; será carregado com valor 0,00'
    FROM staging.stg_gupessanha_grupo
    WHERE nk_frota_origem = 'gupessanha'
      AND (valor_diaria IS NULL OR valor_diaria = 0);

    INSERT INTO staging.stg_conf_grupo (
        nk_frota_origem,
        nk_id_grupo,
        nome_grupo,
        valor_diaria
    )
    SELECT
        nk_frota_origem,
        nk_id_grupo,
        INITCAP(TRIM(COALESCE(nome_grupo, codigo_grupo, 'GRUPO ' || nk_id_grupo::TEXT))),
        COALESCE(valor_diaria, 0)
    FROM staging.stg_gupessanha_grupo
    WHERE nk_frota_origem = 'gupessanha';

    GET DIAGNOSTICS v_total = ROW_COUNT;
END;
$$;


--  2.3) sp_gupessanha_transforma_veiculo
--       T4  Conformação mecanizacao (AUTOMATICA → AUTOMATICO)
--       T10 Campos obrigatórios nulos → sentinelas
CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_transforma_veiculo()
LANGUAGE plpgsql AS $$
DECLARE
    v_total  INTEGER := 0;
    v_rejeit INTEGER := 0;
BEGIN

    TRUNCATE TABLE staging.stg_conf_veiculo;

    -- Rejeita veículos sem grupo ou sem pátio (inconsistência de FK)
    INSERT INTO staging.stg_rejeitos_ia
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_gupessanha_veiculo', nk_frota_origem, nk_id_veiculo,
        'Veículo sem nk_id_grupo ou sem nk_id_patio_origem'
    FROM staging.stg_gupessanha_veiculo
    WHERE nk_frota_origem = 'gupessanha'
      AND (nk_id_grupo IS NULL OR nk_id_patio_origem IS NULL);

    GET DIAGNOSTICS v_rejeit = ROW_COUNT;
    IF v_rejeit > 0 THEN
        RAISE WARNING '[gupessanha][TRANSFORMAÇÃO] % veículos rejeitados (sem grupo/pátio)', v_rejeit;
    END IF;

    INSERT INTO staging.stg_conf_veiculo (
        nk_frota_origem,
        nk_id_veiculo,
        nk_id_grupo,
        nk_id_patio_origem,
        placa,
        marca,
        modelo,
        mecanizacao,
        tem_ar_condicionado
    )
    SELECT
        nk_frota_origem,
        nk_id_veiculo,
        nk_id_grupo,
        nk_id_patio_origem,
        UPPER(TRIM(placa))                      AS placa,
        INITCAP(TRIM(COALESCE(marca, 'NÃO INFORMADO')))  AS marca,
        INITCAP(TRIM(COALESCE(modelo, 'NÃO INFORMADO'))) AS modelo,
        -- T4: normaliza mecanização para 'MANUAL' ou 'AUTOMATICO'
        CASE UPPER(TRIM(COALESCE(mecanizacao, '')))
            WHEN 'MANUAL'     THEN 'MANUAL'
            WHEN 'AUTOMATICA' THEN 'AUTOMATICO'
            WHEN 'AUTOMATICO' THEN 'AUTOMATICO'
            ELSE 'NÃO INFORMADO'
        END                                     AS mecanizacao,
        COALESCE(tem_ar_condicionado, FALSE)    AS tem_ar_condicionado
    FROM staging.stg_gupessanha_veiculo
    WHERE nk_frota_origem = 'gupessanha'
      AND nk_id_grupo IS NOT NULL
      AND nk_id_patio_origem IS NOT NULL;

    GET DIAGNOSTICS v_total = ROW_COUNT;
END;
$$;


--  2.4) sp_gupessanha_transforma_cliente
--       T2  Endereços incompletos
--       T3  Conformação tipo_cliente
--       T5  Normalização de nome
CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_transforma_cliente()
LANGUAGE plpgsql AS $$
DECLARE
    v_total  INTEGER := 0;
    v_rejeit INTEGER := 0;
BEGIN

    TRUNCATE TABLE staging.stg_conf_cliente;

    -- Rejeita clientes sem tipo definido
    INSERT INTO staging.stg_rejeitos_ia
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_gupessanha_cliente', nk_frota_origem, nk_id_cliente,
        'Cliente sem tipo_cliente (PF/PJ)'
    FROM staging.stg_gupessanha_cliente
    WHERE nk_frota_origem = 'gupessanha'
      AND tipo_cliente NOT IN ('PF', 'PJ');

    GET DIAGNOSTICS v_rejeit = ROW_COUNT;

    INSERT INTO staging.stg_conf_cliente (
        nk_frota_origem,
        nk_id_cliente,
        tipo_cliente,
        nome,
        endereco
    )
    SELECT
        nk_frota_origem,
        nk_id_cliente,
        -- T3: garante domínio 'PF'/'PJ'
        UPPER(TRIM(tipo_cliente))               AS tipo_cliente,
        -- T5: trim e normalização básica de nome
        INITCAP(TRIM(COALESCE(nome, 'NÃO IDENTIFICADO'))) AS nome,
        -- T2: endereço conformado
        TRIM(
            COALESCE(NULLIF(TRIM(end_cidade), ''), 'NÃO INFORMADO')
            || ' - '
            || COALESCE(NULLIF(TRIM(end_uf::TEXT), ''), 'XX')
        )                                       AS endereco
    FROM staging.stg_gupessanha_cliente
    WHERE nk_frota_origem = 'gupessanha'
      AND tipo_cliente IN ('PF', 'PJ');

    GET DIAGNOSTICS v_total = ROW_COUNT;
END;
$$;


--  2.5) sp_gupessanha_transforma_reserva
--       T6  Mapeamento de status para Dd_status_reserva do DW (ATIVA, CANCELADA, CONVERTIDA)
--       T7  Valida duração prevista (deve ser >= 1 dia)
--       T9  Valida consistência de datas
--       T10 NULLs em FKs obrigatórias → rejeito
CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_transforma_reserva()
LANGUAGE plpgsql AS $$
DECLARE
    v_total  INTEGER := 0;
    v_rejeit INTEGER := 0;
BEGIN

    TRUNCATE TABLE staging.stg_conf_reserva;

    -- T9 + T10: rejeita reservas com datas inválidas ou FKs nulas
    INSERT INTO staging.stg_rejeitos_ia
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json)
    SELECT
        'stg_gupessanha_reserva',
        nk_frota_origem,
        nk_id_reserva,
        CASE
            WHEN nk_id_cliente IS NULL            THEN 'Reserva sem cliente'
            WHEN nk_id_grupo IS NULL              THEN 'Reserva sem grupo'
            WHEN nk_id_patio_retirada IS NULL     THEN 'Reserva sem pátio de retirada'
            WHEN nk_id_patio_fim IS NULL          THEN 'Reserva sem pátio de fim'
            WHEN data_reserva IS NULL             THEN 'Reserva sem data de reserva'
            WHEN data_retirada_prevista IS NULL   THEN 'Reserva sem data de retirada prevista'
            WHEN data_devolucao_prevista IS NULL  THEN 'Reserva sem data de devolução prevista'
            WHEN data_devolucao_prevista
               <= data_retirada_prevista          THEN 'Data devolução <= data retirada'
            WHEN COALESCE(duracao_prevista_dias, 0) < 1
                                                  THEN 'Duração prevista inválida (< 1 dia)'
        END AS motivo,
        row_to_json(s)::TEXT
    FROM staging.stg_gupessanha_reserva s
    WHERE nk_frota_origem = 'gupessanha'
      AND (
            nk_id_cliente IS NULL
         OR nk_id_grupo IS NULL
         OR nk_id_patio_retirada IS NULL
         OR nk_id_patio_fim IS NULL
         OR data_reserva IS NULL
         OR data_retirada_prevista IS NULL
         OR data_devolucao_prevista IS NULL
         OR data_devolucao_prevista <= data_retirada_prevista
         OR COALESCE(duracao_prevista_dias, 0) < 1
      );

    GET DIAGNOSTICS v_rejeit = ROW_COUNT;

    INSERT INTO staging.stg_conf_reserva (
        nk_frota_origem,
        nk_id_reserva,
        nk_id_cliente,
        nk_id_grupo,
        nk_id_patio_retirada,
        nk_id_patio_fim,
        data_reserva,
        data_retirada_prevista,
        data_devolucao_prevista,
        duracao_prevista_dias,
        valor_previsto_reserva,
        status_reserva
    )
    SELECT
        nk_frota_origem,
        nk_id_reserva,
        nk_id_cliente,
        nk_id_grupo,
        nk_id_patio_retirada,
        nk_id_patio_fim,
        data_reserva,
        data_retirada_prevista,
        data_devolucao_prevista,
        -- T7: duração recalculada para segurança
        (data_devolucao_prevista - data_retirada_prevista) AS duracao_prevista_dias,
        -- T8: valor previsto = duração × diária do grupo conformado
        (data_devolucao_prevista - data_retirada_prevista)
            * COALESCE(g.valor_diaria, 0)                  AS valor_previsto_reserva,
        -- T6: status mapeado já vem do staging; confirmamos aqui
        CASE UPPER(TRIM(COALESCE(status_reserva, '')))
            WHEN 'ATIVA'      THEN 'ATIVA'
            WHEN 'CANCELADA'  THEN 'CANCELADA'
            WHEN 'CONVERTIDA' THEN 'CONVERTIDA'
            ELSE 'ATIVA'     -- default conservador
        END                                                AS status_reserva
    FROM staging.stg_gupessanha_reserva s
    LEFT JOIN staging.stg_conf_grupo g
        ON g.nk_frota_origem = s.nk_frota_origem
       AND g.nk_id_grupo = s.nk_id_grupo
    WHERE s.nk_frota_origem = 'gupessanha'
      AND nk_id_cliente IS NOT NULL
      AND nk_id_grupo IS NOT NULL
      AND nk_id_patio_retirada IS NOT NULL
      AND nk_id_patio_fim IS NOT NULL
      AND data_reserva IS NOT NULL
      AND data_retirada_prevista IS NOT NULL
      AND data_devolucao_prevista IS NOT NULL
      AND data_devolucao_prevista > data_retirada_prevista
      AND COALESCE(duracao_prevista_dias, 0) >= 1;

    GET DIAGNOSTICS v_total = ROW_COUNT;
END;
$$;


--  2.6) sp_gupessanha_transforma_locacao
--       T8  Cálculo e validação do valor_final
--       T9  Validação de datas (retirada < devolução)
--       T10 NULLs críticos → rejeito
CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_transforma_locacao()
LANGUAGE plpgsql AS $$
DECLARE
    v_total  INTEGER := 0;
    v_rejeit INTEGER := 0;
BEGIN

    TRUNCATE TABLE staging.stg_conf_locacao;

    -- T9 + T10: rejeita locações com dados críticos ausentes/inválidos
    INSERT INTO staging.stg_rejeitos_ia
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json)
    SELECT
        'stg_gupessanha_locacao',
        nk_frota_origem,
        nk_id_locacao,
        CASE
            WHEN nk_id_cliente IS NULL         THEN 'Locação sem cliente'
            WHEN nk_id_veiculo IS NULL         THEN 'Locação sem veículo'
            WHEN nk_id_grupo IS NULL           THEN 'Locação sem grupo'
            WHEN nk_id_patio_retirada IS NULL  THEN 'Locação sem pátio de retirada'
            WHEN data_retirada IS NULL         THEN 'Locação sem data de retirada'
            WHEN data_prev_devolucao IS NULL   THEN 'Locação sem data prev. devolução'
            WHEN data_real_devolucao IS NOT NULL
             AND data_real_devolucao < data_retirada
                                               THEN 'Data devolução real anterior à retirada'
        END AS motivo,
        row_to_json(l)::TEXT
    FROM staging.stg_gupessanha_locacao l
    WHERE nk_frota_origem = 'gupessanha'
      AND (
            nk_id_cliente IS NULL
         OR nk_id_veiculo IS NULL
         OR nk_id_grupo IS NULL
         OR nk_id_patio_retirada IS NULL
         OR data_retirada IS NULL
         OR data_prev_devolucao IS NULL
         OR (data_real_devolucao IS NOT NULL AND data_real_devolucao < data_retirada)
      );

    GET DIAGNOSTICS v_rejeit = ROW_COUNT;

    INSERT INTO staging.stg_conf_locacao (
        nk_frota_origem,
        nk_id_locacao,
        nk_id_cliente,
        nk_id_veiculo,
        nk_id_grupo,
        nk_id_patio_retirada,
        nk_id_patio_devolucao,
        data_retirada,
        data_prev_devolucao,
        data_real_devolucao,
        valor_final
    )
    SELECT
        l.nk_frota_origem,
        l.nk_id_locacao,
        l.nk_id_cliente,
        l.nk_id_veiculo,
        l.nk_id_grupo,
        l.nk_id_patio_retirada,
        -- Pátio de devolução: NULL mantido se locação em andamento
        l.nk_id_patio_devolucao,
        l.data_retirada,
        l.data_prev_devolucao,
        l.data_real_devolucao,
        -- T8: valor_final calculado na extração; aqui fazemos sanity-check
        -- Se negativo (improvável, mas possível por estornos), força 0
        GREATEST(COALESCE(l.valor_final, 0), 0) AS valor_final
    FROM staging.stg_gupessanha_locacao l
    WHERE l.nk_frota_origem = 'gupessanha'
      AND nk_id_cliente IS NOT NULL
      AND nk_id_veiculo IS NOT NULL
      AND nk_id_grupo IS NOT NULL
      AND nk_id_patio_retirada IS NOT NULL
      AND data_retirada IS NOT NULL
      AND data_prev_devolucao IS NOT NULL
      AND (data_real_devolucao IS NULL OR data_real_devolucao >= data_retirada);

    GET DIAGNOSTICS v_total = ROW_COUNT;
END;
$$;


--  2.7) sp_gupessanha_transforma_snapshot_patio
--       Simples passthrough com validação de NULLs críticos.
CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_transforma_snapshot_patio()
LANGUAGE plpgsql AS $$
DECLARE
    v_total INTEGER := 0;
BEGIN

    TRUNCATE TABLE staging.stg_conf_snapshot_patio;

    -- Rejeita registros com NULLs em FKs
    INSERT INTO staging.stg_rejeitos_ia
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_gupessanha_snapshot_patio', nk_frota_origem, nk_id_veiculo,
        'Snapshot sem pátio, veículo ou grupo válidos'
    FROM staging.stg_gupessanha_snapshot_patio
    WHERE nk_frota_origem = 'gupessanha'
      AND (nk_id_patio IS NULL OR nk_id_veiculo IS NULL
           OR nk_id_grupo IS NULL OR data_snapshot IS NULL);

    INSERT INTO staging.stg_conf_snapshot_patio (
        nk_frota_origem,
        nk_id_patio,
        nk_id_veiculo,
        nk_id_grupo,
        data_snapshot
    )
    SELECT
        nk_frota_origem,
        nk_id_patio,
        nk_id_veiculo,
        nk_id_grupo,
        data_snapshot
    FROM staging.stg_gupessanha_snapshot_patio
    WHERE nk_frota_origem = 'gupessanha'
      AND nk_id_patio IS NOT NULL
      AND nk_id_veiculo IS NOT NULL
      AND nk_id_grupo IS NOT NULL
      AND data_snapshot IS NOT NULL;

    GET DIAGNOSTICS v_total = ROW_COUNT;
END;
$$;



--  3) PROCEDURE MAIN DE TRANSFORMAÇÃO

CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_transformacao_completa()
LANGUAGE plpgsql AS $$
BEGIN

    -- Ordem: dimensões antes de fatos (fatos referenciam conf_grupo para recalcular valor_previsto_reserva)
    CALL staging.sp_gupessanha_transforma_patio();
    CALL staging.sp_gupessanha_transforma_grupo();
    CALL staging.sp_gupessanha_transforma_veiculo();
    CALL staging.sp_gupessanha_transforma_cliente();
    CALL staging.sp_gupessanha_transforma_reserva();
    CALL staging.sp_gupessanha_transforma_locacao();
    CALL staging.sp_gupessanha_transforma_snapshot_patio();

END;
$$;



--  4) VIEW DE MONITORAMENTO DE QUALIDADE

CREATE OR REPLACE VIEW staging.vw_ia_qualidade_etl AS
SELECT
    tabela_origem,
    COUNT(*)                              AS total_rejeitos,
    MIN(dt_rejeito)                       AS primeiro_rejeito,
    MAX(dt_rejeito)                       AS ultimo_rejeito,
    STRING_AGG(DISTINCT motivo_rejeito,
        ' | ' ORDER BY motivo_rejeito)    AS motivos_distintos
FROM staging.stg_rejeitos_ia
GROUP BY tabela_origem
ORDER BY total_rejeitos DESC;

COMMENT ON VIEW staging.vw_ia_qualidade_etl
    IS 'Resumo de problemas de qualidade detectados na transformação ETL do fonte IA.';
