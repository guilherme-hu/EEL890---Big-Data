-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)

CREATE DATABASE IF NOT EXISTS staging
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE staging;

-- 1) TABELAS DE STAGING BRUTO (copia "raw" da fonte valviessejoao)
--    Conceitos do DW: cliente, veiculo, grupo, patio, reserva, locacao
--    (+ inventario de patio derivado de VEICULO). Coluna data_extracao p/ CDC.


DROP TABLE IF EXISTS stg_valviessejoao_inventario_patio;
DROP TABLE IF EXISTS stg_valviessejoao_locacao;
DROP TABLE IF EXISTS stg_valviessejoao_reserva;
DROP TABLE IF EXISTS stg_valviessejoao_patio;
DROP TABLE IF EXISTS stg_valviessejoao_grupo;
DROP TABLE IF EXISTS stg_valviessejoao_veiculo;
DROP TABLE IF EXISTS stg_valviessejoao_cliente;

-- CLIENTE: origem do Dim_Endereco (cidade/estado) e do Dim_Cliente.
CREATE TABLE stg_valviessejoao_cliente (
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
-- Guardamos id_grupo para enriquecer LOCACAO (que nao tem grupo direto).
CREATE TABLE stg_valviessejoao_veiculo (
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
    id_patio_atual  INTEGER,
    data_extracao   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_veiculo)
) ENGINE=InnoDB;

-- GRUPO_VEICULO: alimenta Dim_Grupo (e a diaria usada no Fato_Reserva).
CREATE TABLE stg_valviessejoao_grupo (
    id_grupo           INTEGER       NOT NULL,
    nome_grupo         VARCHAR(50),
    descricao          VARCHAR(200),
    faixa_valor_diaria DECIMAL(10,2),
    data_extracao      TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_grupo)
) ENGINE=InnoDB;

-- PATIO: alimenta Dim_Patio. ATENCAO: a fonte NAO possui capacidade de vagas.
CREATE TABLE stg_valviessejoao_patio (
    id_patio       INTEGER       NOT NULL,
    id_empresa     INTEGER,
    nome_patio     VARCHAR(100),
    localizacao    VARCHAR(150),
    codigo_patio   VARCHAR(20),
    data_extracao  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_patio)
) ENGINE=InnoDB;

-- RESERVA: alimenta Fato_Reserva.
CREATE TABLE stg_valviessejoao_reserva (
    id_reserva                  INTEGER   NOT NULL,
    data_reserva                DATE,
    data_prev_retirada          DATE,
    data_prev_devolucao         DATE,
    status_reserva              VARCHAR(20),
    id_cliente                  INTEGER,
    id_grupo                    INTEGER,
    id_patio_retirada           INTEGER,
    id_patio_devolucao_previsto INTEGER,
    data_extracao               TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_reserva)
) ENGINE=InnoDB;

-- LOCACAO: alimenta Fato_Locacao. Enriquecida com id_grupo (vindo de VEICULO).
CREATE TABLE stg_valviessejoao_locacao (
    id_locacao                  INTEGER   NOT NULL,
    data_hora_retirada          TIMESTAMP NULL,
    data_hora_prev_devolucao    TIMESTAMP NULL,
    data_hora_real_devolucao    TIMESTAMP NULL,
    valor_previsto              DECIMAL(10,2),
    valor_final                 DECIMAL(10,2),
    status_locacao              VARCHAR(20),
    id_reserva                  INTEGER,
    id_cliente                  INTEGER,
    id_condutor                 INTEGER,
    id_veiculo                  INTEGER,
    id_grupo                    INTEGER,           -- ENRIQUECIDO de VEICULO.id_grupo
    id_patio_retirada           INTEGER,
    id_patio_devolucao_previsto INTEGER,
    id_patio_devolucao_real     INTEGER,
    data_extracao               TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_locacao)
) ENGINE=InnoDB;

-- INVENTARIO DE PATIO: snapshot diario (grao = 1 veiculo presente por dia).
CREATE TABLE stg_valviessejoao_inventario_patio (
    data_snapshot  DATE      NOT NULL,
    id_patio       INTEGER   NOT NULL,
    id_veiculo     INTEGER   NOT NULL,
    id_grupo       INTEGER,
    data_extracao  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (data_snapshot, id_veiculo)
) ENGINE=InnoDB;


-- 2) EXTRACAO POR CARGA TOTAL (procedures) -- backfill inicial + reconciliacao
--    Reexecutaveis (TRUNCATE + INSERT...SELECT). Prefixadas pelo handle pois o
--    schema `staging` e compartilhado por todas as frotas do consorcio.

DROP PROCEDURE IF EXISTS sp_valviessejoao_extrai_dimensoes;
DROP PROCEDURE IF EXISTS sp_valviessejoao_extrai_reservas;
DROP PROCEDURE IF EXISTS sp_valviessejoao_extrai_locacoes;
DROP PROCEDURE IF EXISTS sp_valviessejoao_snapshot_inventario;

DELIMITER $$

-- ---- 2.1) Dimensoes: cliente, veiculo, grupo, patio --------------------------
CREATE PROCEDURE sp_valviessejoao_extrai_dimensoes()
BEGIN
    TRUNCATE TABLE stg_valviessejoao_cliente;
    INSERT INTO stg_valviessejoao_cliente
        (id_cliente, tipo_cliente, nome_razao_social, cpf_cnpj,
         cidade, estado, telefone, email)
    SELECT id_cliente, tipo_cliente, nome_razao_social, cpf_cnpj,
           cidade, estado, telefone, email
    FROM   novook.CLIENTE;

    TRUNCATE TABLE stg_valviessejoao_veiculo;
    INSERT INTO stg_valviessejoao_veiculo
        (id_veiculo, placa, chassi, marca, modelo, cor, mecanizacao,
         ar_condicionado, status, id_grupo, id_empresa, id_patio_atual)
    SELECT id_veiculo, placa, chassi, marca, modelo, cor, mecanizacao,
           ar_condicionado, status, id_grupo, id_empresa, id_patio_atual
    FROM   novook.VEICULO;

    TRUNCATE TABLE stg_valviessejoao_grupo;
    INSERT INTO stg_valviessejoao_grupo
        (id_grupo, nome_grupo, descricao, faixa_valor_diaria)
    SELECT id_grupo, nome_grupo, descricao, faixa_valor_diaria
    FROM   novook.GRUPO_VEICULO;

    TRUNCATE TABLE stg_valviessejoao_patio;
    INSERT INTO stg_valviessejoao_patio
        (id_patio, id_empresa, nome_patio, localizacao, codigo_patio)
    SELECT id_patio, id_empresa, nome_patio, localizacao, codigo_patio
    FROM   novook.PATIO;
END$$

-- ---- 2.2) Reservas -----------------------------------------------------------
CREATE PROCEDURE sp_valviessejoao_extrai_reservas()
BEGIN
    TRUNCATE TABLE stg_valviessejoao_reserva;
    INSERT INTO stg_valviessejoao_reserva
        (id_reserva, data_reserva, data_prev_retirada, data_prev_devolucao,
         status_reserva, id_cliente, id_grupo, id_patio_retirada,
         id_patio_devolucao_previsto)
    SELECT id_reserva, data_reserva, data_prev_retirada, data_prev_devolucao,
           status_reserva, id_cliente, id_grupo, id_patio_retirada,
           id_patio_devolucao_previsto
    FROM   novook.RESERVA;
END$$

-- ---- 2.3) Locacoes (enriquecidas com o grupo do veiculo) ---------------------
CREATE PROCEDURE sp_valviessejoao_extrai_locacoes()
BEGIN
    TRUNCATE TABLE stg_valviessejoao_locacao;
    INSERT INTO stg_valviessejoao_locacao
        (id_locacao, data_hora_retirada, data_hora_prev_devolucao,
         data_hora_real_devolucao, valor_previsto, valor_final, status_locacao,
         id_reserva, id_cliente, id_condutor, id_veiculo, id_grupo,
         id_patio_retirada, id_patio_devolucao_previsto, id_patio_devolucao_real)
    SELECT l.id_locacao, l.data_hora_retirada, l.data_hora_prev_devolucao,
           l.data_hora_real_devolucao, l.valor_previsto, l.valor_final,
           l.status_locacao, l.id_reserva, l.id_cliente, l.id_condutor,
           l.id_veiculo, v.id_grupo,
           l.id_patio_retirada, l.id_patio_devolucao_previsto,
           l.id_patio_devolucao_real
    FROM   novook.LOCACAO l
    JOIN   novook.VEICULO v ON v.id_veiculo = l.id_veiculo;
END$$

-- ---- 2.4) Snapshot diario do inventario de patio -----------------------------
-- valviessejoao POSSUI visibilidade direta (VEICULO.id_patio_atual): basta
-- listar os veiculos NAO alugados (logo, fisicamente presentes no patio).
CREATE PROCEDURE sp_valviessejoao_snapshot_inventario(IN p_data DATE)
BEGIN
    IF p_data IS NULL THEN
        SET p_data = CURRENT_DATE;
    END IF;
    DELETE FROM stg_valviessejoao_inventario_patio WHERE data_snapshot = p_data;
    INSERT INTO stg_valviessejoao_inventario_patio
        (data_snapshot, id_patio, id_veiculo, id_grupo)
    SELECT p_data, v.id_patio_atual, v.id_veiculo, v.id_grupo
    FROM   novook.VEICULO v
    WHERE  v.status <> 'ALUGADO';
END$$

DELIMITER ;

--- 3) EXTRACAO POR CDC (TRIGGERS no OLTP de origem) -- item 5 do plano
--    Triggers AFTER INSERT/AFTER UPDATE para TODAS as entidades do DW:
--    Cliente, Veiculo, Grupo, Patio (dimensoes) + Reserva, Locacao (fatos).
--    Cada trigger faz UPSERT na respectiva tabela bruta stg_valviessejoao_*.
--    OBS: os triggers pertencem ao schema da FONTE (novook); por isso o
--    DROP e o CREATE sao qualificados com "novook.".
-- ----------------------------- CLIENTE --------------------------------------
DROP TRIGGER IF EXISTS novook.trg_ext_valviessejoao_cliente_ai;
DROP TRIGGER IF EXISTS novook.trg_ext_valviessejoao_cliente_au;

DELIMITER $$
CREATE TRIGGER novook.trg_ext_valviessejoao_cliente_ai
AFTER INSERT ON novook.CLIENTE
FOR EACH ROW
INSERT INTO staging.stg_valviessejoao_cliente
    (id_cliente, tipo_cliente, nome_razao_social, cpf_cnpj, cidade, estado, telefone, email)
VALUES (NEW.id_cliente, NEW.tipo_cliente, NEW.nome_razao_social, NEW.cpf_cnpj,
        NEW.cidade, NEW.estado, NEW.telefone, NEW.email)
ON DUPLICATE KEY UPDATE
    tipo_cliente = VALUES(tipo_cliente), nome_razao_social = VALUES(nome_razao_social),
    cpf_cnpj = VALUES(cpf_cnpj), cidade = VALUES(cidade), estado = VALUES(estado),
    telefone = VALUES(telefone), email = VALUES(email), data_extracao = CURRENT_TIMESTAMP$$

CREATE TRIGGER novook.trg_ext_valviessejoao_cliente_au
AFTER UPDATE ON novook.CLIENTE
FOR EACH ROW
INSERT INTO staging.stg_valviessejoao_cliente
    (id_cliente, tipo_cliente, nome_razao_social, cpf_cnpj, cidade, estado, telefone, email)
VALUES (NEW.id_cliente, NEW.tipo_cliente, NEW.nome_razao_social, NEW.cpf_cnpj,
        NEW.cidade, NEW.estado, NEW.telefone, NEW.email)
ON DUPLICATE KEY UPDATE
    tipo_cliente = VALUES(tipo_cliente), nome_razao_social = VALUES(nome_razao_social),
    cpf_cnpj = VALUES(cpf_cnpj), cidade = VALUES(cidade), estado = VALUES(estado),
    telefone = VALUES(telefone), email = VALUES(email), data_extracao = CURRENT_TIMESTAMP$$

-- ----------------------------- VEICULO --------------------------------------
DROP TRIGGER IF EXISTS novook.trg_ext_valviessejoao_veiculo_ai$$
DROP TRIGGER IF EXISTS novook.trg_ext_valviessejoao_veiculo_au$$

CREATE TRIGGER novook.trg_ext_valviessejoao_veiculo_ai
AFTER INSERT ON novook.VEICULO
FOR EACH ROW
INSERT INTO staging.stg_valviessejoao_veiculo
    (id_veiculo, placa, chassi, marca, modelo, cor, mecanizacao,
     ar_condicionado, status, id_grupo, id_empresa, id_patio_atual)
VALUES (NEW.id_veiculo, NEW.placa, NEW.chassi, NEW.marca, NEW.modelo, NEW.cor,
        NEW.mecanizacao, NEW.ar_condicionado, NEW.status, NEW.id_grupo,
        NEW.id_empresa, NEW.id_patio_atual)
ON DUPLICATE KEY UPDATE
    placa = VALUES(placa), chassi = VALUES(chassi), marca = VALUES(marca),
    modelo = VALUES(modelo), cor = VALUES(cor), mecanizacao = VALUES(mecanizacao),
    ar_condicionado = VALUES(ar_condicionado), status = VALUES(status),
    id_grupo = VALUES(id_grupo), id_empresa = VALUES(id_empresa),
    id_patio_atual = VALUES(id_patio_atual), data_extracao = CURRENT_TIMESTAMP$$

CREATE TRIGGER novook.trg_ext_valviessejoao_veiculo_au
AFTER UPDATE ON novook.VEICULO
FOR EACH ROW
INSERT INTO staging.stg_valviessejoao_veiculo
    (id_veiculo, placa, chassi, marca, modelo, cor, mecanizacao,
     ar_condicionado, status, id_grupo, id_empresa, id_patio_atual)
VALUES (NEW.id_veiculo, NEW.placa, NEW.chassi, NEW.marca, NEW.modelo, NEW.cor,
        NEW.mecanizacao, NEW.ar_condicionado, NEW.status, NEW.id_grupo,
        NEW.id_empresa, NEW.id_patio_atual)
ON DUPLICATE KEY UPDATE
    placa = VALUES(placa), chassi = VALUES(chassi), marca = VALUES(marca),
    modelo = VALUES(modelo), cor = VALUES(cor), mecanizacao = VALUES(mecanizacao),
    ar_condicionado = VALUES(ar_condicionado), status = VALUES(status),
    id_grupo = VALUES(id_grupo), id_empresa = VALUES(id_empresa),
    id_patio_atual = VALUES(id_patio_atual), data_extracao = CURRENT_TIMESTAMP$$

-- --------------------------- GRUPO_VEICULO ----------------------------------
DROP TRIGGER IF EXISTS novook.trg_ext_valviessejoao_grupo_ai$$
DROP TRIGGER IF EXISTS novook.trg_ext_valviessejoao_grupo_au$$

CREATE TRIGGER novook.trg_ext_valviessejoao_grupo_ai
AFTER INSERT ON novook.GRUPO_VEICULO
FOR EACH ROW
INSERT INTO staging.stg_valviessejoao_grupo
    (id_grupo, nome_grupo, descricao, faixa_valor_diaria)
VALUES (NEW.id_grupo, NEW.nome_grupo, NEW.descricao, NEW.faixa_valor_diaria)
ON DUPLICATE KEY UPDATE
    nome_grupo = VALUES(nome_grupo), descricao = VALUES(descricao),
    faixa_valor_diaria = VALUES(faixa_valor_diaria), data_extracao = CURRENT_TIMESTAMP$$

CREATE TRIGGER novook.trg_ext_valviessejoao_grupo_au
AFTER UPDATE ON novook.GRUPO_VEICULO
FOR EACH ROW
INSERT INTO staging.stg_valviessejoao_grupo
    (id_grupo, nome_grupo, descricao, faixa_valor_diaria)
VALUES (NEW.id_grupo, NEW.nome_grupo, NEW.descricao, NEW.faixa_valor_diaria)
ON DUPLICATE KEY UPDATE
    nome_grupo = VALUES(nome_grupo), descricao = VALUES(descricao),
    faixa_valor_diaria = VALUES(faixa_valor_diaria), data_extracao = CURRENT_TIMESTAMP$$

-- ------------------------------- PATIO --------------------------------------
DROP TRIGGER IF EXISTS novook.trg_ext_valviessejoao_patio_ai$$
DROP TRIGGER IF EXISTS novook.trg_ext_valviessejoao_patio_au$$

CREATE TRIGGER novook.trg_ext_valviessejoao_patio_ai
AFTER INSERT ON novook.PATIO
FOR EACH ROW
INSERT INTO staging.stg_valviessejoao_patio
    (id_patio, id_empresa, nome_patio, localizacao, codigo_patio)
VALUES (NEW.id_patio, NEW.id_empresa, NEW.nome_patio, NEW.localizacao, NEW.codigo_patio)
ON DUPLICATE KEY UPDATE
    id_empresa = VALUES(id_empresa), nome_patio = VALUES(nome_patio),
    localizacao = VALUES(localizacao), codigo_patio = VALUES(codigo_patio),
    data_extracao = CURRENT_TIMESTAMP$$

CREATE TRIGGER novook.trg_ext_valviessejoao_patio_au
AFTER UPDATE ON novook.PATIO
FOR EACH ROW
INSERT INTO staging.stg_valviessejoao_patio
    (id_patio, id_empresa, nome_patio, localizacao, codigo_patio)
VALUES (NEW.id_patio, NEW.id_empresa, NEW.nome_patio, NEW.localizacao, NEW.codigo_patio)
ON DUPLICATE KEY UPDATE
    id_empresa = VALUES(id_empresa), nome_patio = VALUES(nome_patio),
    localizacao = VALUES(localizacao), codigo_patio = VALUES(codigo_patio),
    data_extracao = CURRENT_TIMESTAMP$$

-- ----------------------------- RESERVA --------------------------------------
DROP TRIGGER IF EXISTS novook.trg_ext_valviessejoao_reserva_ai$$
DROP TRIGGER IF EXISTS novook.trg_ext_valviessejoao_reserva_au$$

CREATE TRIGGER novook.trg_ext_valviessejoao_reserva_ai
AFTER INSERT ON novook.RESERVA
FOR EACH ROW
INSERT INTO staging.stg_valviessejoao_reserva
    (id_reserva, data_reserva, data_prev_retirada, data_prev_devolucao,
     status_reserva, id_cliente, id_grupo, id_patio_retirada, id_patio_devolucao_previsto)
VALUES (NEW.id_reserva, NEW.data_reserva, NEW.data_prev_retirada,
        NEW.data_prev_devolucao, NEW.status_reserva, NEW.id_cliente, NEW.id_grupo,
        NEW.id_patio_retirada, NEW.id_patio_devolucao_previsto)
ON DUPLICATE KEY UPDATE
    data_reserva = VALUES(data_reserva), data_prev_retirada = VALUES(data_prev_retirada),
    data_prev_devolucao = VALUES(data_prev_devolucao), status_reserva = VALUES(status_reserva),
    id_cliente = VALUES(id_cliente), id_grupo = VALUES(id_grupo),
    id_patio_retirada = VALUES(id_patio_retirada),
    id_patio_devolucao_previsto = VALUES(id_patio_devolucao_previsto),
    data_extracao = CURRENT_TIMESTAMP$$

CREATE TRIGGER novook.trg_ext_valviessejoao_reserva_au
AFTER UPDATE ON novook.RESERVA
FOR EACH ROW
INSERT INTO staging.stg_valviessejoao_reserva
    (id_reserva, data_reserva, data_prev_retirada, data_prev_devolucao,
     status_reserva, id_cliente, id_grupo, id_patio_retirada, id_patio_devolucao_previsto)
VALUES (NEW.id_reserva, NEW.data_reserva, NEW.data_prev_retirada,
        NEW.data_prev_devolucao, NEW.status_reserva, NEW.id_cliente, NEW.id_grupo,
        NEW.id_patio_retirada, NEW.id_patio_devolucao_previsto)
ON DUPLICATE KEY UPDATE
    data_reserva = VALUES(data_reserva), data_prev_retirada = VALUES(data_prev_retirada),
    data_prev_devolucao = VALUES(data_prev_devolucao), status_reserva = VALUES(status_reserva),
    id_cliente = VALUES(id_cliente), id_grupo = VALUES(id_grupo),
    id_patio_retirada = VALUES(id_patio_retirada),
    id_patio_devolucao_previsto = VALUES(id_patio_devolucao_previsto),
    data_extracao = CURRENT_TIMESTAMP$$

-- ----------------------------- LOCACAO --------------------------------------
DROP TRIGGER IF EXISTS novook.trg_ext_valviessejoao_locacao_ai$$
DROP TRIGGER IF EXISTS novook.trg_ext_valviessejoao_locacao_au$$

CREATE TRIGGER novook.trg_ext_valviessejoao_locacao_ai
AFTER INSERT ON novook.LOCACAO
FOR EACH ROW
INSERT INTO staging.stg_valviessejoao_locacao
    (id_locacao, data_hora_retirada, data_hora_prev_devolucao, data_hora_real_devolucao,
     valor_previsto, valor_final, status_locacao, id_reserva, id_cliente, id_condutor,
     id_veiculo, id_grupo, id_patio_retirada, id_patio_devolucao_previsto, id_patio_devolucao_real)
VALUES (NEW.id_locacao, NEW.data_hora_retirada, NEW.data_hora_prev_devolucao,
        NEW.data_hora_real_devolucao, NEW.valor_previsto, NEW.valor_final, NEW.status_locacao,
        NEW.id_reserva, NEW.id_cliente, NEW.id_condutor, NEW.id_veiculo,
        (SELECT v.id_grupo FROM novook.VEICULO v WHERE v.id_veiculo = NEW.id_veiculo),
        NEW.id_patio_retirada, NEW.id_patio_devolucao_previsto, NEW.id_patio_devolucao_real)
ON DUPLICATE KEY UPDATE
    data_hora_retirada = VALUES(data_hora_retirada),
    data_hora_prev_devolucao = VALUES(data_hora_prev_devolucao),
    data_hora_real_devolucao = VALUES(data_hora_real_devolucao),
    valor_previsto = VALUES(valor_previsto), valor_final = VALUES(valor_final),
    status_locacao = VALUES(status_locacao), id_reserva = VALUES(id_reserva),
    id_cliente = VALUES(id_cliente), id_condutor = VALUES(id_condutor),
    id_veiculo = VALUES(id_veiculo), id_grupo = VALUES(id_grupo),
    id_patio_retirada = VALUES(id_patio_retirada),
    id_patio_devolucao_previsto = VALUES(id_patio_devolucao_previsto),
    id_patio_devolucao_real = VALUES(id_patio_devolucao_real),
    data_extracao = CURRENT_TIMESTAMP$$

CREATE TRIGGER novook.trg_ext_valviessejoao_locacao_au
AFTER UPDATE ON novook.LOCACAO
FOR EACH ROW
INSERT INTO staging.stg_valviessejoao_locacao
    (id_locacao, data_hora_retirada, data_hora_prev_devolucao, data_hora_real_devolucao,
     valor_previsto, valor_final, status_locacao, id_reserva, id_cliente, id_condutor,
     id_veiculo, id_grupo, id_patio_retirada, id_patio_devolucao_previsto, id_patio_devolucao_real)
VALUES (NEW.id_locacao, NEW.data_hora_retirada, NEW.data_hora_prev_devolucao,
        NEW.data_hora_real_devolucao, NEW.valor_previsto, NEW.valor_final, NEW.status_locacao,
        NEW.id_reserva, NEW.id_cliente, NEW.id_condutor, NEW.id_veiculo,
        (SELECT v.id_grupo FROM novook.VEICULO v WHERE v.id_veiculo = NEW.id_veiculo),
        NEW.id_patio_retirada, NEW.id_patio_devolucao_previsto, NEW.id_patio_devolucao_real)
ON DUPLICATE KEY UPDATE
    data_hora_retirada = VALUES(data_hora_retirada),
    data_hora_prev_devolucao = VALUES(data_hora_prev_devolucao),
    data_hora_real_devolucao = VALUES(data_hora_real_devolucao),
    valor_previsto = VALUES(valor_previsto), valor_final = VALUES(valor_final),
    status_locacao = VALUES(status_locacao), id_reserva = VALUES(id_reserva),
    id_cliente = VALUES(id_cliente), id_condutor = VALUES(id_condutor),
    id_veiculo = VALUES(id_veiculo), id_grupo = VALUES(id_grupo),
    id_patio_retirada = VALUES(id_patio_retirada),
    id_patio_devolucao_previsto = VALUES(id_patio_devolucao_previsto),
    id_patio_devolucao_real = VALUES(id_patio_devolucao_real),
    data_extracao = CURRENT_TIMESTAMP$$

DELIMITER ;

-- 4) AGENDAMENTO (TEMPOS DE ACIONAMENTO) -- rede de seguranca + inventario
--    Politica:
--      * CDC em tempo real pelos TRIGGERS acima (mecanismo principal).
--      * Carga total de reconciliacao: dimensoes 23:00 e movimento 23:15.
--      * Snapshot diario do inventario: 23:50 (fim do dia operacional).
--    EVENTs prefixados pelo handle (schema `staging` e compartilhado).

DROP EVENT IF EXISTS ev_valviessejoao_extrai_dimensoes;
DROP EVENT IF EXISTS ev_valviessejoao_extrai_movimento;
DROP EVENT IF EXISTS ev_valviessejoao_snapshot_inventario;

DELIMITER $$

CREATE EVENT ev_valviessejoao_extrai_dimensoes
ON SCHEDULE EVERY 1 DAY
    STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 23 HOUR)            -- 23:00
DO
BEGIN
    CALL staging.sp_valviessejoao_extrai_dimensoes();
END$$

CREATE EVENT ev_valviessejoao_extrai_movimento
ON SCHEDULE EVERY 1 DAY
    STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 23 HOUR + INTERVAL 15 MINUTE) -- 23:15
DO
BEGIN
    CALL staging.sp_valviessejoao_extrai_reservas();
    CALL staging.sp_valviessejoao_extrai_locacoes();
END$$

CREATE EVENT ev_valviessejoao_snapshot_inventario
ON SCHEDULE EVERY 1 DAY
    STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 23 HOUR + INTERVAL 50 MINUTE) -- 23:50
DO
BEGIN
    CALL staging.sp_valviessejoao_snapshot_inventario(CURRENT_DATE);
END$$

DELIMITER ;

-- 5) HABILITAR O AGENDADOR DE EVENTOS
--    Requer privilegio SUPER / SYSTEM_VARIABLES_ADMIN. Se falhar por falta de
--    privilegio, peca ao DBA; o restante do ETL funciona normalmente sem ele.

SET GLOBAL event_scheduler = ON;

-- 6) CARGA INICIAL / BACKFILL (executar uma vez na primeira montagem)
--    Depois disso, os TRIGGERS mantem o staging atualizado em tempo real.
CALL sp_valviessejoao_extrai_dimensoes();
CALL sp_valviessejoao_extrai_reservas();
CALL sp_valviessejoao_extrai_locacoes();
CALL sp_valviessejoao_snapshot_inventario(CURRENT_DATE);

