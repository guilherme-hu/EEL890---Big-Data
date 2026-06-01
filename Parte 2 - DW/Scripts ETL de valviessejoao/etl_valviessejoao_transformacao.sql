-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)


USE dw_staging;

DROP FUNCTION IF EXISTS fn_frota_origem;
DROP FUNCTION IF EXISTS fn_txt_norm;

DELIMITER $$

CREATE FUNCTION fn_frota_origem() RETURNS VARCHAR(100)
DETERMINISTIC NO SQL
RETURN 'NOVOOK'$$

-- Normaliza texto: tira espacos, sobe para maiusculas e devolve NULL se vazio.
CREATE FUNCTION fn_txt_norm(p VARCHAR(255)) RETURNS VARCHAR(255)
DETERMINISTIC NO SQL
RETURN NULLIF(TRIM(UPPER(p)), '')$$

DELIMITER ;

-- 1) TABELAS CONFORMADAS (trf_*)  -- espelham as colunas do DW (sem as SKs,
--    que so sao geradas na Carga). Guardam as CHAVES NATURAIS (nk_*) para a
--    que so sao geradas na Carga). Guardam as CHAVES NATURAIS (nk_*) para a
--    Carga resolver as Surrogate Keys por JOIN.

CREATE SCHEMA IF NOT EXISTS staging;

CREATE TABLE IF NOT EXISTS staging.stg_rejeitos_etl (
    id_rejeito      INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    tabela_origem   VARCHAR(60)  NOT NULL,
    nk_frota_origem VARCHAR(20)  NOT NULL,
    nk_id_registro  INT          NOT NULL,
    motivo_rejeito  VARCHAR(255) NOT NULL,
    dados_json      JSON,
    dt_rejeito      DATETIME     NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS trf_fato_inventario_patio;
DROP TABLE IF EXISTS trf_fato_reserva;
DROP TABLE IF EXISTS trf_fato_locacao;
DROP TABLE IF EXISTS trf_dim_patio;
DROP TABLE IF EXISTS trf_dim_grupo;
DROP TABLE IF EXISTS trf_dim_veiculo;
DROP TABLE IF EXISTS trf_dim_cliente;
DROP TABLE IF EXISTS trf_dim_endereco;

-- ---- Dim_Endereco: conjunto de enderecos distintos (cidade/estado/pais) -----
CREATE TABLE trf_dim_endereco (
    cidade  VARCHAR(100) NOT NULL,
    estado  VARCHAR(100) NOT NULL,
    pais    VARCHAR(100) NOT NULL,
    PRIMARY KEY (cidade, estado, pais)
) ENGINE=InnoDB;

-- ---- Dim_Cliente (carrega tambem o endereco conformado p/ resolver a FK) -----
CREATE TABLE trf_dim_cliente (
    nk_frota_origem VARCHAR(100) NOT NULL,
    nk_id_cliente   INTEGER      NOT NULL,
    tipo_cliente    VARCHAR(2),
    nome            VARCHAR(150),
    cidade          VARCHAR(100),
    estado          VARCHAR(100),
    pais            VARCHAR(100),
    PRIMARY KEY (nk_frota_origem, nk_id_cliente)
) ENGINE=InnoDB;

-- ---- Dim_Veiculo ------------------------------------------------------------
CREATE TABLE trf_dim_veiculo (
    nk_frota_origem     VARCHAR(100) NOT NULL,
    nk_id_veiculo       INTEGER      NOT NULL,
    placa               VARCHAR(10),
    marca               VARCHAR(50),
    modelo              VARCHAR(50),
    mecanizacao         VARCHAR(20),
    tem_ar_condicionado BOOLEAN,
    PRIMARY KEY (nk_frota_origem, nk_id_veiculo)
) ENGINE=InnoDB;

-- ---- Dim_Grupo --------------------------------------------------------------
CREATE TABLE trf_dim_grupo (
    nk_frota_origem VARCHAR(100)  NOT NULL,
    nk_id_grupo     INTEGER       NOT NULL,
    nome_grupo      VARCHAR(50),
    valor_diaria    DECIMAL(10,2),
    PRIMARY KEY (nk_frota_origem, nk_id_grupo)
) ENGINE=InnoDB;

-- ---- Dim_Patio (capacidade_vagas fica NULL: a fonte NOVOOK nao a possui) -----
CREATE TABLE trf_dim_patio (
    nk_frota_origem  VARCHAR(100) NOT NULL,
    nk_id_patio      INTEGER      NOT NULL,
    nome_patio       VARCHAR(100),
    capacidade_vagas INTEGER,                 -- sempre NULL para esta fonte
    PRIMARY KEY (nk_frota_origem, nk_id_patio)
) ENGINE=InnoDB;

-- ---- Fato_Locacao (grao: 1 contrato de locacao) -----------------------------
CREATE TABLE trf_fato_locacao (
    nk_frota_origem         VARCHAR(100) NOT NULL,
    nk_id_locacao           INTEGER      NOT NULL,
    dt_retirada             DATE,
    dt_prev_devolucao       DATE,
    dt_real_devolucao       DATE,            -- NULL se ainda nao devolvido
    nk_id_cliente           INTEGER,
    nk_id_veiculo           INTEGER,
    nk_id_grupo             INTEGER,
    nk_id_patio_retirada    INTEGER,
    nk_id_patio_devol_real  INTEGER,         -- NULL se ainda nao devolvido
    valor_final             DECIMAL(10,2),   -- NULL ate a devolucao
    qtde_locacoes           INT NOT NULL DEFAULT 1,
    PRIMARY KEY (nk_frota_origem, nk_id_locacao)
) ENGINE=InnoDB;

-- ---- Fato_Reserva (grao: 1 intencao de reserva) -----------------------------
CREATE TABLE trf_fato_reserva (
    nk_frota_origem        VARCHAR(100) NOT NULL,
    nk_id_reserva          INTEGER      NOT NULL,
    dt_reserva             DATE,
    dt_prev_retirada       DATE,
    dt_prev_devolucao      DATE,
    nk_id_cliente          INTEGER,
    nk_id_grupo            INTEGER,
    nk_id_patio_retirada   INTEGER,
    nk_id_patio_fim        INTEGER,
    duracao_prevista_dias  INT,
    valor_previsto_reserva DECIMAL(10,2),
    dd_status_reserva      VARCHAR(100),     -- dimensao degenerada
    qtde_reservas          INT NOT NULL DEFAULT 1,
    PRIMARY KEY (nk_frota_origem, nk_id_reserva)
) ENGINE=InnoDB;

-- ---- Fato_Inventario_Patio (grao: 1 veiculo presente por dia) ---------------
CREATE TABLE trf_fato_inventario_patio (
    nk_frota_origem          VARCHAR(100) NOT NULL,
    dt_referencia            DATE         NOT NULL,
    nk_id_patio              INTEGER      NOT NULL,
    nk_id_veiculo            INTEGER      NOT NULL,
    nk_id_grupo              INTEGER,
    qtde_veiculos_presentes  INT NOT NULL DEFAULT 1,
    PRIMARY KEY (nk_frota_origem, dt_referencia, nk_id_veiculo)
) ENGINE=InnoDB;

-- 2) TRANSFORMACAO EM LOTE (procedures)

DROP PROCEDURE IF EXISTS sp_transforma_dimensoes;
DROP PROCEDURE IF EXISTS sp_transforma_locacoes;
DROP PROCEDURE IF EXISTS sp_transforma_reservas;
DROP PROCEDURE IF EXISTS sp_transforma_inventario;
DROP PROCEDURE IF EXISTS sp_transforma_tudo;

DELIMITER $$

-- ---- 2.1) Dimensoes ----------------------------------------------------------
CREATE PROCEDURE sp_transforma_dimensoes()
BEGIN
    -- Dim_Endereco: enderecos distintos e conformados a partir dos clientes.
    -- Enderecos incompletos viram rotulos padrao (evita "buracos" na dimensao).
    INSERT IGNORE INTO trf_dim_endereco (cidade, estado, pais)
    SELECT DISTINCT
           COALESCE(fn_txt_norm(c.cidade), 'NAO INFORMADO') AS cidade,
           COALESCE(fn_txt_norm(c.estado), 'NI')            AS estado,
           'BRASIL'                                         AS pais
    FROM   stg_cliente c;

    -- Dim_Cliente (guarda o endereco conformado p/ a Carga resolver sk_endereco)
    INSERT INTO trf_dim_cliente
        (nk_frota_origem, nk_id_cliente, tipo_cliente, nome, cidade, estado, pais)
    SELECT fn_frota_origem(), c.id_cliente,
           fn_txt_norm(c.tipo_cliente),
           TRIM(c.nome_razao_social),
           COALESCE(fn_txt_norm(c.cidade), 'NAO INFORMADO'),
           COALESCE(fn_txt_norm(c.estado), 'NI'),
           'BRASIL'
    FROM   stg_cliente c
    ON DUPLICATE KEY UPDATE
        tipo_cliente = VALUES(tipo_cliente),
        nome         = VALUES(nome),
        cidade       = VALUES(cidade),
        estado       = VALUES(estado),
        pais         = VALUES(pais);

    -- Dim_Veiculo
    INSERT INTO trf_dim_veiculo
        (nk_frota_origem, nk_id_veiculo, placa, marca, modelo,
         mecanizacao, tem_ar_condicionado)
    SELECT fn_frota_origem(), v.id_veiculo,
           fn_txt_norm(v.placa), TRIM(v.marca), TRIM(v.modelo),
           fn_txt_norm(v.mecanizacao), v.ar_condicionado
    FROM   stg_veiculo v
    ON DUPLICATE KEY UPDATE
        placa               = VALUES(placa),
        marca               = VALUES(marca),
        modelo              = VALUES(modelo),
        mecanizacao         = VALUES(mecanizacao),
        tem_ar_condicionado = VALUES(tem_ar_condicionado);

    -- Dim_Grupo (faixa_valor_diaria -> valor_diaria)
    INSERT INTO trf_dim_grupo
        (nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria)
    SELECT fn_frota_origem(), g.id_grupo, TRIM(g.nome_grupo), g.faixa_valor_diaria
    FROM   stg_grupo g
    ON DUPLICATE KEY UPDATE
        nome_grupo   = VALUES(nome_grupo),
        valor_diaria = VALUES(valor_diaria);

    -- Dim_Patio (capacidade_vagas = NULL: ausente na fonte)
    INSERT INTO trf_dim_patio
        (nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas)
    SELECT fn_frota_origem(), p.id_patio, TRIM(p.nome_patio), NULL
    FROM   stg_patio p
    ON DUPLICATE KEY UPDATE
        nome_patio       = VALUES(nome_patio),
        capacidade_vagas = VALUES(capacidade_vagas);
END$$

-- ---- 2.2) Fato_Locacao -------------------------------------------------------
CREATE PROCEDURE sp_transforma_locacoes()
BEGIN
    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json)
    SELECT 'stg_locacao', fn_frota_origem(), l.id_locacao,
        CASE
            WHEN l.id_cliente IS NULL         THEN 'Locação sem cliente'
            WHEN l.id_veiculo IS NULL         THEN 'Locação sem veículo'
            WHEN l.id_grupo IS NULL           THEN 'Locação sem grupo'
            WHEN l.id_patio_retirada IS NULL  THEN 'Locação sem pátio de retirada'
            WHEN l.data_hora_retirada IS NULL THEN 'Locação sem data de retirada'
            WHEN l.data_hora_prev_devolucao IS NULL THEN 'Locação sem data prev. devolução'
            WHEN l.data_hora_real_devolucao IS NOT NULL AND DATE(l.data_hora_real_devolucao) < DATE(l.data_hora_retirada) THEN 'Data devolução real anterior à retirada'
            ELSE 'Erro desconhecido'
        END,
        JSON_OBJECT('nk_id_locacao', l.id_locacao, 'nk_id_cliente', l.id_cliente, 'nk_id_veiculo', l.id_veiculo, 'nk_id_grupo', l.id_grupo, 'nk_id_patio_retirada', l.id_patio_retirada, 'data_retirada', l.data_hora_retirada, 'data_prev_devolucao', l.data_hora_prev_devolucao, 'data_real_devolucao', l.data_hora_real_devolucao, 'valor_final', l.valor_final)
    FROM stg_locacao l
    WHERE l.id_cliente IS NULL OR l.id_veiculo IS NULL OR l.id_grupo IS NULL OR l.id_patio_retirada IS NULL OR l.data_hora_retirada IS NULL OR l.data_hora_prev_devolucao IS NULL OR (l.data_hora_real_devolucao IS NOT NULL AND DATE(l.data_hora_real_devolucao) < DATE(l.data_hora_retirada));

    INSERT INTO trf_fato_locacao
        (nk_frota_origem, nk_id_locacao, dt_retirada, dt_prev_devolucao,
         dt_real_devolucao, nk_id_cliente, nk_id_veiculo, nk_id_grupo,
         nk_id_patio_retirada, nk_id_patio_devol_real, valor_final, qtde_locacoes)
    SELECT fn_frota_origem(), l.id_locacao,
           DATE(l.data_hora_retirada),
           DATE(l.data_hora_prev_devolucao),
           DATE(l.data_hora_real_devolucao),   -- NULL se ainda nao devolvido
           l.id_cliente, l.id_veiculo, l.id_grupo,
           l.id_patio_retirada, l.id_patio_devolucao_real,
           l.valor_final, 1
    FROM   stg_locacao l
    ON DUPLICATE KEY UPDATE
        dt_retirada            = VALUES(dt_retirada),
        dt_prev_devolucao      = VALUES(dt_prev_devolucao),
        dt_real_devolucao      = VALUES(dt_real_devolucao),
        nk_id_cliente          = VALUES(nk_id_cliente),
        nk_id_veiculo          = VALUES(nk_id_veiculo),
        nk_id_grupo            = VALUES(nk_id_grupo),
        nk_id_patio_retirada   = VALUES(nk_id_patio_retirada),
        nk_id_patio_devol_real = VALUES(nk_id_patio_devol_real),
        valor_final            = VALUES(valor_final);
END$$

-- ---- 2.3) Fato_Reserva (calcula duracao e valor previsto) --------------------
CREATE PROCEDURE sp_transforma_reservas()
BEGIN
    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json)
    SELECT 'stg_reserva', fn_frota_origem(), r.id_reserva,
        CASE
            WHEN r.id_cliente IS NULL            THEN 'Reserva sem cliente'
            WHEN r.id_grupo IS NULL              THEN 'Reserva sem grupo'
            WHEN r.id_patio_retirada IS NULL     THEN 'Reserva sem pátio de retirada'
            WHEN r.id_patio_devolucao_previsto IS NULL THEN 'Reserva sem pátio de fim'
            WHEN r.data_reserva IS NULL             THEN 'Reserva sem data de reserva'
            WHEN r.data_prev_retirada IS NULL   THEN 'Reserva sem data de retirada prevista'
            WHEN r.data_prev_devolucao IS NULL  THEN 'Reserva sem data de devolução prevista'
            WHEN r.data_prev_devolucao <= r.data_prev_retirada THEN 'Data devolução <= data retirada'
            ELSE 'Erro desconhecido'
        END,
        JSON_OBJECT('nk_id_reserva', r.id_reserva, 'nk_id_cliente', r.id_cliente, 'nk_id_grupo', r.id_grupo, 'nk_id_patio_retirada', r.id_patio_retirada, 'nk_id_patio_fim', r.id_patio_devolucao_previsto, 'data_reserva', r.data_reserva, 'data_retirada_prevista', r.data_prev_retirada, 'data_devolucao_prevista', r.data_prev_devolucao)
    FROM stg_reserva r
    WHERE r.id_cliente IS NULL OR r.id_grupo IS NULL OR r.id_patio_retirada IS NULL OR r.id_patio_devolucao_previsto IS NULL OR r.data_reserva IS NULL OR r.data_prev_retirada IS NULL OR r.data_prev_devolucao IS NULL OR r.data_prev_devolucao <= r.data_prev_retirada;

    INSERT INTO trf_fato_reserva
        (nk_frota_origem, nk_id_reserva, dt_reserva, dt_prev_retirada,
         dt_prev_devolucao, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada,
         nk_id_patio_fim, duracao_prevista_dias, valor_previsto_reserva,
         dd_status_reserva, qtde_reservas)
    SELECT fn_frota_origem(), r.id_reserva,
           r.data_reserva, r.data_prev_retirada, r.data_prev_devolucao,
           r.id_cliente, r.id_grupo, r.id_patio_retirada,
           r.id_patio_devolucao_previsto,
           DATEDIFF(r.data_prev_devolucao, r.data_prev_retirada) AS duracao,
           -- valor previsto = dias previstos * diaria do grupo reservado
           DATEDIFF(r.data_prev_devolucao, r.data_prev_retirada)
               * COALESCE(g.faixa_valor_diaria, 0)            AS valor_previsto,
           fn_txt_norm(r.status_reserva), 1
    FROM   stg_reserva r
    LEFT   JOIN stg_grupo g ON g.id_grupo = r.id_grupo
    ON DUPLICATE KEY UPDATE
        dt_reserva             = VALUES(dt_reserva),
        dt_prev_retirada       = VALUES(dt_prev_retirada),
        dt_prev_devolucao      = VALUES(dt_prev_devolucao),
        nk_id_cliente          = VALUES(nk_id_cliente),
        nk_id_grupo            = VALUES(nk_id_grupo),
        nk_id_patio_retirada   = VALUES(nk_id_patio_retirada),
        nk_id_patio_fim        = VALUES(nk_id_patio_fim),
        duracao_prevista_dias  = VALUES(duracao_prevista_dias),
        valor_previsto_reserva = VALUES(valor_previsto_reserva),
        dd_status_reserva      = VALUES(dd_status_reserva);
END$$

-- ---- 2.4) Fato_Inventario_Patio ---------------------------------------------
CREATE PROCEDURE sp_transforma_inventario()
BEGIN
    INSERT INTO trf_fato_inventario_patio
        (nk_frota_origem, dt_referencia, nk_id_patio, nk_id_veiculo,
         nk_id_grupo, qtde_veiculos_presentes)
    SELECT fn_frota_origem(), i.data_snapshot, i.id_patio, i.id_veiculo,
           i.id_grupo, 1
    FROM   stg_inventario_patio i
    ON DUPLICATE KEY UPDATE
        nk_id_patio             = VALUES(nk_id_patio),
        nk_id_grupo             = VALUES(nk_id_grupo),
        qtde_veiculos_presentes = VALUES(qtde_veiculos_presentes);
END$$

-- ---- 2.5) Orquestrador -------------------------------------------------------
CREATE PROCEDURE sp_transforma_tudo()
BEGIN
    CALL sp_transforma_dimensoes();
    CALL sp_transforma_locacoes();
    CALL sp_transforma_reservas();
    CALL sp_transforma_inventario();
END$$

DELIMITER ;

-- 3) TRANSFORMACAO INCREMENTAL (TRIGGERS sobre o staging cru)
--    Cada vez que a EXTRACAO grava em stg_*, estes triggers conformam a linha
--    e fazem UPSERT em trf_*. Assim o "T" acontece junto do "E", em tempo real.
--    (Mesma logica das procedures, porem linha a linha.)

DROP TRIGGER IF EXISTS trg_trf_cliente_ai;
DROP TRIGGER IF EXISTS trg_trf_cliente_au;
DROP TRIGGER IF EXISTS trg_trf_veiculo_ai;
DROP TRIGGER IF EXISTS trg_trf_veiculo_au;
DROP TRIGGER IF EXISTS trg_trf_grupo_ai;
DROP TRIGGER IF EXISTS trg_trf_grupo_au;
DROP TRIGGER IF EXISTS trg_trf_patio_ai;
DROP TRIGGER IF EXISTS trg_trf_patio_au;
DROP TRIGGER IF EXISTS trg_trf_reserva_ai;
DROP TRIGGER IF EXISTS trg_trf_reserva_au;
DROP TRIGGER IF EXISTS trg_trf_locacao_ai;
DROP TRIGGER IF EXISTS trg_trf_locacao_au;
DROP TRIGGER IF EXISTS trg_trf_inventario_ai;
DROP TRIGGER IF EXISTS trg_trf_inventario_au;

DELIMITER $$

-- ----------------------------- CLIENTE --------------------------------------
-- Conforma o cliente E garante o endereco correspondente na Dim_Endereco.
CREATE TRIGGER trg_trf_cliente_ai
AFTER INSERT ON stg_cliente
FOR EACH ROW
BEGIN
    INSERT IGNORE INTO trf_dim_endereco (cidade, estado, pais)
    VALUES (COALESCE(fn_txt_norm(NEW.cidade), 'NAO INFORMADO'),
            COALESCE(fn_txt_norm(NEW.estado), 'NI'), 'BRASIL');

    INSERT INTO trf_dim_cliente
        (nk_frota_origem, nk_id_cliente, tipo_cliente, nome, cidade, estado, pais)
    VALUES (fn_frota_origem(), NEW.id_cliente, fn_txt_norm(NEW.tipo_cliente),
            TRIM(NEW.nome_razao_social),
            COALESCE(fn_txt_norm(NEW.cidade), 'NAO INFORMADO'),
            COALESCE(fn_txt_norm(NEW.estado), 'NI'), 'BRASIL')
    ON DUPLICATE KEY UPDATE
        tipo_cliente = VALUES(tipo_cliente), nome = VALUES(nome),
        cidade = VALUES(cidade), estado = VALUES(estado), pais = VALUES(pais);
END$$

CREATE TRIGGER trg_trf_cliente_au
AFTER UPDATE ON stg_cliente
FOR EACH ROW
BEGIN
    INSERT IGNORE INTO trf_dim_endereco (cidade, estado, pais)
    VALUES (COALESCE(fn_txt_norm(NEW.cidade), 'NAO INFORMADO'),
            COALESCE(fn_txt_norm(NEW.estado), 'NI'), 'BRASIL');

    INSERT INTO trf_dim_cliente
        (nk_frota_origem, nk_id_cliente, tipo_cliente, nome, cidade, estado, pais)
    VALUES (fn_frota_origem(), NEW.id_cliente, fn_txt_norm(NEW.tipo_cliente),
            TRIM(NEW.nome_razao_social),
            COALESCE(fn_txt_norm(NEW.cidade), 'NAO INFORMADO'),
            COALESCE(fn_txt_norm(NEW.estado), 'NI'), 'BRASIL')
    ON DUPLICATE KEY UPDATE
        tipo_cliente = VALUES(tipo_cliente), nome = VALUES(nome),
        cidade = VALUES(cidade), estado = VALUES(estado), pais = VALUES(pais);
END$$

-- ----------------------------- VEICULO --------------------------------------
CREATE TRIGGER trg_trf_veiculo_ai
AFTER INSERT ON stg_veiculo
FOR EACH ROW
INSERT INTO trf_dim_veiculo
    (nk_frota_origem, nk_id_veiculo, placa, marca, modelo,
     mecanizacao, tem_ar_condicionado)
VALUES (fn_frota_origem(), NEW.id_veiculo, fn_txt_norm(NEW.placa),
        TRIM(NEW.marca), TRIM(NEW.modelo), fn_txt_norm(NEW.mecanizacao),
        NEW.ar_condicionado)
ON DUPLICATE KEY UPDATE
    placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
    mecanizacao = VALUES(mecanizacao),
    tem_ar_condicionado = VALUES(tem_ar_condicionado)$$

CREATE TRIGGER trg_trf_veiculo_au
AFTER UPDATE ON stg_veiculo
FOR EACH ROW
INSERT INTO trf_dim_veiculo
    (nk_frota_origem, nk_id_veiculo, placa, marca, modelo,
     mecanizacao, tem_ar_condicionado)
VALUES (fn_frota_origem(), NEW.id_veiculo, fn_txt_norm(NEW.placa),
        TRIM(NEW.marca), TRIM(NEW.modelo), fn_txt_norm(NEW.mecanizacao),
        NEW.ar_condicionado)
ON DUPLICATE KEY UPDATE
    placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
    mecanizacao = VALUES(mecanizacao),
    tem_ar_condicionado = VALUES(tem_ar_condicionado)$$

-- ----------------------------- GRUPO ----------------------------------------
CREATE TRIGGER trg_trf_grupo_ai
AFTER INSERT ON stg_grupo
FOR EACH ROW
INSERT INTO trf_dim_grupo (nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria)
VALUES (fn_frota_origem(), NEW.id_grupo, TRIM(NEW.nome_grupo), NEW.faixa_valor_diaria)
ON DUPLICATE KEY UPDATE
    nome_grupo = VALUES(nome_grupo), valor_diaria = VALUES(valor_diaria)$$

CREATE TRIGGER trg_trf_grupo_au
AFTER UPDATE ON stg_grupo
FOR EACH ROW
INSERT INTO trf_dim_grupo (nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria)
VALUES (fn_frota_origem(), NEW.id_grupo, TRIM(NEW.nome_grupo), NEW.faixa_valor_diaria)
ON DUPLICATE KEY UPDATE
    nome_grupo = VALUES(nome_grupo), valor_diaria = VALUES(valor_diaria)$$

-- ----------------------------- PATIO ----------------------------------------
CREATE TRIGGER trg_trf_patio_ai
AFTER INSERT ON stg_patio
FOR EACH ROW
INSERT INTO trf_dim_patio (nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas)
VALUES (fn_frota_origem(), NEW.id_patio, TRIM(NEW.nome_patio), NULL)
ON DUPLICATE KEY UPDATE
    nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas)$$

CREATE TRIGGER trg_trf_patio_au
AFTER UPDATE ON stg_patio
FOR EACH ROW
INSERT INTO trf_dim_patio (nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas)
VALUES (fn_frota_origem(), NEW.id_patio, TRIM(NEW.nome_patio), NULL)
ON DUPLICATE KEY UPDATE
    nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas)$$

-- ----------------------------- RESERVA --------------------------------------
-- Calcula duracao e valor previsto (busca a diaria do grupo no staging).
CREATE TRIGGER trg_trf_reserva_ai
AFTER INSERT ON stg_reserva
FOR EACH ROW
BEGIN
IF NEW.id_cliente IS NULL OR NEW.id_grupo IS NULL OR NEW.id_patio_retirada IS NULL OR NEW.id_patio_devolucao_previsto IS NULL OR NEW.data_reserva IS NULL OR NEW.data_prev_retirada IS NULL OR NEW.data_prev_devolucao IS NULL OR NEW.data_prev_devolucao <= NEW.data_prev_retirada THEN
    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json)
    VALUES ('stg_reserva', fn_frota_origem(), NEW.id_reserva,
        CASE
            WHEN NEW.id_cliente IS NULL            THEN 'Reserva sem cliente'
            WHEN NEW.id_grupo IS NULL              THEN 'Reserva sem grupo'
            WHEN NEW.id_patio_retirada IS NULL     THEN 'Reserva sem pátio de retirada'
            WHEN NEW.id_patio_devolucao_previsto IS NULL THEN 'Reserva sem pátio de fim'
            WHEN NEW.data_reserva IS NULL             THEN 'Reserva sem data de reserva'
            WHEN NEW.data_prev_retirada IS NULL   THEN 'Reserva sem data de retirada prevista'
            WHEN NEW.data_prev_devolucao IS NULL  THEN 'Reserva sem data de devolução prevista'
            WHEN NEW.data_prev_devolucao <= NEW.data_prev_retirada THEN 'Data devolução <= data retirada'
            ELSE 'Erro desconhecido'
        END,
        JSON_OBJECT('nk_id_reserva', NEW.id_reserva, 'nk_id_cliente', NEW.id_cliente, 'nk_id_grupo', NEW.id_grupo, 'nk_id_patio_retirada', NEW.id_patio_retirada, 'nk_id_patio_fim', NEW.id_patio_devolucao_previsto, 'data_reserva', NEW.data_reserva, 'data_retirada_prevista', NEW.data_prev_retirada, 'data_devolucao_prevista', NEW.data_prev_devolucao)
    );
ELSE
    INSERT INTO trf_fato_reserva
        (nk_frota_origem, nk_id_reserva, dt_reserva, dt_prev_retirada,
         dt_prev_devolucao, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada,
     nk_id_patio_fim, duracao_prevista_dias, valor_previsto_reserva,
     dd_status_reserva, qtde_reservas)
VALUES (fn_frota_origem(), NEW.id_reserva, NEW.data_reserva, NEW.data_prev_retirada,
        NEW.data_prev_devolucao, NEW.id_cliente, NEW.id_grupo, NEW.id_patio_retirada,
        NEW.id_patio_devolucao_previsto,
        DATEDIFF(NEW.data_prev_devolucao, NEW.data_prev_retirada),
        DATEDIFF(NEW.data_prev_devolucao, NEW.data_prev_retirada)
            * COALESCE((SELECT g.faixa_valor_diaria FROM stg_grupo g
                        WHERE g.id_grupo = NEW.id_grupo), 0),
        fn_txt_norm(NEW.status_reserva), 1)
ON DUPLICATE KEY UPDATE
    dt_reserva = VALUES(dt_reserva), dt_prev_retirada = VALUES(dt_prev_retirada),
    dt_prev_devolucao = VALUES(dt_prev_devolucao), nk_id_cliente = VALUES(nk_id_cliente),
    nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_retirada = VALUES(nk_id_patio_retirada),
    nk_id_patio_fim = VALUES(nk_id_patio_fim),
    duracao_prevista_dias = VALUES(duracao_prevista_dias),
    valor_previsto_reserva = VALUES(valor_previsto_reserva),
    dd_status_reserva = VALUES(dd_status_reserva);
END IF;
END$$

CREATE TRIGGER trg_trf_reserva_au
AFTER UPDATE ON stg_reserva
FOR EACH ROW
BEGIN
IF NEW.id_cliente IS NOT NULL AND NEW.id_grupo IS NOT NULL AND NEW.id_patio_retirada IS NOT NULL AND NEW.id_patio_devolucao_previsto IS NOT NULL AND NEW.data_reserva IS NOT NULL AND NEW.data_prev_retirada IS NOT NULL AND NEW.data_prev_devolucao IS NOT NULL AND NEW.data_prev_devolucao > NEW.data_prev_retirada THEN
    INSERT INTO trf_fato_reserva
        (nk_frota_origem, nk_id_reserva, dt_reserva, dt_prev_retirada,
         dt_prev_devolucao, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada,
     nk_id_patio_fim, duracao_prevista_dias, valor_previsto_reserva,
     dd_status_reserva, qtde_reservas)
VALUES (fn_frota_origem(), NEW.id_reserva, NEW.data_reserva, NEW.data_prev_retirada,
        NEW.data_prev_devolucao, NEW.id_cliente, NEW.id_grupo, NEW.id_patio_retirada,
        NEW.id_patio_devolucao_previsto,
        DATEDIFF(NEW.data_prev_devolucao, NEW.data_prev_retirada),
        DATEDIFF(NEW.data_prev_devolucao, NEW.data_prev_retirada)
            * COALESCE((SELECT g.faixa_valor_diaria FROM stg_grupo g
                        WHERE g.id_grupo = NEW.id_grupo), 0),
        fn_txt_norm(NEW.status_reserva), 1)
ON DUPLICATE KEY UPDATE
    dt_reserva = VALUES(dt_reserva), dt_prev_retirada = VALUES(dt_prev_retirada),
    dt_prev_devolucao = VALUES(dt_prev_devolucao), nk_id_cliente = VALUES(nk_id_cliente),
    nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_retirada = VALUES(nk_id_patio_retirada),
    nk_id_patio_fim = VALUES(nk_id_patio_fim),
    duracao_prevista_dias = VALUES(duracao_prevista_dias),
    valor_previsto_reserva = VALUES(valor_previsto_reserva),
    dd_status_reserva = VALUES(dd_status_reserva);
END IF;
END$$

-- ----------------------------- LOCACAO --------------------------------------
-- INSERT  = nova locacao; UPDATE = devolucao (preenche datas/patio/valor reais).
CREATE TRIGGER trg_trf_locacao_ai
AFTER INSERT ON stg_locacao
FOR EACH ROW
BEGIN
IF NEW.id_cliente IS NULL OR NEW.id_veiculo IS NULL OR NEW.id_grupo IS NULL OR NEW.id_patio_retirada IS NULL OR NEW.data_hora_retirada IS NULL OR NEW.data_hora_prev_devolucao IS NULL OR (NEW.data_hora_real_devolucao IS NOT NULL AND DATE(NEW.data_hora_real_devolucao) < DATE(NEW.data_hora_retirada)) THEN
    INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json)
    VALUES ('stg_locacao', fn_frota_origem(), NEW.id_locacao,
        CASE
            WHEN NEW.id_cliente IS NULL         THEN 'Locação sem cliente'
            WHEN NEW.id_veiculo IS NULL         THEN 'Locação sem veículo'
            WHEN NEW.id_grupo IS NULL           THEN 'Locação sem grupo'
            WHEN NEW.id_patio_retirada IS NULL  THEN 'Locação sem pátio de retirada'
            WHEN NEW.data_hora_retirada IS NULL THEN 'Locação sem data de retirada'
            WHEN NEW.data_hora_prev_devolucao IS NULL THEN 'Locação sem data prev. devolução'
            WHEN NEW.data_hora_real_devolucao IS NOT NULL AND DATE(NEW.data_hora_real_devolucao) < DATE(NEW.data_hora_retirada) THEN 'Data devolução real anterior à retirada'
            ELSE 'Erro desconhecido'
        END,
        JSON_OBJECT('nk_id_locacao', NEW.id_locacao, 'nk_id_cliente', NEW.id_cliente, 'nk_id_veiculo', NEW.id_veiculo, 'nk_id_grupo', NEW.id_grupo, 'nk_id_patio_retirada', NEW.id_patio_retirada, 'data_retirada', NEW.data_hora_retirada, 'data_prev_devolucao', NEW.data_hora_prev_devolucao, 'data_real_devolucao', NEW.data_hora_real_devolucao, 'valor_final', NEW.valor_final)
    );
ELSE
    INSERT INTO trf_fato_locacao
        (nk_frota_origem, nk_id_locacao, dt_retirada, dt_prev_devolucao,
         dt_real_devolucao, nk_id_cliente, nk_id_veiculo, nk_id_grupo,
         nk_id_patio_retirada, nk_id_patio_devol_real, valor_final, qtde_locacoes)
VALUES (fn_frota_origem(), NEW.id_locacao, DATE(NEW.data_hora_retirada),
        DATE(NEW.data_hora_prev_devolucao), DATE(NEW.data_hora_real_devolucao),
        NEW.id_cliente, NEW.id_veiculo, NEW.id_grupo, NEW.id_patio_retirada,
        NEW.id_patio_devolucao_real, NEW.valor_final, 1)
ON DUPLICATE KEY UPDATE
    dt_retirada = VALUES(dt_retirada), dt_prev_devolucao = VALUES(dt_prev_devolucao),
    dt_real_devolucao = VALUES(dt_real_devolucao), nk_id_cliente = VALUES(nk_id_cliente),
    nk_id_veiculo = VALUES(nk_id_veiculo), nk_id_grupo = VALUES(nk_id_grupo),
    nk_id_patio_devol_real = VALUES(nk_id_patio_devol_real),
    valor_final = VALUES(valor_final);
END IF;
END$$

CREATE TRIGGER trg_trf_locacao_au
AFTER UPDATE ON stg_locacao
FOR EACH ROW
BEGIN
IF NEW.id_cliente IS NOT NULL AND NEW.id_veiculo IS NOT NULL AND NEW.id_grupo IS NOT NULL AND NEW.id_patio_retirada IS NOT NULL AND NEW.data_hora_retirada IS NOT NULL AND NEW.data_hora_prev_devolucao IS NOT NULL AND (NEW.data_hora_real_devolucao IS NULL OR DATE(NEW.data_hora_real_devolucao) >= DATE(NEW.data_hora_retirada)) THEN
    INSERT INTO trf_fato_locacao
        (nk_frota_origem, nk_id_locacao, dt_retirada, dt_prev_devolucao,
         dt_real_devolucao, nk_id_cliente, nk_id_veiculo, nk_id_grupo,
         nk_id_patio_retirada, nk_id_patio_devol_real, valor_final, qtde_locacoes)
VALUES (fn_frota_origem(), NEW.id_locacao, DATE(NEW.data_hora_retirada),
        DATE(NEW.data_hora_prev_devolucao), DATE(NEW.data_hora_real_devolucao),
        NEW.id_cliente, NEW.id_veiculo, NEW.id_grupo, NEW.id_patio_retirada,
        NEW.id_patio_devolucao_real, NEW.valor_final, 1)
ON DUPLICATE KEY UPDATE
    dt_retirada = VALUES(dt_retirada), dt_prev_devolucao = VALUES(dt_prev_devolucao),
    dt_real_devolucao = VALUES(dt_real_devolucao), nk_id_cliente = VALUES(nk_id_cliente),
    nk_id_veiculo = VALUES(nk_id_veiculo), nk_id_grupo = VALUES(nk_id_grupo),
    nk_id_patio_devol_real = VALUES(nk_id_patio_devol_real),
    valor_final = VALUES(valor_final);
END IF;
END$$

-- --------------------------- INVENTARIO -------------------------------------
CREATE TRIGGER trg_trf_inventario_ai
AFTER INSERT ON stg_inventario_patio
FOR EACH ROW
INSERT INTO trf_fato_inventario_patio
    (nk_frota_origem, dt_referencia, nk_id_patio, nk_id_veiculo,
     nk_id_grupo, qtde_veiculos_presentes)
VALUES (fn_frota_origem(), NEW.data_snapshot, NEW.id_patio, NEW.id_veiculo,
        NEW.id_grupo, 1)
ON DUPLICATE KEY UPDATE
    nk_id_patio = VALUES(nk_id_patio), nk_id_grupo = VALUES(nk_id_grupo),
    qtde_veiculos_presentes = VALUES(qtde_veiculos_presentes)$$

CREATE TRIGGER trg_trf_inventario_au
AFTER UPDATE ON stg_inventario_patio
FOR EACH ROW
INSERT INTO trf_fato_inventario_patio
    (nk_frota_origem, dt_referencia, nk_id_patio, nk_id_veiculo,
     nk_id_grupo, qtde_veiculos_presentes)
VALUES (fn_frota_origem(), NEW.data_snapshot, NEW.id_patio, NEW.id_veiculo,
        NEW.id_grupo, 1)
ON DUPLICATE KEY UPDATE
    nk_id_patio = VALUES(nk_id_patio), nk_id_grupo = VALUES(nk_id_grupo),
    qtde_veiculos_presentes = VALUES(qtde_veiculos_presentes)$$

DELIMITER ;


-- 4) TRANSFORMACAO INICIAL EM LOTE (executar uma vez, apos a carga inicial do
--    script 01). Depois disso, os TRIGGERS acima mantem trf_* atualizado.
CALL sp_transforma_tudo();

