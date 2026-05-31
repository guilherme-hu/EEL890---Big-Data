-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)


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
    -- Tarifa vigente (join com tarifas_grupo para pegar a mais recente)
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
    versao                VARCHAR(50),
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
    nk_id_grupo               INT,       -- extraído via veiculos→tipos_veiculo→grupos
    nk_id_patio_retirada      INT,
    nk_id_patio_devolucao     INT,
    -- Datas como DATE
    data_retirada             DATE,
    data_prev_devolucao       DATE,
    data_real_devolucao       DATE,          -- NULL se locação em andamento
    -- Medidas financeiras
    valor_diaria_aplicada     DECIMAL(12,2),
    valor_final               DECIMAL(14,2), -- SUM de cobrancas quando CONCLUIDA
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


-- Função auxiliar para corte incremental
-- Retorna a data de corte para extração incremental.
DROP FUNCTION IF EXISTS staging.fn_gupessanha_corte_incremental;
CREATE FUNCTION staging.fn_gupessanha_corte_incremental()
RETURNS DATETIME
READS SQL DATA
BEGIN
    RETURN COALESCE(@ultima_extracao, '1900-01-01 00:00:00');
END;


--  2) PROCEDURES DE EXTRAÇÃO

--  2.1) sp_gupessanha_extrai_patio
--       Carga full (tabela não tem coluna de atualização explícita).
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extrai_patio;
CREATE PROCEDURE staging.sp_gupessanha_extrai_patio()
BEGIN

    -- Limpa e recarrega (full load — tabela de dimensão pequena/estável)
    TRUNCATE TABLE staging.stg_gupessanha_patio;

    INSERT INTO staging.stg_gupessanha_patio (
        nk_frota_origem,
        nk_id_patio,
        nome_patio,
        capacidade_vagas,
        end_cidade,
        end_uf,
        end_logradouro,
        dt_extracao
    )
    SELECT
        'gupessanha'            AS nk_frota_origem,
        p.id_patio              AS nk_id_patio,
        p.nome                  AS nome_patio,
        p.capacidade_vagas      AS capacidade_vagas,
        p.end_cidade            AS end_cidade,
        p.end_uf                AS end_uf,
        p.end_logradouro        AS end_logradouro,
        NOW()                   AS dt_extracao
    FROM locadora.patios p;

END;



--  2.2) sp_gupessanha_extrai_grupo
--       Carga full. Inclui JOIN com tarifas_grupo para pegar a tarifa atualmente vigente.
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extrai_grupo;
CREATE PROCEDURE staging.sp_gupessanha_extrai_grupo()
BEGIN

    TRUNCATE TABLE staging.stg_gupessanha_grupo;

    INSERT INTO staging.stg_gupessanha_grupo (
        nk_frota_origem,
        nk_id_grupo,
        nome_grupo,
        codigo_grupo,
        classe_luxo,
        valor_diaria,
        dt_extracao
    )
    SELECT
        'gupessanha'            AS nk_frota_origem,
        g.id_grupo              AS nk_id_grupo,
        g.nome                  AS nome_grupo,
        g.codigo                AS codigo_grupo,
        g.classe_luxo           AS classe_luxo,
        -- Tarifa vigente: a mais recente com data_inicio <= hoje e (data_fim IS NULL ou data_fim >= hoje)
        COALESCE(t.valor_diaria, 0) AS valor_diaria,
        NOW()                   AS dt_extracao
    FROM locadora.grupos g
    LEFT JOIN (
        SELECT tg.grupo_id, tg.valor_diaria
        FROM locadora.tarifas_grupo tg
        WHERE tg.data_inicio_vigencia <= CURDATE()
          AND (tg.data_fim_vigencia IS NULL OR tg.data_fim_vigencia >= CURDATE())
        ORDER BY tg.grupo_id, tg.data_inicio_vigencia DESC
    ) t ON t.grupo_id = g.id_grupo;

END;



--  2.3) sp_gupessanha_extrai_veiculo
--       Delta incremental por situacao ou carga full.
--       O OLTP "gupessanha" não tem coluna updated_at em veiculos; usa-se full truncate-reload (tabela de dimensão média).
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extrai_veiculo;
CREATE PROCEDURE staging.sp_gupessanha_extrai_veiculo()
BEGIN

    TRUNCATE TABLE staging.stg_gupessanha_veiculo;

    INSERT INTO staging.stg_gupessanha_veiculo (
        nk_frota_origem,
        nk_id_veiculo,
        nk_id_grupo,
        nk_id_patio_origem,
        placa,
        marca,
        modelo,
        versao,
        mecanizacao,
        tem_ar_condicionado,
        ano_fabricacao,
        situacao,
        dt_extracao
    )
    SELECT
        'gupessanha'                AS nk_frota_origem,
        v.id_veiculo                AS nk_id_veiculo,
        tv.grupo_id                 AS nk_id_grupo,
        v.patio_origem_id           AS nk_id_patio_origem,
        v.placa                     AS placa,
        tv.marca                    AS marca,
        tv.modelo                   AS modelo,
        tv.versao                   AS versao,
        -- Normaliza mecanização para valores esperados pelo DW
        CASE tv.mecanizacao
            WHEN 'MANUAL'     THEN 'MANUAL'
            WHEN 'AUTOMATICA' THEN 'AUTOMATICO'
            ELSE tv.mecanizacao
        END                         AS mecanizacao,
        tv.tem_ar_condicionado      AS tem_ar_condicionado,
        v.ano_fabricacao            AS ano_fabricacao,
        v.situacao                  AS situacao,
        NOW()                       AS dt_extracao
    FROM locadora.veiculos v
    JOIN locadora.tipos_veiculo tv
        ON tv.id_tipo_veiculo = v.tipo_veiculo_id;

END;



--  2.4  sp_gupessanha_extrai_cliente
--       Carga incremental por data_cadastro.
--       O OLTP não tem updated_at em clientes; clientes existentes raramente mudam, por isso usamos UPSERT baseado em PK.
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extrai_cliente;
CREATE PROCEDURE staging.sp_gupessanha_extrai_cliente()
BEGIN
    DECLARE v_corte DATETIME DEFAULT staging.fn_gupessanha_corte_incremental();

    -- UPSERT: insere novos ou atualiza nome/email de existentes
    INSERT INTO staging.stg_gupessanha_cliente (
        nk_frota_origem,
        nk_id_cliente,
        tipo_cliente,
        nome,
        email,
        cidade_origem,
        end_uf,
        end_cidade,
        cpf,
        cnpj,
        nome_fantasia,
        dt_extracao
    )
    SELECT
        'gupessanha'                AS nk_frota_origem,
        c.id_cliente                AS nk_id_cliente,
        c.tipo_pessoa               AS tipo_cliente,
        c.nome_razao_social         AS nome,
        c.email                     AS email,
        c.cidade_origem             AS cidade_origem,
        c.end_uf                    AS end_uf,
        c.end_cidade                AS end_cidade,
        -- PF: extrai CPF; PJ: NULL
        pf.cpf                      AS cpf,
        -- PJ: extrai CNPJ; PF: NULL
        pj.cnpj                     AS cnpj,
        pj.nome_fantasia            AS nome_fantasia,
        NOW()                       AS dt_extracao
    FROM locadora.clientes c
    LEFT JOIN locadora.clientes_pf pf ON pf.cliente_id = c.id_cliente
    LEFT JOIN locadora.clientes_pj pj ON pj.cliente_id = c.id_cliente
    WHERE c.data_cadastro >= CAST(v_corte AS DATE)
    ON DUPLICATE KEY UPDATE
        nome        = VALUES(nome),
        email       = VALUES(email),
        dt_extracao = VALUES(dt_extracao);

END;



--  2.5  sp_gupessanha_extrai_reserva
--       Delta por data_hora_reserva (coluna WITH TIME ZONE).
--       Também captura atualizações de estado (ex.: CANCELADA).
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extrai_reserva;
CREATE PROCEDURE staging.sp_gupessanha_extrai_reserva()
BEGIN
    DECLARE v_corte DATETIME DEFAULT staging.fn_gupessanha_corte_incremental();

    INSERT INTO staging.stg_gupessanha_reserva (
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
        status_reserva,
        dt_extracao
    )
    SELECT
        'gupessanha'                                            AS nk_frota_origem,
        r.id_reserva                                            AS nk_id_reserva,
        r.cliente_id                                            AS nk_id_cliente,
        r.grupo_id                                              AS nk_id_grupo,
        r.patio_retirada_prevista_id                            AS nk_id_patio_retirada,
        r.patio_entrega_prevista_id                             AS nk_id_patio_fim,
        -- Trunca para DATE (Dim_Tempo usa DATE)
        DATE(r.data_hora_reserva)                               AS data_reserva,
        DATE(r.data_hora_retirada_prevista)                     AS data_retirada_prevista,
        DATE(r.data_hora_devolucao_prevista)                    AS data_devolucao_prevista,
        -- Duração em dias
        DATEDIFF(
            DATE(r.data_hora_devolucao_prevista),
            DATE(r.data_hora_retirada_prevista))                AS duracao_prevista_dias,
        -- Valor previsto = duração × tarifa vigente do grupo
        DATEDIFF(
            DATE(r.data_hora_devolucao_prevista),
            DATE(r.data_hora_retirada_prevista))
            * COALESCE(t.valor_diaria, 0)                       AS valor_previsto_reserva,
        -- Mapeamento de estados para vocabulário do DW
        CASE r.estado
            WHEN 'CONFIRMADA'     THEN 'ATIVA'
            WHEN 'EM_ANALISE'     THEN 'ATIVA'
            WHEN 'EM_FILA_ESPERA' THEN 'ATIVA'
            WHEN 'CANCELADA'      THEN 'CANCELADA'
            WHEN 'NO_SHOW'        THEN 'CANCELADA'
            WHEN 'EXPIRADA'       THEN 'CANCELADA'
            WHEN 'CONCRETIZADA'   THEN 'CONVERTIDA'
            ELSE r.estado
        END                                                     AS status_reserva,
        NOW()                                                   AS dt_extracao
    FROM locadora.reservas r
    -- Tarifa do grupo vigente no momento da reserva
    LEFT JOIN (
        SELECT tg.grupo_id, tg.valor_diaria, tg.data_inicio_vigencia
        FROM locadora.tarifas_grupo tg
        WHERE (tg.data_fim_vigencia IS NULL OR tg.data_fim_vigencia >= DATE(tg.data_inicio_vigencia))
        ORDER BY tg.grupo_id, tg.data_inicio_vigencia DESC
    ) t ON t.grupo_id = r.grupo_id
       AND t.data_inicio_vigencia <= DATE(r.data_hora_reserva)
    -- Filtro incremental: novas reservas E estados que podem ter mudado
    -- Obs: sem updated_at, capturamos tudo após a data de reserva e fazemos UPSERT para sobrescrever mudanças de estado.
    WHERE r.data_hora_reserva >= v_corte
    ON DUPLICATE KEY UPDATE
        status_reserva         = VALUES(status_reserva),
        valor_previsto_reserva = VALUES(valor_previsto_reserva),
        dt_extracao            = VALUES(dt_extracao);

END;



--  2.6  sp_gupessanha_extrai_locacao
--       Delta por data_hora_retirada_real.
--       O UPSERT é crítico: uma locação pode ser inserida como EM_ANDAMENTO e depois atualizada para CONCLUIDA com devolução e valor_final preenchidos.
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extrai_locacao;
CREATE PROCEDURE staging.sp_gupessanha_extrai_locacao()
BEGIN
    DECLARE v_corte DATETIME DEFAULT staging.fn_gupessanha_corte_incremental();

    INSERT INTO staging.stg_gupessanha_locacao (
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
        valor_diaria_aplicada,
        valor_final,
        dt_extracao
    )
    SELECT
        'gupessanha'                                        AS nk_frota_origem,
        l.id_locacao                                        AS nk_id_locacao,
        l.cliente_id                                        AS nk_id_cliente,
        l.veiculo_id                                        AS nk_id_veiculo,
        -- Grupo obtido via veiculo → tipo_veiculo → grupo
        tv.grupo_id                                         AS nk_id_grupo,
        -- Pátio real de retirada (se não preenchido, usa o previsto)
        COALESCE(l.patio_retirada_real_id,
                 l.patio_retirada_prevista_id)               AS nk_id_patio_retirada,
        -- Pátio real de devolução (NULL se em andamento)
        l.patio_entrega_real_id                             AS nk_id_patio_devolucao,
        -- Datas como DATE
        DATE(COALESCE(l.data_hora_retirada_real,
                 l.data_hora_retirada_prevista))            AS data_retirada,
        DATE(l.data_hora_devolucao_prevista)                AS data_prev_devolucao,
        DATE(l.data_hora_devolucao_real)                    AS data_real_devolucao,
        l.valor_diaria_aplicada                             AS valor_diaria_aplicada,
        -- Valor final: soma de cobranças PAGA ou PENDENTE da locação
        COALESCE((
            SELECT SUM(c.valor_total)
            FROM   locadora.cobrancas c
            WHERE  c.locacao_id = l.id_locacao
              AND  c.status IN ('PENDENTE', 'PAGA', 'PARCIAL')
        ), 0)                                               AS valor_final,
        NOW()                                               AS dt_extracao
    FROM locadora.locacoes l
    JOIN locadora.veiculos v
        ON v.id_veiculo = l.veiculo_id
    JOIN locadora.tipos_veiculo tv
        ON tv.id_tipo_veiculo = v.tipo_veiculo_id
    -- Captura: locações com retirada REAL após o corte (novas) OU devolução real após o corte (atualizações de status)
    WHERE COALESCE(l.data_hora_retirada_real,
                   l.data_hora_retirada_prevista) >= v_corte
       OR l.data_hora_devolucao_real >= v_corte
    ON DUPLICATE KEY UPDATE
        nk_id_patio_devolucao   = VALUES(nk_id_patio_devolucao),
        data_real_devolucao     = VALUES(data_real_devolucao),
        valor_final             = VALUES(valor_final),
        dt_extracao             = VALUES(dt_extracao);

END;



--  2.7  sp_gupessanha_extrai_snapshot_patio
--       Reconstrói, para o dia anterior (snapshot diário), quais veículos estavam em cada pátio.
--       Lógica: veículo está no pátio P na data D se:
--         (a) sua última devolução anterior a D foi em P, OU
--         (b) nunca foi alugado após chegar em P (patio_origem) E não há locação ativa cobrindo D.
DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extrai_snapshot_patio;
CREATE PROCEDURE staging.sp_gupessanha_extrai_snapshot_patio(
    IN p_data_snapshot DATE
)
BEGIN
    DECLARE v_data DATE;
    SET v_data = COALESCE(p_data_snapshot, DATE_SUB(CURDATE(), INTERVAL 1 DAY));

    -- Remove snapshot anterior para este dia (re-execução segura)
    DELETE FROM staging.stg_gupessanha_snapshot_patio
    WHERE data_snapshot = v_data
      AND nk_frota_origem = 'gupessanha';

    -- Insert: para cada veículo ativo, determina em qual pátio estava
    -- Usa ROW_NUMBER() para simular "última devolução por veículo".
    INSERT INTO staging.stg_gupessanha_snapshot_patio (
        nk_frota_origem,
        nk_id_patio,
        nk_id_veiculo,
        nk_id_grupo,
        data_snapshot,
        dt_extracao
    )
    WITH
    -- Última locação concluída ANTES ou NA data do snapshot, que define onde o veículo foi devolvido
    ultima_devolucao AS (
        SELECT veiculo_id, patio_entrega_real_id AS patio_id_devolvido
        FROM (
            SELECT
                l.veiculo_id,
                l.patio_entrega_real_id,
                ROW_NUMBER() OVER (
                    PARTITION BY l.veiculo_id
                    ORDER BY l.data_hora_devolucao_real DESC
                ) AS rn
            FROM locadora.locacoes l
            WHERE l.status = 'CONCLUIDA'
              AND DATE(l.data_hora_devolucao_real) <= v_data
        ) ranked
        WHERE rn = 1
    ),
    -- Veículos que estavam em locação ATIVA na data do snapshot (não devem aparecer no snapshot de pátio)
    em_locacao AS (
        SELECT DISTINCT l.veiculo_id
        FROM locadora.locacoes l
        WHERE l.status IN ('EM_ANDAMENTO', 'EM_ABERTO')
          AND DATE(COALESCE(l.data_hora_retirada_real,
                       l.data_hora_retirada_prevista)) <= v_data
          AND (l.data_hora_devolucao_real IS NULL
               OR DATE(l.data_hora_devolucao_real) > v_data)
    ),
    -- Posição final de cada veículo: usa a devolução mais recente; se nunca foi alugado antes de v_data, usa o patio_origem
    posicao_final AS (
        SELECT
            v.id_veiculo,
            tv.grupo_id,
            COALESCE(ud.patio_id_devolvido, v.patio_origem_id) AS patio_id
        FROM locadora.veiculos v
        JOIN locadora.tipos_veiculo tv
            ON tv.id_tipo_veiculo = v.tipo_veiculo_id
        LEFT JOIN ultima_devolucao ud
            ON ud.veiculo_id = v.id_veiculo
    )
    SELECT
        'gupessanha'        AS nk_frota_origem,
        pf.patio_id         AS nk_id_patio,
        pf.id_veiculo       AS nk_id_veiculo,
        pf.grupo_id         AS nk_id_grupo,
        v_data              AS data_snapshot,
        NOW()               AS dt_extracao
    FROM posicao_final pf
    -- Exclui veículos que estavam em locação naquele dia
    WHERE pf.id_veiculo NOT IN (SELECT veiculo_id FROM em_locacao);


END;



--  3) PROCEDURE MAIN DE EXTRAÇÃO
--     Chama todas as extrações na ordem correta.
--     Parâmetro full_load = TRUE faz carga completa (ignora corte).

DROP PROCEDURE IF EXISTS staging.sp_gupessanha_extracao_completa;
CREATE PROCEDURE staging.sp_gupessanha_extracao_completa(
    IN p_full_load TINYINT(1)
)
BEGIN
    IF p_full_load THEN
        SET @ultima_extracao = '1900-01-01 00:00:00';
    END IF;

    -- Ordem: dimensões antes de fatos
    CALL staging.sp_gupessanha_extrai_patio();
    CALL staging.sp_gupessanha_extrai_grupo();
    CALL staging.sp_gupessanha_extrai_veiculo();
    CALL staging.sp_gupessanha_extrai_cliente();
    CALL staging.sp_gupessanha_extrai_reserva();
    CALL staging.sp_gupessanha_extrai_locacao();
    CALL staging.sp_gupessanha_extrai_snapshot_patio(NULL);

END;

-- =========================================================================
--  4) TRIGGERS DE EXTRAÇÃO (Event-Driven)
--     Substituem as procedures de extração para operação em tempo real.
--     Cada INSERT/UPDATE no OLTP (locadora) replica no staging bruto.
-- =========================================================================

DELIMITER //

-- 4.1) Patio
DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_patio_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_patio_ai
AFTER INSERT ON locadora.patios
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_patio (
        nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas,
        end_cidade, end_uf, end_logradouro, dt_extracao
    ) VALUES (
        'gupessanha', NEW.id_patio, NEW.nome, NEW.capacidade_vagas,
        NEW.end_cidade, NEW.end_uf, NEW.end_logradouro, NOW()
    ) ON DUPLICATE KEY UPDATE
        nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas),
        end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf),
        end_logradouro = VALUES(end_logradouro), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_patio_au//
CREATE TRIGGER locadora.trg_extrai_gupessanha_patio_au
AFTER UPDATE ON locadora.patios
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_patio (
        nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas,
        end_cidade, end_uf, end_logradouro, dt_extracao
    ) VALUES (
        'gupessanha', NEW.id_patio, NEW.nome, NEW.capacidade_vagas,
        NEW.end_cidade, NEW.end_uf, NEW.end_logradouro, NOW()
    ) ON DUPLICATE KEY UPDATE
        nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas),
        end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf),
        end_logradouro = VALUES(end_logradouro), dt_extracao = NOW();
END//

-- 4.2) Grupo
DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_grupo_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_grupo_ai
AFTER INSERT ON locadora.grupos
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_grupo (
        nk_frota_origem, nk_id_grupo, nome_grupo, codigo_grupo, classe_luxo, valor_diaria, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_grupo, NEW.nome, NEW.codigo, NEW.classe_luxo,
           COALESCE((SELECT valor_diaria FROM locadora.tarifas_grupo WHERE grupo_id = NEW.id_grupo AND data_inicio_vigencia <= CURDATE() AND (data_fim_vigencia IS NULL OR data_fim_vigencia >= CURDATE()) ORDER BY data_inicio_vigencia DESC LIMIT 1), 0),
           NOW()
    ON DUPLICATE KEY UPDATE
        nome_grupo = VALUES(nome_grupo), codigo_grupo = VALUES(codigo_grupo),
        classe_luxo = VALUES(classe_luxo), valor_diaria = VALUES(valor_diaria), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_grupo_au//
CREATE TRIGGER locadora.trg_extrai_gupessanha_grupo_au
AFTER UPDATE ON locadora.grupos
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_grupo (
        nk_frota_origem, nk_id_grupo, nome_grupo, codigo_grupo, classe_luxo, valor_diaria, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_grupo, NEW.nome, NEW.codigo, NEW.classe_luxo,
           COALESCE((SELECT valor_diaria FROM locadora.tarifas_grupo WHERE grupo_id = NEW.id_grupo AND data_inicio_vigencia <= CURDATE() AND (data_fim_vigencia IS NULL OR data_fim_vigencia >= CURDATE()) ORDER BY data_inicio_vigencia DESC LIMIT 1), 0),
           NOW()
    ON DUPLICATE KEY UPDATE
        nome_grupo = VALUES(nome_grupo), codigo_grupo = VALUES(codigo_grupo),
        classe_luxo = VALUES(classe_luxo), valor_diaria = VALUES(valor_diaria), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_tarifas_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_tarifas_ai
AFTER INSERT ON locadora.tarifas_grupo
FOR EACH ROW
BEGIN
    -- Atualiza o grupo no staging caso a tarifa tenha mudado
    UPDATE staging.stg_gupessanha_grupo
    SET valor_diaria = COALESCE((SELECT valor_diaria FROM locadora.tarifas_grupo WHERE grupo_id = NEW.grupo_id AND data_inicio_vigencia <= CURDATE() AND (data_fim_vigencia IS NULL OR data_fim_vigencia >= CURDATE()) ORDER BY data_inicio_vigencia DESC LIMIT 1), 0),
        dt_extracao = NOW()
    WHERE nk_frota_origem = 'gupessanha' AND nk_id_grupo = NEW.grupo_id;
END//

-- 4.3) Veiculo
DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_veiculo_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_veiculo_ai
AFTER INSERT ON locadora.veiculos
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_veiculo (
        nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
        placa, marca, modelo, versao, mecanizacao, tem_ar_condicionado,
        ano_fabricacao, situacao, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_veiculo, tv.grupo_id, NEW.patio_origem_id,
           NEW.placa, tv.marca, tv.modelo, tv.versao,
           CASE tv.mecanizacao WHEN 'MANUAL' THEN 'MANUAL' WHEN 'AUTOMATICA' THEN 'AUTOMATICO' ELSE tv.mecanizacao END,
           tv.tem_ar_condicionado, NEW.ano_fabricacao, NEW.situacao, NOW()
    FROM locadora.tipos_veiculo tv
    WHERE tv.id_tipo_veiculo = NEW.tipo_veiculo_id
    ON DUPLICATE KEY UPDATE
        nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_origem = VALUES(nk_id_patio_origem),
        placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo), versao = VALUES(versao),
        mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado),
        situacao = VALUES(situacao), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_veiculo_au//
CREATE TRIGGER locadora.trg_extrai_gupessanha_veiculo_au
AFTER UPDATE ON locadora.veiculos
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_veiculo (
        nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
        placa, marca, modelo, versao, mecanizacao, tem_ar_condicionado,
        ano_fabricacao, situacao, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_veiculo, tv.grupo_id, NEW.patio_origem_id,
           NEW.placa, tv.marca, tv.modelo, tv.versao,
           CASE tv.mecanizacao WHEN 'MANUAL' THEN 'MANUAL' WHEN 'AUTOMATICA' THEN 'AUTOMATICO' ELSE tv.mecanizacao END,
           tv.tem_ar_condicionado, NEW.ano_fabricacao, NEW.situacao, NOW()
    FROM locadora.tipos_veiculo tv
    WHERE tv.id_tipo_veiculo = NEW.tipo_veiculo_id
    ON DUPLICATE KEY UPDATE
        nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_origem = VALUES(nk_id_patio_origem),
        placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo), versao = VALUES(versao),
        mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado),
        situacao = VALUES(situacao), dt_extracao = NOW();
END//

-- 4.4) Cliente
DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_cliente_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_cliente_ai
AFTER INSERT ON locadora.clientes
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_cliente (
        nk_frota_origem, nk_id_cliente, tipo_cliente, nome, email, cidade_origem, end_uf, end_cidade,
        cpf, cnpj, nome_fantasia, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_cliente, NEW.tipo_pessoa, NEW.nome_razao_social, NEW.email, NEW.cidade_origem, NEW.end_uf, NEW.end_cidade,
           pf.cpf, pj.cnpj, pj.nome_fantasia, NOW()
    FROM (SELECT 1) dummy
    LEFT JOIN locadora.clientes_pf pf ON pf.cliente_id = NEW.id_cliente
    LEFT JOIN locadora.clientes_pj pj ON pj.cliente_id = NEW.id_cliente
    ON DUPLICATE KEY UPDATE
        nome = VALUES(nome), email = VALUES(email), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_cliente_au//
CREATE TRIGGER locadora.trg_extrai_gupessanha_cliente_au
AFTER UPDATE ON locadora.clientes
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_cliente (
        nk_frota_origem, nk_id_cliente, tipo_cliente, nome, email, cidade_origem, end_uf, end_cidade,
        cpf, cnpj, nome_fantasia, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_cliente, NEW.tipo_pessoa, NEW.nome_razao_social, NEW.email, NEW.cidade_origem, NEW.end_uf, NEW.end_cidade,
           pf.cpf, pj.cnpj, pj.nome_fantasia, NOW()
    FROM (SELECT 1) dummy
    LEFT JOIN locadora.clientes_pf pf ON pf.cliente_id = NEW.id_cliente
    LEFT JOIN locadora.clientes_pj pj ON pj.cliente_id = NEW.id_cliente
    ON DUPLICATE KEY UPDATE
        nome = VALUES(nome), email = VALUES(email), dt_extracao = NOW();
END//

-- 4.5) Reserva
DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_reserva_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_reserva_ai
AFTER INSERT ON locadora.reservas
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_reserva (
        nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim,
        data_reserva, data_retirada_prevista, data_devolucao_prevista, duracao_prevista_dias, valor_previsto_reserva, status_reserva, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_reserva, NEW.cliente_id, NEW.grupo_id, NEW.patio_retirada_prevista_id, NEW.patio_entrega_prevista_id,
           DATE(NEW.data_hora_reserva), DATE(NEW.data_hora_retirada_prevista), DATE(NEW.data_hora_devolucao_prevista),
           DATEDIFF(DATE(NEW.data_hora_devolucao_prevista), DATE(NEW.data_hora_retirada_prevista)),
           DATEDIFF(DATE(NEW.data_hora_devolucao_prevista), DATE(NEW.data_hora_retirada_prevista)) * COALESCE(t.valor_diaria, 0),
           CASE NEW.estado WHEN 'CONFIRMADA' THEN 'ATIVA' WHEN 'EM_ANALISE' THEN 'ATIVA' WHEN 'EM_FILA_ESPERA' THEN 'ATIVA' WHEN 'CANCELADA' THEN 'CANCELADA' WHEN 'NO_SHOW' THEN 'CANCELADA' WHEN 'EXPIRADA' THEN 'CANCELADA' WHEN 'CONCRETIZADA' THEN 'CONVERTIDA' ELSE NEW.estado END,
           NOW()
    FROM (SELECT 1) dummy
    LEFT JOIN (SELECT grupo_id, valor_diaria, data_inicio_vigencia FROM locadora.tarifas_grupo WHERE (data_fim_vigencia IS NULL OR data_fim_vigencia >= DATE(NEW.data_hora_reserva)) ORDER BY data_inicio_vigencia DESC) t ON t.grupo_id = NEW.grupo_id AND t.data_inicio_vigencia <= DATE(NEW.data_hora_reserva) LIMIT 1
    ON DUPLICATE KEY UPDATE
        status_reserva = VALUES(status_reserva), valor_previsto_reserva = VALUES(valor_previsto_reserva), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_reserva_au//
CREATE TRIGGER locadora.trg_extrai_gupessanha_reserva_au
AFTER UPDATE ON locadora.reservas
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_reserva (
        nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim,
        data_reserva, data_retirada_prevista, data_devolucao_prevista, duracao_prevista_dias, valor_previsto_reserva, status_reserva, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_reserva, NEW.cliente_id, NEW.grupo_id, NEW.patio_retirada_prevista_id, NEW.patio_entrega_prevista_id,
           DATE(NEW.data_hora_reserva), DATE(NEW.data_hora_retirada_prevista), DATE(NEW.data_hora_devolucao_prevista),
           DATEDIFF(DATE(NEW.data_hora_devolucao_prevista), DATE(NEW.data_hora_retirada_prevista)),
           DATEDIFF(DATE(NEW.data_hora_devolucao_prevista), DATE(NEW.data_hora_retirada_prevista)) * COALESCE(t.valor_diaria, 0),
           CASE NEW.estado WHEN 'CONFIRMADA' THEN 'ATIVA' WHEN 'EM_ANALISE' THEN 'ATIVA' WHEN 'EM_FILA_ESPERA' THEN 'ATIVA' WHEN 'CANCELADA' THEN 'CANCELADA' WHEN 'NO_SHOW' THEN 'CANCELADA' WHEN 'EXPIRADA' THEN 'CANCELADA' WHEN 'CONCRETIZADA' THEN 'CONVERTIDA' ELSE NEW.estado END,
           NOW()
    FROM (SELECT 1) dummy
    LEFT JOIN (SELECT grupo_id, valor_diaria, data_inicio_vigencia FROM locadora.tarifas_grupo WHERE (data_fim_vigencia IS NULL OR data_fim_vigencia >= DATE(NEW.data_hora_reserva)) ORDER BY data_inicio_vigencia DESC) t ON t.grupo_id = NEW.grupo_id AND t.data_inicio_vigencia <= DATE(NEW.data_hora_reserva) LIMIT 1
    ON DUPLICATE KEY UPDATE
        status_reserva = VALUES(status_reserva), valor_previsto_reserva = VALUES(valor_previsto_reserva), dt_extracao = NOW();
END//

-- 4.6) Locação
DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_locacao_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_locacao_ai
AFTER INSERT ON locadora.locacoes
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_locacao (
        nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_devolucao,
        data_retirada, data_prev_devolucao, data_real_devolucao, valor_diaria_aplicada, valor_final, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_locacao, NEW.cliente_id, NEW.veiculo_id, tv.grupo_id, COALESCE(NEW.patio_retirada_real_id, NEW.patio_retirada_prevista_id), NEW.patio_entrega_real_id,
           DATE(COALESCE(NEW.data_hora_retirada_real, NEW.data_hora_retirada_prevista)), DATE(NEW.data_hora_devolucao_prevista), DATE(NEW.data_hora_devolucao_real), NEW.valor_diaria_aplicada,
           COALESCE((SELECT SUM(c.valor_total) FROM locadora.cobrancas c WHERE c.locacao_id = NEW.id_locacao AND c.status IN ('PENDENTE', 'PAGA', 'PARCIAL')), 0), NOW()
    FROM locadora.veiculos v
    JOIN locadora.tipos_veiculo tv ON tv.id_tipo_veiculo = v.tipo_veiculo_id
    WHERE v.id_veiculo = NEW.veiculo_id
    ON DUPLICATE KEY UPDATE
        nk_id_patio_devolucao = VALUES(nk_id_patio_devolucao), data_real_devolucao = VALUES(data_real_devolucao), valor_final = VALUES(valor_final), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_locacao_au//
CREATE TRIGGER locadora.trg_extrai_gupessanha_locacao_au
AFTER UPDATE ON locadora.locacoes
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_gupessanha_locacao (
        nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_devolucao,
        data_retirada, data_prev_devolucao, data_real_devolucao, valor_diaria_aplicada, valor_final, dt_extracao
    )
    SELECT 'gupessanha', NEW.id_locacao, NEW.cliente_id, NEW.veiculo_id, tv.grupo_id, COALESCE(NEW.patio_retirada_real_id, NEW.patio_retirada_prevista_id), NEW.patio_entrega_real_id,
           DATE(COALESCE(NEW.data_hora_retirada_real, NEW.data_hora_retirada_prevista)), DATE(NEW.data_hora_devolucao_prevista), DATE(NEW.data_hora_devolucao_real), NEW.valor_diaria_aplicada,
           COALESCE((SELECT SUM(c.valor_total) FROM locadora.cobrancas c WHERE c.locacao_id = NEW.id_locacao AND c.status IN ('PENDENTE', 'PAGA', 'PARCIAL')), 0), NOW()
    FROM locadora.veiculos v
    JOIN locadora.tipos_veiculo tv ON tv.id_tipo_veiculo = v.tipo_veiculo_id
    WHERE v.id_veiculo = NEW.veiculo_id
    ON DUPLICATE KEY UPDATE
        nk_id_patio_devolucao = VALUES(nk_id_patio_devolucao), data_real_devolucao = VALUES(data_real_devolucao), valor_final = VALUES(valor_final), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_cobrancas_ai//
CREATE TRIGGER locadora.trg_extrai_gupessanha_cobrancas_ai
AFTER INSERT ON locadora.cobrancas
FOR EACH ROW
BEGIN
    UPDATE staging.stg_gupessanha_locacao
    SET valor_final = COALESCE((SELECT SUM(c.valor_total) FROM locadora.cobrancas c WHERE c.locacao_id = NEW.locacao_id AND c.status IN ('PENDENTE', 'PAGA', 'PARCIAL')), 0),
        dt_extracao = NOW()
    WHERE nk_frota_origem = 'gupessanha' AND nk_id_locacao = NEW.locacao_id;
END//

DROP TRIGGER IF EXISTS locadora.trg_extrai_gupessanha_cobrancas_au//
CREATE TRIGGER locadora.trg_extrai_gupessanha_cobrancas_au
AFTER UPDATE ON locadora.cobrancas
FOR EACH ROW
BEGIN
    UPDATE staging.stg_gupessanha_locacao
    SET valor_final = COALESCE((SELECT SUM(c.valor_total) FROM locadora.cobrancas c WHERE c.locacao_id = NEW.locacao_id AND c.status IN ('PENDENTE', 'PAGA', 'PARCIAL')), 0),
        dt_extracao = NOW()
    WHERE nk_frota_origem = 'gupessanha' AND nk_id_locacao = NEW.locacao_id;
END//

DELIMITER ;
