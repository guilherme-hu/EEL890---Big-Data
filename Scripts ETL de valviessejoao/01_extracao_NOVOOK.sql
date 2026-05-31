-- ============================================================================
-- TRABALHO DE BIG DATA / DATA WAREHOUSE - MAE016 (PARTE II)
-- ----------------------------------------------------------------------------
-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)
-- ----------------------------------------------------------------------------
-- Arquivo : 01_extracao_NOVOOK.sql
-- Etapa   : EXTRACAO  (o "E" do ETL)
-- Fonte   : OLTP do grupo apelidado "Ok novo"  ==>  frota de origem = 'NOVOOK'
--           Repositorio: https://github.com/valviessejoao/mae016-bdd-dwh-projeto1
-- Destino : Area de STAGING (schema dw_staging) -> tabelas stg_*
-- SGBD    : MySQL 8.x
--
-- Objetivo desta etapa:
--   Copiar/coletar os dados das tabelas-fonte do OLTP NOVOOK para a area de
--   staging. Sao oferecidos DOIS mecanismos de acionamento (conforme pedido
--   "nao esquecer da especificacao dos tempos de acionamento das extracoes"):
--
--     (A) CARGA TOTAL agendada -> procedures sp_extrai_* chamadas por EVENTs
--         diarios. Boa para dimensoes (baixo volume, mudam pouco).
--     (B) CAPTURA DE MUDANCAS (CDC) em tempo (quase) real -> TRIGGERS de
--         AFTER INSERT / AFTER UPDATE nas tabelas RESERVA e LOCACAO, que
--         alimentam o staging assim que o OLTP muda (o modelo do DW pede
--         "logica de trigger quando ha locacao/reserva e update no OLTP").
--     (C) SNAPSHOT DIARIO de inventario de patio -> EVENT diario (em MySQL o
--         "trigger temporal/diario" e implementado por um EVENT agendado).
--
-- OBS: Esta area de staging guarda APENAS dados da fonte NOVOOK. Cada fonte do
--      grupo (GOAT, IA, AMARELO, NOVOOK) possui a sua propria instancia de
--      staging, pois as PKs naturais (id_*) podem colidir entre fontes; a
--      conformacao/uniao ocorre na etapa de Transformacao (script 02).
--
-- OBS: Se o OLTP do NOVOOK estiver em outro schema, basta substituir todas as
--      referencias "novook." abaixo pelo nome correto do schema de origem.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0) Pre-requisitos de ambiente
-- ----------------------------------------------------------------------------
-- Cria a area de staging especifica da fonte NOVOOK.
-- OBS: o EVENT SCHEDULER (necessario para os EVENTs) e ligado no FIM do script
-- (secao 5), de proposito: assim, mesmo que o usuario nao tenha privilegio
-- SUPER, todos os objetos (tabelas, procedures, triggers e events) sao criados
-- normalmente e so o "liga-desliga" do agendador eventualmente falha.
CREATE DATABASE IF NOT EXISTS dw_staging
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE dw_staging;

-- ============================================================================
-- 1) TABELAS DE STAGING (copia "crua"/raw das fontes que interessam ao DW)
--    Os conceitos do universo de discurso sao apenas 5: cliente, veiculo,
--    grupo, patio, reservas e locacoes. Trazemos tambem o inventario de patio
--    (derivado de VEICULO) para alimentar o Fato_Inventario_Patio.
--    Cada tabela tem "data_extracao" para auditoria/recencia (CDC).
-- ============================================================================

DROP TABLE IF EXISTS stg_inventario_patio;
DROP TABLE IF EXISTS stg_locacao;
DROP TABLE IF EXISTS stg_reserva;
DROP TABLE IF EXISTS stg_patio;
DROP TABLE IF EXISTS stg_grupo;
DROP TABLE IF EXISTS stg_veiculo;
DROP TABLE IF EXISTS stg_cliente;

-- CLIENTE: traz cidade/estado (origem do Dim_Endereco) e dados do Dim_Cliente.
CREATE TABLE stg_cliente (
    id_cliente         INTEGER       NOT NULL,
    tipo_cliente       VARCHAR(2),                 -- PF / PJ
    nome_razao_social  VARCHAR(150),
    cpf_cnpj           VARCHAR(20),
    cidade             VARCHAR(50),
    estado             VARCHAR(2),
    telefone           VARCHAR(20),
    email              VARCHAR(100),
    data_extracao      TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_cliente)
) ENGINE=InnoDB;

-- VEICULO: alimenta Dim_Veiculo e, via id_patio_atual/status, o inventario.
-- Guardamos id_grupo aqui para enriquecer LOCACAO (que nao tem grupo direto).
CREATE TABLE stg_veiculo (
    id_veiculo      INTEGER      NOT NULL,
    placa           VARCHAR(10),
    chassi          VARCHAR(50),
    marca           VARCHAR(50),
    modelo          VARCHAR(50),
    cor             VARCHAR(30),
    mecanizacao     VARCHAR(20),                  -- MANUAL / AUTOMATICO
    ar_condicionado BOOLEAN,                      -- 0=Nao, 1=Sim
    status          VARCHAR(20),                  -- DISPONIVEL/ALUGADO/MANUTENCAO/RESERVADO
    id_grupo        INTEGER,
    id_empresa      INTEGER,
    id_patio_atual  INTEGER,                      -- patio onde o veiculo esta agora
    data_extracao   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_veiculo)
) ENGINE=InnoDB;

-- GRUPO_VEICULO: alimenta Dim_Grupo (e a diaria usada no Fato_Reserva).
CREATE TABLE stg_grupo (
    id_grupo           INTEGER       NOT NULL,
    nome_grupo         VARCHAR(50),
    descricao          VARCHAR(200),
    faixa_valor_diaria DECIMAL(10,2),             -- vira "valor_diaria" no DW
    data_extracao      TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_grupo)
) ENGINE=InnoDB;

-- PATIO: alimenta Dim_Patio. ATENCAO: a fonte NAO possui capacidade de vagas.
CREATE TABLE stg_patio (
    id_patio       INTEGER       NOT NULL,
    id_empresa     INTEGER,
    nome_patio     VARCHAR(100),
    localizacao    VARCHAR(150),
    codigo_patio   VARCHAR(20),
    data_extracao  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_patio)
) ENGINE=InnoDB;

-- RESERVA: alimenta Fato_Reserva.
CREATE TABLE stg_reserva (
    id_reserva                  INTEGER   NOT NULL,
    data_reserva                DATE,
    data_prev_retirada          DATE,
    data_prev_devolucao         DATE,
    status_reserva              VARCHAR(20),       -- ATIVA/CANCELADA/CONVERTIDA
    id_cliente                  INTEGER,
    id_grupo                    INTEGER,
    id_patio_retirada           INTEGER,
    id_patio_devolucao_previsto INTEGER,
    data_extracao               TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_reserva)
) ENGINE=InnoDB;

-- LOCACAO: alimenta Fato_Locacao. Enriquecida com id_grupo (vindo de VEICULO),
-- pois o Fato_Locacao precisa do sk_grupo e a LOCACAO nao guarda o grupo.
CREATE TABLE stg_locacao (
    id_locacao                  INTEGER   NOT NULL,
    data_hora_retirada          TIMESTAMP NULL,
    data_hora_prev_devolucao    TIMESTAMP NULL,
    data_hora_real_devolucao    TIMESTAMP NULL,    -- NULL enquanto nao devolvido
    valor_previsto              DECIMAL(10,2),
    valor_final                 DECIMAL(10,2),     -- NULL enquanto nao devolvido
    status_locacao              VARCHAR(20),
    id_reserva                  INTEGER,
    id_cliente                  INTEGER,
    id_condutor                 INTEGER,
    id_veiculo                  INTEGER,
    id_grupo                    INTEGER,           -- ENRIQUECIDO de VEICULO.id_grupo
    id_patio_retirada           INTEGER,
    id_patio_devolucao_previsto INTEGER,
    id_patio_devolucao_real     INTEGER,           -- NULL enquanto nao devolvido
    data_extracao               TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_locacao)
) ENGINE=InnoDB;

-- INVENTARIO DE PATIO: snapshot diario (grao = 1 veiculo presente por dia).
-- Derivado de VEICULO: cada veiculo NAO alugado esta fisicamente no seu patio.
CREATE TABLE stg_inventario_patio (
    data_snapshot  DATE      NOT NULL,             -- dia do snapshot
    id_patio       INTEGER   NOT NULL,             -- = VEICULO.id_patio_atual
    id_veiculo     INTEGER   NOT NULL,
    id_grupo       INTEGER,
    data_extracao  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (data_snapshot, id_veiculo)        -- 1 veiculo aparece 1x por dia
) ENGINE=InnoDB;

-- ============================================================================
-- 2) EXTRACAO POR CARGA TOTAL (procedures)
--    Reexecutaveis (TRUNCATE + INSERT...SELECT). Usadas na carga inicial e
--    pelos EVENTs agendados (ver secao 4).
-- ============================================================================

DROP PROCEDURE IF EXISTS sp_extrai_dimensoes;
DROP PROCEDURE IF EXISTS sp_extrai_reservas;
DROP PROCEDURE IF EXISTS sp_extrai_locacoes;
DROP PROCEDURE IF EXISTS sp_snapshot_inventario;

DELIMITER $$

-- ---- 2.1) Dimensoes: cliente, veiculo, grupo, patio --------------------------
CREATE PROCEDURE sp_extrai_dimensoes()
BEGIN
    -- CLIENTE
    TRUNCATE TABLE stg_cliente;
    INSERT INTO stg_cliente
        (id_cliente, tipo_cliente, nome_razao_social, cpf_cnpj,
         cidade, estado, telefone, email)
    SELECT id_cliente, tipo_cliente, nome_razao_social, cpf_cnpj,
           cidade, estado, telefone, email
    FROM   novook.CLIENTE;

    -- VEICULO
    TRUNCATE TABLE stg_veiculo;
    INSERT INTO stg_veiculo
        (id_veiculo, placa, chassi, marca, modelo, cor, mecanizacao,
         ar_condicionado, status, id_grupo, id_empresa, id_patio_atual)
    SELECT id_veiculo, placa, chassi, marca, modelo, cor, mecanizacao,
           ar_condicionado, status, id_grupo, id_empresa, id_patio_atual
    FROM   novook.VEICULO;

    -- GRUPO_VEICULO
    TRUNCATE TABLE stg_grupo;
    INSERT INTO stg_grupo
        (id_grupo, nome_grupo, descricao, faixa_valor_diaria)
    SELECT id_grupo, nome_grupo, descricao, faixa_valor_diaria
    FROM   novook.GRUPO_VEICULO;

    -- PATIO
    TRUNCATE TABLE stg_patio;
    INSERT INTO stg_patio
        (id_patio, id_empresa, nome_patio, localizacao, codigo_patio)
    SELECT id_patio, id_empresa, nome_patio, localizacao, codigo_patio
    FROM   novook.PATIO;
END$$

-- ---- 2.2) Reservas -----------------------------------------------------------
CREATE PROCEDURE sp_extrai_reservas()
BEGIN
    TRUNCATE TABLE stg_reserva;
    INSERT INTO stg_reserva
        (id_reserva, data_reserva, data_prev_retirada, data_prev_devolucao,
         status_reserva, id_cliente, id_grupo, id_patio_retirada,
         id_patio_devolucao_previsto)
    SELECT id_reserva, data_reserva, data_prev_retirada, data_prev_devolucao,
           status_reserva, id_cliente, id_grupo, id_patio_retirada,
           id_patio_devolucao_previsto
    FROM   novook.RESERVA;
END$$

-- ---- 2.3) Locacoes (enriquecidas com o grupo do veiculo) ---------------------
CREATE PROCEDURE sp_extrai_locacoes()
BEGIN
    TRUNCATE TABLE stg_locacao;
    INSERT INTO stg_locacao
        (id_locacao, data_hora_retirada, data_hora_prev_devolucao,
         data_hora_real_devolucao, valor_previsto, valor_final, status_locacao,
         id_reserva, id_cliente, id_condutor, id_veiculo, id_grupo,
         id_patio_retirada, id_patio_devolucao_previsto, id_patio_devolucao_real)
    SELECT l.id_locacao, l.data_hora_retirada, l.data_hora_prev_devolucao,
           l.data_hora_real_devolucao, l.valor_previsto, l.valor_final,
           l.status_locacao, l.id_reserva, l.id_cliente, l.id_condutor,
           l.id_veiculo, v.id_grupo,           -- grupo vem do veiculo alugado
           l.id_patio_retirada, l.id_patio_devolucao_previsto,
           l.id_patio_devolucao_real
    FROM   novook.LOCACAO l
    JOIN   novook.VEICULO v ON v.id_veiculo = l.id_veiculo;
END$$

-- ---- 2.4) Snapshot diario do inventario de patio -----------------------------
-- NOVOOK POSSUI visibilidade direta do patio (VEICULO.id_patio_atual), entao
-- nao precisamos inferir presenca a partir de locacoes: basta listar os
-- veiculos que NAO estao alugados (logo, fisicamente presentes no patio).
CREATE PROCEDURE sp_snapshot_inventario(IN p_data DATE)
BEGIN
    IF p_data IS NULL THEN
        SET p_data = CURRENT_DATE;
    END IF;

    -- Idempotente para o mesmo dia: regrava o snapshot daquela data.
    DELETE FROM stg_inventario_patio WHERE data_snapshot = p_data;

    INSERT INTO stg_inventario_patio
        (data_snapshot, id_patio, id_veiculo, id_grupo)
    SELECT p_data, v.id_patio_atual, v.id_veiculo, v.id_grupo
    FROM   novook.VEICULO v
    WHERE  v.status <> 'ALUGADO';   -- alugado = fora do patio (com o cliente)
END$$

DELIMITER ;

-- ============================================================================
-- 3) EXTRACAO POR CDC (TRIGGERS no OLTP de origem)
--    Mantem o staging atualizado em (quase) tempo real para os FATOS que
--    mudam de estado ao longo do contrato: RESERVA e LOCACAO.
--    Cada trigger faz UPSERT (INSERT ... ON DUPLICATE KEY UPDATE) no staging.
-- ============================================================================

-- ---------------------------- RESERVA ---------------------------------------
-- OBS: estes triggers de CDC pertencem ao schema da FONTE (novook), pois sao
-- criados sobre novook.RESERVA / novook.LOCACAO. Por isso o DROP e qualificado
-- com "novook." (senao uma reexecucao nao encontraria o trigger para apagar).
DROP TRIGGER IF EXISTS novook.trg_cdc_reserva_ai;
DROP TRIGGER IF EXISTS novook.trg_cdc_reserva_au;

DELIMITER $$

-- AFTER INSERT: nova reserva criada no OLTP -> entra no staging.
CREATE TRIGGER novook.trg_cdc_reserva_ai
AFTER INSERT ON novook.RESERVA
FOR EACH ROW
BEGIN
    INSERT INTO dw_staging.stg_reserva
        (id_reserva, data_reserva, data_prev_retirada, data_prev_devolucao,
         status_reserva, id_cliente, id_grupo, id_patio_retirada,
         id_patio_devolucao_previsto)
    VALUES
        (NEW.id_reserva, NEW.data_reserva, NEW.data_prev_retirada,
         NEW.data_prev_devolucao, NEW.status_reserva, NEW.id_cliente,
         NEW.id_grupo, NEW.id_patio_retirada, NEW.id_patio_devolucao_previsto)
    ON DUPLICATE KEY UPDATE
        data_reserva                = VALUES(data_reserva),
        data_prev_retirada          = VALUES(data_prev_retirada),
        data_prev_devolucao         = VALUES(data_prev_devolucao),
        status_reserva              = VALUES(status_reserva),
        id_cliente                  = VALUES(id_cliente),
        id_grupo                    = VALUES(id_grupo),
        id_patio_retirada           = VALUES(id_patio_retirada),
        id_patio_devolucao_previsto = VALUES(id_patio_devolucao_previsto),
        data_extracao               = CURRENT_TIMESTAMP;
END$$

-- AFTER UPDATE: reserva mudou de status (ex.: ATIVA -> CONVERTIDA/CANCELADA).
CREATE TRIGGER novook.trg_cdc_reserva_au
AFTER UPDATE ON novook.RESERVA
FOR EACH ROW
BEGIN
    INSERT INTO dw_staging.stg_reserva
        (id_reserva, data_reserva, data_prev_retirada, data_prev_devolucao,
         status_reserva, id_cliente, id_grupo, id_patio_retirada,
         id_patio_devolucao_previsto)
    VALUES
        (NEW.id_reserva, NEW.data_reserva, NEW.data_prev_retirada,
         NEW.data_prev_devolucao, NEW.status_reserva, NEW.id_cliente,
         NEW.id_grupo, NEW.id_patio_retirada, NEW.id_patio_devolucao_previsto)
    ON DUPLICATE KEY UPDATE
        data_reserva                = VALUES(data_reserva),
        data_prev_retirada          = VALUES(data_prev_retirada),
        data_prev_devolucao         = VALUES(data_prev_devolucao),
        status_reserva              = VALUES(status_reserva),
        id_cliente                  = VALUES(id_cliente),
        id_grupo                    = VALUES(id_grupo),
        id_patio_retirada           = VALUES(id_patio_retirada),
        id_patio_devolucao_previsto = VALUES(id_patio_devolucao_previsto),
        data_extracao               = CURRENT_TIMESTAMP;
END$$

-- ---------------------------- LOCACAO ---------------------------------------
DROP TRIGGER IF EXISTS novook.trg_cdc_locacao_ai$$
DROP TRIGGER IF EXISTS novook.trg_cdc_locacao_au$$

-- AFTER INSERT: novo contrato de locacao -> entra no staging (com o grupo do
-- veiculo, buscado em VEICULO para preencher o sk_grupo do fato).
CREATE TRIGGER novook.trg_cdc_locacao_ai
AFTER INSERT ON novook.LOCACAO
FOR EACH ROW
BEGIN
    INSERT INTO dw_staging.stg_locacao
        (id_locacao, data_hora_retirada, data_hora_prev_devolucao,
         data_hora_real_devolucao, valor_previsto, valor_final, status_locacao,
         id_reserva, id_cliente, id_condutor, id_veiculo, id_grupo,
         id_patio_retirada, id_patio_devolucao_previsto, id_patio_devolucao_real)
    VALUES
        (NEW.id_locacao, NEW.data_hora_retirada, NEW.data_hora_prev_devolucao,
         NEW.data_hora_real_devolucao, NEW.valor_previsto, NEW.valor_final,
         NEW.status_locacao, NEW.id_reserva, NEW.id_cliente, NEW.id_condutor,
         NEW.id_veiculo,
         (SELECT v.id_grupo FROM novook.VEICULO v WHERE v.id_veiculo = NEW.id_veiculo),
         NEW.id_patio_retirada, NEW.id_patio_devolucao_previsto,
         NEW.id_patio_devolucao_real)
    ON DUPLICATE KEY UPDATE
        data_hora_retirada          = VALUES(data_hora_retirada),
        data_hora_prev_devolucao    = VALUES(data_hora_prev_devolucao),
        data_hora_real_devolucao    = VALUES(data_hora_real_devolucao),
        valor_previsto              = VALUES(valor_previsto),
        valor_final                 = VALUES(valor_final),
        status_locacao              = VALUES(status_locacao),
        id_reserva                  = VALUES(id_reserva),
        id_cliente                  = VALUES(id_cliente),
        id_condutor                 = VALUES(id_condutor),
        id_veiculo                  = VALUES(id_veiculo),
        id_grupo                    = VALUES(id_grupo),
        id_patio_retirada           = VALUES(id_patio_retirada),
        id_patio_devolucao_previsto = VALUES(id_patio_devolucao_previsto),
        id_patio_devolucao_real     = VALUES(id_patio_devolucao_real),
        data_extracao               = CURRENT_TIMESTAMP;
END$$

-- AFTER UPDATE: a locacao foi atualizada (tipicamente a DEVOLUCAO -> preenche
-- data_hora_real_devolucao, valor_final e id_patio_devolucao_real).
CREATE TRIGGER novook.trg_cdc_locacao_au
AFTER UPDATE ON novook.LOCACAO
FOR EACH ROW
BEGIN
    INSERT INTO dw_staging.stg_locacao
        (id_locacao, data_hora_retirada, data_hora_prev_devolucao,
         data_hora_real_devolucao, valor_previsto, valor_final, status_locacao,
         id_reserva, id_cliente, id_condutor, id_veiculo, id_grupo,
         id_patio_retirada, id_patio_devolucao_previsto, id_patio_devolucao_real)
    VALUES
        (NEW.id_locacao, NEW.data_hora_retirada, NEW.data_hora_prev_devolucao,
         NEW.data_hora_real_devolucao, NEW.valor_previsto, NEW.valor_final,
         NEW.status_locacao, NEW.id_reserva, NEW.id_cliente, NEW.id_condutor,
         NEW.id_veiculo,
         (SELECT v.id_grupo FROM novook.VEICULO v WHERE v.id_veiculo = NEW.id_veiculo),
         NEW.id_patio_retirada, NEW.id_patio_devolucao_previsto,
         NEW.id_patio_devolucao_real)
    ON DUPLICATE KEY UPDATE
        data_hora_retirada          = VALUES(data_hora_retirada),
        data_hora_prev_devolucao    = VALUES(data_hora_prev_devolucao),
        data_hora_real_devolucao    = VALUES(data_hora_real_devolucao),
        valor_previsto              = VALUES(valor_previsto),
        valor_final                 = VALUES(valor_final),
        status_locacao              = VALUES(status_locacao),
        id_reserva                  = VALUES(id_reserva),
        id_cliente                  = VALUES(id_cliente),
        id_condutor                 = VALUES(id_condutor),
        id_veiculo                  = VALUES(id_veiculo),
        id_grupo                    = VALUES(id_grupo),
        id_patio_retirada           = VALUES(id_patio_retirada),
        id_patio_devolucao_previsto = VALUES(id_patio_devolucao_previsto),
        id_patio_devolucao_real     = VALUES(id_patio_devolucao_real),
        data_extracao               = CURRENT_TIMESTAMP;
END$$

DELIMITER ;

-- ============================================================================
-- 4) AGENDAMENTO DAS EXTRACOES  (TEMPOS DE ACIONAMENTO)
--    Politica adotada:
--      * Dimensoes (cliente/veiculo/grupo/patio): CARGA TOTAL diaria 23:00.
--        Mudam pouco e tem baixo volume -> recarga completa e simples.
--      * Reservas e Locacoes: CDC em tempo real pelos TRIGGERS acima +
--        carga total diaria 23:15 como "rede de seguranca" (reconciliacao).
--      * Inventario de patio: SNAPSHOT diario as 23:50 (fim do dia operacional).
--    Ajuste os horarios conforme a janela de menor uso do sistema.
-- ============================================================================

DROP EVENT IF EXISTS ev_extrai_dimensoes;
DROP EVENT IF EXISTS ev_extrai_movimento;
DROP EVENT IF EXISTS ev_snapshot_inventario;

DELIMITER $$

CREATE EVENT ev_extrai_dimensoes
ON SCHEDULE EVERY 1 DAY
    STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 23 HOUR)  -- 23:00
DO
BEGIN
    CALL dw_staging.sp_extrai_dimensoes();
END$$

CREATE EVENT ev_extrai_movimento
ON SCHEDULE EVERY 1 DAY
    STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 23 HOUR + INTERVAL 15 MINUTE) -- 23:15
DO
BEGIN
    CALL dw_staging.sp_extrai_reservas();
    CALL dw_staging.sp_extrai_locacoes();
END$$

CREATE EVENT ev_snapshot_inventario
ON SCHEDULE EVERY 1 DAY
    STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 23 HOUR + INTERVAL 50 MINUTE) -- 23:50
DO
BEGIN
    CALL dw_staging.sp_snapshot_inventario(CURRENT_DATE);
END$$

DELIMITER ;

-- ============================================================================
-- 5) HABILITAR O AGENDADOR DE EVENTOS
--    Necessario para os EVENTs da secao 4 dispararem nos horarios definidos.
--    Requer privilegio SUPER / SYSTEM_VARIABLES_ADMIN. Se este comando falhar
--    por falta de privilegio, peca ao DBA para liga-lo; o restante do ETL
--    (procedures e triggers de CDC) funciona normalmente mesmo sem ele.
-- ============================================================================
SET GLOBAL event_scheduler = ON;

-- ============================================================================
-- 6) CARGA INICIAL (executar uma vez, na primeira montagem da staging)
--    Depois disso, os EVENTs/TRIGGERS mantem o staging atualizado.
-- ============================================================================
CALL sp_extrai_dimensoes();
CALL sp_extrai_reservas();
CALL sp_extrai_locacoes();
CALL sp_snapshot_inventario(CURRENT_DATE);

-- FIM DO SCRIPT DE EXTRACAO (NOVOOK)
