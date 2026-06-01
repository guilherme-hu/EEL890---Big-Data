-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)


CREATE SCHEMA IF NOT EXISTS staging;

-- 1) TABELAS DE REJEITOS E CONFORMADAS (compartilhadas) - garantia de existencia
--    DDL identica a usada por gui-hu / p-rique (contrato unico do consorcio).


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

-- 2) PROCEDURES DE TRANSFORMACAO (conformacao em LOTE / backfill)

-- ---- 2.1) Patio -------------------------------------------------------------
DROP PROCEDURE IF EXISTS staging.sp_valviessejoao_transforma_patio;
DELIMITER //
CREATE PROCEDURE staging.sp_valviessejoao_transforma_patio()
BEGIN
    DELETE FROM staging.stg_conf_patio WHERE nk_frota_origem = 'valviessejoao';

    INSERT INTO staging.stg_conf_patio
        (nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas, end_cidade, end_uf, end_pais)
    SELECT 'valviessejoao', p.id_patio,
        CONCAT(UPPER(LEFT(TRIM(COALESCE(p.nome_patio, CONCAT('PATIO ', p.id_patio))), 1)),
               LOWER(SUBSTRING(TRIM(COALESCE(p.nome_patio, CONCAT('PATIO ', p.id_patio))), 2))),
        -1,
        'NÃO INFORMADO', 'XX', 'Brasil'
    FROM staging.stg_valviessejoao_patio p;
END//
DELIMITER ;

-- ---- 2.2) Grupo -------------------------------------------------------------
DROP PROCEDURE IF EXISTS staging.sp_valviessejoao_transforma_grupo;
DELIMITER //
CREATE PROCEDURE staging.sp_valviessejoao_transforma_grupo()
BEGIN
    DELETE FROM staging.stg_conf_grupo WHERE nk_frota_origem = 'valviessejoao';

    -- DQ: grupo sem tarifa vigente (sera carregado com 0,00)
    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT 'stg_valviessejoao_grupo', 'valviessejoao', g.id_grupo,
           'Grupo sem valor_diaria vigente; será carregado com valor 0,00'
    FROM staging.stg_valviessejoao_grupo g
    WHERE g.faixa_valor_diaria IS NULL OR g.faixa_valor_diaria = 0;

    INSERT INTO staging.stg_conf_grupo (nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria)
    SELECT 'valviessejoao', g.id_grupo,
        CONCAT(UPPER(LEFT(TRIM(COALESCE(g.nome_grupo, CONCAT('GRUPO ', g.id_grupo))), 1)),
               LOWER(SUBSTRING(TRIM(COALESCE(g.nome_grupo, CONCAT('GRUPO ', g.id_grupo))), 2))),
        COALESCE(g.faixa_valor_diaria, 0)
    FROM staging.stg_valviessejoao_grupo g;
END//
DELIMITER ;

-- ---- 2.3) Veiculo -----------------------------------------------------------
DROP PROCEDURE IF EXISTS staging.sp_valviessejoao_transforma_veiculo;
DELIMITER //
CREATE PROCEDURE staging.sp_valviessejoao_transforma_veiculo()
BEGIN
    DELETE FROM staging.stg_conf_veiculo WHERE nk_frota_origem = 'valviessejoao';

    -- DQ: veiculo sem grupo (FK obrigatoria no conformado e no DW)
    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT 'stg_valviessejoao_veiculo', 'valviessejoao', v.id_veiculo, 'Veículo sem id_grupo'
    FROM staging.stg_valviessejoao_veiculo v
    WHERE v.id_grupo IS NULL;

    INSERT INTO staging.stg_conf_veiculo
        (nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
         placa, marca, modelo, mecanizacao, tem_ar_condicionado)
    SELECT 'valviessejoao', v.id_veiculo, v.id_grupo, v.id_patio_atual,
        COALESCE(NULLIF(UPPER(TRIM(v.placa)), ''), 'SEM PLACA'),
        CONCAT(UPPER(LEFT(TRIM(COALESCE(v.marca, 'NÃO INFORMADO')), 1)),
               LOWER(SUBSTRING(TRIM(COALESCE(v.marca, 'NÃO INFORMADO')), 2))),
        CONCAT(UPPER(LEFT(TRIM(COALESCE(v.modelo, 'NÃO INFORMADO')), 1)),
               LOWER(SUBSTRING(TRIM(COALESCE(v.modelo, 'NÃO INFORMADO')), 2))),
        CASE
            WHEN UPPER(TRIM(COALESCE(v.mecanizacao, ''))) IN ('MANUAL') THEN 'MANUAL'
            WHEN UPPER(TRIM(COALESCE(v.mecanizacao, ''))) IN ('AUTOMATICO', 'AUTOMÁTICO', 'AUTOMATICA', 'AUTOMÁTICA') THEN 'AUTOMATICO'
            ELSE 'NÃO INFORMADO'
        END,
        COALESCE(v.ar_condicionado, FALSE)
    FROM staging.stg_valviessejoao_veiculo v
    WHERE v.id_grupo IS NOT NULL;
END//
DELIMITER ;

-- ---- 2.4) Cliente -----------------------------------------------------------
DROP PROCEDURE IF EXISTS staging.sp_valviessejoao_transforma_cliente;
DELIMITER //
CREATE PROCEDURE staging.sp_valviessejoao_transforma_cliente()
BEGIN
    DELETE FROM staging.stg_conf_cliente WHERE nk_frota_origem = 'valviessejoao';

    -- DQ: tipo_cliente fora de PF/PJ (CHECK do DW)
    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT 'stg_valviessejoao_cliente', 'valviessejoao', c.id_cliente, 'Cliente sem tipo_cliente válido (PF/PJ)'
    FROM staging.stg_valviessejoao_cliente c
    WHERE UPPER(TRIM(COALESCE(c.tipo_cliente, ''))) NOT IN ('PF', 'PJ');

    INSERT INTO staging.stg_conf_cliente
        (nk_frota_origem, nk_id_cliente, tipo_cliente, nome, end_cidade, end_uf, end_pais)
    SELECT 'valviessejoao', c.id_cliente,
        UPPER(TRIM(c.tipo_cliente)),
        CONCAT(UPPER(LEFT(TRIM(COALESCE(c.nome_razao_social, 'NÃO IDENTIFICADO')), 1)),
               LOWER(SUBSTRING(TRIM(COALESCE(c.nome_razao_social, 'NÃO IDENTIFICADO')), 2))),
        COALESCE(NULLIF(TRIM(c.cidade), ''), 'NÃO INFORMADO'),
        COALESCE(NULLIF(TRIM(c.estado), ''), 'XX'),
        'Brasil'
    FROM staging.stg_valviessejoao_cliente c
    WHERE UPPER(TRIM(COALESCE(c.tipo_cliente, ''))) IN ('PF', 'PJ');
END//
DELIMITER ;

-- ---- 2.5) Reserva (calcula duracao e valor previsto) ------------------------
DROP PROCEDURE IF EXISTS staging.sp_valviessejoao_transforma_reserva;
DELIMITER //
CREATE PROCEDURE staging.sp_valviessejoao_transforma_reserva()
BEGIN
    DELETE FROM staging.stg_conf_reserva WHERE nk_frota_origem = 'valviessejoao';

    -- DQ: chaves/datas ausentes ou janela invalida
    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json)
    SELECT 'stg_valviessejoao_reserva', 'valviessejoao', r.id_reserva,
        CASE
            WHEN r.id_cliente IS NULL THEN 'Reserva sem cliente'
            WHEN r.id_grupo IS NULL THEN 'Reserva sem grupo'
            WHEN r.id_patio_retirada IS NULL THEN 'Reserva sem pátio de retirada'
            WHEN r.id_patio_devolucao_previsto IS NULL THEN 'Reserva sem pátio de fim'
            WHEN r.data_reserva IS NULL THEN 'Reserva sem data de reserva'
            WHEN r.data_prev_retirada IS NULL THEN 'Reserva sem data de retirada prevista'
            WHEN r.data_prev_devolucao IS NULL THEN 'Reserva sem data de devolução prevista'
            WHEN r.data_prev_devolucao <= r.data_prev_retirada THEN 'Data devolução <= data retirada (duração < 1)'
            ELSE 'Erro desconhecido'
        END,
        JSON_OBJECT('nk_id_reserva', r.id_reserva, 'nk_id_cliente', r.id_cliente, 'nk_id_grupo', r.id_grupo,
                    'nk_id_patio_retirada', r.id_patio_retirada, 'nk_id_patio_fim', r.id_patio_devolucao_previsto,
                    'data_reserva', r.data_reserva, 'data_retirada_prevista', r.data_prev_retirada,
                    'data_devolucao_prevista', r.data_prev_devolucao)
    FROM staging.stg_valviessejoao_reserva r
    WHERE r.id_cliente IS NULL OR r.id_grupo IS NULL OR r.id_patio_retirada IS NULL
       OR r.id_patio_devolucao_previsto IS NULL OR r.data_reserva IS NULL
       OR r.data_prev_retirada IS NULL OR r.data_prev_devolucao IS NULL
       OR r.data_prev_devolucao <= r.data_prev_retirada;

    INSERT INTO staging.stg_conf_reserva
        (nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim,
         data_reserva, data_retirada_prevista, data_devolucao_prevista,
         duracao_prevista_dias, valor_previsto_reserva, status_reserva)
    SELECT 'valviessejoao', r.id_reserva, r.id_cliente, r.id_grupo, r.id_patio_retirada, r.id_patio_devolucao_previsto,
        r.data_reserva, r.data_prev_retirada, r.data_prev_devolucao,
        DATEDIFF(r.data_prev_devolucao, r.data_prev_retirada),
        DATEDIFF(r.data_prev_devolucao, r.data_prev_retirada) * COALESCE(g.faixa_valor_diaria, 0),
        CASE UPPER(TRIM(COALESCE(r.status_reserva, '')))
            WHEN 'ATIVA' THEN 'ATIVA'
            WHEN 'CANCELADA' THEN 'CANCELADA'
            WHEN 'CONVERTIDA' THEN 'CONVERTIDA'
            ELSE 'ATIVA'
        END
    FROM staging.stg_valviessejoao_reserva r
    LEFT JOIN staging.stg_valviessejoao_grupo g ON g.id_grupo = r.id_grupo
    WHERE r.id_cliente IS NOT NULL AND r.id_grupo IS NOT NULL AND r.id_patio_retirada IS NOT NULL
      AND r.id_patio_devolucao_previsto IS NOT NULL AND r.data_reserva IS NOT NULL
      AND r.data_prev_retirada IS NOT NULL AND r.data_prev_devolucao IS NOT NULL
      AND r.data_prev_devolucao > r.data_prev_retirada;
END//
DELIMITER ;

-- ---- 2.6) Locacao -----------------------------------------------------------
DROP PROCEDURE IF EXISTS staging.sp_valviessejoao_transforma_locacao;
DELIMITER //
CREATE PROCEDURE staging.sp_valviessejoao_transforma_locacao()
BEGIN
    DELETE FROM staging.stg_conf_locacao WHERE nk_frota_origem = 'valviessejoao';

    -- DQ: chaves/datas ausentes ou devolucao real anterior a retirada
    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json)
    SELECT 'stg_valviessejoao_locacao', 'valviessejoao', l.id_locacao,
        CASE
            WHEN l.id_cliente IS NULL THEN 'Locação sem cliente'
            WHEN l.id_veiculo IS NULL THEN 'Locação sem veículo'
            WHEN l.id_grupo IS NULL THEN 'Locação sem grupo'
            WHEN l.id_patio_retirada IS NULL THEN 'Locação sem pátio de retirada'
            WHEN l.data_hora_retirada IS NULL THEN 'Locação sem data de retirada'
            WHEN l.data_hora_prev_devolucao IS NULL THEN 'Locação sem data prev. devolução'
            WHEN l.data_hora_real_devolucao IS NOT NULL AND DATE(l.data_hora_real_devolucao) < DATE(l.data_hora_retirada) THEN 'Data devolução real anterior à retirada'
            ELSE 'Erro desconhecido'
        END,
        JSON_OBJECT('nk_id_locacao', l.id_locacao, 'nk_id_cliente', l.id_cliente, 'nk_id_veiculo', l.id_veiculo,
                    'nk_id_grupo', l.id_grupo, 'nk_id_patio_retirada', l.id_patio_retirada,
                    'data_retirada', l.data_hora_retirada, 'data_prev_devolucao', l.data_hora_prev_devolucao,
                    'data_real_devolucao', l.data_hora_real_devolucao, 'valor_final', l.valor_final)
    FROM staging.stg_valviessejoao_locacao l
    WHERE l.id_cliente IS NULL OR l.id_veiculo IS NULL OR l.id_grupo IS NULL OR l.id_patio_retirada IS NULL
       OR l.data_hora_retirada IS NULL OR l.data_hora_prev_devolucao IS NULL
       OR (l.data_hora_real_devolucao IS NOT NULL AND DATE(l.data_hora_real_devolucao) < DATE(l.data_hora_retirada));

    INSERT INTO staging.stg_conf_locacao
        (nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo,
         nk_id_patio_retirada, nk_id_patio_devolucao, data_retirada, data_prev_devolucao,
         data_real_devolucao, valor_final)
    SELECT 'valviessejoao', l.id_locacao, l.id_cliente, l.id_veiculo, l.id_grupo,
        l.id_patio_retirada, l.id_patio_devolucao_real,
        DATE(l.data_hora_retirada), DATE(l.data_hora_prev_devolucao), DATE(l.data_hora_real_devolucao),
        GREATEST(COALESCE(l.valor_final, 0), 0)
    FROM staging.stg_valviessejoao_locacao l
    WHERE l.id_cliente IS NOT NULL AND l.id_veiculo IS NOT NULL AND l.id_grupo IS NOT NULL
      AND l.id_patio_retirada IS NOT NULL AND l.data_hora_retirada IS NOT NULL
      AND l.data_hora_prev_devolucao IS NOT NULL
      AND (l.data_hora_real_devolucao IS NULL OR DATE(l.data_hora_real_devolucao) >= DATE(l.data_hora_retirada));
END//
DELIMITER ;

-- ---- 2.7) Snapshot de inventario de patio -----------------------------------
DROP PROCEDURE IF EXISTS staging.sp_valviessejoao_transforma_snapshot_patio;
DELIMITER //
CREATE PROCEDURE staging.sp_valviessejoao_transforma_snapshot_patio()
BEGIN
    DELETE FROM staging.stg_conf_snapshot_patio WHERE nk_frota_origem = 'valviessejoao';

    -- DQ: snapshot exige patio + veiculo + grupo + data (todos compoem a PK e FKs)
    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT 'stg_valviessejoao_inventario_patio', 'valviessejoao', i.id_veiculo, 'Snapshot sem chaves válidas (patio/veiculo/grupo/data)'
    FROM staging.stg_valviessejoao_inventario_patio i
    WHERE i.id_patio IS NULL OR i.id_veiculo IS NULL OR i.id_grupo IS NULL OR i.data_snapshot IS NULL;

    INSERT INTO staging.stg_conf_snapshot_patio (nk_frota_origem, nk_id_patio, nk_id_veiculo, nk_id_grupo, data_snapshot)
    SELECT 'valviessejoao', i.id_patio, i.id_veiculo, i.id_grupo, i.data_snapshot
    FROM staging.stg_valviessejoao_inventario_patio i
    WHERE i.id_patio IS NOT NULL AND i.id_veiculo IS NOT NULL AND i.id_grupo IS NOT NULL AND i.data_snapshot IS NOT NULL;
END//
DELIMITER ;

-- ---- 2.8) Orquestrador ------------------------------------------------------
DROP PROCEDURE IF EXISTS staging.sp_valviessejoao_transformacao_completa;
DELIMITER //
CREATE PROCEDURE staging.sp_valviessejoao_transformacao_completa()
BEGIN
    CALL staging.sp_valviessejoao_transforma_patio();
    CALL staging.sp_valviessejoao_transforma_grupo();
    CALL staging.sp_valviessejoao_transforma_veiculo();
    CALL staging.sp_valviessejoao_transforma_cliente();
    CALL staging.sp_valviessejoao_transforma_reserva();
    CALL staging.sp_valviessejoao_transforma_locacao();
    CALL staging.sp_valviessejoao_transforma_snapshot_patio();
END//
DELIMITER ;

-- 3) VIEW DE MONITORAMENTO DE QUALIDADE (rejeitos desta frota)
CREATE OR REPLACE VIEW staging.vw_valviessejoao_qualidade_etl AS
SELECT
    tabela_origem,
    COUNT(*)        AS total_rejeitos,
    MIN(dt_rejeito) AS primeiro_rejeito,
    MAX(dt_rejeito) AS ultimo_rejeito,
    GROUP_CONCAT(DISTINCT motivo_rejeito ORDER BY motivo_rejeito SEPARATOR ' | ') AS motivos_distintos
FROM staging.stg_rejeitos_etl
WHERE nk_frota_origem = 'valviessejoao'
GROUP BY tabela_origem
ORDER BY total_rejeitos DESC;

-- 4) TRIGGERS DE TRANSFORMACAO INCREMENTAL (CDC sobre o staging cru)

DELIMITER //

-- ----------------------------- PATIO ----------------------------------------
DROP TRIGGER IF EXISTS staging.trg_trf_valviessejoao_patio_ai//
CREATE TRIGGER staging.trg_trf_valviessejoao_patio_ai
AFTER INSERT ON staging.stg_valviessejoao_patio FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_conf_patio
        (nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas, end_cidade, end_uf, end_pais)
    VALUES ('valviessejoao', NEW.id_patio,
        CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome_patio, CONCAT('PATIO ', NEW.id_patio))), 1)),
               LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome_patio, CONCAT('PATIO ', NEW.id_patio))), 2))),
        -1, 'NÃO INFORMADO', 'XX', 'Brasil')
    ON DUPLICATE KEY UPDATE
        nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas),
        end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf), end_pais = VALUES(end_pais);
END//

DROP TRIGGER IF EXISTS staging.trg_trf_valviessejoao_patio_au//
CREATE TRIGGER staging.trg_trf_valviessejoao_patio_au
AFTER UPDATE ON staging.stg_valviessejoao_patio FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_conf_patio
        (nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas, end_cidade, end_uf, end_pais)
    VALUES ('valviessejoao', NEW.id_patio,
        CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome_patio, CONCAT('PATIO ', NEW.id_patio))), 1)),
               LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome_patio, CONCAT('PATIO ', NEW.id_patio))), 2))),
        -1, 'NÃO INFORMADO', 'XX', 'Brasil')
    ON DUPLICATE KEY UPDATE
        nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas),
        end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf), end_pais = VALUES(end_pais);
END//

-- ----------------------------- GRUPO ----------------------------------------
DROP TRIGGER IF EXISTS staging.trg_trf_valviessejoao_grupo_ai//
CREATE TRIGGER staging.trg_trf_valviessejoao_grupo_ai
AFTER INSERT ON staging.stg_valviessejoao_grupo FOR EACH ROW
BEGIN
    IF NEW.faixa_valor_diaria IS NULL OR NEW.faixa_valor_diaria = 0 THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_valviessejoao_grupo', 'valviessejoao', NEW.id_grupo, 'Grupo sem valor_diaria vigente; será carregado com valor 0,00');
    END IF;

    INSERT INTO staging.stg_conf_grupo (nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria)
    VALUES ('valviessejoao', NEW.id_grupo,
        CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome_grupo, CONCAT('GRUPO ', NEW.id_grupo))), 1)),
               LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome_grupo, CONCAT('GRUPO ', NEW.id_grupo))), 2))),
        COALESCE(NEW.faixa_valor_diaria, 0))
    ON DUPLICATE KEY UPDATE nome_grupo = VALUES(nome_grupo), valor_diaria = VALUES(valor_diaria);
END//

DROP TRIGGER IF EXISTS staging.trg_trf_valviessejoao_grupo_au//
CREATE TRIGGER staging.trg_trf_valviessejoao_grupo_au
AFTER UPDATE ON staging.stg_valviessejoao_grupo FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_conf_grupo (nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria)
    VALUES ('valviessejoao', NEW.id_grupo,
        CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome_grupo, CONCAT('GRUPO ', NEW.id_grupo))), 1)),
               LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome_grupo, CONCAT('GRUPO ', NEW.id_grupo))), 2))),
        COALESCE(NEW.faixa_valor_diaria, 0))
    ON DUPLICATE KEY UPDATE nome_grupo = VALUES(nome_grupo), valor_diaria = VALUES(valor_diaria);
END//

-- ----------------------------- VEICULO --------------------------------------
DROP TRIGGER IF EXISTS staging.trg_trf_valviessejoao_veiculo_ai//
CREATE TRIGGER staging.trg_trf_valviessejoao_veiculo_ai
AFTER INSERT ON staging.stg_valviessejoao_veiculo FOR EACH ROW
BEGIN
    IF NEW.id_grupo IS NULL THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_valviessejoao_veiculo', 'valviessejoao', NEW.id_veiculo, 'Veículo sem id_grupo');
    ELSE
        INSERT INTO staging.stg_conf_veiculo
            (nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
             placa, marca, modelo, mecanizacao, tem_ar_condicionado)
        VALUES ('valviessejoao', NEW.id_veiculo, NEW.id_grupo, NEW.id_patio_atual,
            COALESCE(NULLIF(UPPER(TRIM(NEW.placa)), ''), 'SEM PLACA'),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 1)),
                   LOWER(SUBSTRING(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 2))),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 1)),
                   LOWER(SUBSTRING(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 2))),
            CASE
                WHEN UPPER(TRIM(COALESCE(NEW.mecanizacao, ''))) IN ('MANUAL') THEN 'MANUAL'
                WHEN UPPER(TRIM(COALESCE(NEW.mecanizacao, ''))) IN ('AUTOMATICO', 'AUTOMÁTICO', 'AUTOMATICA', 'AUTOMÁTICA') THEN 'AUTOMATICO'
                ELSE 'NÃO INFORMADO'
            END,
            COALESCE(NEW.ar_condicionado, FALSE))
        ON DUPLICATE KEY UPDATE
            nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_origem = VALUES(nk_id_patio_origem),
            placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
            mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_trf_valviessejoao_veiculo_au//
CREATE TRIGGER staging.trg_trf_valviessejoao_veiculo_au
AFTER UPDATE ON staging.stg_valviessejoao_veiculo FOR EACH ROW
BEGIN
    IF NEW.id_grupo IS NOT NULL THEN
        INSERT INTO staging.stg_conf_veiculo
            (nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
             placa, marca, modelo, mecanizacao, tem_ar_condicionado)
        VALUES ('valviessejoao', NEW.id_veiculo, NEW.id_grupo, NEW.id_patio_atual,
            COALESCE(NULLIF(UPPER(TRIM(NEW.placa)), ''), 'SEM PLACA'),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 1)),
                   LOWER(SUBSTRING(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 2))),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 1)),
                   LOWER(SUBSTRING(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 2))),
            CASE
                WHEN UPPER(TRIM(COALESCE(NEW.mecanizacao, ''))) IN ('MANUAL') THEN 'MANUAL'
                WHEN UPPER(TRIM(COALESCE(NEW.mecanizacao, ''))) IN ('AUTOMATICO', 'AUTOMÁTICO', 'AUTOMATICA', 'AUTOMÁTICA') THEN 'AUTOMATICO'
                ELSE 'NÃO INFORMADO'
            END,
            COALESCE(NEW.ar_condicionado, FALSE))
        ON DUPLICATE KEY UPDATE
            nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_origem = VALUES(nk_id_patio_origem),
            placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
            mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado);
    END IF;
END//

-- ----------------------------- CLIENTE --------------------------------------
DROP TRIGGER IF EXISTS staging.trg_trf_valviessejoao_cliente_ai//
CREATE TRIGGER staging.trg_trf_valviessejoao_cliente_ai
AFTER INSERT ON staging.stg_valviessejoao_cliente FOR EACH ROW
BEGIN
    IF UPPER(TRIM(COALESCE(NEW.tipo_cliente, ''))) NOT IN ('PF', 'PJ') THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_valviessejoao_cliente', 'valviessejoao', NEW.id_cliente, 'Cliente sem tipo_cliente válido (PF/PJ)');
    ELSE
        INSERT INTO staging.stg_conf_cliente
            (nk_frota_origem, nk_id_cliente, tipo_cliente, nome, end_cidade, end_uf, end_pais)
        VALUES ('valviessejoao', NEW.id_cliente, UPPER(TRIM(NEW.tipo_cliente)),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome_razao_social, 'NÃO IDENTIFICADO')), 1)),
                   LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome_razao_social, 'NÃO IDENTIFICADO')), 2))),
            COALESCE(NULLIF(TRIM(NEW.cidade), ''), 'NÃO INFORMADO'),
            COALESCE(NULLIF(TRIM(NEW.estado), ''), 'XX'), 'Brasil')
        ON DUPLICATE KEY UPDATE
            tipo_cliente = VALUES(tipo_cliente), nome = VALUES(nome),
            end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf), end_pais = VALUES(end_pais);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_trf_valviessejoao_cliente_au//
CREATE TRIGGER staging.trg_trf_valviessejoao_cliente_au
AFTER UPDATE ON staging.stg_valviessejoao_cliente FOR EACH ROW
BEGIN
    IF UPPER(TRIM(COALESCE(NEW.tipo_cliente, ''))) IN ('PF', 'PJ') THEN
        INSERT INTO staging.stg_conf_cliente
            (nk_frota_origem, nk_id_cliente, tipo_cliente, nome, end_cidade, end_uf, end_pais)
        VALUES ('valviessejoao', NEW.id_cliente, UPPER(TRIM(NEW.tipo_cliente)),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome_razao_social, 'NÃO IDENTIFICADO')), 1)),
                   LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome_razao_social, 'NÃO IDENTIFICADO')), 2))),
            COALESCE(NULLIF(TRIM(NEW.cidade), ''), 'NÃO INFORMADO'),
            COALESCE(NULLIF(TRIM(NEW.estado), ''), 'XX'), 'Brasil')
        ON DUPLICATE KEY UPDATE
            tipo_cliente = VALUES(tipo_cliente), nome = VALUES(nome),
            end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf), end_pais = VALUES(end_pais);
    END IF;
END//

-- ----------------------------- RESERVA --------------------------------------
DROP TRIGGER IF EXISTS staging.trg_trf_valviessejoao_reserva_ai//
CREATE TRIGGER staging.trg_trf_valviessejoao_reserva_ai
AFTER INSERT ON staging.stg_valviessejoao_reserva FOR EACH ROW
BEGIN
    IF NEW.id_cliente IS NULL OR NEW.id_grupo IS NULL OR NEW.id_patio_retirada IS NULL
       OR NEW.id_patio_devolucao_previsto IS NULL OR NEW.data_reserva IS NULL
       OR NEW.data_prev_retirada IS NULL OR NEW.data_prev_devolucao IS NULL
       OR NEW.data_prev_devolucao <= NEW.data_prev_retirada THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_valviessejoao_reserva', 'valviessejoao', NEW.id_reserva,
            CASE
                WHEN NEW.id_cliente IS NULL THEN 'Reserva sem cliente'
                WHEN NEW.id_grupo IS NULL THEN 'Reserva sem grupo'
                WHEN NEW.id_patio_retirada IS NULL THEN 'Reserva sem pátio de retirada'
                WHEN NEW.id_patio_devolucao_previsto IS NULL THEN 'Reserva sem pátio de fim'
                WHEN NEW.data_reserva IS NULL THEN 'Reserva sem data de reserva'
                WHEN NEW.data_prev_retirada IS NULL THEN 'Reserva sem data de retirada prevista'
                WHEN NEW.data_prev_devolucao IS NULL THEN 'Reserva sem data de devolução prevista'
                WHEN NEW.data_prev_devolucao <= NEW.data_prev_retirada THEN 'Data devolução <= data retirada (duração < 1)'
                ELSE 'Erro desconhecido'
            END);
    ELSE
        INSERT INTO staging.stg_conf_reserva
            (nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim,
             data_reserva, data_retirada_prevista, data_devolucao_prevista,
             duracao_prevista_dias, valor_previsto_reserva, status_reserva)
        VALUES ('valviessejoao', NEW.id_reserva, NEW.id_cliente, NEW.id_grupo, NEW.id_patio_retirada, NEW.id_patio_devolucao_previsto,
            NEW.data_reserva, NEW.data_prev_retirada, NEW.data_prev_devolucao,
            DATEDIFF(NEW.data_prev_devolucao, NEW.data_prev_retirada),
            DATEDIFF(NEW.data_prev_devolucao, NEW.data_prev_retirada)
                * COALESCE((SELECT g.faixa_valor_diaria FROM staging.stg_valviessejoao_grupo g WHERE g.id_grupo = NEW.id_grupo), 0),
            CASE UPPER(TRIM(COALESCE(NEW.status_reserva, '')))
                WHEN 'ATIVA' THEN 'ATIVA' WHEN 'CANCELADA' THEN 'CANCELADA' WHEN 'CONVERTIDA' THEN 'CONVERTIDA' ELSE 'ATIVA'
            END)
        ON DUPLICATE KEY UPDATE
            nk_id_cliente = VALUES(nk_id_cliente), nk_id_grupo = VALUES(nk_id_grupo),
            nk_id_patio_retirada = VALUES(nk_id_patio_retirada), nk_id_patio_fim = VALUES(nk_id_patio_fim),
            data_reserva = VALUES(data_reserva), data_retirada_prevista = VALUES(data_retirada_prevista),
            data_devolucao_prevista = VALUES(data_devolucao_prevista),
            duracao_prevista_dias = VALUES(duracao_prevista_dias),
            valor_previsto_reserva = VALUES(valor_previsto_reserva), status_reserva = VALUES(status_reserva);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_trf_valviessejoao_reserva_au//
CREATE TRIGGER staging.trg_trf_valviessejoao_reserva_au
AFTER UPDATE ON staging.stg_valviessejoao_reserva FOR EACH ROW
BEGIN
    IF NEW.id_cliente IS NOT NULL AND NEW.id_grupo IS NOT NULL AND NEW.id_patio_retirada IS NOT NULL
       AND NEW.id_patio_devolucao_previsto IS NOT NULL AND NEW.data_reserva IS NOT NULL
       AND NEW.data_prev_retirada IS NOT NULL AND NEW.data_prev_devolucao IS NOT NULL
       AND NEW.data_prev_devolucao > NEW.data_prev_retirada THEN
        INSERT INTO staging.stg_conf_reserva
            (nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim,
             data_reserva, data_retirada_prevista, data_devolucao_prevista,
             duracao_prevista_dias, valor_previsto_reserva, status_reserva)
        VALUES ('valviessejoao', NEW.id_reserva, NEW.id_cliente, NEW.id_grupo, NEW.id_patio_retirada, NEW.id_patio_devolucao_previsto,
            NEW.data_reserva, NEW.data_prev_retirada, NEW.data_prev_devolucao,
            DATEDIFF(NEW.data_prev_devolucao, NEW.data_prev_retirada),
            DATEDIFF(NEW.data_prev_devolucao, NEW.data_prev_retirada)
                * COALESCE((SELECT g.faixa_valor_diaria FROM staging.stg_valviessejoao_grupo g WHERE g.id_grupo = NEW.id_grupo), 0),
            CASE UPPER(TRIM(COALESCE(NEW.status_reserva, '')))
                WHEN 'ATIVA' THEN 'ATIVA' WHEN 'CANCELADA' THEN 'CANCELADA' WHEN 'CONVERTIDA' THEN 'CONVERTIDA' ELSE 'ATIVA'
            END)
        ON DUPLICATE KEY UPDATE
            nk_id_cliente = VALUES(nk_id_cliente), nk_id_grupo = VALUES(nk_id_grupo),
            nk_id_patio_retirada = VALUES(nk_id_patio_retirada), nk_id_patio_fim = VALUES(nk_id_patio_fim),
            data_reserva = VALUES(data_reserva), data_retirada_prevista = VALUES(data_retirada_prevista),
            data_devolucao_prevista = VALUES(data_devolucao_prevista),
            duracao_prevista_dias = VALUES(duracao_prevista_dias),
            valor_previsto_reserva = VALUES(valor_previsto_reserva), status_reserva = VALUES(status_reserva);
    END IF;
END//

-- ----------------------------- LOCACAO --------------------------------------
DROP TRIGGER IF EXISTS staging.trg_trf_valviessejoao_locacao_ai//
CREATE TRIGGER staging.trg_trf_valviessejoao_locacao_ai
AFTER INSERT ON staging.stg_valviessejoao_locacao FOR EACH ROW
BEGIN
    IF NEW.id_cliente IS NULL OR NEW.id_veiculo IS NULL OR NEW.id_grupo IS NULL OR NEW.id_patio_retirada IS NULL
       OR NEW.data_hora_retirada IS NULL OR NEW.data_hora_prev_devolucao IS NULL
       OR (NEW.data_hora_real_devolucao IS NOT NULL AND DATE(NEW.data_hora_real_devolucao) < DATE(NEW.data_hora_retirada)) THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_valviessejoao_locacao', 'valviessejoao', NEW.id_locacao,
            CASE
                WHEN NEW.id_cliente IS NULL THEN 'Locação sem cliente'
                WHEN NEW.id_veiculo IS NULL THEN 'Locação sem veículo'
                WHEN NEW.id_grupo IS NULL THEN 'Locação sem grupo'
                WHEN NEW.id_patio_retirada IS NULL THEN 'Locação sem pátio de retirada'
                WHEN NEW.data_hora_retirada IS NULL THEN 'Locação sem data de retirada'
                WHEN NEW.data_hora_prev_devolucao IS NULL THEN 'Locação sem data prev. devolução'
                ELSE 'Data devolução real anterior à retirada'
            END);
    ELSE
        INSERT INTO staging.stg_conf_locacao
            (nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo,
             nk_id_patio_retirada, nk_id_patio_devolucao, data_retirada, data_prev_devolucao,
             data_real_devolucao, valor_final)
        VALUES ('valviessejoao', NEW.id_locacao, NEW.id_cliente, NEW.id_veiculo, NEW.id_grupo,
            NEW.id_patio_retirada, NEW.id_patio_devolucao_real,
            DATE(NEW.data_hora_retirada), DATE(NEW.data_hora_prev_devolucao), DATE(NEW.data_hora_real_devolucao),
            GREATEST(COALESCE(NEW.valor_final, 0), 0))
        ON DUPLICATE KEY UPDATE
            nk_id_cliente = VALUES(nk_id_cliente), nk_id_veiculo = VALUES(nk_id_veiculo),
            nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_retirada = VALUES(nk_id_patio_retirada),
            nk_id_patio_devolucao = VALUES(nk_id_patio_devolucao), data_retirada = VALUES(data_retirada),
            data_prev_devolucao = VALUES(data_prev_devolucao), data_real_devolucao = VALUES(data_real_devolucao),
            valor_final = VALUES(valor_final);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_trf_valviessejoao_locacao_au//
CREATE TRIGGER staging.trg_trf_valviessejoao_locacao_au
AFTER UPDATE ON staging.stg_valviessejoao_locacao FOR EACH ROW
BEGIN
    IF NEW.id_cliente IS NOT NULL AND NEW.id_veiculo IS NOT NULL AND NEW.id_grupo IS NOT NULL
       AND NEW.id_patio_retirada IS NOT NULL AND NEW.data_hora_retirada IS NOT NULL
       AND NEW.data_hora_prev_devolucao IS NOT NULL
       AND (NEW.data_hora_real_devolucao IS NULL OR DATE(NEW.data_hora_real_devolucao) >= DATE(NEW.data_hora_retirada)) THEN
        INSERT INTO staging.stg_conf_locacao
            (nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo,
             nk_id_patio_retirada, nk_id_patio_devolucao, data_retirada, data_prev_devolucao,
             data_real_devolucao, valor_final)
        VALUES ('valviessejoao', NEW.id_locacao, NEW.id_cliente, NEW.id_veiculo, NEW.id_grupo,
            NEW.id_patio_retirada, NEW.id_patio_devolucao_real,
            DATE(NEW.data_hora_retirada), DATE(NEW.data_hora_prev_devolucao), DATE(NEW.data_hora_real_devolucao),
            GREATEST(COALESCE(NEW.valor_final, 0), 0))
        ON DUPLICATE KEY UPDATE
            nk_id_patio_devolucao = VALUES(nk_id_patio_devolucao), data_real_devolucao = VALUES(data_real_devolucao),
            valor_final = VALUES(valor_final);
    END IF;
END//

DELIMITER ;

CALL staging.sp_valviessejoao_transformacao_completa();


