-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)



--  1) TABELAS CONFORMADAS (criar se não existirem)

-- Tabela de rejeitos — captura erros de qualidade para monitoramento e análise posterior
CREATE TABLE IF NOT EXISTS staging.stg_rejeitos_etl (
    id_rejeito      INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    tabela_origem   VARCHAR(50)  NOT NULL,
    nk_frota_origem VARCHAR(10),
    nk_id_registro  INT,
    motivo_rejeito  VARCHAR(500) NOT NULL,
    dados_json      TEXT,        -- snapshot do registro rejeitado
    dt_rejeito      DATETIME     NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_patio (
    nk_frota_origem       VARCHAR(20)  NOT NULL,
    nk_id_patio           INT          NOT NULL,
    nome_patio            VARCHAR(100) NOT NULL,
    capacidade_vagas      INT          NOT NULL,  -- -1 se desconhecida
    end_cidade            VARCHAR(100),
    end_uf                VARCHAR(100),
    end_pais              VARCHAR(100),
    PRIMARY KEY (nk_frota_origem, nk_id_patio)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_grupo (
    nk_frota_origem       VARCHAR(20)   NOT NULL,
    nk_id_grupo           INT           NOT NULL,
    nome_grupo            VARCHAR(80)   NOT NULL,
    valor_diaria          DECIMAL(12,2) NOT NULL,
    PRIMARY KEY (nk_frota_origem, nk_id_grupo)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_veiculo (
    nk_frota_origem       VARCHAR(20)  NOT NULL,
    nk_id_veiculo         INT          NOT NULL,
    nk_id_grupo           INT          NOT NULL,
    nk_id_patio_origem    INT          NOT NULL,
    placa                 VARCHAR(10)  NOT NULL,
    marca                 VARCHAR(50)  NOT NULL,
    modelo                VARCHAR(60)  NOT NULL,
    mecanizacao           VARCHAR(20)  NOT NULL,  -- 'MANUAL' ou 'AUTOMATICO'
    tem_ar_condicionado   TINYINT(1)   NOT NULL,
    PRIMARY KEY (nk_frota_origem, nk_id_veiculo)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_cliente (
    nk_frota_origem       VARCHAR(20)  NOT NULL,
    nk_id_cliente         INT          NOT NULL,
    tipo_cliente          VARCHAR(2)   NOT NULL,  -- 'PF' ou 'PJ'
    nome                  VARCHAR(150) NOT NULL,
    end_cidade            VARCHAR(100),
    end_uf                VARCHAR(100),
    end_pais              VARCHAR(100),
    PRIMARY KEY (nk_frota_origem, nk_id_cliente)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_reserva (
    nk_frota_origem           VARCHAR(10)   NOT NULL,
    nk_id_reserva             INT           NOT NULL,
    nk_id_cliente             INT           NOT NULL,
    nk_id_grupo               INT           NOT NULL,
    nk_id_patio_retirada      INT           NOT NULL,
    nk_id_patio_fim           INT           NOT NULL,
    data_reserva              DATE          NOT NULL,
    data_retirada_prevista    DATE          NOT NULL,
    data_devolucao_prevista   DATE          NOT NULL,
    duracao_prevista_dias     INT           NOT NULL,
    valor_previsto_reserva    DECIMAL(12,2) NOT NULL,
    status_reserva            VARCHAR(20)   NOT NULL,
    PRIMARY KEY (nk_frota_origem, nk_id_reserva)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_locacao (
    nk_frota_origem           VARCHAR(10)   NOT NULL,
    nk_id_locacao             INT           NOT NULL,
    nk_id_cliente             INT           NOT NULL,
    nk_id_veiculo             INT           NOT NULL,
    nk_id_grupo               INT           NOT NULL,
    nk_id_patio_retirada      INT           NOT NULL,
    nk_id_patio_devolucao     INT,              -- NULL se em andamento
    data_retirada             DATE          NOT NULL,
    data_prev_devolucao       DATE          NOT NULL,
    data_real_devolucao       DATE,              -- NULL se em andamento
    valor_final               DECIMAL(14,2) NOT NULL,
    PRIMARY KEY (nk_frota_origem, nk_id_locacao)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_snapshot_patio (
    nk_frota_origem       VARCHAR(20)  NOT NULL,
    nk_id_patio           INT          NOT NULL,
    nk_id_veiculo         INT          NOT NULL,
    nk_id_grupo           INT          NOT NULL,
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
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_transforma_patio;
CREATE PROCEDURE staging.sp_gupessanha_transforma_patio()
BEGIN
    DECLARE v_total   INT DEFAULT 0;
    DECLARE v_rejeit  INT DEFAULT 0;

    TRUNCATE TABLE staging.stg_conf_patio;

    INSERT INTO staging.stg_conf_patio (
        nk_frota_origem,
        nk_id_patio,
        nome_patio,
        capacidade_vagas,
        end_cidade,
        end_uf,
        end_pais
    )
    SELECT
        nk_frota_origem,
        nk_id_patio,
        -- T5: trim e title-case básico no nome
        CONCAT(
            UPPER(LEFT(TRIM(nome_patio), 1)),
            LOWER(SUBSTRING(TRIM(nome_patio), 2))
        )                                            AS nome_patio,
        -- T11: capacidade nula → sentinela -1
        COALESCE(capacidade_vagas, -1)               AS capacidade_vagas,
        -- T2: monta endereço desmembrado
        COALESCE(NULLIF(TRIM(end_cidade), ''), 'NÃO INFORMADO') AS end_cidade,
        COALESCE(NULLIF(TRIM(end_uf), ''), 'XX')                AS end_uf,
        'Brasil'                                                AS end_pais
    FROM staging.stg_gupessanha_patio
    WHERE nk_frota_origem = 'gupessanha';

    SET v_total = ROW_COUNT();
END;


--  2.2) sp_gupessanha_transforma_grupo
--       T10 valor_diaria NULL → 0 com aviso de rejeito (DQ)
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_transforma_grupo;
CREATE PROCEDURE staging.sp_gupessanha_transforma_grupo()
BEGIN
    DECLARE v_total INT DEFAULT 0;

    TRUNCATE TABLE staging.stg_conf_grupo;

    -- Registra rejeitos: grupos sem tarifa (qualidade de dados)
    INSERT INTO staging.stg_rejeitos_etl
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
        CONCAT(
            UPPER(LEFT(TRIM(COALESCE(nome_grupo, codigo_grupo, CONCAT('GRUPO ', nk_id_grupo))), 1)),
            LOWER(SUBSTRING(TRIM(COALESCE(nome_grupo, codigo_grupo, CONCAT('GRUPO ', nk_id_grupo))), 2))
        ),
        COALESCE(valor_diaria, 0)
    FROM staging.stg_gupessanha_grupo
    WHERE nk_frota_origem = 'gupessanha';

    SET v_total = ROW_COUNT();
END;


--  2.3) sp_gupessanha_transforma_veiculo
--       T4  Conformação mecanizacao (AUTOMATICA → AUTOMATICO)
--       T10 Campos obrigatórios nulos → sentinelas
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_transforma_veiculo;
CREATE PROCEDURE staging.sp_gupessanha_transforma_veiculo()
BEGIN
    DECLARE v_total  INT DEFAULT 0;
    DECLARE v_rejeit INT DEFAULT 0;

    TRUNCATE TABLE staging.stg_conf_veiculo;

    -- Rejeita veículos sem grupo ou sem pátio (inconsistência de FK)
    INSERT INTO staging.stg_rejeitos_etl
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_gupessanha_veiculo', nk_frota_origem, nk_id_veiculo,
        'Veículo sem nk_id_grupo ou sem nk_id_patio_origem'
    FROM staging.stg_gupessanha_veiculo
    WHERE nk_frota_origem = 'gupessanha'
      AND (nk_id_grupo IS NULL OR nk_id_patio_origem IS NULL);

    SET v_rejeit = ROW_COUNT();

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
        UPPER(TRIM(placa))                       AS placa,
        CONCAT(
            UPPER(LEFT(TRIM(COALESCE(marca, 'NÃO INFORMADO')), 1)),
            LOWER(SUBSTRING(TRIM(COALESCE(marca, 'NÃO INFORMADO')), 2))
        )                                        AS marca,
        CONCAT(
            UPPER(LEFT(TRIM(COALESCE(modelo, 'NÃO INFORMADO')), 1)),
            LOWER(SUBSTRING(TRIM(COALESCE(modelo, 'NÃO INFORMADO')), 2))
        )                                        AS modelo,
        -- T4: normaliza mecanização para 'MANUAL' ou 'AUTOMATICO'
        CASE UPPER(TRIM(COALESCE(mecanizacao, '')))
            WHEN 'MANUAL'     THEN 'MANUAL'
            WHEN 'AUTOMATICA' THEN 'AUTOMATICO'
            WHEN 'AUTOMATICO' THEN 'AUTOMATICO'
            ELSE 'NÃO INFORMADO'
        END                                      AS mecanizacao,
        COALESCE(tem_ar_condicionado, FALSE)     AS tem_ar_condicionado
    FROM staging.stg_gupessanha_veiculo
    WHERE nk_frota_origem = 'gupessanha'
      AND nk_id_grupo IS NOT NULL
      AND nk_id_patio_origem IS NOT NULL;

    SET v_total = ROW_COUNT();
END;


--  2.4) sp_gupessanha_transforma_cliente
--       T2  Endereços incompletos
--       T3  Conformação tipo_cliente
--       T5  Normalização de nome
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_transforma_cliente;
CREATE PROCEDURE staging.sp_gupessanha_transforma_cliente()
BEGIN
    DECLARE v_total  INT DEFAULT 0;
    DECLARE v_rejeit INT DEFAULT 0;

    TRUNCATE TABLE staging.stg_conf_cliente;

    -- Rejeita clientes sem tipo definido
    INSERT INTO staging.stg_rejeitos_etl
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_gupessanha_cliente', nk_frota_origem, nk_id_cliente,
        'Cliente sem tipo_cliente (PF/PJ)'
    FROM staging.stg_gupessanha_cliente
    WHERE nk_frota_origem = 'gupessanha'
      AND tipo_cliente NOT IN ('PF', 'PJ');

    SET v_rejeit = ROW_COUNT();

    INSERT INTO staging.stg_conf_cliente (
        nk_frota_origem,
        nk_id_cliente,
        tipo_cliente,
        nome,
        end_cidade,
        end_uf,
        end_pais
    )
    SELECT
        nk_frota_origem,
        nk_id_cliente,
        -- T3: garante domínio 'PF'/'PJ'
        UPPER(TRIM(tipo_cliente))                AS tipo_cliente,
        -- T5: trim e normalização básica de nome
        CONCAT(
            UPPER(LEFT(TRIM(COALESCE(nome, 'NÃO IDENTIFICADO')), 1)),
            LOWER(SUBSTRING(TRIM(COALESCE(nome, 'NÃO IDENTIFICADO')), 2))
        )                                        AS nome,
        -- T2: endereço conformado desmembrado
        COALESCE(NULLIF(TRIM(end_cidade), ''), 'NÃO INFORMADO') AS end_cidade,
        COALESCE(NULLIF(TRIM(end_uf), ''), 'XX')                AS end_uf,
        'Brasil'                                                AS end_pais
    FROM staging.stg_gupessanha_cliente
    WHERE nk_frota_origem = 'gupessanha'
      AND tipo_cliente IN ('PF', 'PJ');

    SET v_total = ROW_COUNT();
END;


--  2.5) sp_gupessanha_transforma_reserva
--       T6  Mapeamento de status para Dd_status_reserva do DW (ATIVA, CANCELADA, CONVERTIDA)
--       T7  Valida duração prevista (deve ser >= 1 dia)
--       T9  Valida consistência de datas
--       T10 NULLs em FKs obrigatórias → rejeito
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_transforma_reserva;
CREATE PROCEDURE staging.sp_gupessanha_transforma_reserva()
BEGIN
    DECLARE v_total  INT DEFAULT 0;
    DECLARE v_rejeit INT DEFAULT 0;

    TRUNCATE TABLE staging.stg_conf_reserva;

    -- T9 + T10: rejeita reservas com datas inválidas ou FKs nulas
    INSERT INTO staging.stg_rejeitos_etl
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
        JSON_OBJECT(
            'nk_id_reserva',           nk_id_reserva,
            'nk_id_cliente',           nk_id_cliente,
            'nk_id_grupo',             nk_id_grupo,
            'nk_id_patio_retirada',    nk_id_patio_retirada,
            'nk_id_patio_fim',         nk_id_patio_fim,
            'data_reserva',            data_reserva,
            'data_retirada_prevista',  data_retirada_prevista,
            'data_devolucao_prevista', data_devolucao_prevista,
            'duracao_prevista_dias',   duracao_prevista_dias,
            'status_reserva',          status_reserva
        )
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

    SET v_rejeit = ROW_COUNT();

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
        s.nk_frota_origem,
        s.nk_id_reserva,
        s.nk_id_cliente,
        s.nk_id_grupo,
        s.nk_id_patio_retirada,
        s.nk_id_patio_fim,
        s.data_reserva,
        s.data_retirada_prevista,
        s.data_devolucao_prevista,
        -- T7: duração recalculada para segurança
        DATEDIFF(s.data_devolucao_prevista, s.data_retirada_prevista) AS duracao_prevista_dias,
        -- T8: valor previsto mantido do OLTP (preserva descontos e negociações)
        COALESCE(s.valor_previsto_reserva, 0)                         AS valor_previsto_reserva,
        -- T6: status mapeado já vem do staging; confirmamos aqui
        CASE UPPER(TRIM(COALESCE(s.status_reserva, '')))
            WHEN 'ATIVA'      THEN 'ATIVA'
            WHEN 'CANCELADA'  THEN 'CANCELADA'
            WHEN 'CONVERTIDA' THEN 'CONVERTIDA'
            ELSE 'ATIVA'     -- default conservador
        END                                                           AS status_reserva
    FROM staging.stg_gupessanha_reserva s
    LEFT JOIN staging.stg_conf_grupo g
        ON g.nk_frota_origem = s.nk_frota_origem
       AND g.nk_id_grupo = s.nk_id_grupo
    WHERE s.nk_frota_origem = 'gupessanha'
      AND s.nk_id_cliente IS NOT NULL
      AND s.nk_id_grupo IS NOT NULL
      AND s.nk_id_patio_retirada IS NOT NULL
      AND s.nk_id_patio_fim IS NOT NULL
      AND s.data_reserva IS NOT NULL
      AND s.data_retirada_prevista IS NOT NULL
      AND s.data_devolucao_prevista IS NOT NULL
      AND s.data_devolucao_prevista > s.data_retirada_prevista
      AND COALESCE(s.duracao_prevista_dias, 0) >= 1;

    SET v_total = ROW_COUNT();
END;


--  2.6) sp_gupessanha_transforma_locacao
--       T8  Cálculo e validação do valor_final
--       T9  Validação de datas (retirada < devolução)
--       T10 NULLs críticos → rejeito
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_transforma_locacao;
CREATE PROCEDURE staging.sp_gupessanha_transforma_locacao()
BEGIN
    DECLARE v_total  INT DEFAULT 0;
    DECLARE v_rejeit INT DEFAULT 0;

    TRUNCATE TABLE staging.stg_conf_locacao;

    -- T9 + T10: rejeita locações com dados críticos ausentes/inválidos
    INSERT INTO staging.stg_rejeitos_etl
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
        JSON_OBJECT(
            'nk_id_locacao',          nk_id_locacao,
            'nk_id_cliente',          nk_id_cliente,
            'nk_id_veiculo',          nk_id_veiculo,
            'nk_id_grupo',            nk_id_grupo,
            'nk_id_patio_retirada',   nk_id_patio_retirada,
            'data_retirada',          data_retirada,
            'data_prev_devolucao',    data_prev_devolucao,
            'data_real_devolucao',    data_real_devolucao,
            'valor_final',            valor_final
        )
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

    SET v_rejeit = ROW_COUNT();

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

    SET v_total = ROW_COUNT();
END;


--  2.7) sp_gupessanha_transforma_snapshot_patio
--       Simples passthrough com validação de NULLs críticos.
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_transforma_snapshot_patio;
CREATE PROCEDURE staging.sp_gupessanha_transforma_snapshot_patio()
BEGIN
    DECLARE v_total INT DEFAULT 0;

    TRUNCATE TABLE staging.stg_conf_snapshot_patio;

    -- Rejeita registros com NULLs em FKs
    INSERT INTO staging.stg_rejeitos_etl
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

    SET v_total = ROW_COUNT();
END;



--  3) PROCEDURE MAIN DE TRANSFORMAÇÃO

DROP PROCEDURE IF EXISTS staging.sp_gupessanha_transformacao_completa;
CREATE PROCEDURE staging.sp_gupessanha_transformacao_completa()
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



--  4) VIEW DE MONITORAMENTO DE QUALIDADE

CREATE OR REPLACE VIEW staging.vw_gupessanha_qualidade_etl AS
SELECT
    tabela_origem,
    COUNT(*)                              AS total_rejeitos,
    MIN(dt_rejeito)                       AS primeiro_rejeito,
    MAX(dt_rejeito)                       AS ultimo_rejeito,
    GROUP_CONCAT(DISTINCT motivo_rejeito
        ORDER BY motivo_rejeito
        SEPARATOR ' | ')                  AS motivos_distintos
FROM staging.stg_rejeitos_etl
GROUP BY tabela_origem
ORDER BY total_rejeitos DESC;


-- =========================================================================
--  5) TRIGGERS DE TRANSFORMAÇÃO (Event-Driven)
--     Substituem as procedures de transformação para operação em tempo real.
--     Cada INSERT/UPDATE no staging bruto (stg_gupessanha_*) dispara a
--     transformação e grava no staging conformado (stg_conf_*).
-- =========================================================================

DELIMITER //

-- 5.1) Patio
DROP TRIGGER IF EXISTS staging.trg_transforma_gupessanha_patio_ai//
CREATE TRIGGER staging.trg_transforma_gupessanha_patio_ai
AFTER INSERT ON staging.stg_gupessanha_patio
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_conf_patio (
        nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas,
        end_cidade, end_uf, end_pais
    ) VALUES (
        NEW.nk_frota_origem, NEW.nk_id_patio,
        CONCAT(UPPER(LEFT(TRIM(NEW.nome_patio), 1)), LOWER(SUBSTRING(TRIM(NEW.nome_patio), 2))),
        COALESCE(NEW.capacidade_vagas, -1),
        COALESCE(NULLIF(TRIM(NEW.end_cidade), ''), 'NÃO INFORMADO'),
        COALESCE(NULLIF(TRIM(NEW.end_uf), ''), 'XX'), 'Brasil'
    ) ON DUPLICATE KEY UPDATE
        nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas),
        end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf);
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_gupessanha_patio_au//
CREATE TRIGGER staging.trg_transforma_gupessanha_patio_au
AFTER UPDATE ON staging.stg_gupessanha_patio
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_conf_patio (
        nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas,
        end_cidade, end_uf, end_pais
    ) VALUES (
        NEW.nk_frota_origem, NEW.nk_id_patio,
        CONCAT(UPPER(LEFT(TRIM(NEW.nome_patio), 1)), LOWER(SUBSTRING(TRIM(NEW.nome_patio), 2))),
        COALESCE(NEW.capacidade_vagas, -1),
        COALESCE(NULLIF(TRIM(NEW.end_cidade), ''), 'NÃO INFORMADO'),
        COALESCE(NULLIF(TRIM(NEW.end_uf), ''), 'XX'), 'Brasil'
    ) ON DUPLICATE KEY UPDATE
        nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas),
        end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf);
END//

-- 5.2) Grupo
DROP TRIGGER IF EXISTS staging.trg_transforma_gupessanha_grupo_ai//
CREATE TRIGGER staging.trg_transforma_gupessanha_grupo_ai
AFTER INSERT ON staging.stg_gupessanha_grupo
FOR EACH ROW
BEGIN
    IF NEW.valor_diaria IS NULL OR NEW.valor_diaria = 0 THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_gupessanha_grupo', NEW.nk_frota_origem, NEW.nk_id_grupo, 'Grupo sem valor_diaria vigente; será carregado com valor 0,00');
    END IF;

    INSERT INTO staging.stg_conf_grupo (
        nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria
    ) VALUES (
        NEW.nk_frota_origem, NEW.nk_id_grupo,
        CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome_grupo, NEW.codigo_grupo, CONCAT('GRUPO ', NEW.nk_id_grupo))), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome_grupo, NEW.codigo_grupo, CONCAT('GRUPO ', NEW.nk_id_grupo))), 2))),
        COALESCE(NEW.valor_diaria, 0)
    ) ON DUPLICATE KEY UPDATE
        nome_grupo = VALUES(nome_grupo), valor_diaria = VALUES(valor_diaria);
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_gupessanha_grupo_au//
CREATE TRIGGER staging.trg_transforma_gupessanha_grupo_au
AFTER UPDATE ON staging.stg_gupessanha_grupo
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_conf_grupo (
        nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria
    ) VALUES (
        NEW.nk_frota_origem, NEW.nk_id_grupo,
        CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome_grupo, NEW.codigo_grupo, CONCAT('GRUPO ', NEW.nk_id_grupo))), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome_grupo, NEW.codigo_grupo, CONCAT('GRUPO ', NEW.nk_id_grupo))), 2))),
        COALESCE(NEW.valor_diaria, 0)
    ) ON DUPLICATE KEY UPDATE
        nome_grupo = VALUES(nome_grupo), valor_diaria = VALUES(valor_diaria);
END//

-- 5.3) Veiculo
DROP TRIGGER IF EXISTS staging.trg_transforma_gupessanha_veiculo_ai//
CREATE TRIGGER staging.trg_transforma_gupessanha_veiculo_ai
AFTER INSERT ON staging.stg_gupessanha_veiculo
FOR EACH ROW
BEGIN
    IF NEW.nk_id_grupo IS NULL OR NEW.nk_id_patio_origem IS NULL THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_gupessanha_veiculo', NEW.nk_frota_origem, NEW.nk_id_veiculo, 'Veículo sem nk_id_grupo ou sem nk_id_patio_origem');
    ELSE
        INSERT INTO staging.stg_conf_veiculo (
            nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
            placa, marca, modelo, mecanizacao, tem_ar_condicionado
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_veiculo, NEW.nk_id_grupo, NEW.nk_id_patio_origem,
            UPPER(TRIM(NEW.placa)),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 2))),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 2))),
            CASE UPPER(TRIM(COALESCE(NEW.mecanizacao, ''))) WHEN 'MANUAL' THEN 'MANUAL' WHEN 'AUTOMATICA' THEN 'AUTOMATICO' WHEN 'AUTOMATICO' THEN 'AUTOMATICO' ELSE 'NÃO INFORMADO' END,
            COALESCE(NEW.tem_ar_condicionado, FALSE)
        ) ON DUPLICATE KEY UPDATE
            nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_origem = VALUES(nk_id_patio_origem),
            placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
            mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_gupessanha_veiculo_au//
CREATE TRIGGER staging.trg_transforma_gupessanha_veiculo_au
AFTER UPDATE ON staging.stg_gupessanha_veiculo
FOR EACH ROW
BEGIN
    IF NEW.nk_id_grupo IS NOT NULL AND NEW.nk_id_patio_origem IS NOT NULL THEN
        INSERT INTO staging.stg_conf_veiculo (
            nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
            placa, marca, modelo, mecanizacao, tem_ar_condicionado
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_veiculo, NEW.nk_id_grupo, NEW.nk_id_patio_origem,
            UPPER(TRIM(NEW.placa)),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 2))),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 2))),
            CASE UPPER(TRIM(COALESCE(NEW.mecanizacao, ''))) WHEN 'MANUAL' THEN 'MANUAL' WHEN 'AUTOMATICA' THEN 'AUTOMATICO' WHEN 'AUTOMATICO' THEN 'AUTOMATICO' ELSE 'NÃO INFORMADO' END,
            COALESCE(NEW.tem_ar_condicionado, FALSE)
        ) ON DUPLICATE KEY UPDATE
            nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_origem = VALUES(nk_id_patio_origem),
            placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
            mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado);
    END IF;
END//

-- 5.4) Cliente
DROP TRIGGER IF EXISTS staging.trg_transforma_gupessanha_cliente_ai//
CREATE TRIGGER staging.trg_transforma_gupessanha_cliente_ai
AFTER INSERT ON staging.stg_gupessanha_cliente
FOR EACH ROW
BEGIN
    IF NEW.tipo_cliente NOT IN ('PF', 'PJ') THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_gupessanha_cliente', NEW.nk_frota_origem, NEW.nk_id_cliente, 'Cliente sem tipo_cliente (PF/PJ)');
    ELSE
        INSERT INTO staging.stg_conf_cliente (
            nk_frota_origem, nk_id_cliente, tipo_cliente, nome, end_cidade, end_uf, end_pais
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_cliente, UPPER(TRIM(NEW.tipo_cliente)),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome, 'NÃO IDENTIFICADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome, 'NÃO IDENTIFICADO')), 2))),
            COALESCE(NULLIF(TRIM(NEW.end_cidade), ''), 'NÃO INFORMADO'),
            COALESCE(NULLIF(TRIM(NEW.end_uf), ''), 'XX'), 'Brasil'
        ) ON DUPLICATE KEY UPDATE
            tipo_cliente = VALUES(tipo_cliente), nome = VALUES(nome),
            end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_gupessanha_cliente_au//
CREATE TRIGGER staging.trg_transforma_gupessanha_cliente_au
AFTER UPDATE ON staging.stg_gupessanha_cliente
FOR EACH ROW
BEGIN
    IF NEW.tipo_cliente IN ('PF', 'PJ') THEN
        INSERT INTO staging.stg_conf_cliente (
            nk_frota_origem, nk_id_cliente, tipo_cliente, nome, end_cidade, end_uf, end_pais
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_cliente, UPPER(TRIM(NEW.tipo_cliente)),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome, 'NÃO IDENTIFICADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome, 'NÃO IDENTIFICADO')), 2))),
            COALESCE(NULLIF(TRIM(NEW.end_cidade), ''), 'NÃO INFORMADO'),
            COALESCE(NULLIF(TRIM(NEW.end_uf), ''), 'XX'), 'Brasil'
        ) ON DUPLICATE KEY UPDATE
            tipo_cliente = VALUES(tipo_cliente), nome = VALUES(nome),
            end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf);
    END IF;
END//

-- 5.5) Reserva
DROP TRIGGER IF EXISTS staging.trg_transforma_gupessanha_reserva_ai//
CREATE TRIGGER staging.trg_transforma_gupessanha_reserva_ai
AFTER INSERT ON staging.stg_gupessanha_reserva
FOR EACH ROW
BEGIN
    IF NEW.nk_id_cliente IS NULL OR NEW.nk_id_grupo IS NULL OR NEW.nk_id_patio_retirada IS NULL OR NEW.nk_id_patio_fim IS NULL OR NEW.data_reserva IS NULL OR NEW.data_retirada_prevista IS NULL OR NEW.data_devolucao_prevista IS NULL OR NEW.data_devolucao_prevista <= NEW.data_retirada_prevista OR COALESCE(NEW.duracao_prevista_dias, 0) < 1 THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_gupessanha_reserva', NEW.nk_frota_origem, NEW.nk_id_reserva, 'Reserva inválida');
    ELSE
        INSERT INTO staging.stg_conf_reserva (
            nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim,
            data_reserva, data_retirada_prevista, data_devolucao_prevista, duracao_prevista_dias, valor_previsto_reserva, status_reserva
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_reserva, NEW.nk_id_cliente, NEW.nk_id_grupo, NEW.nk_id_patio_retirada, NEW.nk_id_patio_fim,
            NEW.data_reserva, NEW.data_retirada_prevista, NEW.data_devolucao_prevista,
            DATEDIFF(NEW.data_devolucao_prevista, NEW.data_retirada_prevista),
            COALESCE(NEW.valor_previsto_reserva, 0),
            CASE UPPER(TRIM(COALESCE(NEW.status_reserva, ''))) WHEN 'ATIVA' THEN 'ATIVA' WHEN 'CANCELADA' THEN 'CANCELADA' WHEN 'CONVERTIDA' THEN 'CONVERTIDA' ELSE 'ATIVA' END
        ) ON DUPLICATE KEY UPDATE
            status_reserva = VALUES(status_reserva), valor_previsto_reserva = VALUES(valor_previsto_reserva);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_gupessanha_reserva_au//
CREATE TRIGGER staging.trg_transforma_gupessanha_reserva_au
AFTER UPDATE ON staging.stg_gupessanha_reserva
FOR EACH ROW
BEGIN
    IF NEW.nk_id_cliente IS NOT NULL AND NEW.nk_id_grupo IS NOT NULL AND NEW.nk_id_patio_retirada IS NOT NULL AND NEW.nk_id_patio_fim IS NOT NULL AND NEW.data_reserva IS NOT NULL AND NEW.data_retirada_prevista IS NOT NULL AND NEW.data_devolucao_prevista IS NOT NULL AND NEW.data_devolucao_prevista > NEW.data_retirada_prevista AND COALESCE(NEW.duracao_prevista_dias, 0) >= 1 THEN
        INSERT INTO staging.stg_conf_reserva (
            nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim,
            data_reserva, data_retirada_prevista, data_devolucao_prevista, duracao_prevista_dias, valor_previsto_reserva, status_reserva
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_reserva, NEW.nk_id_cliente, NEW.nk_id_grupo, NEW.nk_id_patio_retirada, NEW.nk_id_patio_fim,
            NEW.data_reserva, NEW.data_retirada_prevista, NEW.data_devolucao_prevista,
            DATEDIFF(NEW.data_devolucao_prevista, NEW.data_retirada_prevista),
            COALESCE(NEW.valor_previsto_reserva, 0),
            CASE UPPER(TRIM(COALESCE(NEW.status_reserva, ''))) WHEN 'ATIVA' THEN 'ATIVA' WHEN 'CANCELADA' THEN 'CANCELADA' WHEN 'CONVERTIDA' THEN 'CONVERTIDA' ELSE 'ATIVA' END
        ) ON DUPLICATE KEY UPDATE
            status_reserva = VALUES(status_reserva), valor_previsto_reserva = VALUES(valor_previsto_reserva);
    END IF;
END//

-- 5.6) Locação
DROP TRIGGER IF EXISTS staging.trg_transforma_gupessanha_locacao_ai//
CREATE TRIGGER staging.trg_transforma_gupessanha_locacao_ai
AFTER INSERT ON staging.stg_gupessanha_locacao
FOR EACH ROW
BEGIN
    IF NEW.nk_id_cliente IS NULL OR NEW.nk_id_veiculo IS NULL OR NEW.nk_id_grupo IS NULL OR NEW.nk_id_patio_retirada IS NULL OR NEW.data_retirada IS NULL OR NEW.data_prev_devolucao IS NULL OR (NEW.data_real_devolucao IS NOT NULL AND NEW.data_real_devolucao < NEW.data_retirada) THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_gupessanha_locacao', NEW.nk_frota_origem, NEW.nk_id_locacao, 'Locação inválida');
    ELSE
        INSERT INTO staging.stg_conf_locacao (
            nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_devolucao,
            data_retirada, data_prev_devolucao, data_real_devolucao, valor_final
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_locacao, NEW.nk_id_cliente, NEW.nk_id_veiculo, NEW.nk_id_grupo, NEW.nk_id_patio_retirada, NEW.nk_id_patio_devolucao,
            NEW.data_retirada, NEW.data_prev_devolucao, NEW.data_real_devolucao, GREATEST(COALESCE(NEW.valor_final, 0), 0)
        ) ON DUPLICATE KEY UPDATE
            nk_id_patio_devolucao = VALUES(nk_id_patio_devolucao), data_real_devolucao = VALUES(data_real_devolucao), valor_final = VALUES(valor_final);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_gupessanha_locacao_au//
CREATE TRIGGER staging.trg_transforma_gupessanha_locacao_au
AFTER UPDATE ON staging.stg_gupessanha_locacao
FOR EACH ROW
BEGIN
    IF NEW.nk_id_cliente IS NOT NULL AND NEW.nk_id_veiculo IS NOT NULL AND NEW.nk_id_grupo IS NOT NULL AND NEW.nk_id_patio_retirada IS NOT NULL AND NEW.data_retirada IS NOT NULL AND NEW.data_prev_devolucao IS NOT NULL AND (NEW.data_real_devolucao IS NULL OR NEW.data_real_devolucao >= NEW.data_retirada) THEN
        INSERT INTO staging.stg_conf_locacao (
            nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_devolucao,
            data_retirada, data_prev_devolucao, data_real_devolucao, valor_final
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_locacao, NEW.nk_id_cliente, NEW.nk_id_veiculo, NEW.nk_id_grupo, NEW.nk_id_patio_retirada, NEW.nk_id_patio_devolucao,
            NEW.data_retirada, NEW.data_prev_devolucao, NEW.data_real_devolucao, GREATEST(COALESCE(NEW.valor_final, 0), 0)
        ) ON DUPLICATE KEY UPDATE
            nk_id_patio_devolucao = VALUES(nk_id_patio_devolucao), data_real_devolucao = VALUES(data_real_devolucao), valor_final = VALUES(valor_final);
    END IF;
END//

DELIMITER ;
