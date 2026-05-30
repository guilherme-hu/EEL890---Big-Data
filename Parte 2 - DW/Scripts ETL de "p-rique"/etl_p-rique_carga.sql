-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)


-- =============================================================================
-- 03_amarelo_load.sql
-- Carga ETL — Staging Conformado Amarelo → Data Warehouse
--
-- Execução: após 02_amarelo_transform.sql
-- Bancos: staging_dw (fonte) → data_warehouse (destino)
--
-- Estratégias de carga por objeto:
--   Dim_Endereco      → INSERT IF NOT EXISTS por NK (cidade, estado, pais)
--   Dim_Grupo         → UPSERT (ON DUPLICATE KEY UPDATE)
--   Dim_Patio         → UPSERT (ON DUPLICATE KEY UPDATE)
--   Dim_Veiculo       → UPSERT (ON DUPLICATE KEY UPDATE)
--   Dim_Cliente       → UPSERT (ON DUPLICATE KEY UPDATE)
--   Fato_Inventario   → UPSERT por (sk_tempo, sk_patio, sk_veiculo)
--   Fato_Locacao      → UPSERT por (nk_frota_origem, nk_id_locacao)
--                        UPDATE em devolução_real e valor_final ao encerrar
--   Fato_Reserva      → UPSERT por (nk_frota_origem, nk_id_reserva)
--                        UPDATE em status ao cancelar ou converter
--
-- Premissa sobre Dim_Tempo:
--   A tabela Dim_Tempo já está pré-populada no DW com sk_tempo = YYYYMMDD
--   (ex: 20260101 para 1º de janeiro de 2026). Nenhuma inserção é feita
--   nela por este script. Se uma data não existir em Dim_Tempo, o registro
--   correspondente na fato será silenciosamente descartado pelo LEFT JOIN.
-- =============================================================================

-- =============================================================================
-- PARTE 1 — CARGA DAS DIMENSÕES (ordem importa: Endereco antes de Cliente)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- D1. DIM_ENDERECO
-- Insere apenas combinações novas de (cidade, estado, pais).
-- A UNIQUE constraint na tabela garante que duplicatas sejam ignoradas.
-- ---------------------------------------------------------------------------
INSERT IGNORE INTO data_warehouse.Dim_Endereco (cidade, estado, pais)
SELECT DISTINCT
    te.cidade,
    te.estado,
    te.pais
FROM staging_dw.stg_amar_t_endereco te;

-- ---------------------------------------------------------------------------
-- D2. DIM_GRUPO  (Categoria Amarelo → Grupo DW)
-- Upsert: atualiza nome e valor da diária se houver mudança no OLTP.
-- ---------------------------------------------------------------------------
INSERT INTO data_warehouse.Dim_Grupo
    (nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria)
SELECT
    tg.frota_origem,
    tg.id_grupo,
    tg.nome_grupo,
    tg.valor_diaria
FROM staging_dw.stg_amar_t_grupo tg
ON DUPLICATE KEY UPDATE
    nome_grupo   = VALUES(nome_grupo),
    valor_diaria = VALUES(valor_diaria);

-- ---------------------------------------------------------------------------
-- D3. DIM_PATIO
-- Upsert: capacidade pode ser atualizada no OLTP.
-- ---------------------------------------------------------------------------
INSERT INTO data_warehouse.Dim_Patio
    (nk_frota_origem, nk_id_patio, nome_patio, capacidadeVagasPatio)
SELECT
    tp.frota_origem,
    tp.id_patio,
    tp.nome_patio,
    tp.capacidade_vagas
FROM staging_dw.stg_amar_t_patio tp
ON DUPLICATE KEY UPDATE
    nome_patio           = VALUES(nome_patio),
    capacidadeVagasPatio = VALUES(capacidadeVagasPatio);

-- ---------------------------------------------------------------------------
-- D4. DIM_VEICULO
-- Upsert: placa, marca, modelo, mecanização e A/C podem ser corrigidos.
-- ---------------------------------------------------------------------------
INSERT INTO data_warehouse.Dim_Veiculo
    (nk_frota_origem, nk_id_veiculo, placa, marca, modelo,
     mecanizacao, tem_ar_condicionado)
SELECT
    tv.frota_origem,
    tv.id_veiculo,
    tv.placa,
    tv.marca,
    tv.modelo,
    tv.mecanizacao,
    tv.tem_ar_condicionado
FROM staging_dw.stg_amar_t_veiculo tv
ON DUPLICATE KEY UPDATE
    placa               = VALUES(placa),
    marca               = VALUES(marca),
    modelo              = VALUES(modelo),
    mecanizacao         = VALUES(mecanizacao),
    tem_ar_condicionado = VALUES(tem_ar_condicionado);

-- ---------------------------------------------------------------------------
-- D5. DIM_CLIENTE
-- Upsert: nome e endereço podem ser atualizados no OLTP.
-- O JOIN com Dim_Endereco resolve a SK a partir de (cidade, estado, pais).
-- Clientes cujo endereço não exista em Dim_Endereco após D1 são descartados;
-- isto só ocorreria se a extração encontrasse um endereco sem cidade E sem UF,
-- neste caso o fallback 'Não Informado' garante que ao menos esse conjunto
-- exista em Dim_Endereco.
-- ---------------------------------------------------------------------------
INSERT INTO data_warehouse.Dim_Cliente
    (nk_frota_origem, nk_id_cliente, tipo_cliente, nome, sk_endereco)
SELECT
    tc.frota_origem,
    tc.id_cliente,
    tc.tipo_cliente,
    tc.nome,
    de.sk_endereco
FROM staging_dw.stg_amar_t_cliente tc
JOIN data_warehouse.Dim_Endereco de
  ON de.cidade = tc.cidade
 AND de.estado = tc.estado
 AND de.pais   = tc.pais
ON DUPLICATE KEY UPDATE
    tipo_cliente = VALUES(tipo_cliente),
    nome         = VALUES(nome),
    sk_endereco  = VALUES(sk_endereco);


-- =============================================================================
-- PARTE 2 — CARGA DA FATO_INVENTARIO_PATIO
-- =============================================================================
-- Snapshot diário: cada execução representa o estado físico dos pátios
-- no final do dia. A PK composta impede duplicatas para o mesmo veículo
-- no mesmo dia; ON DUPLICATE KEY UPDATE atualiza caso o script seja
-- reexecutado no mesmo dia.
-- =============================================================================
INSERT INTO data_warehouse.Fato_Inventario_Patio
    (sk_tempo_referencia, sk_patio, sk_veiculo, sk_grupo, qtde_veiculos_presentes)
SELECT
    -- Converte DATE para inteiro YYYYMMDD (formato da Dim_Tempo)
    CAST(DATE_FORMAT(ti.dt_snapshot, '%Y%m%d') AS UNSIGNED)     AS sk_tempo_referencia,
    dp.sk_patio,
    dv.sk_veiculo,
    dg.sk_grupo,
    1                                                            AS qtde_veiculos_presentes
FROM staging_dw.stg_amar_t_inventario ti
-- Resolve SK do pátio pela NK (frota_origem + id_patio)
JOIN data_warehouse.Dim_Patio dp
  ON dp.nk_frota_origem = ti.frota_origem
 AND dp.nk_id_patio     = ti.id_patio
-- Resolve SK do veículo pela NK (frota_origem + id_veiculo)
JOIN data_warehouse.Dim_Veiculo dv
  ON dv.nk_frota_origem = ti.frota_origem
 AND dv.nk_id_veiculo   = ti.id_veiculo
-- Resolve SK do grupo pela NK (frota_origem + id_categoria)
JOIN data_warehouse.Dim_Grupo dg
  ON dg.nk_frota_origem = ti.frota_origem
 AND dg.nk_id_grupo     = ti.id_grupo
-- Verifica se a data do snapshot existe em Dim_Tempo (pré-populada)
JOIN data_warehouse.Dim_Tempo dt
  ON dt.sk_tempo = CAST(DATE_FORMAT(ti.dt_snapshot, '%Y%m%d') AS UNSIGNED)
ON DUPLICATE KEY UPDATE
    qtde_veiculos_presentes = VALUES(qtde_veiculos_presentes);


-- =============================================================================
-- PARTE 3 — CARGA DA FATO_LOCACAO
-- =============================================================================
-- Estratégia de upsert:
--   - INSERT quando a locação é nova (retirada recém-registrada)
--   - UPDATE nos campos de devolução quando a locação é encerrada:
--       sk_tempo_real_devolucao, sk_patio_devolucao_real, valor_final
-- As locações em aberto terão esses campos como NULL até a devolução.
-- =============================================================================
INSERT INTO data_warehouse.Fato_Locacao (
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
    tl.frota_origem                                                     AS nk_frota_origem,
    tl.id_locacao                                                       AS nk_id_locacao,

    -- SK tempo de retirada (obrigatório: locação sem retirada foi filtrada na T7)
    dt_ret.sk_tempo                                                     AS sk_tempo_retirada,

    -- SK tempo previsão devolução (NULL se reserva não tinha data prevista)
    dt_pd.sk_tempo                                                      AS sk_tempo_prev_devolucao,

    -- SK tempo devolução real (NULL enquanto locação em aberto)
    dt_rd.sk_tempo                                                      AS sk_tempo_real_devolucao,

    dc.sk_cliente,
    dv.sk_veiculo,
    dg.sk_grupo,
    dp_ret.sk_patio                                                     AS sk_patio_retirada,

    -- SK pátio devolução real: NULL se locação ainda em aberto
    dp_dev.sk_patio                                                     AS sk_patio_devolucao_real,

    tl.valor_final,
    1                                                                   AS qtde_locacoes

FROM staging_dw.stg_amar_t_locacao tl

-- Lookup: Cliente
JOIN data_warehouse.Dim_Cliente dc
  ON dc.nk_frota_origem = tl.frota_origem
 AND dc.nk_id_cliente   = tl.id_cliente

-- Lookup: Veículo
JOIN data_warehouse.Dim_Veiculo dv
  ON dv.nk_frota_origem = tl.frota_origem
 AND dv.nk_id_veiculo   = tl.id_veiculo

-- Lookup: Grupo
JOIN data_warehouse.Dim_Grupo dg
  ON dg.nk_frota_origem = tl.frota_origem
 AND dg.nk_id_grupo     = tl.id_grupo

-- Lookup: Pátio de retirada (obrigatório)
JOIN data_warehouse.Dim_Patio dp_ret
  ON dp_ret.nk_frota_origem = tl.frota_origem
 AND dp_ret.nk_id_patio     = tl.id_patio_retirada

-- Lookup: Pátio de devolução real (opcional — NULL enquanto em aberto)
LEFT JOIN data_warehouse.Dim_Patio dp_dev
  ON dp_dev.nk_frota_origem = tl.frota_origem
 AND dp_dev.nk_id_patio     = tl.id_patio_devolucao

-- Lookup: Data de retirada em Dim_Tempo
JOIN data_warehouse.Dim_Tempo dt_ret
  ON dt_ret.sk_tempo = CAST(DATE_FORMAT(tl.data_retirada, '%Y%m%d') AS UNSIGNED)

-- Lookup: Data previsão devolução em Dim_Tempo (LEFT: pode ser NULL)
LEFT JOIN data_warehouse.Dim_Tempo dt_pd
  ON dt_pd.sk_tempo = CAST(DATE_FORMAT(tl.data_prev_devolucao, '%Y%m%d') AS UNSIGNED)

-- Lookup: Data devolução real em Dim_Tempo (LEFT: NULL quando em aberto)
LEFT JOIN data_warehouse.Dim_Tempo dt_rd
  ON dt_rd.sk_tempo = CAST(DATE_FORMAT(tl.data_real_devolucao, '%Y%m%d') AS UNSIGNED)

-- UPSERT: atualiza apenas campos que se completam com a devolução
ON DUPLICATE KEY UPDATE
    sk_tempo_real_devolucao = VALUES(sk_tempo_real_devolucao),
    sk_patio_devolucao_real = VALUES(sk_patio_devolucao_real),
    valor_final             = VALUES(valor_final);


-- =============================================================================
-- PARTE 4 — CARGA DA FATO_RESERVA
-- =============================================================================
-- Estratégia de upsert:
--   - INSERT quando a reserva é nova
--   - UPDATE em dd_status_reserva e valor_previsto quando há alterações
--     (cancelamento, conversão em locação, ajuste de datas)
-- =============================================================================
INSERT INTO data_warehouse.Fato_Reserva (
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
    tr.frota_origem                                                     AS nk_frota_origem,
    tr.id_reserva                                                       AS nk_id_reserva,

    dt_res.sk_tempo                                                     AS sk_tempo_reserva,
    dt_pr.sk_tempo                                                      AS sk_tempo_prev_retirada,
    dt_pd.sk_tempo                                                      AS sk_tempo_prev_devolucao,

    dc.sk_cliente,
    dg.sk_grupo,

    dp_ret.sk_patio                                                     AS sk_patio_retirada,
    dp_fim.sk_patio                                                     AS sk_patio_fim,

    tr.duracao_prevista_dias,
    tr.valor_previsto,
    tr.status_reserva                                                   AS dd_status_reserva,
    1                                                                   AS qtde_reservas

FROM staging_dw.stg_amar_t_reserva tr

-- Lookup: Cliente
JOIN data_warehouse.Dim_Cliente dc
  ON dc.nk_frota_origem = tr.frota_origem
 AND dc.nk_id_cliente   = tr.id_cliente

-- Lookup: Grupo
JOIN data_warehouse.Dim_Grupo dg
  ON dg.nk_frota_origem = tr.frota_origem
 AND dg.nk_id_grupo     = tr.id_grupo

-- Lookup: Pátio de retirada previsto
JOIN data_warehouse.Dim_Patio dp_ret
  ON dp_ret.nk_frota_origem = tr.frota_origem
 AND dp_ret.nk_id_patio     = tr.id_patio_retirada

-- Lookup: Pátio de devolução previsto
JOIN data_warehouse.Dim_Patio dp_fim
  ON dp_fim.nk_frota_origem = tr.frota_origem
 AND dp_fim.nk_id_patio     = tr.id_patio_fim

-- Lookup: Data da reserva em Dim_Tempo
JOIN data_warehouse.Dim_Tempo dt_res
  ON dt_res.sk_tempo = CAST(DATE_FORMAT(tr.data_reserva, '%Y%m%d') AS UNSIGNED)

-- Lookup: Data prevista de retirada em Dim_Tempo
JOIN data_warehouse.Dim_Tempo dt_pr
  ON dt_pr.sk_tempo = CAST(DATE_FORMAT(tr.data_prev_retirada, '%Y%m%d') AS UNSIGNED)

-- Lookup: Data prevista de devolução em Dim_Tempo
JOIN data_warehouse.Dim_Tempo dt_pd
  ON dt_pd.sk_tempo = CAST(DATE_FORMAT(tr.data_prev_devolucao, '%Y%m%d') AS UNSIGNED)

-- UPSERT: status e valor podem mudar quando reserva é cancelada ou convertida
ON DUPLICATE KEY UPDATE
    dd_status_reserva      = VALUES(dd_status_reserva),
    valor_previsto_reserva = VALUES(valor_previsto_reserva),
    duracao_prevista_dias  = VALUES(duracao_prevista_dias);