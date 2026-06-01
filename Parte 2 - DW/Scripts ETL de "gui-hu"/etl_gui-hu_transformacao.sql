-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)

-- -----------------------------------------------------------------------------
-- ARQUIVO : etl_guilherme_hu_transformacao.sql
-- ESCOPO  : Camada de Transformação (T) do Processo ETL
-- FLUXO   : Staging Bruto (guilherme-hu) ➔ Staging Conformado (Comum do DW)
-- -----------------------------------------------------------------------------
-- ID DA FROTA DE ORIGEM : 'guilherme-hu'
--
-- ESTRATÉGIA:
--   • Os dados da stg_guilherme_hu_* são lidos, limpos e validados.
--   • Registros válidos vão para as tabelas stg_conf_* (compartilhadas por todas frotas).
--   • Registros inválidos (ex: datas inconsistentes, FKs nulas) vão para stg_rejeitos_etl.
--   • Suporta execução Batch via Procedures e Event-Driven via Triggers.
-- -----------------------------------------------------------------------------

-- =============================================================================
-- 1) TABELAS CONFORMADAS E DE REJEITOS (Garantia de Existência)
-- =============================================================================

CREATE TABLE IF NOT EXISTS staging.stg_rejeitos_etl (
    id_rejeito      INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    tabela_origem   VARCHAR(50)  NOT NULL,
    nk_frota_origem VARCHAR(30),
    nk_id_registro  INT,
    motivo_rejeito  VARCHAR(500) NOT NULL,
    dados_json      TEXT,
    dt_rejeito      DATETIME     NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_patio (
    nk_frota_origem       VARCHAR(30)  NOT NULL,
    nk_id_patio           INT          NOT NULL,
    nome_patio            VARCHAR(100) NOT NULL,
    capacidade_vagas      INT          NOT NULL,
    end_cidade            VARCHAR(100),
    end_uf                VARCHAR(100),
    end_pais              VARCHAR(100),
    PRIMARY KEY (nk_frota_origem, nk_id_patio)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_grupo (
    nk_frota_origem       VARCHAR(30)   NOT NULL,
    nk_id_grupo           INT           NOT NULL,
    nome_grupo            VARCHAR(80)   NOT NULL,
    valor_diaria          DECIMAL(12,2) NOT NULL,
    PRIMARY KEY (nk_frota_origem, nk_id_grupo)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_veiculo (
    nk_frota_origem       VARCHAR(30)  NOT NULL,
    nk_id_veiculo         INT          NOT NULL,
    nk_id_grupo           INT          NOT NULL,
    nk_id_patio_origem    INT,
    placa                 VARCHAR(10)  NOT NULL,
    marca                 VARCHAR(50)  NOT NULL,
    modelo                VARCHAR(60)  NOT NULL,
    mecanizacao           VARCHAR(20)  NOT NULL,
    tem_ar_condicionado   TINYINT(1)   NOT NULL,
    PRIMARY KEY (nk_frota_origem, nk_id_veiculo)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_cliente (
    nk_frota_origem       VARCHAR(30)  NOT NULL,
    nk_id_cliente         INT          NOT NULL,
    tipo_cliente          VARCHAR(2)   NOT NULL,
    nome                  VARCHAR(150) NOT NULL,
    end_cidade            VARCHAR(100),
    end_uf                VARCHAR(100),
    end_pais              VARCHAR(100),
    PRIMARY KEY (nk_frota_origem, nk_id_cliente)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_reserva (
    nk_frota_origem           VARCHAR(30)   NOT NULL,
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
    status_reserva            VARCHAR(100)  NOT NULL,
    PRIMARY KEY (nk_frota_origem, nk_id_reserva)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_locacao (
    nk_frota_origem           VARCHAR(30)   NOT NULL,
    nk_id_locacao             INT           NOT NULL,
    nk_id_cliente             INT           NOT NULL,
    nk_id_veiculo             INT           NOT NULL,
    nk_id_grupo               INT           NOT NULL,
    nk_id_patio_retirada      INT           NOT NULL,
    nk_id_patio_devolucao     INT,
    data_retirada             DATE          NOT NULL,
    data_prev_devolucao       DATE          NOT NULL,
    data_real_devolucao       DATE,
    valor_final               DECIMAL(14,2) NOT NULL,
    PRIMARY KEY (nk_frota_origem, nk_id_locacao)
);

CREATE TABLE IF NOT EXISTS staging.stg_conf_snapshot_patio (
    nk_frota_origem       VARCHAR(30)  NOT NULL,
    nk_id_patio           INT          NOT NULL,
    nk_id_veiculo         INT          NOT NULL,
    nk_id_grupo           INT          NOT NULL,
    data_snapshot         DATE         NOT NULL,
    PRIMARY KEY (nk_frota_origem, nk_id_patio, nk_id_veiculo, data_snapshot)
);

-- =============================================================================
-- 2) PROCEDURES DE TRANSFORMAÇÃO (Carga em Lote / Batch)
-- =============================================================================

-- 2.1) Patio
DROP PROCEDURE IF EXISTS staging.sp_guilherme_hu_transforma_patio;
DELIMITER //
CREATE PROCEDURE staging.sp_guilherme_hu_transforma_patio()
BEGIN
    DELETE FROM staging.stg_conf_patio WHERE nk_frota_origem = 'guilherme-hu';

    INSERT INTO staging.stg_conf_patio (nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas, end_cidade, end_uf, end_pais)
    SELECT
        nk_frota_origem, nk_id_patio,
        CONCAT(UPPER(LEFT(TRIM(nome_patio), 1)), LOWER(SUBSTRING(TRIM(nome_patio), 2))) AS nome_patio,
        COALESCE(capacidade_vagas, -1) AS capacidade_vagas,
        COALESCE(NULLIF(TRIM(end_cidade), ''), 'NÃO INFORMADO') AS end_cidade,
        COALESCE(NULLIF(TRIM(end_uf), ''), 'XX') AS end_uf,
        'Brasil' AS end_pais
    FROM staging.stg_guilherme_hu_patio
    WHERE nk_frota_origem = 'guilherme-hu';
END//
DELIMITER ;

-- 2.2) Grupo
DROP PROCEDURE IF EXISTS staging.sp_guilherme_hu_transforma_grupo;
DELIMITER //
CREATE PROCEDURE staging.sp_guilherme_hu_transforma_grupo()
BEGIN
    DELETE FROM staging.stg_conf_grupo WHERE nk_frota_origem = 'guilherme-hu';

    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT 'stg_guilherme_hu_grupo', nk_frota_origem, nk_id_grupo, 'Grupo sem valor_diaria vigente; será carregado com valor 0,00'
    FROM staging.stg_guilherme_hu_grupo
    WHERE nk_frota_origem = 'guilherme-hu' AND (valor_diaria IS NULL OR valor_diaria = 0);

    INSERT INTO staging.stg_conf_grupo (nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria)
    SELECT nk_frota_origem, nk_id_grupo,
        CONCAT(UPPER(LEFT(TRIM(COALESCE(nome_grupo, CONCAT('GRUPO ', nk_id_grupo))), 1)), LOWER(SUBSTRING(TRIM(COALESCE(nome_grupo, CONCAT('GRUPO ', nk_id_grupo))), 2))),
        COALESCE(valor_diaria, 0)
    FROM staging.stg_guilherme_hu_grupo
    WHERE nk_frota_origem = 'guilherme-hu';
END//
DELIMITER ;

-- 2.3) Veiculo
DROP PROCEDURE IF EXISTS staging.sp_guilherme_hu_transforma_veiculo;
DELIMITER //
CREATE PROCEDURE staging.sp_guilherme_hu_transforma_veiculo()
BEGIN
    DELETE FROM staging.stg_conf_veiculo WHERE nk_frota_origem = 'guilherme-hu';

    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT 'stg_guilherme_hu_veiculo', nk_frota_origem, nk_id_veiculo, 'Veículo sem nk_id_grupo'
    FROM staging.stg_guilherme_hu_veiculo
    WHERE nk_frota_origem = 'guilherme-hu' AND nk_id_grupo IS NULL;

    INSERT INTO staging.stg_conf_veiculo (nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem, placa, marca, modelo, mecanizacao, tem_ar_condicionado)
    SELECT nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
        UPPER(TRIM(placa)),
        CONCAT(UPPER(LEFT(TRIM(COALESCE(marca, 'NÃO INFORMADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(marca, 'NÃO INFORMADO')), 2))),
        CONCAT(UPPER(LEFT(TRIM(COALESCE(modelo, 'NÃO INFORMADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(modelo, 'NÃO INFORMADO')), 2))),
        CASE UPPER(TRIM(COALESCE(mecanizacao, ''))) WHEN 'MANUAL' THEN 'MANUAL' WHEN 'AUTOMATICO' THEN 'AUTOMATICO' ELSE 'NÃO INFORMADO' END,
        COALESCE(tem_ar_condicionado, FALSE)
    FROM staging.stg_guilherme_hu_veiculo
    WHERE nk_frota_origem = 'guilherme-hu' AND nk_id_grupo IS NOT NULL;
END//
DELIMITER ;

-- 2.4) Cliente
DROP PROCEDURE IF EXISTS staging.sp_guilherme_hu_transforma_cliente;
DELIMITER //
CREATE PROCEDURE staging.sp_guilherme_hu_transforma_cliente()
BEGIN
    DELETE FROM staging.stg_conf_cliente WHERE nk_frota_origem = 'guilherme-hu';

    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT 'stg_guilherme_hu_cliente', nk_frota_origem, nk_id_cliente, 'Cliente sem tipo_cliente válido'
    FROM staging.stg_guilherme_hu_cliente
    WHERE nk_frota_origem = 'guilherme-hu' AND tipo_cliente NOT IN ('PF', 'PJ');

    INSERT INTO staging.stg_conf_cliente (nk_frota_origem, nk_id_cliente, tipo_cliente, nome, end_cidade, end_uf, end_pais)
    SELECT nk_frota_origem, nk_id_cliente,
        UPPER(TRIM(tipo_cliente)),
        CONCAT(UPPER(LEFT(TRIM(COALESCE(nome, 'NÃO IDENTIFICADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(nome, 'NÃO IDENTIFICADO')), 2))),
        COALESCE(NULLIF(TRIM(end_cidade), ''), 'NÃO INFORMADO'),
        COALESCE(NULLIF(TRIM(end_uf), ''), 'XX'), 'Brasil'
    FROM staging.stg_guilherme_hu_cliente
    WHERE nk_frota_origem = 'guilherme-hu' AND tipo_cliente IN ('PF', 'PJ');
END//
DELIMITER ;

-- 2.5) Reserva
DROP PROCEDURE IF EXISTS staging.sp_guilherme_hu_transforma_reserva;
DELIMITER //
CREATE PROCEDURE staging.sp_guilherme_hu_transforma_reserva()
BEGIN
    DELETE FROM staging.stg_conf_reserva WHERE nk_frota_origem = 'guilherme-hu';

    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json)
    SELECT 'stg_guilherme_hu_reserva', nk_frota_origem, nk_id_reserva,
        CASE
            WHEN nk_id_cliente IS NULL THEN 'Reserva sem cliente'
            WHEN nk_id_grupo IS NULL THEN 'Reserva sem grupo'
            WHEN nk_id_patio_retirada IS NULL THEN 'Reserva sem pátio de retirada'
            WHEN nk_id_patio_fim IS NULL THEN 'Reserva sem pátio de fim'
            WHEN data_reserva IS NULL THEN 'Reserva sem data de reserva'
            WHEN data_retirada_prevista IS NULL THEN 'Reserva sem data de retirada prevista'
            WHEN data_devolucao_prevista IS NULL THEN 'Reserva sem data de devolução prevista'
            WHEN data_devolucao_prevista <= data_retirada_prevista THEN 'Data devolução <= data retirada'
            WHEN COALESCE(duracao_prevista_dias, 0) < 1 THEN 'Duração prevista inválida (< 1 dia)'
            ELSE 'Erro desconhecido'
        END,
        JSON_OBJECT('nk_id_reserva', nk_id_reserva, 'nk_id_cliente', nk_id_cliente, 'nk_id_grupo', nk_id_grupo, 'nk_id_patio_retirada', nk_id_patio_retirada, 'nk_id_patio_fim', nk_id_patio_fim, 'data_reserva', data_reserva, 'data_retirada_prevista', data_retirada_prevista, 'data_devolucao_prevista', data_devolucao_prevista, 'duracao_prevista_dias', duracao_prevista_dias, 'status_reserva', status_reserva)
    FROM staging.stg_guilherme_hu_reserva
    WHERE nk_frota_origem = 'guilherme-hu'
      AND (nk_id_cliente IS NULL OR nk_id_grupo IS NULL OR nk_id_patio_retirada IS NULL OR nk_id_patio_fim IS NULL OR data_reserva IS NULL OR data_retirada_prevista IS NULL OR data_devolucao_prevista IS NULL OR data_devolucao_prevista <= data_retirada_prevista OR COALESCE(duracao_prevista_dias, 0) < 1);

    INSERT INTO staging.stg_conf_reserva (nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim, data_reserva, data_retirada_prevista, data_devolucao_prevista, duracao_prevista_dias, valor_previsto_reserva, status_reserva)
    SELECT nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim,
        data_reserva, data_retirada_prevista, data_devolucao_prevista,
        DATEDIFF(data_devolucao_prevista, data_retirada_prevista) AS duracao_prevista_dias,
        COALESCE(valor_previsto_reserva, 0),
        CASE UPPER(TRIM(COALESCE(status_reserva, ''))) WHEN 'ATIVA' THEN 'ATIVA' WHEN 'CANCELADA' THEN 'CANCELADA' WHEN 'CONVERTIDA' THEN 'CONVERTIDA' ELSE 'ATIVA' END
    FROM staging.stg_guilherme_hu_reserva
    WHERE nk_frota_origem = 'guilherme-hu' AND nk_id_cliente IS NOT NULL AND nk_id_grupo IS NOT NULL AND nk_id_patio_retirada IS NOT NULL AND nk_id_patio_fim IS NOT NULL AND data_reserva IS NOT NULL AND data_retirada_prevista IS NOT NULL AND data_devolucao_prevista IS NOT NULL AND data_devolucao_prevista > data_retirada_prevista AND COALESCE(duracao_prevista_dias, 0) >= 1;
END//
DELIMITER ;

-- 2.6) Locacao
DROP PROCEDURE IF EXISTS staging.sp_guilherme_hu_transforma_locacao;
DELIMITER //
CREATE PROCEDURE staging.sp_guilherme_hu_transforma_locacao()
BEGIN
    DELETE FROM staging.stg_conf_locacao WHERE nk_frota_origem = 'guilherme-hu';

    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json)
    SELECT 'stg_guilherme_hu_locacao', nk_frota_origem, nk_id_locacao,
        CASE
            WHEN nk_id_cliente IS NULL THEN 'Locação sem cliente'
            WHEN nk_id_veiculo IS NULL THEN 'Locação sem veículo'
            WHEN nk_id_grupo IS NULL THEN 'Locação sem grupo'
            WHEN nk_id_patio_retirada IS NULL THEN 'Locação sem pátio de retirada'
            WHEN data_retirada IS NULL THEN 'Locação sem data de retirada'
            WHEN data_prev_devolucao IS NULL THEN 'Locação sem data prev. devolução'
            WHEN data_real_devolucao IS NOT NULL AND data_real_devolucao < data_retirada THEN 'Data devolução real anterior à retirada'
            ELSE 'Erro desconhecido'
        END, JSON_OBJECT('nk_id_locacao', nk_id_locacao, 'nk_id_cliente', nk_id_cliente, 'nk_id_veiculo', nk_id_veiculo, 'nk_id_grupo', nk_id_grupo, 'nk_id_patio_retirada', nk_id_patio_retirada, 'data_retirada', data_retirada, 'data_prev_devolucao', data_prev_devolucao, 'data_real_devolucao', data_real_devolucao, 'valor_final', valor_final)
    FROM staging.stg_guilherme_hu_locacao
    WHERE nk_frota_origem = 'guilherme-hu'
      AND (nk_id_cliente IS NULL OR nk_id_veiculo IS NULL OR nk_id_grupo IS NULL OR nk_id_patio_retirada IS NULL OR data_retirada IS NULL OR data_prev_devolucao IS NULL OR (data_real_devolucao IS NOT NULL AND data_real_devolucao < data_retirada));

    INSERT INTO staging.stg_conf_locacao (nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_devolucao, data_retirada, data_prev_devolucao, data_real_devolucao, valor_final)
    SELECT nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_devolucao,
        data_retirada, data_prev_devolucao, data_real_devolucao,
        GREATEST(COALESCE(valor_final, 0), 0)
    FROM staging.stg_guilherme_hu_locacao
    WHERE nk_frota_origem = 'guilherme-hu' AND nk_id_cliente IS NOT NULL AND nk_id_veiculo IS NOT NULL AND nk_id_grupo IS NOT NULL AND nk_id_patio_retirada IS NOT NULL AND data_retirada IS NOT NULL AND data_prev_devolucao IS NOT NULL AND (data_real_devolucao IS NULL OR data_real_devolucao >= data_retirada);
END//
DELIMITER ;

-- 2.7) Snapshot Patio
DROP PROCEDURE IF EXISTS staging.sp_guilherme_hu_transforma_snapshot_patio;
DELIMITER //
CREATE PROCEDURE staging.sp_guilherme_hu_transforma_snapshot_patio()
BEGIN
    DELETE FROM staging.stg_conf_snapshot_patio WHERE nk_frota_origem = 'guilherme-hu';

    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT 'stg_guilherme_hu_snapshot_patio', nk_frota_origem, nk_id_veiculo, 'Snapshot sem chaves válidas'
    FROM staging.stg_guilherme_hu_snapshot_patio
    WHERE nk_frota_origem = 'guilherme-hu' AND (nk_id_patio IS NULL OR nk_id_veiculo IS NULL OR nk_id_grupo IS NULL OR data_snapshot IS NULL);

    INSERT INTO staging.stg_conf_snapshot_patio (nk_frota_origem, nk_id_patio, nk_id_veiculo, nk_id_grupo, data_snapshot)
    SELECT nk_frota_origem, nk_id_patio, nk_id_veiculo, nk_id_grupo, data_snapshot
    FROM staging.stg_guilherme_hu_snapshot_patio
    WHERE nk_frota_origem = 'guilherme-hu' AND nk_id_patio IS NOT NULL AND nk_id_veiculo IS NOT NULL AND nk_id_grupo IS NOT NULL AND data_snapshot IS NOT NULL;
END//
DELIMITER ;

-- =============================================================================
-- 3) PROCEDURE MAIN
-- =============================================================================
DROP PROCEDURE IF EXISTS staging.sp_guilherme_hu_transformacao_completa;
DELIMITER //
CREATE PROCEDURE staging.sp_guilherme_hu_transformacao_completa()
BEGIN
    CALL staging.sp_guilherme_hu_transforma_patio();
    CALL staging.sp_guilherme_hu_transforma_grupo();
    CALL staging.sp_guilherme_hu_transforma_veiculo();
    CALL staging.sp_guilherme_hu_transforma_cliente();
    CALL staging.sp_guilherme_hu_transforma_reserva();
    CALL staging.sp_guilherme_hu_transforma_locacao();
    CALL staging.sp_guilherme_hu_transforma_snapshot_patio();
END//
DELIMITER ;

-- =============================================================================
-- 4) VIEW DE MONITORAMENTO DE QUALIDADE
-- =============================================================================
CREATE OR REPLACE VIEW staging.vw_guilherme_hu_qualidade_etl AS
SELECT
    tabela_origem,
    COUNT(*) AS total_rejeitos,
    MIN(dt_rejeito) AS primeiro_rejeito,
    MAX(dt_rejeito) AS ultimo_rejeito,
    GROUP_CONCAT(DISTINCT motivo_rejeito ORDER BY motivo_rejeito SEPARATOR ' | ') AS motivos_distintos
FROM staging.stg_rejeitos_etl
WHERE nk_frota_origem = 'guilherme-hu'
GROUP BY tabela_origem
ORDER BY total_rejeitos DESC;

-- =============================================================================
-- 5) TRIGGERS DE TRANSFORMAÇÃO (Event-Driven)
-- =============================================================================
DELIMITER //

-- Patio
DROP TRIGGER IF EXISTS staging.trg_transforma_guilherme_hu_patio_ai//
CREATE TRIGGER staging.trg_transforma_guilherme_hu_patio_ai AFTER INSERT ON staging.stg_guilherme_hu_patio FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_conf_patio (nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas, end_cidade, end_uf, end_pais)
    VALUES (NEW.nk_frota_origem, NEW.nk_id_patio, CONCAT(UPPER(LEFT(TRIM(NEW.nome_patio), 1)), LOWER(SUBSTRING(TRIM(NEW.nome_patio), 2))), COALESCE(NEW.capacidade_vagas, -1), COALESCE(NULLIF(TRIM(NEW.end_cidade), ''), 'NÃO INFORMADO'), COALESCE(NULLIF(TRIM(NEW.end_uf), ''), 'XX'), 'Brasil')
    ON DUPLICATE KEY UPDATE nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas), end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf);
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_guilherme_hu_patio_au//
CREATE TRIGGER staging.trg_transforma_guilherme_hu_patio_au AFTER UPDATE ON staging.stg_guilherme_hu_patio FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_conf_patio (nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas, end_cidade, end_uf, end_pais)
    VALUES (NEW.nk_frota_origem, NEW.nk_id_patio, CONCAT(UPPER(LEFT(TRIM(NEW.nome_patio), 1)), LOWER(SUBSTRING(TRIM(NEW.nome_patio), 2))), COALESCE(NEW.capacidade_vagas, -1), COALESCE(NULLIF(TRIM(NEW.end_cidade), ''), 'NÃO INFORMADO'), COALESCE(NULLIF(TRIM(NEW.end_uf), ''), 'XX'), 'Brasil')
    ON DUPLICATE KEY UPDATE nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas), end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf);
END//

-- Grupo
DROP TRIGGER IF EXISTS staging.trg_transforma_guilherme_hu_grupo_ai//
CREATE TRIGGER staging.trg_transforma_guilherme_hu_grupo_ai AFTER INSERT ON staging.stg_guilherme_hu_grupo FOR EACH ROW
BEGIN
    IF NEW.valor_diaria IS NULL OR NEW.valor_diaria = 0 THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json)
        VALUES ('stg_guilherme_hu_grupo', NEW.nk_frota_origem, NEW.nk_id_grupo, 'Grupo sem valor_diaria vigente; será carregado com valor 0,00', JSON_OBJECT('nk_id_grupo', NEW.nk_id_grupo, 'valor_diaria', NEW.valor_diaria));
    END IF;

    INSERT INTO staging.stg_conf_grupo (nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria)
    VALUES (NEW.nk_frota_origem, NEW.nk_id_grupo,
        CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome_grupo, CONCAT('GRUPO ', NEW.nk_id_grupo))), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome_grupo, CONCAT('GRUPO ', NEW.nk_id_grupo))), 2))),
        COALESCE(NEW.valor_diaria, 0))
    ON DUPLICATE KEY UPDATE nome_grupo = VALUES(nome_grupo), valor_diaria = VALUES(valor_diaria);
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_guilherme_hu_grupo_au//
CREATE TRIGGER staging.trg_transforma_guilherme_hu_grupo_au AFTER UPDATE ON staging.stg_guilherme_hu_grupo FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_conf_grupo (nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria)
    VALUES (NEW.nk_frota_origem, NEW.nk_id_grupo,
        CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome_grupo, CONCAT('GRUPO ', NEW.nk_id_grupo))), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome_grupo, CONCAT('GRUPO ', NEW.nk_id_grupo))), 2))),
        COALESCE(NEW.valor_diaria, 0))
    ON DUPLICATE KEY UPDATE nome_grupo = VALUES(nome_grupo), valor_diaria = VALUES(valor_diaria);
END//

-- Veículo
DROP TRIGGER IF EXISTS staging.trg_transforma_guilherme_hu_veiculo_ai//
CREATE TRIGGER staging.trg_transforma_guilherme_hu_veiculo_ai AFTER INSERT ON staging.stg_guilherme_hu_veiculo FOR EACH ROW
BEGIN
    IF NEW.nk_id_grupo IS NULL THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json)
        VALUES ('stg_guilherme_hu_veiculo', NEW.nk_frota_origem, NEW.nk_id_veiculo, 'Veículo sem nk_id_grupo', JSON_OBJECT('nk_id_veiculo', NEW.nk_id_veiculo, 'nk_id_grupo', NEW.nk_id_grupo));
    ELSE
        INSERT INTO staging.stg_conf_veiculo (nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem, placa, marca, modelo, mecanizacao, tem_ar_condicionado)
        VALUES (NEW.nk_frota_origem, NEW.nk_id_veiculo, NEW.nk_id_grupo, NEW.nk_id_patio_origem,
            UPPER(TRIM(NEW.placa)),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 2))),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 2))),
            CASE UPPER(TRIM(COALESCE(NEW.mecanizacao, ''))) WHEN 'MANUAL' THEN 'MANUAL' WHEN 'AUTOMATICO' THEN 'AUTOMATICO' ELSE 'NÃO INFORMADO' END,
            COALESCE(NEW.tem_ar_condicionado, FALSE))
        ON DUPLICATE KEY UPDATE
            nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_origem = VALUES(nk_id_patio_origem),
            placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
            mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_guilherme_hu_veiculo_au//
CREATE TRIGGER staging.trg_transforma_guilherme_hu_veiculo_au AFTER UPDATE ON staging.stg_guilherme_hu_veiculo FOR EACH ROW
BEGIN
    IF NEW.nk_id_grupo IS NOT NULL THEN
        INSERT INTO staging.stg_conf_veiculo (nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem, placa, marca, modelo, mecanizacao, tem_ar_condicionado)
        VALUES (NEW.nk_frota_origem, NEW.nk_id_veiculo, NEW.nk_id_grupo, NEW.nk_id_patio_origem,
            UPPER(TRIM(NEW.placa)),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 2))),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 2))),
            CASE UPPER(TRIM(COALESCE(NEW.mecanizacao, ''))) WHEN 'MANUAL' THEN 'MANUAL' WHEN 'AUTOMATICO' THEN 'AUTOMATICO' ELSE 'NÃO INFORMADO' END,
            COALESCE(NEW.tem_ar_condicionado, FALSE))
        ON DUPLICATE KEY UPDATE
            nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_origem = VALUES(nk_id_patio_origem),
            placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
            mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado);
    END IF;
END//

-- Cliente
DROP TRIGGER IF EXISTS staging.trg_transforma_guilherme_hu_cliente_ai//
CREATE TRIGGER staging.trg_transforma_guilherme_hu_cliente_ai AFTER INSERT ON staging.stg_guilherme_hu_cliente FOR EACH ROW
BEGIN
    IF NEW.tipo_cliente NOT IN ('PF', 'PJ') THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito) VALUES ('stg_guilherme_hu_cliente', NEW.nk_frota_origem, NEW.nk_id_cliente, 'Cliente sem tipo_cliente válido');
    ELSE
        INSERT INTO staging.stg_conf_cliente (nk_frota_origem, nk_id_cliente, tipo_cliente, nome, end_cidade, end_uf, end_pais)
        VALUES (NEW.nk_frota_origem, NEW.nk_id_cliente, UPPER(TRIM(NEW.tipo_cliente)), CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome, 'NÃO IDENTIFICADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome, 'NÃO IDENTIFICADO')), 2))), COALESCE(NULLIF(TRIM(NEW.end_cidade), ''), 'NÃO INFORMADO'), COALESCE(NULLIF(TRIM(NEW.end_uf), ''), 'XX'), 'Brasil')
        ON DUPLICATE KEY UPDATE tipo_cliente = VALUES(tipo_cliente), nome = VALUES(nome), end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_guilherme_hu_cliente_au//
CREATE TRIGGER staging.trg_transforma_guilherme_hu_cliente_au AFTER UPDATE ON staging.stg_guilherme_hu_cliente FOR EACH ROW
BEGIN
    IF NEW.tipo_cliente IN ('PF', 'PJ') THEN
        INSERT INTO staging.stg_conf_cliente (nk_frota_origem, nk_id_cliente, tipo_cliente, nome, end_cidade, end_uf, end_pais)
        VALUES (NEW.nk_frota_origem, NEW.nk_id_cliente, UPPER(TRIM(NEW.tipo_cliente)), CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome, 'NÃO IDENTIFICADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome, 'NÃO IDENTIFICADO')), 2))), COALESCE(NULLIF(TRIM(NEW.end_cidade), ''), 'NÃO INFORMADO'), COALESCE(NULLIF(TRIM(NEW.end_uf), ''), 'XX'), 'Brasil')
        ON DUPLICATE KEY UPDATE tipo_cliente = VALUES(tipo_cliente), nome = VALUES(nome), end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf);
    END IF;
END//

-- Reserva
DROP TRIGGER IF EXISTS staging.trg_transforma_guilherme_hu_reserva_ai//
CREATE TRIGGER staging.trg_transforma_guilherme_hu_reserva_ai AFTER INSERT ON staging.stg_guilherme_hu_reserva FOR EACH ROW
BEGIN
    IF NEW.nk_id_cliente IS NULL OR NEW.nk_id_grupo IS NULL OR NEW.nk_id_patio_retirada IS NULL OR NEW.nk_id_patio_fim IS NULL OR NEW.data_reserva IS NULL OR NEW.data_retirada_prevista IS NULL OR NEW.data_devolucao_prevista IS NULL OR NEW.data_devolucao_prevista <= NEW.data_retirada_prevista OR COALESCE(NEW.duracao_prevista_dias, 0) < 1 THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_guilherme_hu_reserva', NEW.nk_frota_origem, NEW.nk_id_reserva,
            CASE
                WHEN NEW.nk_id_cliente IS NULL THEN 'Reserva sem cliente'
                WHEN NEW.nk_id_grupo IS NULL THEN 'Reserva sem grupo'
                WHEN NEW.nk_id_patio_retirada IS NULL THEN 'Reserva sem pátio de retirada'
                WHEN NEW.nk_id_patio_fim IS NULL THEN 'Reserva sem pátio de fim'
                WHEN NEW.data_reserva IS NULL THEN 'Reserva sem data de reserva'
                WHEN NEW.data_retirada_prevista IS NULL THEN 'Reserva sem data de retirada prevista'
                WHEN NEW.data_devolucao_prevista IS NULL THEN 'Reserva sem data de devolução prevista'
                WHEN NEW.data_devolucao_prevista <= NEW.data_retirada_prevista THEN 'Data devolução <= data retirada'
                WHEN COALESCE(NEW.duracao_prevista_dias, 0) < 1 THEN 'Duração prevista inválida (< 1 dia)'
                ELSE 'Erro desconhecido'
            END);
    ELSE
        INSERT INTO staging.stg_conf_reserva (nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim, data_reserva, data_retirada_prevista, data_devolucao_prevista, duracao_prevista_dias, valor_previsto_reserva, status_reserva)
        VALUES (NEW.nk_frota_origem, NEW.nk_id_reserva, NEW.nk_id_cliente, NEW.nk_id_grupo, NEW.nk_id_patio_retirada, NEW.nk_id_patio_fim, NEW.data_reserva, NEW.data_retirada_prevista, NEW.data_devolucao_prevista, DATEDIFF(NEW.data_devolucao_prevista, NEW.data_retirada_prevista), COALESCE(NEW.valor_previsto_reserva, 0), CASE UPPER(TRIM(COALESCE(NEW.status_reserva, ''))) WHEN 'ATIVA' THEN 'ATIVA' WHEN 'CANCELADA' THEN 'CANCELADA' WHEN 'CONVERTIDA' THEN 'CONVERTIDA' ELSE 'ATIVA' END)
        ON DUPLICATE KEY UPDATE status_reserva = VALUES(status_reserva), valor_previsto_reserva = VALUES(valor_previsto_reserva);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_guilherme_hu_reserva_au//
CREATE TRIGGER staging.trg_transforma_guilherme_hu_reserva_au AFTER UPDATE ON staging.stg_guilherme_hu_reserva FOR EACH ROW
BEGIN
    IF NEW.nk_id_cliente IS NOT NULL AND NEW.nk_id_grupo IS NOT NULL AND NEW.data_devolucao_prevista > NEW.data_retirada_prevista THEN
        INSERT INTO staging.stg_conf_reserva (nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim, data_reserva, data_retirada_prevista, data_devolucao_prevista, duracao_prevista_dias, valor_previsto_reserva, status_reserva)
        VALUES (NEW.nk_frota_origem, NEW.nk_id_reserva, NEW.nk_id_cliente, NEW.nk_id_grupo, NEW.nk_id_patio_retirada, NEW.nk_id_patio_fim, NEW.data_reserva, NEW.data_retirada_prevista, NEW.data_devolucao_prevista, DATEDIFF(NEW.data_devolucao_prevista, NEW.data_retirada_prevista), COALESCE(NEW.valor_previsto_reserva, 0), CASE UPPER(TRIM(COALESCE(NEW.status_reserva, ''))) WHEN 'ATIVA' THEN 'ATIVA' WHEN 'CANCELADA' THEN 'CANCELADA' WHEN 'CONVERTIDA' THEN 'CONVERTIDA' ELSE 'ATIVA' END)
        ON DUPLICATE KEY UPDATE status_reserva = VALUES(status_reserva), valor_previsto_reserva = VALUES(valor_previsto_reserva);
    END IF;
END//

-- Locação
DROP TRIGGER IF EXISTS staging.trg_transforma_guilherme_hu_locacao_ai//
CREATE TRIGGER staging.trg_transforma_guilherme_hu_locacao_ai AFTER INSERT ON staging.stg_guilherme_hu_locacao FOR EACH ROW
BEGIN
    IF NEW.nk_id_cliente IS NULL OR NEW.nk_id_veiculo IS NULL OR NEW.nk_id_grupo IS NULL OR NEW.nk_id_patio_retirada IS NULL OR NEW.data_retirada IS NULL OR NEW.data_prev_devolucao IS NULL OR (NEW.data_real_devolucao IS NOT NULL AND NEW.data_real_devolucao < NEW.data_retirada) THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json) VALUES ('stg_guilherme_hu_locacao', NEW.nk_frota_origem, NEW.nk_id_locacao,
            CASE
                WHEN NEW.nk_id_cliente IS NULL THEN 'Locação sem cliente'
                WHEN NEW.nk_id_veiculo IS NULL THEN 'Locação sem veículo'
                WHEN NEW.nk_id_grupo IS NULL THEN 'Locação sem grupo'
                WHEN NEW.nk_id_patio_retirada IS NULL THEN 'Locação sem pátio de retirada'
                WHEN NEW.data_retirada IS NULL THEN 'Locação sem data de retirada'
                WHEN NEW.data_prev_devolucao IS NULL THEN 'Locação sem data prev. devolução'
                WHEN NEW.data_real_devolucao IS NOT NULL AND NEW.data_real_devolucao < NEW.data_retirada THEN 'Data devolução real anterior à retirada'
                ELSE 'Erro desconhecido'
            END,
            JSON_OBJECT('nk_id_locacao', NEW.nk_id_locacao, 'nk_id_cliente', NEW.nk_id_cliente, 'nk_id_veiculo', NEW.nk_id_veiculo, 'nk_id_grupo', NEW.nk_id_grupo, 'nk_id_patio_retirada', NEW.nk_id_patio_retirada, 'data_retirada', NEW.data_retirada, 'data_prev_devolucao', NEW.data_prev_devolucao, 'data_real_devolucao', NEW.data_real_devolucao, 'valor_final', NEW.valor_final));
    ELSE
        INSERT INTO staging.stg_conf_locacao (nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_devolucao, data_retirada, data_prev_devolucao, data_real_devolucao, valor_final)
        VALUES (NEW.nk_frota_origem, NEW.nk_id_locacao, NEW.nk_id_cliente, NEW.nk_id_veiculo, NEW.nk_id_grupo, NEW.nk_id_patio_retirada, NEW.nk_id_patio_devolucao, NEW.data_retirada, NEW.data_prev_devolucao, NEW.data_real_devolucao, GREATEST(COALESCE(NEW.valor_final, 0), 0))
        ON DUPLICATE KEY UPDATE nk_id_patio_devolucao = VALUES(nk_id_patio_devolucao), data_real_devolucao = VALUES(data_real_devolucao), valor_final = VALUES(valor_final);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_guilherme_hu_locacao_au//
CREATE TRIGGER staging.trg_transforma_guilherme_hu_locacao_au AFTER UPDATE ON staging.stg_guilherme_hu_locacao FOR EACH ROW
BEGIN
    IF NEW.nk_id_cliente IS NOT NULL AND NEW.nk_id_veiculo IS NOT NULL AND NEW.nk_id_grupo IS NOT NULL AND NEW.nk_id_patio_retirada IS NOT NULL AND NEW.data_retirada IS NOT NULL AND NEW.data_prev_devolucao IS NOT NULL AND (NEW.data_real_devolucao IS NULL OR NEW.data_real_devolucao >= NEW.data_retirada) THEN
        INSERT INTO staging.stg_conf_locacao (nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_devolucao, data_retirada, data_prev_devolucao, data_real_devolucao, valor_final)
        VALUES (NEW.nk_frota_origem, NEW.nk_id_locacao, NEW.nk_id_cliente, NEW.nk_id_veiculo, NEW.nk_id_grupo, NEW.nk_id_patio_retirada, NEW.nk_id_patio_devolucao, NEW.data_retirada, NEW.data_prev_devolucao, NEW.data_real_devolucao, GREATEST(COALESCE(NEW.valor_final, 0), 0))
        ON DUPLICATE KEY UPDATE nk_id_patio_devolucao = VALUES(nk_id_patio_devolucao), data_real_devolucao = VALUES(data_real_devolucao), valor_final = VALUES(valor_final);
    END IF;
END//

DELIMITER ;
