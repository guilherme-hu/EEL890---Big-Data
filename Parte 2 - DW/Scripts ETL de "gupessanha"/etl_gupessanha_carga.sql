-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)


SET search_path TO dw, staging, public;


--  1) FUNÇÃO AUXILIAR: lookup de sk_tempo por DATE
--     Retorna NULL se a data não estiver populada em dim_tempo (sinaliza para o agendador repovoar a dimensão de tempo).
CREATE OR REPLACE FUNCTION dw.fn_sk_tempo(p_data DATE)
RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT sk_tempo
    FROM   dw.dim_tempo
    WHERE  data = p_data
    LIMIT  1;
$$;

-- Popula dim_tempo para o intervalo necessário se ainda não existir a data
CREATE OR REPLACE PROCEDURE dw.sp_garante_dim_tempo(p_data DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dw.dim_tempo WHERE data = p_data) THEN
        INSERT INTO dw.dim_tempo (
            sk_tempo, data, ano, trimestre, mes,
            semana_ano, dia_semana, nome_mes, nome_dia
        )
        VALUES (
            TO_CHAR(p_data, 'YYYYMMDD')::INTEGER,
            p_data,
            EXTRACT(YEAR   FROM p_data)::INTEGER,
            EXTRACT(QUARTER FROM p_data)::INTEGER,
            EXTRACT(MONTH  FROM p_data)::INTEGER,
            EXTRACT(WEEK   FROM p_data)::INTEGER,
            EXTRACT(ISODOW FROM p_data)::INTEGER,
            TO_CHAR(p_data, 'TMMonth'),
            TO_CHAR(p_data, 'TMDay')
        )
        ON CONFLICT (sk_tempo) DO NOTHING;
    END IF;
END;
$$;



--  2) PROCEDURES DE CARGA — DIMENSÕES

--  2.1) sp_gupessanha_carga_dim_patio
CREATE OR REPLACE PROCEDURE dw.sp_gupessanha_carga_dim_patio()
LANGUAGE plpgsql AS $$
DECLARE v_total INTEGER := 0;
BEGIN

    INSERT INTO dw.dim_patio (
        nk_frota_origem,
        nk_id_patio,
        nome_patio,
        capacidadeVagasPatio,
        endereco
    )
    SELECT
        nk_frota_origem,
        nk_id_patio,
        nome_patio,
        capacidade_vagas,
        endereco
    FROM staging.stg_conf_patio
    WHERE nk_frota_origem = 'gupessanha'
    ON CONFLICT (nk_frota_origem, nk_id_patio) DO UPDATE
        SET nome_patio           = EXCLUDED.nome_patio,
            capacidadeVagasPatio = EXCLUDED.capacidadeVagasPatio,
            endereco             = EXCLUDED.endereco;

    GET DIAGNOSTICS v_total = ROW_COUNT;
END;
$$;


--  2.2) sp_gupessanha_carga_dim_grupo
CREATE OR REPLACE PROCEDURE dw.sp_gupessanha_carga_dim_grupo()
LANGUAGE plpgsql AS $$
DECLARE v_total INTEGER := 0;
BEGIN

    INSERT INTO dw.dim_grupo (
        nk_frota_origem,
        nk_id_grupo,
        nome_grupo,
        valor_diaria
    )
    SELECT
        nk_frota_origem,
        nk_id_grupo,
        nome_grupo,
        valor_diaria
    FROM staging.stg_conf_grupo
    WHERE nk_frota_origem = 'gupessanha'
    ON CONFLICT (nk_frota_origem, nk_id_grupo) DO UPDATE
        SET nome_grupo   = EXCLUDED.nome_grupo,
            valor_diaria = EXCLUDED.valor_diaria;

    GET DIAGNOSTICS v_total = ROW_COUNT;
END;
$$;


--  2.3) sp_gupessanha_carga_dim_veiculo
CREATE OR REPLACE PROCEDURE dw.sp_gupessanha_carga_dim_veiculo()
LANGUAGE plpgsql AS $$
DECLARE v_total INTEGER := 0;
BEGIN

    INSERT INTO dw.dim_veiculo (
        nk_frota_origem,
        nk_id_veiculo,
        placa,
        marca,
        modelo,
        mecanizacao,
        tem_ar_condicionado
    )
    SELECT
        nk_frota_origem,
        nk_id_veiculo,
        placa,
        marca,
        modelo,
        mecanizacao,
        tem_ar_condicionado
    FROM staging.stg_conf_veiculo
    WHERE nk_frota_origem = 'gupessanha'
    ON CONFLICT (nk_frota_origem, nk_id_veiculo) DO UPDATE
        SET placa               = EXCLUDED.placa,
            marca               = EXCLUDED.marca,
            modelo              = EXCLUDED.modelo,
            mecanizacao         = EXCLUDED.mecanizacao,
            tem_ar_condicionado = EXCLUDED.tem_ar_condicionado;

    GET DIAGNOSTICS v_total = ROW_COUNT;
END;
$$;


--  2.4) sp_gupessanha_carga_dim_cliente
CREATE OR REPLACE PROCEDURE dw.sp_gupessanha_carga_dim_cliente()
LANGUAGE plpgsql AS $$
DECLARE v_total INTEGER := 0;
BEGIN

    INSERT INTO dw.dim_cliente (
        nk_frota_origem,
        nk_id_cliente,
        tipo_cliente,
        nome,
        endereço
    )
    SELECT
        nk_frota_origem,
        nk_id_cliente,
        tipo_cliente,
        nome,
        endereco
    FROM staging.stg_conf_cliente
    WHERE nk_frota_origem = 'gupessanha'
    ON CONFLICT (nk_frota_origem, nk_id_cliente) DO UPDATE
        SET tipo_cliente = EXCLUDED.tipo_cliente,
            nome         = EXCLUDED.nome,
            endereço     = EXCLUDED.endereço;

    GET DIAGNOSTICS v_total = ROW_COUNT;
END;
$$;



--  3) PROCEDURES DE CARGA — FATOS

--  3.1) sp_gupessanha_carga_fato_inventario_patio
--       Carrega snapshots diários de veículos em pátios.
--       Garante que as datas existam em Dim_Tempo antes do INSERT.
CREATE OR REPLACE PROCEDURE dw.sp_gupessanha_carga_fato_inventario_patio()
LANGUAGE plpgsql AS $$
DECLARE
    v_total   INTEGER := 0;
    v_rejeit  INTEGER := 0;
    v_data    DATE;
BEGIN

    -- Garante que todas as datas de snapshot existam em Dim_Tempo
    FOR v_data IN
        SELECT DISTINCT data_snapshot
        FROM staging.stg_conf_snapshot_patio
        WHERE nk_frota_origem = 'gupessanha'
    LOOP
        CALL dw.sp_garante_dim_tempo(v_data);
    END LOOP;

    -- Registra rejeitos: snapshots sem SK correspondente nas dimensões
    INSERT INTO staging.stg_rejeitos_ia
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_conf_snapshot_patio', s.nk_frota_origem, s.nk_id_veiculo,
        CASE
            WHEN dw.fn_sk_tempo(s.data_snapshot) IS NULL THEN
                'DATA NÃO ENCONTRADA EM DIM_TEMPO: ' || s.data_snapshot::TEXT
            WHEN dp.sk_patio IS NULL THEN
                'PÁTIO NÃO ENCONTRADO EM DIM_PATIO: nk=' || s.nk_id_patio::TEXT
            WHEN dv.sk_veiculo IS NULL THEN
                'VEÍCULO NÃO ENCONTRADO EM DIM_VEICULO: nk=' || s.nk_id_veiculo::TEXT
            WHEN dg.sk_grupo IS NULL THEN
                'GRUPO NÃO ENCONTRADO EM DIM_GRUPO: nk=' || s.nk_id_grupo::TEXT
        END
    FROM staging.stg_conf_snapshot_patio s
    LEFT JOIN dw.dim_patio dp
        ON dp.nk_frota_origem = s.nk_frota_origem
       AND dp.nk_id_patio = s.nk_id_patio
    LEFT JOIN dw.dim_veiculo dv
        ON dv.nk_frota_origem = s.nk_frota_origem
       AND dv.nk_id_veiculo = s.nk_id_veiculo
    LEFT JOIN dw.dim_grupo dg
        ON dg.nk_frota_origem = s.nk_frota_origem
       AND dg.nk_id_grupo = s.nk_id_grupo
    WHERE s.nk_frota_origem = 'gupessanha'
      AND (
            dw.fn_sk_tempo(s.data_snapshot) IS NULL
         OR dp.sk_patio IS NULL
         OR dv.sk_veiculo IS NULL
         OR dg.sk_grupo IS NULL
      );

    GET DIAGNOSTICS v_rejeit = ROW_COUNT;

    INSERT INTO dw.fato_inventario_patio (
        sk_tempo_referencia,
        sk_patio,
        sk_veiculo,
        sk_grupo,
        qtde_veiculos_presentes
    )
    SELECT
        dw.fn_sk_tempo(s.data_snapshot)   AS sk_tempo_referencia,
        dp.sk_patio,
        dv.sk_veiculo,
        dg.sk_grupo,
        1                                  AS qtde_veiculos_presentes
    FROM staging.stg_conf_snapshot_patio s
    JOIN dw.dim_patio dp
        ON dp.nk_frota_origem = s.nk_frota_origem
       AND dp.nk_id_patio = s.nk_id_patio
    JOIN dw.dim_veiculo dv
        ON dv.nk_frota_origem = s.nk_frota_origem
       AND dv.nk_id_veiculo = s.nk_id_veiculo
    JOIN dw.dim_grupo dg
        ON dg.nk_frota_origem = s.nk_frota_origem
       AND dg.nk_id_grupo = s.nk_id_grupo
    WHERE s.nk_frota_origem = 'gupessanha'
      AND dw.fn_sk_tempo(s.data_snapshot) IS NOT NULL
    ON CONFLICT (sk_tempo_referencia, sk_patio, sk_veiculo) DO UPDATE
        SET sk_grupo               = EXCLUDED.sk_grupo,
            qtde_veiculos_presentes = EXCLUDED.qtde_veiculos_presentes;

    GET DIAGNOSTICS v_total = ROW_COUNT;
END;
$$;


--  3.2) sp_gupessanha_carga_fato_locacao
--       Carrega/atualiza eventos de locação.
--       sk_tempo_real_devolucao e sk_patio_devolucao_real ficam NULL enquanto a locação está em andamento; são preenchidos na próxima execução após a devolução.
CREATE OR REPLACE PROCEDURE dw.sp_gupessanha_carga_fato_locacao()
LANGUAGE plpgsql AS $$
DECLARE
    v_total   INTEGER := 0;
    v_rejeit  INTEGER := 0;
    v_data    DATE;
BEGIN

    -- Garante que todas as datas envolvidas existam em Dim_Tempo
    FOR v_data IN
        SELECT DISTINCT unnest(ARRAY[
            data_retirada,
            data_prev_devolucao,
            data_real_devolucao
        ])
        FROM staging.stg_conf_locacao
        WHERE nk_frota_origem = 'gupessanha'
    LOOP
        IF v_data IS NOT NULL THEN
            CALL dw.sp_garante_dim_tempo(v_data);
        END IF;
    END LOOP;

    -- Registra rejeitos: FKs que não resolvem para SK
    INSERT INTO staging.stg_rejeitos_ia
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_conf_locacao', l.nk_frota_origem, l.nk_id_locacao,
        CASE
            WHEN dw.fn_sk_tempo(l.data_retirada) IS NULL THEN
                'DATA RETIRADA NÃO EM DIM_TEMPO: ' || l.data_retirada::TEXT
            WHEN dc.sk_cliente IS NULL THEN
                'CLIENTE NÃO EM DIM_CLIENTE: nk=' || l.nk_id_cliente::TEXT
            WHEN dv.sk_veiculo IS NULL THEN
                'VEÍCULO NÃO EM DIM_VEICULO: nk=' || l.nk_id_veiculo::TEXT
            WHEN dg.sk_grupo IS NULL THEN
                'GRUPO NÃO EM DIM_GRUPO: nk=' || l.nk_id_grupo::TEXT
            WHEN dp_ret.sk_patio IS NULL THEN
                'PÁTIO RETIRADA NÃO EM DIM_PATIO: nk=' || l.nk_id_patio_retirada::TEXT
        END
    FROM staging.stg_conf_locacao l
    LEFT JOIN dw.dim_cliente dc
        ON dc.nk_frota_origem = l.nk_frota_origem
       AND dc.nk_id_cliente = l.nk_id_cliente
    LEFT JOIN dw.dim_veiculo dv
        ON dv.nk_frota_origem = l.nk_frota_origem
       AND dv.nk_id_veiculo = l.nk_id_veiculo
    LEFT JOIN dw.dim_grupo dg
        ON dg.nk_frota_origem = l.nk_frota_origem
       AND dg.nk_id_grupo = l.nk_id_grupo
    LEFT JOIN dw.dim_patio dp_ret
        ON dp_ret.nk_frota_origem = l.nk_frota_origem
       AND dp_ret.nk_id_patio = l.nk_id_patio_retirada
    WHERE l.nk_frota_origem = 'gupessanha'
      AND (
            dw.fn_sk_tempo(l.data_retirada) IS NULL
         OR dc.sk_cliente IS NULL
         OR dv.sk_veiculo IS NULL
         OR dg.sk_grupo IS NULL
         OR dp_ret.sk_patio IS NULL
      );

    GET DIAGNOSTICS v_rejeit = ROW_COUNT;

    INSERT INTO dw.fato_locacao (
        nk_frota_origem,
        nk_id_locacao,
        sk_tempo_retirada,
        sk_tempo_prev_devolucao,
        sk_tempo_real_devolucao,
        sk_cliente,
        sk_veiculo,
        sk_grupo,
        sk_patio_retirada,
        sk_patio_devolucao_real,
        valor_final,
        qtde_locacoes
    )
    SELECT
        l.nk_frota_origem,
        l.nk_id_locacao,
        dw.fn_sk_tempo(l.data_retirada)          AS sk_tempo_retirada,
        dw.fn_sk_tempo(l.data_prev_devolucao)    AS sk_tempo_prev_devolucao,
        dw.fn_sk_tempo(l.data_real_devolucao)    AS sk_tempo_real_devolucao,   -- NULL se em andamento
        dc.sk_cliente,
        dv.sk_veiculo,
        dg.sk_grupo,
        dp_ret.sk_patio                          AS sk_patio_retirada,
        dp_dev.sk_patio                          AS sk_patio_devolucao_real,   -- NULL se em andamento
        l.valor_final,
        1                                        AS qtde_locacoes
    FROM staging.stg_conf_locacao l
    JOIN dw.dim_cliente dc
        ON dc.nk_frota_origem = l.nk_frota_origem
       AND dc.nk_id_cliente = l.nk_id_cliente
    JOIN dw.dim_veiculo dv
        ON dv.nk_frota_origem = l.nk_frota_origem
       AND dv.nk_id_veiculo = l.nk_id_veiculo
    JOIN dw.dim_grupo dg
        ON dg.nk_frota_origem = l.nk_frota_origem
       AND dg.nk_id_grupo = l.nk_id_grupo
    JOIN dw.dim_patio dp_ret
        ON dp_ret.nk_frota_origem = l.nk_frota_origem
       AND dp_ret.nk_id_patio = l.nk_id_patio_retirada
    LEFT JOIN dw.dim_patio dp_dev
        ON dp_dev.nk_frota_origem = l.nk_frota_origem
       AND dp_dev.nk_id_patio = l.nk_id_patio_devolucao   -- pode ser NULL
    WHERE l.nk_frota_origem = 'gupessanha'
      AND dw.fn_sk_tempo(l.data_retirada) IS NOT NULL
    ON CONFLICT (nk_frota_origem, nk_id_locacao) DO UPDATE
        -- Atualiza apenas campos que podem mudar após a carga inicial
        SET sk_tempo_real_devolucao  = EXCLUDED.sk_tempo_real_devolucao,
            sk_patio_devolucao_real  = EXCLUDED.sk_patio_devolucao_real,
            valor_final              = EXCLUDED.valor_final;

    GET DIAGNOSTICS v_total = ROW_COUNT;
END;
$$;


--  3.3) sp_gupessanha_carga_fato_reserva
--       Carrega/atualiza registros de reserva.
--       dd_status_reserva é dimensão degenerada (armazenado no fato).
--       O status pode mudar de 'ATIVA' → 'CANCELADA' ou 'CONVERTIDA'.
CREATE OR REPLACE PROCEDURE dw.sp_gupessanha_carga_fato_reserva()
LANGUAGE plpgsql AS $$
DECLARE
    v_total   INTEGER := 0;
    v_rejeit  INTEGER := 0;
    v_data    DATE;
BEGIN

    -- Garante datas em Dim_Tempo
    FOR v_data IN
        SELECT DISTINCT unnest(ARRAY[
            data_reserva,
            data_retirada_prevista,
            data_devolucao_prevista
        ])
        FROM staging.stg_conf_reserva
        WHERE nk_frota_origem = 'gupessanha'
    LOOP
        IF v_data IS NOT NULL THEN
            CALL dw.sp_garante_dim_tempo(v_data);
        END IF;
    END LOOP;

    -- Rejeitos
    INSERT INTO staging.stg_rejeitos_ia
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_conf_reserva', r.nk_frota_origem, r.nk_id_reserva,
        CASE
            WHEN dw.fn_sk_tempo(r.data_reserva) IS NULL THEN
                'DATA RESERVA NÃO EM DIM_TEMPO: ' || r.data_reserva::TEXT
            WHEN dc.sk_cliente IS NULL THEN
                'CLIENTE NÃO EM DIM_CLIENTE: nk=' || r.nk_id_cliente::TEXT
            WHEN dg.sk_grupo IS NULL THEN
                'GRUPO NÃO EM DIM_GRUPO: nk=' || r.nk_id_grupo::TEXT
            WHEN dp_ret.sk_patio IS NULL THEN
                'PÁTIO RETIRADA NÃO EM DIM_PATIO: nk=' || r.nk_id_patio_retirada::TEXT
            WHEN dp_fim.sk_patio IS NULL THEN
                'PÁTIO FIM NÃO EM DIM_PATIO: nk=' || r.nk_id_patio_fim::TEXT
        END
    FROM staging.stg_conf_reserva r
    LEFT JOIN dw.dim_cliente dc
        ON dc.nk_frota_origem = r.nk_frota_origem
       AND dc.nk_id_cliente = r.nk_id_cliente
    LEFT JOIN dw.dim_grupo dg
        ON dg.nk_frota_origem = r.nk_frota_origem
       AND dg.nk_id_grupo = r.nk_id_grupo
    LEFT JOIN dw.dim_patio dp_ret
        ON dp_ret.nk_frota_origem = r.nk_frota_origem
       AND dp_ret.nk_id_patio = r.nk_id_patio_retirada
    LEFT JOIN dw.dim_patio dp_fim
        ON dp_fim.nk_frota_origem = r.nk_frota_origem
       AND dp_fim.nk_id_patio = r.nk_id_patio_fim
    WHERE r.nk_frota_origem = 'gupessanha'
      AND (
            dw.fn_sk_tempo(r.data_reserva) IS NULL
         OR dc.sk_cliente IS NULL
         OR dg.sk_grupo IS NULL
         OR dp_ret.sk_patio IS NULL
         OR dp_fim.sk_patio IS NULL
      );

    GET DIAGNOSTICS v_rejeit = ROW_COUNT;

    INSERT INTO dw.fato_reserva (
        nk_frota_origem,
        nk_id_reserva,
        sk_tempo_reserva,
        sk_tempo_prev_retirada,
        sk_tempo_prev_devolucao,
        sk_cliente,
        sk_grupo,
        sk_patio_retirada,
        sk_patio_fim,
        duracao_prevista_dias,
        valor_previsto_reserva,
        dd_status_reserva,
        qtde_reservas
    )
    SELECT
        r.nk_frota_origem,
        r.nk_id_reserva,
        dw.fn_sk_tempo(r.data_reserva)               AS sk_tempo_reserva,
        dw.fn_sk_tempo(r.data_retirada_prevista)      AS sk_tempo_prev_retirada,
        dw.fn_sk_tempo(r.data_devolucao_prevista)     AS sk_tempo_prev_devolucao,
        dc.sk_cliente,
        dg.sk_grupo,
        dp_ret.sk_patio                              AS sk_patio_retirada,
        dp_fim.sk_patio                              AS sk_patio_fim,
        r.duracao_prevista_dias,
        r.valor_previsto_reserva,
        r.status_reserva                             AS dd_status_reserva,
        1                                            AS qtde_reservas
    FROM staging.stg_conf_reserva r
    JOIN dw.dim_cliente dc
        ON dc.nk_frota_origem = r.nk_frota_origem
       AND dc.nk_id_cliente = r.nk_id_cliente
    JOIN dw.dim_grupo dg
        ON dg.nk_frota_origem = r.nk_frota_origem
       AND dg.nk_id_grupo = r.nk_id_grupo
    JOIN dw.dim_patio dp_ret
        ON dp_ret.nk_frota_origem = r.nk_frota_origem
       AND dp_ret.nk_id_patio = r.nk_id_patio_retirada
    JOIN dw.dim_patio dp_fim
        ON dp_fim.nk_frota_origem = r.nk_frota_origem
       AND dp_fim.nk_id_patio = r.nk_id_patio_fim
    WHERE r.nk_frota_origem = 'gupessanha'
      AND dw.fn_sk_tempo(r.data_reserva) IS NOT NULL
    ON CONFLICT (nk_frota_origem, nk_id_reserva) DO UPDATE
        -- Status pode mudar de ATIVA para CANCELADA ou CONVERTIDA
        SET dd_status_reserva      = EXCLUDED.dd_status_reserva,
            valor_previsto_reserva = EXCLUDED.valor_previsto_reserva,
            duracao_prevista_dias  = EXCLUDED.duracao_prevista_dias;

    GET DIAGNOSTICS v_total = ROW_COUNT;
END;
$$;



--  4) PROCEDURE MAIN DE CARGA

CREATE OR REPLACE PROCEDURE dw.sp_gupessanha_carga_completa()
LANGUAGE plpgsql AS $$
BEGIN

    -- Dimensões primeiro (fatos referenciam SKs das dimensões)
    CALL dw.sp_gupessanha_carga_dim_patio();
    CALL dw.sp_gupessanha_carga_dim_grupo();
    CALL dw.sp_gupessanha_carga_dim_veiculo();
    CALL dw.sp_gupessanha_carga_dim_cliente();

    -- Fatos depois
    CALL dw.sp_gupessanha_carga_fato_inventario_patio();
    CALL dw.sp_gupessanha_carga_fato_locacao();
    CALL dw.sp_gupessanha_carga_fato_reserva();

END;
$$;



--  5) SCRIPT DE EXECUÇÃO SEQUENCIAL COMPLETA DO ETL gupessanha
--     (Extração → Transformação → Carga)

/*
  -- Carga full (primeira vez):
  CALL staging.sp_gupessanha_extracao_completa(TRUE);
  CALL staging.sp_gupessanha_transformacao_completa();
  CALL dw.sp_gupessanha_carga_completa();

  -- Carga incremental (execuções subsequentes):
  SET app.ultima_extracao = '2026-05-28 00:00:00';
  CALL staging.sp_gupessanha_extracao_completa(FALSE);
  CALL staging.sp_gupessanha_transformacao_completa();
  CALL dw.sp_gupessanha_carga_completa();

  -- Verificar rejeitos:
  SELECT * FROM staging.vw_ia_qualidade_etl;
  SELECT * FROM staging.stg_rejeitos_ia ORDER BY dt_rejeito DESC LIMIT 50;
*/
