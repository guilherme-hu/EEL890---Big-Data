-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)
-- ============================================================================
-- SCRIPT DE CONSULTAS ANALÍTICAS COMPLETO (DQL MYSQL)
-- MODELO DIMENSIONAL: DATA WAREHOUSE DE LOCAÇÃO DE VEÍCULOS
-- ============================================================================
-- Estrutura de Visões Gerenciais:
-- Bloco 1: Visões Essenciais (Inventário, Locações, Reservas, Consumo)
-- Bloco 2: Matriz Logística e Balanço de Pátios
-- Bloco 3: Métricas Financeiras
-- Bloco 4: Qualidade Operacional (SLA)
-- Bloco 5: Auditoria de Dados
-- ============================================================================

USE dw;

-- ============================================================================
-- BLOCO 1: VISÕES ESSENCIAIS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1.1 Controle de Pátio (Inventário Estático)
--Quantos veículos em cada pátio, segmentados por frota (própria vs associada), grupo, marca, modelo e mecanização.
-- ----------------------------------------------------------------------------
SELECT 
    g.nome_grupo,
    CASE 
        WHEN v.nk_frota_origem = p.nk_frota_origem THEN 'FROTA PRÓPRIA'
        ELSE 'FROTA ASSOCIADA' 
    END AS origem_frota,
    v.marca,
    v.modelo,
    v.mecanizacao,
    SUM(f.qtde_veiculos_presentes) AS total_veiculos
FROM dw.fato_inventario_patio f
INNER JOIN dw.dim_tempo t ON f.sk_tempo_referencia = t.sk_tempo
INNER JOIN dw.dim_patio p ON f.sk_patio = p.sk_patio
INNER JOIN dw.dim_veiculo v ON f.sk_veiculo = v.sk_veiculo
INNER JOIN dw.dim_grupo g ON f.sk_grupo = g.sk_grupo
WHERE t.data = CURRENT_DATE - INTERVAL 1 DAY
GROUP BY g.nome_grupo, origem_frota, v.marca, v.modelo, v.mecanizacao
ORDER BY total_veiculos DESC;

-- ----------------------------------------------------------------------------
-- 1.2 Controle das Locações (Contratos Ativos)
-- Quantas locações estão ativas (sem data de devolução real) e qual o tempo decorrido desde a retirada, bem como o tempo restante previsto para devolução.
-- ----------------------------------------------------------------------------
SELECT 
    g.nome_grupo,
    DATEDIFF(CURRENT_DATE, t_ret.data) AS dias_transcorridos,
    DATEDIFF(t_prev.data, CURRENT_DATE) AS dias_restantes_previstos,
    SUM(f.qtde_locacoes) AS veiculos_alugados
FROM dw.fato_locacao f
INNER JOIN dw.dim_grupo g ON f.sk_grupo = g.sk_grupo
INNER JOIN dw.dim_tempo t_ret ON f.sk_tempo_retirada = t_ret.sk_tempo
INNER JOIN dw.dim_tempo t_prev ON f.sk_tempo_prev_devolucao = t_prev.sk_tempo
WHERE f.sk_tempo_real_devolucao IS NULL
GROUP BY g.nome_grupo, dias_transcorridos, dias_restantes_previstos
ORDER BY g.nome_grupo, dias_restantes_previstos ASC;

-- ----------------------------------------------------------------------------
-- 1.3 Controle de Reservas (Projeção de Demanda)
-- Quantas reservas estão ativas (sem data de retirada passada) e qual o horizonte de retirada previsto, segmentado por grupo, pátio de retirada e cidade de origem do cliente.
-- ----------------------------------------------------------------------------
SELECT 
    g.nome_grupo,
    p.nome_patio AS patio_retirada,
    CASE 
         DATEDIFF(t_ret.data, CURRENT_DATE) <= 7 THEN 'Próxima Semana'
        WHEN DATEDIFF(t_ret.data, CURRENT_DATE) <= 30 THEN 'Próximo Mês'
        ELSE 'Longo Prazo' 
    END AS horizonte_retirada,
    f.duracao_prevista_dias,
    e.cidade AS cidade_origem_cliente,
    SUM(f.qtde_reservas) AS total_reservas
FROM dw.fato_reserva f
INNER JOIN dw.dim_grupo g ON f.sk_grupo = g.sk_grupo
INNER JOIN dw.dim_patio p ON f.sk_patio_retirada = p.sk_patio
INNER JOIN dw.dim_tempo t_ret ON f.sk_tempo_prev_retirada = t_ret.sk_tempo
INNER JOIN dw.dim_cliente c ON f.sk_cliente = c.sk_cliente
INNER JOIN dw.dim_endereco e ON c.sk_endereco = e.sk_endereco
WHERE f.dd_status_reserva = 'ATIVA' 
  AND t_ret.data >= CURRENT_DATE
GROUP BY g.nome_grupo, p.nome_patio, horizonte_retirada, f.duracao_prevista_dias, e.cidade
ORDER BY total_reservas DESC;

-- ----------------------------------------------------------------------------
-- 1.4 Análise de Consumo (Preferências e Conversão)
-- Quais grupos de veículos são mais locados, segmentados por cidade de origem do cliente, e qual o volume total de locações realizadas (com data de devolução real) para cada combinação.
-- ----------------------------------------------------------------------------
SELECT 
    g.nome_grupo,
    e.cidade AS cidade_origem_cliente,
    SUM(f.qtde_locacoes) AS volume_locacoes
FROM dw.fato_locacao f
INNER JOIN dw.dim_grupo g ON f.sk_grupo = g.sk_grupo
INNER JOIN dw.dim_cliente c ON f.sk_cliente = c.sk_cliente
INNER JOIN dw.dim_endereco e ON c.sk_endereco = e.sk_endereco
WHERE f.sk_tempo_real_devolucao IS NOT NULL
GROUP BY g.nome_grupo, e.cidade
ORDER BY volume_locacoes DESC;


-- ============================================================================
-- BLOCO 2: MATRIZ LOGÍSTICA E BALANÇO DE PÁTIOS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 2.1 Matriz de Movimentação Logística (Cadeias Estocásticas)
-- ----------------------------------------------------------------------------
SELECT 
    p_origem.nome_patio AS patio_origem,
    p_destino.nome_patio AS patio_destino,
    COUNT(*) AS total_movimentacoes,
    ROUND(
        COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY p_origem.nome_patio), 
        2
    ) AS percentual_movimentacao
FROM dw.fato_locacao f
INNER JOIN dw.dim_patio p_origem ON f.sk_patio_retirada = p_origem.sk_patio
INNER JOIN dw.dim_patio p_destino ON f.sk_patio_devolucao_real = p_destino.sk_patio
WHERE f.sk_tempo_real_devolucao IS NOT NULL
GROUP BY p_origem.nome_patio, p_destino.nome_patio
ORDER BY patio_origem ASC, percentual_movimentacao DESC;

-- ----------------------------------------------------------------------------
-- 2.2 Balanço Logístico (Déficit e Superávit de Frota)
-- Calcula a diferença entre veículos devolvidos e retirados por pátio.
-- ----------------------------------------------------------------------------
WITH saidas AS (
    SELECT sk_patio_retirada AS sk_patio, COUNT(*) AS total_saidas
    FROM dw.fato_locacao
    WHERE sk_patio_devolucao_real IS NOT NULL
    GROUP BY sk_patio_retirada
),
entradas AS (
    SELECT sk_patio_devolucao_real AS sk_patio, COUNT(*) AS total_entradas
    FROM dw.fato_locacao
    WHERE sk_patio_devolucao_real IS NOT NULL
    GROUP BY sk_patio_devolucao_real
)
SELECT
    p.nome_patio,
    p.nk_frota_origem AS empresa,
    COALESCE(e.total_entradas, 0) AS total_entradas,
    COALESCE(s.total_saidas, 0) AS total_saidas,
    (COALESCE(e.total_entradas, 0) - COALESCE(s.total_saidas, 0)) AS saldo_liquido,
    CASE
        WHEN COALESCE(e.total_entradas, 0) > COALESCE(s.total_saidas, 0) THEN 'ACÚMULO'
        WHEN COALESCE(e.total_entradas, 0) < COALESCE(s.total_saidas, 0) THEN 'DÉFICIT'
        ELSE 'EQUILIBRADO'
    END AS situacao
FROM dw.dim_patio p
LEFT JOIN entradas e ON e.sk_patio = p.sk_patio
LEFT JOIN saidas s ON s.sk_patio = p.sk_patio
ORDER BY saldo_liquido ASC;


-- ============================================================================
-- BLOCO 3: MÉTRICAS FINANCEIRAS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 3.1 Receita Consolidada por Empresa, Ano e Mês
-- ----------------------------------------------------------------------------
SELECT
    f.nk_frota_origem AS empresa,
    YEAR(t.data) AS ano,
    MONTH(t.data) AS mes,
    MONTHNAME(t.data) AS nome_mes,
    SUM(f.qtde_locacoes) AS total_locacoes,
    SUM(f.valor_final) AS receita_total,
    ROUND(AVG(f.valor_final), 2) AS ticket_medio
FROM dw.fato_locacao f
INNER JOIN dw.dim_tempo t ON f.sk_tempo_retirada = t.sk_tempo
WHERE f.sk_tempo_real_devolucao IS NOT NULL
GROUP BY f.nk_frota_origem, YEAR(t.data), MONTH(t.data), MONTHNAME(t.data)
ORDER BY f.nk_frota_origem, ano, mes;

-- ----------------------------------------------------------------------------
-- 3.2 Receita e Representatividade Relativa por Grupo de Veículo
-- ----------------------------------------------------------------------------
SELECT
    f.nk_frota_origem AS empresa,
    g.nome_grupo AS grupo,
    g.valor_diaria AS diaria_atual,
    SUM(f.qtde_locacoes) AS total_locacoes,
    SUM(f.valor_final) AS receita_total,
    ROUND(
        SUM(f.valor_final) * 100.0 / SUM(SUM(f.valor_final)) OVER (PARTITION BY f.nk_frota_origem), 
        2
    ) AS pct_receita_empresa
FROM dw.fato_locacao f
INNER JOIN dw.dim_grupo g ON f.sk_grupo = g.sk_grupo
WHERE f.sk_tempo_real_devolucao IS NOT NULL
GROUP BY f.nk_frota_origem, g.nome_grupo, g.valor_diaria
ORDER BY f.nk_frota_origem, receita_total DESC;

-- ----------------------------------------------------------------------------
-- 3.3 Pipeline de Vendas (Receita Potencial de Reservas)
-- ----------------------------------------------------------------------------
SELECT
    f.nk_frota_origem AS empresa,
    YEAR(t_ret.data) AS ano_retirada,
    QUARTER(t_ret.data) AS trimestre_retirada,
    g.nome_grupo AS grupo,
    SUM(f.qtde_reservas) AS total_reservas_ativas,
    SUM(f.valor_previsto_reserva) AS receita_potencial,
    ROUND(AVG(f.duracao_prevista_dias), 1) AS duracao_media_prevista
FROM dw.fato_reserva f
INNER JOIN dw.dim_tempo t_ret ON f.sk_tempo_prev_retirada = t_ret.sk_tempo
INNER JOIN dw.dim_grupo g ON f.sk_grupo = g.sk_grupo
WHERE f.dd_status_reserva = 'ATIVA'
  AND t_ret.data >= CURRENT_DATE
GROUP BY f.nk_frota_origem, YEAR(t_ret.data), QUARTER(t_ret.data), g.nome_grupo
ORDER BY receita_potencial DESC;


-- ============================================================================
-- BLOCO 4: QUALIDADE OPERACIONAL (SLA)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 4.1 SLA de Devoluções (Taxa de Atraso por Grupo)
-- ----------------------------------------------------------------------------
SELECT
    f.nk_frota_origem AS empresa,
    g.nome_grupo AS grupo,
    COUNT(*) AS total_concluidas,
    SUM(IF(t_real.data > t_prev.data, 1, 0)) AS devolvidas_em_atraso,
    ROUND(
        SUM(IF(t_real.data > t_prev.data, 1, 0)) * 100.0 / NULLIF(COUNT(*), 0), 
        2
    ) AS pct_atraso,
    ROUND(
        AVG(IF(t_real.data > t_prev.data, DATEDIFF(t_real.data, t_prev.data), NULL)), 
        1
    ) AS atraso_medio_dias
FROM dw.fato_locacao f
INNER JOIN dw.dim_grupo g ON f.sk_grupo = g.sk_grupo
INNER JOIN dw.dim_tempo t_prev ON f.sk_tempo_prev_devolucao = t_prev.sk_tempo
INNER JOIN dw.dim_tempo t_real ON f.sk_tempo_real_devolucao = t_real.sk_tempo
WHERE f.sk_tempo_real_devolucao IS NOT NULL
GROUP BY f.nk_frota_origem, g.nome_grupo
ORDER BY pct_atraso DESC;

-- ----------------------------------------------------------------------------
-- 4.2 Desvio de Duração (Previsto vs Realizado)
-- ----------------------------------------------------------------------------
SELECT
    f.nk_frota_origem AS empresa,
    g.nome_grupo AS grupo,
    ROUND(AVG(DATEDIFF(t_prev.data, t_ret.data)), 1) AS duracao_prevista_media,
    ROUND(AVG(DATEDIFF(t_real.data, t_ret.data)), 1) AS duracao_real_media,
    ROUND(
        AVG(DATEDIFF(t_real.data, t_ret.data) - DATEDIFF(t_prev.data, t_ret.data)), 
        1
    ) AS desvio_medio_dias
FROM dw.fato_locacao f
INNER JOIN dw.dim_grupo g ON f.sk_grupo = g.sk_grupo
INNER JOIN dw.dim_tempo t_ret ON f.sk_tempo_retirada = t_ret.sk_tempo
INNER JOIN dw.dim_tempo t_prev ON f.sk_tempo_prev_devolucao = t_prev.sk_tempo
INNER JOIN dw.dim_tempo t_real ON f.sk_tempo_real_devolucao = t_real.sk_tempo
WHERE f.sk_tempo_real_devolucao IS NOT NULL
GROUP BY f.nk_frota_origem, g.nome_grupo
ORDER BY ABS(ROUND(AVG(DATEDIFF(t_real.data, t_ret.data) - DATEDIFF(t_prev.data, t_ret.data)), 1)) DESC;


-- ============================================================================
-- BLOCO 5: AUDITORIA DE DADOS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 5.1 Conferência Volumétrica de Registros no DW
-- ----------------------------------------------------------------------------
SELECT 'dim_tempo' AS tabela, COUNT(*) AS registros FROM dw.dim_tempo
UNION ALL
SELECT 'dim_patio', COUNT(*) FROM dw.dim_patio
UNION ALL
SELECT 'dim_grupo', COUNT(*) FROM dw.dim_grupo
UNION ALL
SELECT 'dim_veiculo', COUNT(*) FROM dw.dim_veiculo
UNION ALL
SELECT 'dim_cliente', COUNT(*) FROM dw.dim_cliente
UNION ALL
SELECT 'dim_endereco', COUNT(*) FROM dw.dim_endereco
UNION ALL
SELECT 'fato_inventario_patio', COUNT(*) FROM dw.fato_inventario_patio
UNION ALL
SELECT 'fato_locacao', COUNT(*) FROM dw.fato_locacao
UNION ALL
SELECT 'fato_reserva', COUNT(*) FROM dw.fato_reserva
ORDER BY registros DESC;

-- ----------------------------------------------------------------------------
-- 5.2 Detecção de Anomalias (Locações pendentes com duração irreal > 90 dias)
-- ----------------------------------------------------------------------------
SELECT
    f.nk_frota_origem AS empresa,
    f.nk_id_locacao,
    t_ret.data AS data_retirada,
    DATEDIFF(CURRENT_DATE, t_ret.data) AS dias_em_andamento,
    g.nome_grupo AS grupo
FROM dw.fato_locacao f
INNER JOIN dw.dim_tempo t_ret ON f.sk_tempo_retirada = t_ret.sk_tempo
INNER JOIN dw.dim_grupo g ON f.sk_grupo = g.sk_grupo
WHERE f.sk_tempo_real_devolucao IS NULL
  AND DATEDIFF(CURRENT_DATE, t_ret.data) > 90
ORDER BY dias_em_andamento DESC;
