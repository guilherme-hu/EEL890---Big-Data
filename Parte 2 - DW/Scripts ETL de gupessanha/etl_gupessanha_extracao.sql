-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)

-- =====================================================================
--  EXTRAÇÃO ETL — Frota "gupessanha" (OLTP da IA)
--  Fonte: schema CANÔNICO (simples) da IA — locadora.{patio, grupo,
--  veiculo, cliente, cliente_pf, cliente_pj, reserva, locacao, cobranca}.
--  As tabelas de staging bruto (stg_gupessanha_*) e as fases de
--  Transformação/Carga permanecem inalteradas (são agnósticas ao OLTP).
-- =====================================================================

-- Marca o momento desta extração para uso nos metadados
SET @extracao_ts = NOW();


--  1) STAGING: Criação das tabelas (caso ainda não existam)

CREATE SCHEMA IF NOT EXISTS staging;

--  1.1) stg_gupessanha_patio
CREATE TABLE IF NOT EXISTS staging.stg_gupessanha_patio (
    -- Chaves naturais do sistema de origem
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'gupessanha',
    nk_id_patio           INT          NOT NULL,
    -- Atributos
    nome_patio            VARCHAR(100),
    capacidade_vagas      INT,
    end_cidade            VARCHAR(80),
    end_uf                CHAR(2),
    end_logradouro        VARCHAR(150),
    -- Metadados de controle
    dt_extracao           DATETIME     NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_patio)
);

--  1.2) stg_gupessanha_grupo
CREATE TABLE IF NOT EXISTS staging.stg_gupessanha_grupo (
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'gupessanha',
    nk_id_grupo           INT          NOT NULL,
    nome_grupo            VARCHAR(80),
    codigo_grupo          VARCHAR(10),
    classe_luxo           VARCHAR(30),
    -- Tarifa vigente: no schema simples vem direto de grupo.valor_diaria
    valor_diaria          DECIMAL(12,2),
    dt_extracao           DATETIME     NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_grupo)
);


--  1.3) stg_gupessanha_veiculo
CREATE TABLE IF NOT EXISTS staging.stg_gupessanha_veiculo (
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'gupessanha',
    nk_id_veiculo         INT          NOT NULL,
    nk_id_grupo           INT,          -- FK para stg_gupessanha_grupo
    nk_id_patio_origem    INT,          -- FK para stg_gupessanha_patio
    placa                 VARCHAR(10),
    marca                 VARCHAR(50),
    modelo                VARCHAR(60),
    versao                VARCHAR(50),  -- inexistente no schema simples (NULL)
    mecanizacao           VARCHAR(20),
    tem_ar_condicionado   TINYINT(1),
    ano_fabricacao        INT,
    situacao              VARCHAR(20),
    dt_extracao           DATETIME     NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_veiculo)
);


--  1.4) stg_gupessanha_cliente
CREATE TABLE IF NOT EXISTS staging.stg_gupessanha_cliente (
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'gupessanha',
    nk_id_cliente         INT          NOT NULL,
    tipo_cliente          VARCHAR(2),       -- 'PF' ou 'PJ'
    nome                  VARCHAR(150),
    email                 VARCHAR(150),
    cidade_origem         VARCHAR(80),
    end_uf                CHAR(2),
    end_cidade            VARCHAR(80),
    -- Campos PF (nullable quando PJ)
    cpf                   VARCHAR(11),
    -- Campos PJ (nullable quando PF)
    cnpj                  VARCHAR(14),
    nome_fantasia         VARCHAR(150),
    dt_extracao           DATETIME     NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_cliente)
);


--  1.5) stg_gupessanha_reserva
CREATE TABLE IF NOT EXISTS staging.stg_gupessanha_reserva (
    nk_frota_origem           VARCHAR(10)  NOT NULL DEFAULT 'gupessanha',
    nk_id_reserva             INT          NOT NULL,
    nk_id_cliente             INT,
    nk_id_grupo               INT,
    nk_id_patio_retirada      INT,
    nk_id_patio_fim           INT,
    -- Datas (extraídas como DATE para bater com Dim_Tempo)
    data_reserva              DATE,
    data_retirada_prevista    DATE,
    data_devolucao_prevista   DATE,
    -- Medidas
    duracao_prevista_dias     INT,
    valor_previsto_reserva    DECIMAL(12,2),
    -- Dimensão degenerada
    status_reserva            VARCHAR(30),
    dt_extracao               DATETIME     NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_reserva)
);


--  1.6) stg_gupessanha_locacao
CREATE TABLE IF NOT EXISTS staging.stg_gupessanha_locacao (
    nk_frota_origem           VARCHAR(10)  NOT NULL DEFAULT 'gupessanha',
    nk_id_locacao             INT          NOT NULL,
    nk_id_cliente             INT,
    nk_id_veiculo             INT,
    nk_id_grupo               INT,       -- extraído via veiculo.grupo_id
    nk_id_patio_retirada      INT,
    nk_id_patio_devolucao     INT,
    -- Datas como DATE
    data_retirada             DATE,
    data_prev_devolucao       DATE,
    data_real_devolucao       DATE,          -- NULL se locação em andamento
    -- Medidas financeiras
    valor_diaria_aplicada     DECIMAL(12,2),
    valor_final               DECIMAL(14,2), -- SUM de cobranca quando faturada
    dt_extracao               DATETIME      NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_locacao)
);


--  1.7) stg_gupessanha_snapshot_patio  (para Fato_Inventario_Patio)
--       Snapshot diário: um registro por veículo em pátio por data.
CREATE TABLE IF NOT EXISTS staging.stg_gupessanha_snapshot_patio (
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'gupessanha',
    nk_id_patio           INT          NOT NULL,
    nk_id_veiculo         INT          NOT NULL,
    nk_id_grupo           INT,
    data_snapshot         DATE         NOT NULL,
    dt_extracao           DATETIME     NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_patio, nk_id_veiculo, data_snapshot)
);


DELIMITER //

-- Função auxiliar para corte incremental
-- Retorna a data de corte para extração incremental.
DROP FUNCTION IF EXISTS staging.fn_gupessanha_corte_incremental//
CREATE FUNCTION staging.fn_gupessanha_corte_incremental()
RETURNS DATETIME
READS SQL DATA
BEGIN
    RETURN COALESCE(@ultima_extracao, '1900-01-01 00:00:00');
END//


--  2) PROCEDURES DE EXTRAÇÃO

--  2.1) sp_gupessanha_extrai_patio
--       Carga full. O schema simples guarda o endereço numa única string
--       (locadora.patio.endereco); cidade/UF ficam NULL (a IA só conhece a
--       cidade de origem dos clientes), e a string vai para end_logradouro.
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extrai_patio//
CREATE PROCEDURE staging.sp_gupessanha_extrai_patio()
BEGIN
    TRUNCATE TABLE staging.stg_gupessanha_patio;

    INSERT INTO staging.stg_gupessanha_patio (
        nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas,
        end_cidade, end_uf, end_logradouro, dt_extracao
    )
    SELECT
        'gupessanha'            AS nk_frota_origem,
        p.id_patio              AS nk_id_patio,
        p.nome                  AS nome_patio,
        p.capacidade_vagas      AS capacidade_vagas,
        NULL                    AS end_cidade,
        NULL                    AS end_uf,
        LEFT(p.endereco, 150)   AS end_logradouro,
        NOW()                   AS dt_extracao
    FROM locadora.patio p;
END//


--  2.2) sp_gupessanha_extrai_grupo
--       Carga full. valor_diaria vem direto de grupo (sem tabela de tarifas).
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extrai_grupo//
CREATE PROCEDURE staging.sp_gupessanha_extrai_grupo()
BEGIN
    TRUNCATE TABLE staging.stg_gupessanha_grupo;

    INSERT INTO staging.stg_gupessanha_grupo (
        nk_frota_origem, nk_id_grupo, nome_grupo, codigo_grupo, classe_luxo, valor_diaria, dt_extracao
    )
    SELECT
        'gupessanha'                AS nk_frota_origem,
        g.id_grupo                  AS nk_id_grupo,
        g.nome                      AS nome_grupo,
        g.codigo                    AS codigo_grupo,
        g.classe_luxo               AS classe_luxo,
        COALESCE(g.valor_diaria, 0) AS valor_diaria,
        NOW()                       AS dt_extracao
    FROM locadora.grupo g;
END//


--  2.3) sp_gupessanha_extrai_veiculo
--       Carga full. marca/modelo/grupo_id estão diretos em veiculo
--       (sem tabela tipos_veiculo). mecanizacao: AUTOMATICA -> AUTOMATICO.
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extrai_veiculo//
CREATE PROCEDURE staging.sp_gupessanha_extrai_veiculo()
BEGIN
    TRUNCATE TABLE staging.stg_gupessanha_veiculo;

    INSERT INTO staging.stg_gupessanha_veiculo (
        nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
        placa, marca, modelo, versao, mecanizacao, tem_ar_condicionado,
        ano_fabricacao, situacao, dt_extracao
    )
    SELECT
        'gupessanha'                AS nk_frota_origem,
        v.id_veiculo                AS nk_id_veiculo,
        v.grupo_id                  AS nk_id_grupo,
        v.patio_origem_id           AS nk_id_patio_origem,
        v.placa                     AS placa,
        v.marca                     AS marca,
        v.modelo                    AS modelo,
        NULL                        AS versao,
        CASE v.mecanizacao
            WHEN 'MANUAL'     THEN 'MANUAL'
            WHEN 'AUTOMATICA' THEN 'AUTOMATICO'
            ELSE v.mecanizacao
        END                         AS mecanizacao,
        v.tem_ar_condicionado       AS tem_ar_condicionado,
        v.ano_fabricacao            AS ano_fabricacao,
        v.situacao                  AS situacao,
        NOW()                       AS dt_extracao
    FROM locadora.veiculo v;
END//


--  2.4) sp_gupessanha_extrai_cliente
--       Delta por data_cadastro + UPSERT. A IA só conhece a cidade de origem
--       (cliente.cidade_origem); não há UF. PF/PJ via subclasses.
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extrai_cliente//
CREATE PROCEDURE staging.sp_gupessanha_extrai_cliente()
BEGIN
    DECLARE v_corte DATETIME DEFAULT staging.fn_gupessanha_corte_incremental();

    INSERT INTO staging.stg_gupessanha_cliente (
        nk_frota_origem, nk_id_cliente, tipo_cliente, nome, email,
        cidade_origem, end_uf, end_cidade, cpf, cnpj, nome_fantasia, dt_extracao
    )
    SELECT
        'gupessanha'                AS nk_frota_origem,
        c.id_cliente                AS nk_id_cliente,
        c.tipo_pessoa               AS tipo_cliente,
        c.nome                      AS nome,
        c.email                     AS email,
        c.cidade_origem             AS cidade_origem,
        NULL                        AS end_uf,
        c.cidade_origem             AS end_cidade,
        pf.cpf                      AS cpf,
        pj.cnpj                     AS cnpj,
        pj.nome_fantasia            AS nome_fantasia,
        NOW()                       AS dt_extracao
    FROM locadora.cliente c
    LEFT JOIN locadora.cliente_pf pf ON pf.cliente_id = c.id_cliente
    LEFT JOIN locadora.cliente_pj pj ON pj.cliente_id = c.id_cliente
    WHERE c.data_cadastro >= CAST(v_corte AS DATE)
    ON DUPLICATE KEY UPDATE
        nome        = VALUES(nome),
        email       = VALUES(email),
        dt_extracao = VALUES(dt_extracao);
END//


--  2.5) sp_gupessanha_extrai_reserva
--       Delta por data_reserva + UPSERT (captura mudanças de estado).
--       valor_previsto = duração prevista * tarifa do grupo (reserva não
--       guarda valor no schema simples). Estados mapeados ao vocabulário DW.
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extrai_reserva//
CREATE PROCEDURE staging.sp_gupessanha_extrai_reserva()
BEGIN
    DECLARE v_corte DATETIME DEFAULT staging.fn_gupessanha_corte_incremental();

    INSERT INTO staging.stg_gupessanha_reserva (
        nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo,
        nk_id_patio_retirada, nk_id_patio_fim,
        data_reserva, data_retirada_prevista, data_devolucao_prevista,
        duracao_prevista_dias, valor_previsto_reserva, status_reserva, dt_extracao
    )
    SELECT
        'gupessanha'                                            AS nk_frota_origem,
        r.id_reserva                                            AS nk_id_reserva,
        r.cliente_id                                            AS nk_id_cliente,
        r.grupo_id                                              AS nk_id_grupo,
        r.patio_retirada_id                                     AS nk_id_patio_retirada,
        r.patio_devolucao_id                                    AS nk_id_patio_fim,
        DATE(r.data_reserva)                                    AS data_reserva,
        DATE(r.data_retirada_prevista)                          AS data_retirada_prevista,
        DATE(r.data_devolucao_prevista)                         AS data_devolucao_prevista,
        DATEDIFF(DATE(r.data_devolucao_prevista),
                 DATE(r.data_retirada_prevista))                AS duracao_prevista_dias,
        DATEDIFF(DATE(r.data_devolucao_prevista),
                 DATE(r.data_retirada_prevista))
            * COALESCE(g.valor_diaria, 0)                       AS valor_previsto_reserva,
        CASE r.estado
            WHEN 'CONFIRMADA'     THEN 'ATIVA'
            WHEN 'EM_FILA_ESPERA' THEN 'ATIVA'
            WHEN 'CANCELADA'      THEN 'CANCELADA'
            WHEN 'CONCRETIZADA'   THEN 'CONVERTIDA'
            ELSE 'ATIVA'
        END                                                     AS status_reserva,
        NOW()                                                   AS dt_extracao
    FROM locadora.reserva r
    LEFT JOIN locadora.grupo g ON g.id_grupo = r.grupo_id
    WHERE r.data_reserva >= v_corte
    ON DUPLICATE KEY UPDATE
        status_reserva         = VALUES(status_reserva),
        valor_previsto_reserva = VALUES(valor_previsto_reserva),
        dt_extracao            = VALUES(dt_extracao);
END//


--  2.6) sp_gupessanha_extrai_locacao
--       Delta por data_retirada_real / data_devolucao_real + UPSERT.
--       grupo via veiculo.grupo_id; devolução prevista via a reserva de origem;
--       pátio de devolução real só preenchido após a devolução; valor_final =
--       SUM(cobranca) faturada (PAGA/PENDENTE, exceto CANCELADA).
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extrai_locacao//
CREATE PROCEDURE staging.sp_gupessanha_extrai_locacao()
BEGIN
    DECLARE v_corte DATETIME DEFAULT staging.fn_gupessanha_corte_incremental();

    INSERT INTO staging.stg_gupessanha_locacao (
        nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo,
        nk_id_patio_retirada, nk_id_patio_devolucao,
        data_retirada, data_prev_devolucao, data_real_devolucao,
        valor_diaria_aplicada, valor_final, dt_extracao
    )
    SELECT
        'gupessanha'                                        AS nk_frota_origem,
        l.id_locacao                                        AS nk_id_locacao,
        l.cliente_id                                        AS nk_id_cliente,
        l.veiculo_id                                        AS nk_id_veiculo,
        v.grupo_id                                          AS nk_id_grupo,
        l.patio_retirada_id                                 AS nk_id_patio_retirada,
        CASE WHEN l.data_devolucao_real IS NOT NULL
             THEN l.patio_devolucao_id ELSE NULL END        AS nk_id_patio_devolucao,
        DATE(l.data_retirada_real)                          AS data_retirada,
        DATE(COALESCE(r.data_devolucao_prevista,
                      l.data_devolucao_real,
                      l.data_retirada_real))                AS data_prev_devolucao,
        DATE(l.data_devolucao_real)                         AS data_real_devolucao,
        l.valor_diaria_aplicada                             AS valor_diaria_aplicada,
        COALESCE((
            SELECT SUM(cb.valor_total)
            FROM   locadora.cobranca cb
            WHERE  cb.locacao_id = l.id_locacao
              AND  cb.status IN ('PAGA', 'PENDENTE')
        ), 0)                                               AS valor_final,
        NOW()                                               AS dt_extracao
    FROM locadora.locacao l
    JOIN locadora.veiculo v ON v.id_veiculo = l.veiculo_id
    LEFT JOIN locadora.reserva r ON r.id_reserva = l.reserva_id
    WHERE l.data_retirada_real >= v_corte
       OR l.data_devolucao_real >= v_corte
    ON DUPLICATE KEY UPDATE
        nk_id_patio_devolucao   = VALUES(nk_id_patio_devolucao),
        data_real_devolucao     = VALUES(data_real_devolucao),
        valor_final             = VALUES(valor_final),
        dt_extracao             = VALUES(dt_extracao);
END//


--  2.7) sp_gupessanha_extrai_snapshot_patio
--       Reconstrói, para o dia do snapshot, em que pátio cada veículo estava:
--         (a) última devolução CONCLUIDA <= data -> pátio de devolução, OU
--         (b) na ausência dela, o patio_origem do veículo.
--       Exclui veículos em locação EM_ANDAMENTO cobrindo a data e os BAIXADOS.
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extrai_snapshot_patio//
CREATE PROCEDURE staging.sp_gupessanha_extrai_snapshot_patio(
    IN p_data_snapshot DATE
)
BEGIN
    DECLARE v_data DATE;
    SET v_data = COALESCE(p_data_snapshot, DATE_SUB(CURDATE(), INTERVAL 1 DAY));

    DELETE FROM staging.stg_gupessanha_snapshot_patio
    WHERE data_snapshot = v_data
      AND nk_frota_origem = 'gupessanha';

    INSERT INTO staging.stg_gupessanha_snapshot_patio (
        nk_frota_origem, nk_id_patio, nk_id_veiculo, nk_id_grupo, data_snapshot, dt_extracao
    )
    WITH
    ultima_devolucao AS (
        SELECT veiculo_id, patio_devolucao_id AS patio_id_devolvido
        FROM (
            SELECT
                l.veiculo_id,
                l.patio_devolucao_id,
                ROW_NUMBER() OVER (
                    PARTITION BY l.veiculo_id
                    ORDER BY l.data_devolucao_real DESC
                ) AS rn
            FROM locadora.locacao l
            WHERE l.status = 'CONCLUIDA'
              AND DATE(l.data_devolucao_real) <= v_data
        ) ranked
        WHERE rn = 1
    ),
    em_locacao AS (
        SELECT DISTINCT l.veiculo_id
        FROM locadora.locacao l
        WHERE l.status = 'EM_ANDAMENTO'
          AND DATE(l.data_retirada_real) <= v_data
          AND (l.data_devolucao_real IS NULL
               OR DATE(l.data_devolucao_real) > v_data)
    ),
    posicao_final AS (
        SELECT
            v.id_veiculo,
            v.grupo_id,
            COALESCE(ud.patio_id_devolvido, v.patio_origem_id) AS patio_id
        FROM locadora.veiculo v
        LEFT JOIN ultima_devolucao ud ON ud.veiculo_id = v.id_veiculo
        WHERE v.situacao <> 'BAIXADO'
    )
    SELECT
        'gupessanha'        AS nk_frota_origem,
        pf.patio_id         AS nk_id_patio,
        pf.id_veiculo       AS nk_id_veiculo,
        pf.grupo_id         AS nk_id_grupo,
        v_data              AS data_snapshot,
        NOW()               AS dt_extracao
    FROM posicao_final pf
    WHERE pf.id_veiculo NOT IN (SELECT veiculo_id FROM em_locacao);
END//


--  3) PROCEDURE MAIN DE EXTRAÇÃO
--     Chama todas as extrações na ordem correta (dimensões antes de fatos).
--     full_load = TRUE faz carga completa (ignora corte incremental).
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extracao_completa//
CREATE PROCEDURE staging.sp_gupessanha_extracao_completa(
    IN p_full_load TINYINT(1)
)
BEGIN
    IF p_full_load THEN
        SET @ultima_extracao = '1900-01-01 00:00:00';
    END IF;

    CALL staging.sp_gupessanha_extrai_patio();
    CALL staging.sp_gupessanha_extrai_grupo();
    CALL staging.sp_gupessanha_extrai_veiculo();
    CALL staging.sp_gupessanha_extrai_cliente();
    CALL staging.sp_gupessanha_extrai_reserva();
    CALL staging.sp_gupessanha_extrai_locacao();
    CALL staging.sp_gupessanha_extrai_snapshot_patio(NULL);
END//


-- =========================================================================
--  4) TRIGGERS DE EXTRAÇÃO (Event-Driven)
--     Cada INSERT/UPDATE no OLTP (locadora) replica no staging bruto.
-- =========================================================================

-- 4.1) Patio
DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_patio_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_patio_ai
AFTER INSERT ON locadora.patio
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_patio (
        nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas,
        end_cidade, end_uf, end_logradouro, dt_extracao
    ) VALUES (
        'gupessanha', NEW.id_patio, NEW.nome, NEW.capacidade_vagas,
        NULL, NULL, LEFT(NEW.endereco, 150), NOW()
    ) ON DUPLICATE KEY UPDATE
        nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas),
        end_logradouro = VALUES(end_logradouro), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_patio_au//
CREATE TRIGGER locadora.trg_extrai_gupessanha_patio_au
AFTER UPDATE ON locadora.patio
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_patio (
        nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas,
        end_cidade, end_uf, end_logradouro, dt_extracao
    ) VALUES (
        'gupessanha', NEW.id_patio, NEW.nome, NEW.capacidade_vagas,
        NULL, NULL, LEFT(NEW.endereco, 150), NOW()
    ) ON DUPLICATE KEY UPDATE
        nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas),
        end_logradouro = VALUES(end_logradouro), dt_extracao = NOW();
END//

-- 4.2) Grupo
DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_grupo_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_grupo_ai
AFTER INSERT ON locadora.grupo
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_grupo (
        nk_frota_origem, nk_id_grupo, nome_grupo, codigo_grupo, classe_luxo, valor_diaria, dt_extracao
    ) VALUES (
        'gupessanha', NEW.id_grupo, NEW.nome, NEW.codigo, NEW.classe_luxo, COALESCE(NEW.valor_diaria, 0), NOW()
    ) ON DUPLICATE KEY UPDATE
        nome_grupo = VALUES(nome_grupo), codigo_grupo = VALUES(codigo_grupo),
        classe_luxo = VALUES(classe_luxo), valor_diaria = VALUES(valor_diaria), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_grupo_au//
CREATE TRIGGER locadora.trg_extrai_gupessanha_grupo_au
AFTER UPDATE ON locadora.grupo
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_grupo (
        nk_frota_origem, nk_id_grupo, nome_grupo, codigo_grupo, classe_luxo, valor_diaria, dt_extracao
    ) VALUES (
        'gupessanha', NEW.id_grupo, NEW.nome, NEW.codigo, NEW.classe_luxo, COALESCE(NEW.valor_diaria, 0), NOW()
    ) ON DUPLICATE KEY UPDATE
        nome_grupo = VALUES(nome_grupo), codigo_grupo = VALUES(codigo_grupo),
        classe_luxo = VALUES(classe_luxo), valor_diaria = VALUES(valor_diaria), dt_extracao = NOW();
END//

-- 4.3) Veiculo
DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_veiculo_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_veiculo_ai
AFTER INSERT ON locadora.veiculo
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_veiculo (
        nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
        placa, marca, modelo, versao, mecanizacao, tem_ar_condicionado,
        ano_fabricacao, situacao, dt_extracao
    ) VALUES (
        'gupessanha', NEW.id_veiculo, NEW.grupo_id, NEW.patio_origem_id,
        NEW.placa, NEW.marca, NEW.modelo, NULL,
        CASE NEW.mecanizacao WHEN 'MANUAL' THEN 'MANUAL' WHEN 'AUTOMATICA' THEN 'AUTOMATICO' ELSE NEW.mecanizacao END,
        NEW.tem_ar_condicionado, NEW.ano_fabricacao, NEW.situacao, NOW()
    ) ON DUPLICATE KEY UPDATE
        nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_origem = VALUES(nk_id_patio_origem),
        placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
        mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado),
        situacao = VALUES(situacao), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_veiculo_au//
CREATE TRIGGER locadora.trg_extrai_gupessanha_veiculo_au
AFTER UPDATE ON locadora.veiculo
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_veiculo (
        nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
        placa, marca, modelo, versao, mecanizacao, tem_ar_condicionado,
        ano_fabricacao, situacao, dt_extracao
    ) VALUES (
        'gupessanha', NEW.id_veiculo, NEW.grupo_id, NEW.patio_origem_id,
        NEW.placa, NEW.marca, NEW.modelo, NULL,
        CASE NEW.mecanizacao WHEN 'MANUAL' THEN 'MANUAL' WHEN 'AUTOMATICA' THEN 'AUTOMATICO' ELSE NEW.mecanizacao END,
        NEW.tem_ar_condicionado, NEW.ano_fabricacao, NEW.situacao, NOW()
    ) ON DUPLICATE KEY UPDATE
        nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_origem = VALUES(nk_id_patio_origem),
        placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
        mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado),
        situacao = VALUES(situacao), dt_extracao = NOW();
END//

-- 4.4) Cliente
DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_cliente_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_cliente_ai
AFTER INSERT ON locadora.cliente
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_cliente (
        nk_frota_origem, nk_id_cliente, tipo_cliente, nome, email, cidade_origem, end_uf, end_cidade,
        cpf, cnpj, nome_fantasia, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_cliente, NEW.tipo_pessoa, NEW.nome, NEW.email, NEW.cidade_origem, NULL, NEW.cidade_origem,
           pf.cpf, pj.cnpj, pj.nome_fantasia, NOW()
    FROM (SELECT 1) dummy
    LEFT JOIN locadora.cliente_pf pf ON pf.cliente_id = NEW.id_cliente
    LEFT JOIN locadora.cliente_pj pj ON pj.cliente_id = NEW.id_cliente
    ON DUPLICATE KEY UPDATE
        nome = VALUES(nome), email = VALUES(email), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_cliente_au//
CREATE TRIGGER locadora.trg_extrai_gupessanha_cliente_au
AFTER UPDATE ON locadora.cliente
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_cliente (
        nk_frota_origem, nk_id_cliente, tipo_cliente, nome, email, cidade_origem, end_uf, end_cidade,
        cpf, cnpj, nome_fantasia, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_cliente, NEW.tipo_pessoa, NEW.nome, NEW.email, NEW.cidade_origem, NULL, NEW.cidade_origem,
           pf.cpf, pj.cnpj, pj.nome_fantasia, NOW()
    FROM (SELECT 1) dummy
    LEFT JOIN locadora.cliente_pf pf ON pf.cliente_id = NEW.id_cliente
    LEFT JOIN locadora.cliente_pj pj ON pj.cliente_id = NEW.id_cliente
    ON DUPLICATE KEY UPDATE
        nome = VALUES(nome), email = VALUES(email), dt_extracao = NOW();
END//

-- 4.5) Reserva
DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_reserva_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_reserva_ai
AFTER INSERT ON locadora.reserva
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_reserva (
        nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim,
        data_reserva, data_retirada_prevista, data_devolucao_prevista, duracao_prevista_dias, valor_previsto_reserva, status_reserva, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_reserva, NEW.cliente_id, NEW.grupo_id, NEW.patio_retirada_id, NEW.patio_devolucao_id,
           DATE(NEW.data_reserva), DATE(NEW.data_retirada_prevista), DATE(NEW.data_devolucao_prevista),
           DATEDIFF(DATE(NEW.data_devolucao_prevista), DATE(NEW.data_retirada_prevista)),
           DATEDIFF(DATE(NEW.data_devolucao_prevista), DATE(NEW.data_retirada_prevista)) * COALESCE(g.valor_diaria, 0),
           CASE NEW.estado WHEN 'CONFIRMADA' THEN 'ATIVA' WHEN 'EM_FILA_ESPERA' THEN 'ATIVA' WHEN 'CANCELADA' THEN 'CANCELADA' WHEN 'CONCRETIZADA' THEN 'CONVERTIDA' ELSE 'ATIVA' END,
           NOW()
    FROM (SELECT 1) dummy
    LEFT JOIN locadora.grupo g ON g.id_grupo = NEW.grupo_id
    ON DUPLICATE KEY UPDATE
        status_reserva = VALUES(status_reserva), valor_previsto_reserva = VALUES(valor_previsto_reserva), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_reserva_au//
CREATE TRIGGER locadora.trg_extrai_gupessanha_reserva_au
AFTER UPDATE ON locadora.reserva
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_reserva (
        nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim,
        data_reserva, data_retirada_prevista, data_devolucao_prevista, duracao_prevista_dias, valor_previsto_reserva, status_reserva, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_reserva, NEW.cliente_id, NEW.grupo_id, NEW.patio_retirada_id, NEW.patio_devolucao_id,
           DATE(NEW.data_reserva), DATE(NEW.data_retirada_prevista), DATE(NEW.data_devolucao_prevista),
           DATEDIFF(DATE(NEW.data_devolucao_prevista), DATE(NEW.data_retirada_prevista)),
           DATEDIFF(DATE(NEW.data_devolucao_prevista), DATE(NEW.data_retirada_prevista)) * COALESCE(g.valor_diaria, 0),
           CASE NEW.estado WHEN 'CONFIRMADA' THEN 'ATIVA' WHEN 'EM_FILA_ESPERA' THEN 'ATIVA' WHEN 'CANCELADA' THEN 'CANCELADA' WHEN 'CONCRETIZADA' THEN 'CONVERTIDA' ELSE 'ATIVA' END,
           NOW()
    FROM (SELECT 1) dummy
    LEFT JOIN locadora.grupo g ON g.id_grupo = NEW.grupo_id
    ON DUPLICATE KEY UPDATE
        status_reserva = VALUES(status_reserva), valor_previsto_reserva = VALUES(valor_previsto_reserva), dt_extracao = NOW();
END//

-- 4.6) Locação
DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_locacao_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_locacao_ai
AFTER INSERT ON locadora.locacao
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_locacao (
        nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_devolucao,
        data_retirada, data_prev_devolucao, data_real_devolucao, valor_diaria_aplicada, valor_final, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_locacao, NEW.cliente_id, NEW.veiculo_id, v.grupo_id, NEW.patio_retirada_id,
           CASE WHEN NEW.data_devolucao_real IS NOT NULL THEN NEW.patio_devolucao_id ELSE NULL END,
           DATE(NEW.data_retirada_real),
           DATE(COALESCE(r.data_devolucao_prevista, NEW.data_devolucao_real, NEW.data_retirada_real)),
           DATE(NEW.data_devolucao_real), NEW.valor_diaria_aplicada,
           COALESCE((SELECT SUM(cb.valor_total) FROM locadora.cobranca cb WHERE cb.locacao_id = NEW.id_locacao AND cb.status IN ('PAGA','PENDENTE')), 0),
           NOW()
    FROM locadora.veiculo v
    LEFT JOIN locadora.reserva r ON r.id_reserva = NEW.reserva_id
    WHERE v.id_veiculo = NEW.veiculo_id
    ON DUPLICATE KEY UPDATE
        nk_id_patio_devolucao = VALUES(nk_id_patio_devolucao), data_real_devolucao = VALUES(data_real_devolucao),
        valor_final = VALUES(valor_final), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_locacao_au//
CREATE TRIGGER locadora.trg_extrai_gupessanha_locacao_au
AFTER UPDATE ON locadora.locacao
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_locacao (
        nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_devolucao,
        data_retirada, data_prev_devolucao, data_real_devolucao, valor_diaria_aplicada, valor_final, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_locacao, NEW.cliente_id, NEW.veiculo_id, v.grupo_id, NEW.patio_retirada_id,
           CASE WHEN NEW.data_devolucao_real IS NOT NULL THEN NEW.patio_devolucao_id ELSE NULL END,
           DATE(NEW.data_retirada_real),
           DATE(COALESCE(r.data_devolucao_prevista, NEW.data_devolucao_real, NEW.data_retirada_real)),
           DATE(NEW.data_devolucao_real), NEW.valor_diaria_aplicada,
           COALESCE((SELECT SUM(cb.valor_total) FROM locadora.cobranca cb WHERE cb.locacao_id = NEW.id_locacao AND cb.status IN ('PAGA','PENDENTE')), 0),
           NOW()
    FROM locadora.veiculo v
    LEFT JOIN locadora.reserva r ON r.id_reserva = NEW.reserva_id
    WHERE v.id_veiculo = NEW.veiculo_id
    ON DUPLICATE KEY UPDATE
        nk_id_patio_devolucao = VALUES(nk_id_patio_devolucao), data_real_devolucao = VALUES(data_real_devolucao),
        valor_final = VALUES(valor_final), dt_extracao = NOW();
END//

-- 4.7) Cobranca (atualiza valor_final da locação correspondente)
DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_cobranca_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_cobranca_ai
AFTER INSERT ON locadora.cobranca
FOR EACH ROW
BEGIN
    UPDATE staging.stg_gupessanha_locacao
    SET valor_final = COALESCE((SELECT SUM(cb.valor_total) FROM locadora.cobranca cb WHERE cb.locacao_id = NEW.locacao_id AND cb.status IN ('PAGA','PENDENTE')), 0),
        dt_extracao = NOW()
    WHERE nk_frota_origem = 'gupessanha' AND nk_id_locacao = NEW.locacao_id;
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_cobranca_au//
CREATE TRIGGER locadora.trg_extrai_gupessanha_cobranca_au
AFTER UPDATE ON locadora.cobranca
FOR EACH ROW
BEGIN
    UPDATE staging.stg_gupessanha_locacao
    SET valor_final = COALESCE((SELECT SUM(cb.valor_total) FROM locadora.cobranca cb WHERE cb.locacao_id = NEW.locacao_id AND cb.status IN ('PAGA','PENDENTE')), 0),
        dt_extracao = NOW()
    WHERE nk_frota_origem = 'gupessanha' AND nk_id_locacao = NEW.locacao_id;
END//

DELIMITER ;
