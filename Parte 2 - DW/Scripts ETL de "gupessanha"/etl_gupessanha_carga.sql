-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)



--  1) FUNÇÃO AUXILIAR: lookup de sk_tempo por DATE
--     Retorna NULL se a data não estiver populada em dim_tempo (sinaliza para o agendador repovoar a dimensão de tempo).
DROP FUNCTION IF EXISTS dw.fn_sk_tempo;
CREATE FUNCTION dw.fn_sk_tempo(p_data DATE)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_sk INT;
    SELECT sk_tempo INTO v_sk
    FROM   dw.dim_tempo
    WHERE  data = p_data
    LIMIT  1;
    RETURN v_sk;
END;

-- Popula dim_tempo para o intervalo necessário se ainda não existir a data
DROP PROCEDURE IF EXISTS dw.sp_garante_dim_tempo;
CREATE PROCEDURE dw.sp_garante_dim_tempo(IN p_data DATE)
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dw.dim_tempo WHERE data = p_data) THEN
        INSERT INTO dw.dim_tempo (
            sk_tempo, data, ano, trimestre, mes,
            semana_ano, dia_semana, nome_mes, nome_dia
        )
        VALUES (
            CAST(DATE_FORMAT(p_data, '%Y%m%d') AS SIGNED),
            p_data,
            YEAR(p_data),
            QUARTER(p_data),
            MONTH(p_data),
            WEEK(p_data, 3),
            -- Em MySQL, DAYOFWEEK retorna 1=domingo; para manter o padrão ISO (1=segunda) usa-se WEEKDAY + 1: WEEKDAY retorna 0=segunda, então +1 resulta em 1=segunda.
            WEEKDAY(p_data) + 1,
            DATE_FORMAT(p_data, '%M'),
            DATE_FORMAT(p_data, '%W')
        )
        ON DUPLICATE KEY UPDATE sk_tempo = sk_tempo;
    END IF;
END;



--  2) PROCEDURES DE CARGA — DIMENSÕES

--  2.0) sp_gupessanha_carga_dim_endereco
DROP PROCEDURE IF EXISTS dw.sp_gupessanha_carga_dim_endereco;
CREATE PROCEDURE dw.sp_gupessanha_carga_dim_endereco()
BEGIN
    INSERT IGNORE INTO dw.dim_endereco (cidade, estado, pais)
    SELECT DISTINCT end_cidade, end_uf, end_pais
    FROM staging.stg_conf_patio
    WHERE nk_frota_origem = 'gupessanha' AND end_cidade IS NOT NULL;

    INSERT IGNORE INTO dw.dim_endereco (cidade, estado, pais)
    SELECT DISTINCT end_cidade, end_uf, end_pais
    FROM staging.stg_conf_cliente
    WHERE nk_frota_origem = 'gupessanha' AND end_cidade IS NOT NULL;
END;

--  2.1) sp_gupessanha_carga_dim_patio
DROP PROCEDURE IF EXISTS dw.sp_gupessanha_carga_dim_patio;
CREATE PROCEDURE dw.sp_gupessanha_carga_dim_patio()
BEGIN
    DECLARE v_total INT DEFAULT 0;

    INSERT INTO dw.dim_patio (
        nk_frota_origem,
        nk_id_patio,
        nome_patio,
        capacidade_vagas_patio,
        sk_endereco
    )
    SELECT
        p.nk_frota_origem,
        p.nk_id_patio,
        p.nome_patio,
        p.capacidade_vagas,
        e.sk_endereco
    FROM staging.stg_conf_patio p
    LEFT JOIN dw.dim_endereco e
        ON e.cidade = p.end_cidade AND e.estado = p.end_uf AND e.pais = p.end_pais
    WHERE p.nk_frota_origem = 'gupessanha'
    ON DUPLICATE KEY UPDATE
        nome_patio             = VALUES(nome_patio),
        capacidade_vagas_patio = VALUES(capacidade_vagas_patio),
        sk_endereco            = VALUES(sk_endereco);

    SET v_total = ROW_COUNT();
END;


--  2.2) sp_gupessanha_carga_dim_grupo
DROP PROCEDURE IF EXISTS dw.sp_gupessanha_carga_dim_grupo;
CREATE PROCEDURE dw.sp_gupessanha_carga_dim_grupo()
BEGIN
    DECLARE v_total INT DEFAULT 0;

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
    ON DUPLICATE KEY UPDATE
        nome_grupo   = VALUES(nome_grupo),
        valor_diaria = VALUES(valor_diaria);

    SET v_total = ROW_COUNT();
END;


--  2.3) sp_gupessanha_carga_dim_veiculo
DROP PROCEDURE IF EXISTS dw.sp_gupessanha_carga_dim_veiculo;
CREATE PROCEDURE dw.sp_gupessanha_carga_dim_veiculo()
BEGIN
    DECLARE v_total INT DEFAULT 0;

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
    ON DUPLICATE KEY UPDATE
        placa               = VALUES(placa),
        marca               = VALUES(marca),
        modelo              = VALUES(modelo),
        mecanizacao         = VALUES(mecanizacao),
        tem_ar_condicionado = VALUES(tem_ar_condicionado);

    SET v_total = ROW_COUNT();
END;


--  2.4) sp_gupessanha_carga_dim_cliente
DROP PROCEDURE IF EXISTS dw.sp_gupessanha_carga_dim_cliente;
CREATE PROCEDURE dw.sp_gupessanha_carga_dim_cliente()
BEGIN
    DECLARE v_total INT DEFAULT 0;

    INSERT INTO dw.dim_cliente (
        nk_frota_origem,
        nk_id_cliente,
        tipo_cliente,
        nome,
        sk_endereco
    )
    SELECT
        c.nk_frota_origem,
        c.nk_id_cliente,
        c.tipo_cliente,
        c.nome,
        e.sk_endereco
    FROM staging.stg_conf_cliente c
    LEFT JOIN dw.dim_endereco e
        ON e.cidade = c.end_cidade AND e.estado = c.end_uf AND e.pais = c.end_pais
    WHERE c.nk_frota_origem = 'gupessanha'
    ON DUPLICATE KEY UPDATE
        tipo_cliente = VALUES(tipo_cliente),
        nome         = VALUES(nome),
        sk_endereco  = VALUES(sk_endereco);

    SET v_total = ROW_COUNT();
END;



--  3) PROCEDURES DE CARGA — FATOS

--  3.1) sp_gupessanha_carga_fato_inventario_patio
--       Carrega snapshots diários de veículos em pátios.
--       Garante que as datas existam em Dim_Tempo antes do INSERT.
DROP PROCEDURE IF EXISTS dw.sp_gupessanha_carga_fato_inventario_patio;
CREATE PROCEDURE dw.sp_gupessanha_carga_fato_inventario_patio()
BEGIN
    DECLARE v_total   INT DEFAULT 0;
    DECLARE v_rejeit  INT DEFAULT 0;
    DECLARE v_data    DATE;
    DECLARE v_done    INT DEFAULT 0;
    DECLARE cur_datas CURSOR FOR
        SELECT DISTINCT data_snapshot
        FROM staging.stg_conf_snapshot_patio
        WHERE nk_frota_origem = 'gupessanha';
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    -- Garante que todas as datas de snapshot existam em Dim_Tempo
    -- CURSOR para iterar sobre as datas distintas e chamar sp_garante_dim_tempo para cada uma.
    OPEN cur_datas;
    loop_datas: LOOP
        FETCH cur_datas INTO v_data;
        IF v_done THEN LEAVE loop_datas; END IF;
        CALL dw.sp_garante_dim_tempo(v_data);
    END LOOP;
    CLOSE cur_datas;

    -- Registra rejeitos: snapshots sem SK correspondente nas dimensões
    INSERT INTO staging.stg_rejeitos_etl
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_conf_snapshot_patio', s.nk_frota_origem, s.nk_id_veiculo,
        CASE
            WHEN dw.fn_sk_tempo(s.data_snapshot) IS NULL THEN
                CONCAT('DATA NÃO ENCONTRADA EM DIM_TEMPO: ', CAST(s.data_snapshot AS CHAR))
            WHEN dp.sk_patio IS NULL THEN
                CONCAT('PÁTIO NÃO ENCONTRADO EM DIM_PATIO: nk=', CAST(s.nk_id_patio AS CHAR))
            WHEN dv.sk_veiculo IS NULL THEN
                CONCAT('VEÍCULO NÃO ENCONTRADO EM DIM_VEICULO: nk=', CAST(s.nk_id_veiculo AS CHAR))
            WHEN dg.sk_grupo IS NULL THEN
                CONCAT('GRUPO NÃO ENCONTRADO EM DIM_GRUPO: nk=', CAST(s.nk_id_grupo AS CHAR))
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

    SET v_rejeit = ROW_COUNT();

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
    ON DUPLICATE KEY UPDATE
        sk_grupo                = VALUES(sk_grupo),
        qtde_veiculos_presentes = VALUES(qtde_veiculos_presentes);

    SET v_total = ROW_COUNT();
END;


--  3.2) sp_gupessanha_carga_fato_locacao
--       Carrega/atualiza eventos de locação.
--       sk_tempo_real_devolucao e sk_patio_devolucao_real ficam NULL enquanto a locação está em andamento; são preenchidos na próxima execução após a devolução.
DROP PROCEDURE IF EXISTS dw.sp_gupessanha_carga_fato_locacao;
CREATE PROCEDURE dw.sp_gupessanha_carga_fato_locacao()
BEGIN
    DECLARE v_total   INT DEFAULT 0;
    DECLARE v_rejeit  INT DEFAULT 0;
    DECLARE v_data    DATE;
    DECLARE v_done    INT DEFAULT 0;
    DECLARE cur_datas CURSOR FOR
        -- CURSOR sobre uma subquery com UNION ALL das três colunas de data para fazer loop
        SELECT DISTINCT dt FROM (
            SELECT data_retirada      AS dt FROM staging.stg_conf_locacao WHERE nk_frota_origem = 'gupessanha' AND data_retirada IS NOT NULL
            UNION ALL
            SELECT data_prev_devolucao               FROM staging.stg_conf_locacao WHERE nk_frota_origem = 'gupessanha' AND data_prev_devolucao IS NOT NULL
            UNION ALL
            SELECT data_real_devolucao               FROM staging.stg_conf_locacao WHERE nk_frota_origem = 'gupessanha' AND data_real_devolucao IS NOT NULL
        ) all_dates;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    -- Garante que todas as datas envolvidas existam em Dim_Tempo
    OPEN cur_datas; 
    loop_datas: LOOP
        FETCH cur_datas INTO v_data;
        IF v_done THEN LEAVE loop_datas; END IF;
        CALL dw.sp_garante_dim_tempo(v_data);
    END LOOP;
    CLOSE cur_datas;

    -- Registra rejeitos: FKs que não resolvem para SK
    INSERT INTO staging.stg_rejeitos_etl
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_conf_locacao', l.nk_frota_origem, l.nk_id_locacao,
        CASE
            WHEN dw.fn_sk_tempo(l.data_retirada) IS NULL THEN
                CONCAT('DATA RETIRADA NÃO EM DIM_TEMPO: ', CAST(l.data_retirada AS CHAR))
            WHEN dc.sk_cliente IS NULL THEN
                CONCAT('CLIENTE NÃO EM DIM_CLIENTE: nk=', CAST(l.nk_id_cliente AS CHAR))
            WHEN dv.sk_veiculo IS NULL THEN
                CONCAT('VEÍCULO NÃO EM DIM_VEICULO: nk=', CAST(l.nk_id_veiculo AS CHAR))
            WHEN dg.sk_grupo IS NULL THEN
                CONCAT('GRUPO NÃO EM DIM_GRUPO: nk=', CAST(l.nk_id_grupo AS CHAR))
            WHEN dp_ret.sk_patio IS NULL THEN
                CONCAT('PÁTIO RETIRADA NÃO EM DIM_PATIO: nk=', CAST(l.nk_id_patio_retirada AS CHAR))
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

    SET v_rejeit = ROW_COUNT();

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
    ON DUPLICATE KEY UPDATE
        -- Atualiza apenas campos que podem mudar após a carga inicial
        sk_tempo_real_devolucao  = VALUES(sk_tempo_real_devolucao),
        sk_patio_devolucao_real  = VALUES(sk_patio_devolucao_real),
        valor_final              = VALUES(valor_final);

    SET v_total = ROW_COUNT();
END;


--  3.3) sp_gupessanha_carga_fato_reserva
--       Carrega/atualiza registros de reserva.
--       dd_status_reserva é dimensão degenerada (armazenado no fato).
--       O status pode mudar de 'ATIVA' → 'CANCELADA' ou 'CONVERTIDA'.
DROP PROCEDURE IF EXISTS dw.sp_gupessanha_carga_fato_reserva;
CREATE PROCEDURE dw.sp_gupessanha_carga_fato_reserva()
BEGIN
    DECLARE v_total   INT DEFAULT 0;
    DECLARE v_rejeit  INT DEFAULT 0;
    DECLARE v_data    DATE;
    DECLARE v_done    INT DEFAULT 0;
    DECLARE cur_datas CURSOR FOR
        -- CURSOR sobre uma subquery com UNION ALL das três colunas de data para fazer loop
        SELECT DISTINCT dt FROM (
            SELECT data_reserva           AS dt FROM staging.stg_conf_reserva WHERE nk_frota_origem = 'gupessanha' AND data_reserva IS NOT NULL
            UNION ALL
            SELECT data_retirada_prevista              FROM staging.stg_conf_reserva WHERE nk_frota_origem = 'gupessanha' AND data_retirada_prevista IS NOT NULL
            UNION ALL
            SELECT data_devolucao_prevista             FROM staging.stg_conf_reserva WHERE nk_frota_origem = 'gupessanha' AND data_devolucao_prevista IS NOT NULL
        ) all_dates;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    -- Garante datas em Dim_Tempo
    OPEN cur_datas;
    loop_datas: LOOP
        FETCH cur_datas INTO v_data;
        IF v_done THEN LEAVE loop_datas; END IF;
        CALL dw.sp_garante_dim_tempo(v_data);
    END LOOP;
    CLOSE cur_datas;

    -- Rejeitos
    INSERT INTO staging.stg_rejeitos_etl
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_conf_reserva', r.nk_frota_origem, r.nk_id_reserva,
        CASE
            WHEN dw.fn_sk_tempo(r.data_reserva) IS NULL THEN
                CONCAT('DATA RESERVA NÃO EM DIM_TEMPO: ', CAST(r.data_reserva AS CHAR))
            WHEN dc.sk_cliente IS NULL THEN
                CONCAT('CLIENTE NÃO EM DIM_CLIENTE: nk=', CAST(r.nk_id_cliente AS CHAR))
            WHEN dg.sk_grupo IS NULL THEN
                CONCAT('GRUPO NÃO EM DIM_GRUPO: nk=', CAST(r.nk_id_grupo AS CHAR))
            WHEN dp_ret.sk_patio IS NULL THEN
                CONCAT('PÁTIO RETIRADA NÃO EM DIM_PATIO: nk=', CAST(r.nk_id_patio_retirada AS CHAR))
            WHEN dp_fim.sk_patio IS NULL THEN
                CONCAT('PÁTIO FIM NÃO EM DIM_PATIO: nk=', CAST(r.nk_id_patio_fim AS CHAR))
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

    SET v_rejeit = ROW_COUNT();

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
    ON DUPLICATE KEY UPDATE
        -- Status pode mudar de ATIVA para CANCELADA ou CONVERTIDA
        dd_status_reserva      = VALUES(dd_status_reserva),
        valor_previsto_reserva = VALUES(valor_previsto_reserva),
        duracao_prevista_dias  = VALUES(duracao_prevista_dias);

    SET v_total = ROW_COUNT();
END;



--  4) PROCEDURE MAIN DE CARGA

DROP PROCEDURE IF EXISTS dw.sp_gupessanha_carga_completa;
CREATE PROCEDURE dw.sp_gupessanha_carga_completa()
BEGIN

    -- Dimensões primeiro (fatos referenciam SKs das dimensões)
    CALL dw.sp_gupessanha_carga_dim_endereco();
    CALL dw.sp_gupessanha_carga_dim_patio();
    CALL dw.sp_gupessanha_carga_dim_grupo();
    CALL dw.sp_gupessanha_carga_dim_veiculo();
    CALL dw.sp_gupessanha_carga_dim_cliente();

    -- Fatos depois
    CALL dw.sp_gupessanha_carga_fato_inventario_patio();
    CALL dw.sp_gupessanha_carga_fato_locacao();
    CALL dw.sp_gupessanha_carga_fato_reserva();

END;



--  5) SCRIPT DE EXECUÇÃO SEQUENCIAL COMPLETA DO ETL gupessanha
--     (Extração → Transformação → Carga)

/*
  -- Carga full (primeira vez):
  CALL staging.sp_gupessanha_extracao_completa(TRUE);
  CALL staging.sp_gupessanha_transformacao_completa();
  CALL dw.sp_gupessanha_carga_completa();

  -- Carga incremental (execuções subsequentes):
  SET @ultima_extracao = '2026-05-28 00:00:00';
  CALL staging.sp_gupessanha_extracao_completa(FALSE);
  CALL staging.sp_gupessanha_transformacao_completa();
  CALL dw.sp_gupessanha_carga_completa();

  -- Verificar rejeitos:
  SELECT * FROM staging.vw_gupessanha_qualidade_etl;
  SELECT * FROM staging.stg_rejeitos_etl ORDER BY dt_rejeito DESC LIMIT 50;
*/
