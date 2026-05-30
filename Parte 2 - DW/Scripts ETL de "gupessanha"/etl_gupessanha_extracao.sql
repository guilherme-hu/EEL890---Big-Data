-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)


SET search_path TO staging, public;

-- Marca o momento desta extração para uso nos metadados
DO $$
BEGIN
    PERFORM set_config('app.extracao_ts', NOW()::TEXT, true);
END $$;



--  1) STAGING: Criação das tabelas (caso ainda não existam)

CREATE SCHEMA IF NOT EXISTS staging;

--  1.1) stg_gupessanha_patio
CREATE TABLE IF NOT EXISTS staging.stg_gupessanha_patio (
    -- Chaves naturais do sistema de origem
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'gupessanha',
    nk_id_patio           INTEGER      NOT NULL,
    -- Atributos
    nome_patio            VARCHAR(100),
    capacidade_vagas      INTEGER,
    end_cidade            VARCHAR(80),
    end_uf                CHAR(2),
    end_logradouro        VARCHAR(150),
    -- Metadados de controle
    dt_extracao           TIMESTAMP    NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_patio)
);

--  1.2) stg_gupessanha_grupo
CREATE TABLE IF NOT EXISTS staging.stg_gupessanha_grupo (
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'gupessanha',
    nk_id_grupo           INTEGER      NOT NULL,
    nome_grupo            VARCHAR(80),
    codigo_grupo          VARCHAR(10),
    classe_luxo           VARCHAR(30),
    -- Tarifa vigente (join com tarifas_grupo para pegar a mais recente)
    valor_diaria          NUMERIC(12,2),
    dt_extracao           TIMESTAMP    NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_grupo)
);


--  1.3) stg_gupessanha_veiculo
CREATE TABLE IF NOT EXISTS staging.stg_gupessanha_veiculo (
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'gupessanha',
    nk_id_veiculo         INTEGER      NOT NULL,
    nk_id_grupo           INTEGER,          -- FK para stg_gupessanha_grupo
    nk_id_patio_origem    INTEGER,          -- FK para stg_gupessanha_patio
    placa                 VARCHAR(10),
    marca                 VARCHAR(50),
    modelo                VARCHAR(60),
    versao                VARCHAR(50),
    mecanizacao           VARCHAR(20),
    tem_ar_condicionado   BOOLEAN,
    ano_fabricacao        INTEGER,
    situacao              VARCHAR(20),
    dt_extracao           TIMESTAMP    NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_veiculo)
);


--  1.4) stg_gupessanha_cliente
CREATE TABLE IF NOT EXISTS staging.stg_gupessanha_cliente (
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'gupessanha',
    nk_id_cliente         INTEGER      NOT NULL,
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
    dt_extracao           TIMESTAMP    NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_cliente)
);


--  1.5) stg_gupessanha_reserva
CREATE TABLE IF NOT EXISTS staging.stg_gupessanha_reserva (
    nk_frota_origem           VARCHAR(10)  NOT NULL DEFAULT 'gupessanha',
    nk_id_reserva             INTEGER      NOT NULL,
    nk_id_cliente             INTEGER,
    nk_id_grupo               INTEGER,
    nk_id_patio_retirada      INTEGER,
    nk_id_patio_fim           INTEGER,
    -- Datas (extraídas como DATE para bater com Dim_Tempo)
    data_reserva              DATE,
    data_retirada_prevista    DATE,
    data_devolucao_prevista   DATE,
    -- Medidas
    duracao_prevista_dias     INTEGER,
    valor_previsto_reserva    NUMERIC(12,2),
    -- Dimensão degenerada
    status_reserva            VARCHAR(30),
    dt_extracao               TIMESTAMP    NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_reserva)
);


--  1.6) stg_gupessanha_locacao
CREATE TABLE IF NOT EXISTS staging.stg_gupessanha_locacao (
    nk_frota_origem           VARCHAR(10)  NOT NULL DEFAULT 'gupessanha',
    nk_id_locacao             INTEGER      NOT NULL,
    nk_id_cliente             INTEGER,
    nk_id_veiculo             INTEGER,
    nk_id_grupo               INTEGER,       -- extraído via veiculos→tipos_veiculo→grupos
    nk_id_patio_retirada      INTEGER,
    nk_id_patio_devolucao     INTEGER,
    -- Datas como DATE
    data_retirada             DATE,
    data_prev_devolucao       DATE,
    data_real_devolucao       DATE,          -- NULL se locação em andamento
    -- Medidas financeiras
    valor_diaria_aplicada     NUMERIC(12,2),
    valor_final               NUMERIC(14,2), -- SUM de cobrancas quando CONCLUIDA
    dt_extracao               TIMESTAMP     NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_locacao)
);


--  1.7) stg_gupessanha_snapshot_patio  (para Fato_Inventario_Patio)
--       Snapshot diário: um registro por veículo em pátio por data.
CREATE TABLE IF NOT EXISTS staging.stg_gupessanha_snapshot_patio (
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'gupessanha',
    nk_id_patio           INTEGER      NOT NULL,
    nk_id_veiculo         INTEGER      NOT NULL,
    nk_id_grupo           INTEGER,
    data_snapshot         DATE         NOT NULL,
    dt_extracao           TIMESTAMP    NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_patio, nk_id_veiculo, data_snapshot)
);


-- Função auxiliar para corte incremental
-- Retorna a data de corte para extração incremental.
CREATE OR REPLACE FUNCTION staging.fn_gupessanha_corte_incremental()
RETURNS TIMESTAMP LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        current_setting('app.ultima_extracao', true)::TIMESTAMP,
        '1900-01-01 00:00:00'::TIMESTAMP
    );
$$;


--  2) PROCEDURES DE EXTRAÇÃO

--  2.1) sp_gupessanha_extrai_patio
--       Carga full (tabela não tem coluna de atualização explícita).
CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_extrai_patio()
LANGUAGE plpgsql AS $$
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
$$;



--  2.2) sp_gupessanha_extrai_grupo
--       Carga full. Inclui JOIN com tarifas_grupo para pegar a tarifa atualmente vigente.
CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_extrai_grupo()
LANGUAGE plpgsql AS $$
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
    LEFT JOIN LATERAL (
        SELECT tg.valor_diaria
        FROM   locadora.tarifas_grupo tg
        WHERE  tg.grupo_id = g.id_grupo
          AND  tg.data_inicio_vigencia <= CURRENT_DATE
          AND  (tg.data_fim_vigencia IS NULL OR tg.data_fim_vigencia >= CURRENT_DATE)
        ORDER BY tg.data_inicio_vigencia DESC
        LIMIT 1
    ) t ON true;

END;
$$;



--  2.3) sp_gupessanha_extrai_veiculo
--       Delta incremental por situacao ou carga full.
--       O OLTP "gupessanha" não tem coluna updated_at em veiculos; usa-se full truncate-reload (tabela de dimensão média).
CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_extrai_veiculo()
LANGUAGE plpgsql AS $$
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
        CASE tv.mecanizacao::TEXT
            WHEN 'MANUAL'     THEN 'MANUAL'
            WHEN 'AUTOMATICA' THEN 'AUTOMATICO'
            ELSE tv.mecanizacao::TEXT
        END                         AS mecanizacao,
        tv.tem_ar_condicionado      AS tem_ar_condicionado,
        v.ano_fabricacao            AS ano_fabricacao,
        v.situacao::TEXT            AS situacao,
        NOW()                       AS dt_extracao
    FROM locadora.veiculos v
    JOIN locadora.tipos_veiculo tv
        ON tv.id_tipo_veiculo = v.tipo_veiculo_id;

END;
$$;



--  2.4  sp_gupessanha_extrai_cliente
--       Carga incremental por data_cadastro.
--       O OLTP não tem updated_at em clientes; clientes existentes raramente mudam, por isso usamos UPSERT baseado em PK.
CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_extrai_cliente()
LANGUAGE plpgsql AS $$
DECLARE
    v_corte TIMESTAMP := staging.fn_gupessanha_corte_incremental();
BEGIN

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
        c.tipo_pessoa::TEXT         AS tipo_cliente,
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
    WHERE c.data_cadastro >= v_corte::DATE
    ON CONFLICT (nk_frota_origem, nk_id_cliente) DO UPDATE
        SET nome         = EXCLUDED.nome,
            email        = EXCLUDED.email,
            dt_extracao  = EXCLUDED.dt_extracao;

END;
$$;



--  2.5  sp_gupessanha_extrai_reserva
--       Delta por data_hora_reserva (coluna WITH TIME ZONE).
--       Também captura atualizações de estado (ex.: CANCELADA).
CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_extrai_reserva()
LANGUAGE plpgsql AS $$
DECLARE
    v_corte TIMESTAMP := staging.fn_gupessanha_corte_incremental();
BEGIN

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
        r.data_hora_reserva::DATE                               AS data_reserva,
        r.data_hora_retirada_prevista::DATE                     AS data_retirada_prevista,
        r.data_hora_devolucao_prevista::DATE                    AS data_devolucao_prevista,
        -- Duração em dias
        (r.data_hora_devolucao_prevista::DATE
            - r.data_hora_retirada_prevista::DATE)              AS duracao_prevista_dias,
        -- Valor previsto = duração × tarifa vigente do grupo
        (r.data_hora_devolucao_prevista::DATE
            - r.data_hora_retirada_prevista::DATE)
            * COALESCE(t.valor_diaria, 0)                       AS valor_previsto_reserva,
        -- Mapeamento de estados para vocabulário do DW
        CASE r.estado::TEXT
            WHEN 'CONFIRMADA'     THEN 'ATIVA'
            WHEN 'EM_ANALISE'     THEN 'ATIVA'
            WHEN 'EM_FILA_ESPERA' THEN 'ATIVA'
            WHEN 'CANCELADA'      THEN 'CANCELADA'
            WHEN 'NO_SHOW'        THEN 'CANCELADA'
            WHEN 'EXPIRADA'       THEN 'CANCELADA'
            WHEN 'CONCRETIZADA'   THEN 'CONVERTIDA'
            ELSE r.estado::TEXT
        END                                                     AS status_reserva,
        NOW()                                                   AS dt_extracao
    FROM locadora.reservas r
    -- Tarifa do grupo vigente no momento da reserva
    LEFT JOIN LATERAL (
        SELECT tg.valor_diaria
        FROM   locadora.tarifas_grupo tg
        WHERE  tg.grupo_id = r.grupo_id
          AND  tg.data_inicio_vigencia <= r.data_hora_reserva::DATE
          AND  (tg.data_fim_vigencia IS NULL OR tg.data_fim_vigencia >= r.data_hora_reserva::DATE)
        ORDER BY tg.data_inicio_vigencia DESC
        LIMIT 1
    ) t ON true
    -- Filtro incremental: novas reservas E estados que podem ter mudado
    -- Obs: sem updated_at, capturamos tudo após a data de reserva e fazemos UPSERT para sobrescrever mudanças de estado.
    WHERE r.data_hora_reserva >= v_corte
    ON CONFLICT (nk_frota_origem, nk_id_reserva) DO UPDATE
        SET status_reserva         = EXCLUDED.status_reserva,
            valor_previsto_reserva = EXCLUDED.valor_previsto_reserva,
            dt_extracao            = EXCLUDED.dt_extracao;

END;
$$;



--  2.6  sp_gupessanha_extrai_locacao
--       Delta por data_hora_retirada_real.
--       O UPSERT é crítico: uma locação pode ser inserida como EM_ANDAMENTO e depois atualizada para CONCLUIDA com devolução e valor_final preenchidos.
CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_extrai_locacao()
LANGUAGE plpgsql AS $$
DECLARE
    v_corte TIMESTAMP := staging.fn_gupessanha_corte_incremental();
BEGIN

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
        COALESCE(l.data_hora_retirada_real,
                 l.data_hora_retirada_prevista)::DATE       AS data_retirada,
        l.data_hora_devolucao_prevista::DATE                AS data_prev_devolucao,
        l.data_hora_devolucao_real::DATE                    AS data_real_devolucao,
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
    ON CONFLICT (nk_frota_origem, nk_id_locacao) DO UPDATE
        SET nk_id_patio_devolucao   = EXCLUDED.nk_id_patio_devolucao,
            data_real_devolucao     = EXCLUDED.data_real_devolucao,
            valor_final             = EXCLUDED.valor_final,
            dt_extracao             = EXCLUDED.dt_extracao;

END;
$$;



--  2.7  sp_gupessanha_extrai_snapshot_patio
--       Reconstrói, para o dia anterior (snapshot diário), quais veículos estavam em cada pátio.
--       Lógica: veículo está no pátio P na data D se:
--         (a) sua última devolução anterior a D foi em P, OU
--         (b) nunca foi alugado após chegar em P (patio_origem) E não há locação ativa cobrindo D.
CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_extrai_snapshot_patio(
    p_data_snapshot DATE DEFAULT (CURRENT_DATE - 1)
)
LANGUAGE plpgsql AS $$
DECLARE
    v_data DATE := p_data_snapshot;
BEGIN

    -- Remove snapshot anterior para este dia (re-execução segura)
    DELETE FROM staging.stg_gupessanha_snapshot_patio
    WHERE data_snapshot = v_data
      AND nk_frota_origem = 'gupessanha';

    -- Insert: para cada veículo ativo, determina em qual pátio estava
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
        SELECT DISTINCT ON (l.veiculo_id)
            l.veiculo_id,
            l.patio_entrega_real_id   AS patio_id_devolvido
        FROM locadora.locacoes l
        WHERE l.status = 'CONCLUIDA'
          AND l.data_hora_devolucao_real::DATE <= v_data
        ORDER BY l.veiculo_id,
                 l.data_hora_devolucao_real DESC
    ),
    -- Veículos que estavam em locação ATIVA na data do snapshot (não devem aparecer no snapshot de pátio)
    em_locacao AS (
        SELECT DISTINCT l.veiculo_id
        FROM locadora.locacoes l
        WHERE l.status IN ('EM_ANDAMENTO', 'EM_ABERTO')
          AND COALESCE(l.data_hora_retirada_real,
                       l.data_hora_retirada_prevista)::DATE <= v_data
          AND (l.data_hora_devolucao_real IS NULL
               OR l.data_hora_devolucao_real::DATE > v_data)
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
$$;



--  3) PROCEDURE MAIN DE EXTRAÇÃO
--     Chama todas as extrações na ordem correta.
--     Parâmetro full_load = TRUE faz carga completa (ignora corte).

CREATE OR REPLACE PROCEDURE staging.sp_gupessanha_extracao_completa(
    p_full_load BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_full_load THEN
        PERFORM set_config('app.ultima_extracao', '1900-01-01 00:00:00', true);
    END IF;

    -- Ordem: dimensões antes de fatos
    CALL staging.sp_gupessanha_extrai_patio();
    CALL staging.sp_gupessanha_extrai_grupo();
    CALL staging.sp_gupessanha_extrai_veiculo();
    CALL staging.sp_gupessanha_extrai_cliente();
    CALL staging.sp_gupessanha_extrai_reserva();
    CALL staging.sp_gupessanha_extrai_locacao();
    CALL staging.sp_gupessanha_extrai_snapshot_patio();
    
END;
$$;
