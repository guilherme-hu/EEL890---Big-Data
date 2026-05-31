-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)
-- ----------------------------------------------------------------------------
-- Arquivo : 03_carga_NOVOOK.sql
-- Etapa   : CARGA  (o "L"/Load do ETL)
-- Entrada : Area de STAGING conformada (dw_staging.trf_*) -- gerada pelo script 02
-- Saida   : DATA WAREHOUSE estrela (schema dw_locadora) -- dim_* e fato_*
-- SGBD    : MySQL 8.x
--
-- O que esta etapa faz:
--   1. Garante a existencia do ESQUEMA ESTRELA (CREATE TABLE IF NOT EXISTS) tal
--      como descrito no "Modelo dw". (Se o esquema ja existir, nada e refeito.)
--   2. Popula a Dim_Tempo (pre-populada + datas referenciadas pelos fatos).
--   3. Carrega as DIMENSOES gerando/atualizando as Surrogate Keys (SK):
--        - faz UPSERT pela Chave Natural (nk_frota_origem + nk_id_*);
--        - resolve sk_endereco do cliente por JOIN na Dim_Endereco.
--   4. Carrega os FATOS resolvendo TODAS as SKs por JOIN nas dimensoes.
--
-- Decisao de projeto sobre a Dim_Tempo:
--   sk_tempo usa o formato YYYYMMDD (ex.: 2026-05-31 -> 20260531). Preferimos
--   YYYYMMDD a DDMMYYYY porque YYYYMMDD e crescente no tempo (ordenavel), que e
--   o padrao para "smart keys" de dimensao tempo. A coluna "data" guarda a DATE
--   real; a apresentacao DD/MM/AAAA fica a cargo dos relatorios.
--
-- OBS: A carga e IDEMPOTENTE (INSERT ... ON DUPLICATE KEY UPDATE). Pode rodar
--      varias vezes; linhas existentes sao atualizadas, nao duplicadas.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS dw_locadora
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE dw_locadora;

-- ============================================================================
-- 1) ESQUEMA ESTRELA (cria apenas se ainda nao existir)
--    Dimensoes primeiro; fatos por ultimo (por causa das FKs).
-- ============================================================================

-- ---- Dim_Endereco -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_endereco (
    sk_endereco INT AUTO_INCREMENT PRIMARY KEY,
    cidade      VARCHAR(100) NOT NULL,
    estado      VARCHAR(100) NOT NULL,
    pais        VARCHAR(100) NOT NULL,
    CONSTRAINT uq_endereco UNIQUE (cidade, estado, pais)
) ENGINE=InnoDB;

-- ---- Dim_Cliente ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_cliente (
    sk_cliente      INT AUTO_INCREMENT PRIMARY KEY,
    nk_frota_origem VARCHAR(100) NOT NULL,   -- GOAT / IA / AMARELO / NOVOOK
    nk_id_cliente   INT          NOT NULL,   -- id no sistema de origem
    tipo_cliente    VARCHAR(2),              -- PF / PJ
    nome            VARCHAR(150),
    sk_endereco     INT,
    CONSTRAINT uq_cliente_nk UNIQUE (nk_frota_origem, nk_id_cliente),
    CONSTRAINT fk_cliente_endereco FOREIGN KEY (sk_endereco)
        REFERENCES dim_endereco (sk_endereco)
) ENGINE=InnoDB;

-- ---- Dim_Veiculo ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_veiculo (
    sk_veiculo          INT AUTO_INCREMENT PRIMARY KEY,
    nk_frota_origem     VARCHAR(100) NOT NULL,
    nk_id_veiculo       INT          NOT NULL,
    placa               VARCHAR(10),
    marca               VARCHAR(50),
    modelo              VARCHAR(50),
    mecanizacao         VARCHAR(20),
    tem_ar_condicionado BOOLEAN,
    CONSTRAINT uq_veiculo_nk UNIQUE (nk_frota_origem, nk_id_veiculo)
) ENGINE=InnoDB;

-- ---- Dim_Grupo --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_grupo (
    sk_grupo        INT AUTO_INCREMENT PRIMARY KEY,
    nk_frota_origem VARCHAR(100)  NOT NULL,
    nk_id_grupo     INT           NOT NULL,
    nome_grupo      VARCHAR(50),
    valor_diaria    DECIMAL(10,2),
    CONSTRAINT uq_grupo_nk UNIQUE (nk_frota_origem, nk_id_grupo)
) ENGINE=InnoDB;

-- ---- Dim_Patio --------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_patio (
    sk_patio         INT AUTO_INCREMENT PRIMARY KEY,
    nk_frota_origem  VARCHAR(100) NOT NULL,
    nk_id_patio      INT          NOT NULL,
    nome_patio       VARCHAR(100),
    capacidade_vagas INT,                    -- pode ser NULL (fonte sem o dado)
    CONSTRAINT uq_patio_nk UNIQUE (nk_frota_origem, nk_id_patio)
) ENGINE=InnoDB;

-- ---- Dim_Tempo (sk_tempo = YYYYMMDD) ----------------------------------------
-- Atributos extras (ano/mes/dia/trimestre/nome_mes/dia_semana/fim_de_semana)
-- foram incluidos para apoiar os relatorios gerenciais por periodo.
CREATE TABLE IF NOT EXISTS dim_tempo (
    sk_tempo          INT  PRIMARY KEY,       -- ex.: 20260531
    data              DATE NOT NULL,
    ano               INT,
    mes               INT,
    dia               INT,
    trimestre         INT,
    nome_mes          VARCHAR(15),
    dia_semana        VARCHAR(15),
    eh_fim_de_semana  BOOLEAN,
    CONSTRAINT uq_tempo_data UNIQUE (data)
) ENGINE=InnoDB;

-- ---- Fato_Inventario_Patio (grao: 1 veiculo presente por dia) ---------------
CREATE TABLE IF NOT EXISTS fato_inventario_patio (
    sk_fato_inventario      INT AUTO_INCREMENT PRIMARY KEY,
    sk_tempo_referencia     INT NOT NULL,
    sk_patio                INT NOT NULL,
    sk_veiculo              INT NOT NULL,
    sk_grupo                INT,
    qtde_veiculos_presentes INT NOT NULL DEFAULT 1,
    CONSTRAINT uq_inv UNIQUE (sk_tempo_referencia, sk_veiculo),
    CONSTRAINT fk_inv_tempo   FOREIGN KEY (sk_tempo_referencia) REFERENCES dim_tempo (sk_tempo),
    CONSTRAINT fk_inv_patio   FOREIGN KEY (sk_patio)   REFERENCES dim_patio (sk_patio),
    CONSTRAINT fk_inv_veiculo FOREIGN KEY (sk_veiculo) REFERENCES dim_veiculo (sk_veiculo),
    CONSTRAINT fk_inv_grupo   FOREIGN KEY (sk_grupo)   REFERENCES dim_grupo (sk_grupo)
) ENGINE=InnoDB;

-- ---- Fato_Locacao (grao: 1 contrato de locacao) -----------------------------
CREATE TABLE IF NOT EXISTS fato_locacao (
    sk_fato_locacao         INT AUTO_INCREMENT PRIMARY KEY,
    nk_frota_origem         VARCHAR(100) NOT NULL,  -- compoe a NK do fato
    nk_id_locacao           INT          NOT NULL,
    sk_tempo_retirada       INT NOT NULL,
    sk_tempo_prev_devolucao INT,
    sk_tempo_real_devolucao INT,                    -- NULL se nao devolvido
    sk_cliente              INT,
    sk_veiculo              INT,
    sk_grupo                INT,
    sk_patio_retirada       INT,
    sk_patio_devolucao_real INT,                    -- NULL se nao devolvido
    valor_final             DECIMAL(10,2),          -- NULL ate a devolucao
    qtde_locacoes           INT NOT NULL DEFAULT 1,
    CONSTRAINT uq_locacao_nk UNIQUE (nk_frota_origem, nk_id_locacao),
    CONSTRAINT fk_loc_tempo_ret   FOREIGN KEY (sk_tempo_retirada)       REFERENCES dim_tempo (sk_tempo),
    CONSTRAINT fk_loc_tempo_prev  FOREIGN KEY (sk_tempo_prev_devolucao) REFERENCES dim_tempo (sk_tempo),
    CONSTRAINT fk_loc_tempo_real  FOREIGN KEY (sk_tempo_real_devolucao) REFERENCES dim_tempo (sk_tempo),
    CONSTRAINT fk_loc_cliente     FOREIGN KEY (sk_cliente)              REFERENCES dim_cliente (sk_cliente),
    CONSTRAINT fk_loc_veiculo     FOREIGN KEY (sk_veiculo)              REFERENCES dim_veiculo (sk_veiculo),
    CONSTRAINT fk_loc_grupo       FOREIGN KEY (sk_grupo)                REFERENCES dim_grupo (sk_grupo),
    CONSTRAINT fk_loc_patio_ret   FOREIGN KEY (sk_patio_retirada)       REFERENCES dim_patio (sk_patio),
    CONSTRAINT fk_loc_patio_dev   FOREIGN KEY (sk_patio_devolucao_real) REFERENCES dim_patio (sk_patio)
) ENGINE=InnoDB;

-- ---- Fato_Reserva (grao: 1 intencao de reserva) -----------------------------
CREATE TABLE IF NOT EXISTS fato_reserva (
    sk_fato_reserva         INT AUTO_INCREMENT PRIMARY KEY,
    nk_frota_origem         VARCHAR(100) NOT NULL,
    nk_id_reserva           INT          NOT NULL,
    sk_tempo_reserva        INT,
    sk_tempo_prev_retirada  INT,
    sk_tempo_prev_devolucao INT,
    sk_cliente              INT,
    sk_grupo                INT,
    sk_patio_retirada       INT,
    sk_patio_fim            INT,
    duracao_prevista_dias   INT,
    valor_previsto_reserva  DECIMAL(10,2),
    dd_status_reserva       VARCHAR(100),           -- dimensao degenerada
    qtde_reservas           INT NOT NULL DEFAULT 1,
    CONSTRAINT uq_reserva_nk UNIQUE (nk_frota_origem, nk_id_reserva),
    CONSTRAINT fk_res_tempo_res   FOREIGN KEY (sk_tempo_reserva)        REFERENCES dim_tempo (sk_tempo),
    CONSTRAINT fk_res_tempo_ret   FOREIGN KEY (sk_tempo_prev_retirada)  REFERENCES dim_tempo (sk_tempo),
    CONSTRAINT fk_res_tempo_dev   FOREIGN KEY (sk_tempo_prev_devolucao) REFERENCES dim_tempo (sk_tempo),
    CONSTRAINT fk_res_cliente     FOREIGN KEY (sk_cliente)              REFERENCES dim_cliente (sk_cliente),
    CONSTRAINT fk_res_grupo       FOREIGN KEY (sk_grupo)                REFERENCES dim_grupo (sk_grupo),
    CONSTRAINT fk_res_patio_ret   FOREIGN KEY (sk_patio_retirada)       REFERENCES dim_patio (sk_patio),
    CONSTRAINT fk_res_patio_fim   FOREIGN KEY (sk_patio_fim)            REFERENCES dim_patio (sk_patio)
) ENGINE=InnoDB;

-- ============================================================================
-- 2) FUNCAO AUXILIAR: data -> sk_tempo (YYYYMMDD)
-- ============================================================================
DROP FUNCTION IF EXISTS fn_sk_tempo;
DELIMITER $$
CREATE FUNCTION fn_sk_tempo(d DATE) RETURNS INT
DETERMINISTIC NO SQL
RETURN IF(d IS NULL, NULL, YEAR(d) * 10000 + MONTH(d) * 100 + DAY(d))$$
DELIMITER ;

-- ============================================================================
-- 3) PROCEDURES DE CARGA
-- ============================================================================
DROP PROCEDURE IF EXISTS sp_popula_dim_tempo;
DROP PROCEDURE IF EXISTS sp_garante_datas_dim_tempo;
DROP PROCEDURE IF EXISTS sp_carga_dimensoes;
DROP PROCEDURE IF EXISTS sp_carga_fatos;
DROP PROCEDURE IF EXISTS sp_carga_tudo;

DELIMITER $$

-- ---- 3.1) Pre-popula a Dim_Tempo em um intervalo de datas --------------------
CREATE PROCEDURE sp_popula_dim_tempo(IN p_ini DATE, IN p_fim DATE)
BEGIN
    DECLARE d DATE;
    SET d = p_ini;
    WHILE d <= p_fim DO
        INSERT IGNORE INTO dim_tempo
            (sk_tempo, data, ano, mes, dia, trimestre, nome_mes, dia_semana, eh_fim_de_semana)
        VALUES (
            fn_sk_tempo(d), d, YEAR(d), MONTH(d), DAY(d), QUARTER(d),
            ELT(MONTH(d), 'JANEIRO','FEVEREIRO','MARCO','ABRIL','MAIO','JUNHO',
                          'JULHO','AGOSTO','SETEMBRO','OUTUBRO','NOVEMBRO','DEZEMBRO'),
            ELT(DAYOFWEEK(d), 'DOMINGO','SEGUNDA','TERCA','QUARTA','QUINTA','SEXTA','SABADO'),
            IF(DAYOFWEEK(d) IN (1, 7), 1, 0)
        );
        SET d = d + INTERVAL 1 DAY;
    END WHILE;
END$$

-- ---- 3.2) Garante na Dim_Tempo TODA data referenciada pelos fatos -----------
-- (rede de seguranca para datas fora do intervalo pre-populado)
CREATE PROCEDURE sp_garante_datas_dim_tempo()
BEGIN
    INSERT IGNORE INTO dim_tempo
        (sk_tempo, data, ano, mes, dia, trimestre, nome_mes, dia_semana, eh_fim_de_semana)
    SELECT fn_sk_tempo(x.d), x.d, YEAR(x.d), MONTH(x.d), DAY(x.d), QUARTER(x.d),
           ELT(MONTH(x.d), 'JANEIRO','FEVEREIRO','MARCO','ABRIL','MAIO','JUNHO',
                           'JULHO','AGOSTO','SETEMBRO','OUTUBRO','NOVEMBRO','DEZEMBRO'),
           ELT(DAYOFWEEK(x.d), 'DOMINGO','SEGUNDA','TERCA','QUARTA','QUINTA','SEXTA','SABADO'),
           IF(DAYOFWEEK(x.d) IN (1, 7), 1, 0)
    FROM (
        SELECT dt_retirada       AS d FROM dw_staging.trf_fato_locacao
        UNION SELECT dt_prev_devolucao   FROM dw_staging.trf_fato_locacao
        UNION SELECT dt_real_devolucao   FROM dw_staging.trf_fato_locacao
        UNION SELECT dt_reserva          FROM dw_staging.trf_fato_reserva
        UNION SELECT dt_prev_retirada    FROM dw_staging.trf_fato_reserva
        UNION SELECT dt_prev_devolucao   FROM dw_staging.trf_fato_reserva
        UNION SELECT dt_referencia       FROM dw_staging.trf_fato_inventario_patio
    ) x
    WHERE x.d IS NOT NULL;
END$$

-- ---- 3.3) Carga das DIMENSOES (gera/atualiza SKs por UPSERT na NK) ----------
CREATE PROCEDURE sp_carga_dimensoes()
BEGIN
    -- Dim_Endereco (sem NK de origem; a chave e o proprio trio cidade/estado/pais)
    INSERT IGNORE INTO dim_endereco (cidade, estado, pais)
    SELECT cidade, estado, pais FROM dw_staging.trf_dim_endereco;

    -- Dim_Cliente: resolve sk_endereco por JOIN na Dim_Endereco ja carregada
    INSERT INTO dim_cliente (nk_frota_origem, nk_id_cliente, tipo_cliente, nome, sk_endereco)
    SELECT t.nk_frota_origem, t.nk_id_cliente, t.tipo_cliente, t.nome, e.sk_endereco
    FROM   dw_staging.trf_dim_cliente t
    JOIN   dim_endereco e
           ON e.cidade = t.cidade AND e.estado = t.estado AND e.pais = t.pais
    ON DUPLICATE KEY UPDATE
        tipo_cliente = VALUES(tipo_cliente),
        nome         = VALUES(nome),
        sk_endereco  = VALUES(sk_endereco);

    -- Dim_Veiculo
    INSERT INTO dim_veiculo
        (nk_frota_origem, nk_id_veiculo, placa, marca, modelo, mecanizacao, tem_ar_condicionado)
    SELECT nk_frota_origem, nk_id_veiculo, placa, marca, modelo, mecanizacao, tem_ar_condicionado
    FROM   dw_staging.trf_dim_veiculo
    ON DUPLICATE KEY UPDATE
        placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
        mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado);

    -- Dim_Grupo
    INSERT INTO dim_grupo (nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria)
    SELECT nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria
    FROM   dw_staging.trf_dim_grupo
    ON DUPLICATE KEY UPDATE
        nome_grupo = VALUES(nome_grupo), valor_diaria = VALUES(valor_diaria);

    -- Dim_Patio
    INSERT INTO dim_patio (nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas)
    SELECT nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas
    FROM   dw_staging.trf_dim_patio
    ON DUPLICATE KEY UPDATE
        nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas);
END$$

-- ---- 3.4) Carga dos FATOS (resolve todas as SKs por JOIN nas dimensoes) -----
CREATE PROCEDURE sp_carga_fatos()
BEGIN
    -- ---------------------- Fato_Locacao -----------------------------------
    -- INNER JOIN nas dimensoes obrigatorias (cliente/veiculo/grupo/patio_ret):
    -- se alguma SK nao resolver (problema de qualidade de dado), a linha e
    -- descartada em vez de quebrar a carga. Devolucao usa LEFT JOIN (pode ser
    -- NULL enquanto o carro nao volta).
    INSERT INTO fato_locacao
        (nk_frota_origem, nk_id_locacao, sk_tempo_retirada, sk_tempo_prev_devolucao,
         sk_tempo_real_devolucao, sk_cliente, sk_veiculo, sk_grupo, sk_patio_retirada,
         sk_patio_devolucao_real, valor_final, qtde_locacoes)
    SELECT f.nk_frota_origem, f.nk_id_locacao,
           fn_sk_tempo(f.dt_retirada), fn_sk_tempo(f.dt_prev_devolucao),
           fn_sk_tempo(f.dt_real_devolucao),
           dc.sk_cliente, dv.sk_veiculo, dg.sk_grupo, dpr.sk_patio,
           dpd.sk_patio, f.valor_final, 1
    FROM   dw_staging.trf_fato_locacao f
    JOIN   dim_cliente dc ON dc.nk_frota_origem = f.nk_frota_origem AND dc.nk_id_cliente = f.nk_id_cliente
    JOIN   dim_veiculo dv ON dv.nk_frota_origem = f.nk_frota_origem AND dv.nk_id_veiculo = f.nk_id_veiculo
    JOIN   dim_grupo   dg ON dg.nk_frota_origem = f.nk_frota_origem AND dg.nk_id_grupo   = f.nk_id_grupo
    JOIN   dim_patio  dpr ON dpr.nk_frota_origem = f.nk_frota_origem AND dpr.nk_id_patio = f.nk_id_patio_retirada
    LEFT   JOIN dim_patio dpd ON dpd.nk_frota_origem = f.nk_frota_origem AND dpd.nk_id_patio = f.nk_id_patio_devol_real
    ON DUPLICATE KEY UPDATE
        sk_tempo_retirada       = VALUES(sk_tempo_retirada),
        sk_tempo_prev_devolucao = VALUES(sk_tempo_prev_devolucao),
        sk_tempo_real_devolucao = VALUES(sk_tempo_real_devolucao),
        sk_cliente              = VALUES(sk_cliente),
        sk_veiculo              = VALUES(sk_veiculo),
        sk_grupo                = VALUES(sk_grupo),
        sk_patio_retirada       = VALUES(sk_patio_retirada),
        sk_patio_devolucao_real = VALUES(sk_patio_devolucao_real),
        valor_final             = VALUES(valor_final);

    -- ---------------------- Fato_Reserva -----------------------------------
    INSERT INTO fato_reserva
        (nk_frota_origem, nk_id_reserva, sk_tempo_reserva, sk_tempo_prev_retirada,
         sk_tempo_prev_devolucao, sk_cliente, sk_grupo, sk_patio_retirada, sk_patio_fim,
         duracao_prevista_dias, valor_previsto_reserva, dd_status_reserva, qtde_reservas)
    SELECT f.nk_frota_origem, f.nk_id_reserva,
           fn_sk_tempo(f.dt_reserva), fn_sk_tempo(f.dt_prev_retirada),
           fn_sk_tempo(f.dt_prev_devolucao),
           dc.sk_cliente, dg.sk_grupo, dpr.sk_patio, dpf.sk_patio,
           f.duracao_prevista_dias, f.valor_previsto_reserva, f.dd_status_reserva, 1
    FROM   dw_staging.trf_fato_reserva f
    JOIN   dim_cliente dc ON dc.nk_frota_origem = f.nk_frota_origem AND dc.nk_id_cliente = f.nk_id_cliente
    JOIN   dim_grupo   dg ON dg.nk_frota_origem = f.nk_frota_origem AND dg.nk_id_grupo   = f.nk_id_grupo
    JOIN   dim_patio  dpr ON dpr.nk_frota_origem = f.nk_frota_origem AND dpr.nk_id_patio = f.nk_id_patio_retirada
    JOIN   dim_patio  dpf ON dpf.nk_frota_origem = f.nk_frota_origem AND dpf.nk_id_patio = f.nk_id_patio_fim
    ON DUPLICATE KEY UPDATE
        sk_tempo_reserva        = VALUES(sk_tempo_reserva),
        sk_tempo_prev_retirada  = VALUES(sk_tempo_prev_retirada),
        sk_tempo_prev_devolucao = VALUES(sk_tempo_prev_devolucao),
        sk_cliente              = VALUES(sk_cliente),
        sk_grupo                = VALUES(sk_grupo),
        sk_patio_retirada       = VALUES(sk_patio_retirada),
        sk_patio_fim            = VALUES(sk_patio_fim),
        duracao_prevista_dias   = VALUES(duracao_prevista_dias),
        valor_previsto_reserva  = VALUES(valor_previsto_reserva),
        dd_status_reserva       = VALUES(dd_status_reserva);

    -- ------------------- Fato_Inventario_Patio -----------------------------
    INSERT INTO fato_inventario_patio
        (sk_tempo_referencia, sk_patio, sk_veiculo, sk_grupo, qtde_veiculos_presentes)
    SELECT fn_sk_tempo(f.dt_referencia), dp.sk_patio, dv.sk_veiculo, dg.sk_grupo, 1
    FROM   dw_staging.trf_fato_inventario_patio f
    JOIN   dim_patio   dp ON dp.nk_frota_origem = f.nk_frota_origem AND dp.nk_id_patio   = f.nk_id_patio
    JOIN   dim_veiculo dv ON dv.nk_frota_origem = f.nk_frota_origem AND dv.nk_id_veiculo = f.nk_id_veiculo
    LEFT   JOIN dim_grupo dg ON dg.nk_frota_origem = f.nk_frota_origem AND dg.nk_id_grupo = f.nk_id_grupo
    ON DUPLICATE KEY UPDATE
        sk_patio                = VALUES(sk_patio),
        sk_grupo                = VALUES(sk_grupo),
        qtde_veiculos_presentes = VALUES(qtde_veiculos_presentes);
END$$

-- ---- 3.5) Orquestrador da carga completa ------------------------------------
CREATE PROCEDURE sp_carga_tudo()
BEGIN
    -- (1) Dim_Tempo pre-populada (ajuste o intervalo conforme seus dados)
    CALL sp_popula_dim_tempo('2023-01-01', '2027-12-31');
    -- (2) Garante quaisquer datas extras referenciadas pelos fatos
    CALL sp_garante_datas_dim_tempo();
    -- (3) Dimensoes antes (precisam existir para os fatos resolverem as SKs)
    CALL sp_carga_dimensoes();
    -- (4) Fatos
    CALL sp_carga_fatos();
END$$

DELIMITER ;

-- ============================================================================
-- 4) EXECUCAO DA CARGA
-- ============================================================================
CALL sp_carga_tudo();

-- ----------------------------------------------------------------------------
-- 5) CONFERENCIA RAPIDA (opcional) - descomente para validar a carga
-- ----------------------------------------------------------------------------
-- SELECT 'dim_endereco' tabela, COUNT(*) linhas FROM dim_endereco
-- UNION ALL SELECT 'dim_cliente',  COUNT(*) FROM dim_cliente
-- UNION ALL SELECT 'dim_veiculo',  COUNT(*) FROM dim_veiculo
-- UNION ALL SELECT 'dim_grupo',    COUNT(*) FROM dim_grupo
-- UNION ALL SELECT 'dim_patio',    COUNT(*) FROM dim_patio
-- UNION ALL SELECT 'dim_tempo',    COUNT(*) FROM dim_tempo
-- UNION ALL SELECT 'fato_locacao', COUNT(*) FROM fato_locacao
-- UNION ALL SELECT 'fato_reserva', COUNT(*) FROM fato_reserva
-- UNION ALL SELECT 'fato_inventario_patio', COUNT(*) FROM fato_inventario_patio;

-- FIM DO SCRIPT DE CARGA (NOVOOK)
