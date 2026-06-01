-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)

--  2) PROCEDURES DE TRANSFORMAÇÃO
--  2.1) sp_prique_transforma_patio
--       T2  Endereços incompletos: concatena logradouro + cidade + UF
--       T11 Capacidade nula → -1 (sentinela "desconhecida")
DELIMITER //
DROP PROCEDURE IF EXISTS staging.sp_prique_transforma_patio//
CREATE PROCEDURE staging.sp_prique_transforma_patio()
BEGIN
    DECLARE v_total   INT DEFAULT 0;

    -- Remove apenas dados do p-rique (preserva dados de outras frotas)
    DELETE FROM staging.stg_conf_patio WHERE nk_frota_origem = 'p-rique';

    INSERT INTO staging.stg_conf_patio (
        nk_frota_origem,
        nk_id_patio,
        nome_patio,
        capacidade_vagas,
        end_cidade,
        end_uf,
        end_pais
    )
    SELECT
        nk_frota_origem,
        nk_id_patio,
        -- T5: trim e title-case básico no nome
        CONCAT(
            UPPER(LEFT(TRIM(nome_patio), 1)),
            LOWER(SUBSTRING(TRIM(nome_patio), 2))
        )                                            AS nome_patio,
        -- T11: capacidade nula → sentinela -1
        COALESCE(capacidade_vagas, -1)               AS capacidade_vagas,
        -- T2: endereço desmembrado para dim_endereco
        COALESCE(NULLIF(TRIM(end_cidade), ''), 'NÃO INFORMADO') AS end_cidade,
        COALESCE(NULLIF(TRIM(end_uf), ''), 'XX')                AS end_uf,
        'Brasil'                                                AS end_pais
    FROM staging.stg_prique_patio
    WHERE nk_frota_origem = 'p-rique';

    SET v_total = ROW_COUNT();
END//


--  2.2) sp_prique_transforma_grupo
--       T10 valor_diaria NULL → 0 com aviso de rejeito (DQ)
DROP PROCEDURE IF EXISTS staging.sp_prique_transforma_grupo//
CREATE PROCEDURE staging.sp_prique_transforma_grupo()
BEGIN
    DECLARE v_total INT DEFAULT 0;

    -- Remove apenas dados do p-rique
    DELETE FROM staging.stg_conf_grupo WHERE nk_frota_origem = 'p-rique';

    -- Registra rejeitos: grupos sem tarifa (qualidade de dados)
    INSERT INTO staging.stg_rejeitos_etl
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_prique_grupo', nk_frota_origem, nk_id_grupo,
        'Grupo sem valor_diaria vigente; será carregado com valor 0,00'
    FROM staging.stg_prique_grupo
    WHERE nk_frota_origem = 'p-rique'
      AND (valor_diaria IS NULL OR valor_diaria = 0);

    INSERT INTO staging.stg_conf_grupo (
        nk_frota_origem,
        nk_id_grupo,
        nome_grupo,
        valor_diaria
    )
    SELECT
        nk_frota_origem,
        nk_id_grupo,
        CONCAT(
            UPPER(LEFT(TRIM(COALESCE(nome_grupo, codigo_grupo, CONCAT('GRUPO ', nk_id_grupo))), 1)),
            LOWER(SUBSTRING(TRIM(COALESCE(nome_grupo, codigo_grupo, CONCAT('GRUPO ', nk_id_grupo))), 2))
        ),
        COALESCE(valor_diaria, 0)
    FROM staging.stg_prique_grupo
    WHERE nk_frota_origem = 'p-rique';

    SET v_total = ROW_COUNT();
END//


--  2.3) sp_prique_transforma_veiculo
DROP PROCEDURE IF EXISTS staging.sp_prique_transforma_veiculo//
CREATE PROCEDURE staging.sp_prique_transforma_veiculo()
BEGIN
    DECLARE v_total  INT DEFAULT 0;
    DECLARE v_rejeit INT DEFAULT 0;

    -- Remove apenas dados do p-rique
    DELETE FROM staging.stg_conf_veiculo WHERE nk_frota_origem = 'p-rique';

    -- Rejeita veículos sem grupo (inconsistência de FK)
    INSERT INTO staging.stg_rejeitos_etl
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_prique_veiculo', nk_frota_origem, nk_id_veiculo,
        'Veículo sem nk_id_grupo (Id_categoria)'
    FROM staging.stg_prique_veiculo
    WHERE nk_frota_origem = 'p-rique'
      AND nk_id_grupo IS NULL;

    SET v_rejeit = ROW_COUNT();

    INSERT INTO staging.stg_conf_veiculo (
        nk_frota_origem,
        nk_id_veiculo,
        nk_id_grupo,
        nk_id_patio_origem,
        placa,
        marca,
        modelo,
        mecanizacao,
        tem_ar_condicionado
    )
    SELECT
        nk_frota_origem,
        nk_id_veiculo,
        nk_id_grupo,
        -- Pátio de origem: sentinela 0 quando veículo está fora do pátio
        -- (em locação ativa, sem Vaga atribuída no OLTP Amarelo).
        -- Este campo NÃO é carregado em dim_veiculo, então o sentinela é seguro.
        COALESCE(nk_id_patio_origem, 0)          AS nk_id_patio_origem,
        UPPER(TRIM(placa))                       AS placa,
        CONCAT(
            UPPER(LEFT(TRIM(COALESCE(marca, 'NÃO INFORMADO')), 1)),
            LOWER(SUBSTRING(TRIM(COALESCE(marca, 'NÃO INFORMADO')), 2))
        )                                        AS marca,
        CONCAT(
            UPPER(LEFT(TRIM(COALESCE(modelo, 'NÃO INFORMADO')), 1)),
            LOWER(SUBSTRING(TRIM(COALESCE(modelo, 'NÃO INFORMADO')), 2))
        )                                        AS modelo,
        -- T4: normaliza mecanização para 'MANUAL' ou 'AUTOMATICO'
        CASE UPPER(TRIM(COALESCE(mecanizacao, '')))
            WHEN 'MANUAL'     THEN 'MANUAL'
            WHEN 'AUTOMATICA' THEN 'AUTOMATICO'
            WHEN 'AUTOMATICO' THEN 'AUTOMATICO'
            ELSE 'NÃO INFORMADO'
        END                                      AS mecanizacao,
        COALESCE(tem_ar_condicionado, FALSE)     AS tem_ar_condicionado
    FROM staging.stg_prique_veiculo
    WHERE nk_frota_origem = 'p-rique'
      AND nk_id_grupo IS NOT NULL;

    SET v_total = ROW_COUNT();
END//


--  2.4) sp_prique_transforma_cliente
--       T2  Endereços incompletos → desnormalizado em string
--       T3  Conformação tipo_cliente
--       T5  Normalização de nome
DROP PROCEDURE IF EXISTS staging.sp_prique_transforma_cliente//
CREATE PROCEDURE staging.sp_prique_transforma_cliente()
BEGIN
    DECLARE v_total  INT DEFAULT 0;
    DECLARE v_rejeit INT DEFAULT 0;

    -- Remove apenas dados do p-rique
    DELETE FROM staging.stg_conf_cliente WHERE nk_frota_origem = 'p-rique';

    -- Rejeita clientes sem tipo definido
    INSERT INTO staging.stg_rejeitos_etl
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_prique_cliente', nk_frota_origem, nk_id_cliente,
        'Cliente sem tipo_cliente (PF/PJ)'
    FROM staging.stg_prique_cliente
    WHERE nk_frota_origem = 'p-rique'
      AND tipo_cliente NOT IN ('PF', 'PJ');

    SET v_rejeit = ROW_COUNT();

    INSERT INTO staging.stg_conf_cliente (
        nk_frota_origem,
        nk_id_cliente,
        tipo_cliente,
        nome,
        end_cidade,
        end_uf,
        end_pais
    )
    SELECT
        nk_frota_origem,
        nk_id_cliente,
        -- T3: garante domínio 'PF'/'PJ'
        UPPER(TRIM(tipo_cliente))                AS tipo_cliente,
        -- T5: trim e normalização básica de nome
        CONCAT(
            UPPER(LEFT(TRIM(COALESCE(nome, 'NÃO IDENTIFICADO')), 1)),
            LOWER(SUBSTRING(TRIM(COALESCE(nome, 'NÃO IDENTIFICADO')), 2))
        )                                        AS nome,
        -- T2: endereço desmembrado para dim_endereco
        COALESCE(NULLIF(TRIM(end_cidade), ''), 'NÃO INFORMADO') AS end_cidade,
        COALESCE(NULLIF(TRIM(end_uf), ''), 'XX')                AS end_uf,
        'Brasil'                                                AS end_pais
    FROM staging.stg_prique_cliente
    WHERE nk_frota_origem = 'p-rique'
      AND tipo_cliente IN ('PF', 'PJ');

    SET v_total = ROW_COUNT();
END//


--  2.5) sp_prique_transforma_reserva
--       T6  Mapeamento de status para vocabulário DW (ATIVA, CANCELADA, CONVERTIDA)
--       T7  Valida duração prevista (deve ser >= 1 dia)
--       T9  Valida consistência de datas
--       T10 NULLs em FKs obrigatórias → rejeito
DROP PROCEDURE IF EXISTS staging.sp_prique_transforma_reserva//
CREATE PROCEDURE staging.sp_prique_transforma_reserva()
BEGIN
    DECLARE v_total  INT DEFAULT 0;
    DECLARE v_rejeit INT DEFAULT 0;

    -- Remove apenas dados do p-rique
    DELETE FROM staging.stg_conf_reserva WHERE nk_frota_origem = 'p-rique';

    -- T9 + T10: rejeita reservas com datas inválidas ou FKs nulas
    INSERT INTO staging.stg_rejeitos_etl
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json)
    SELECT
        'stg_prique_reserva',
        nk_frota_origem,
        nk_id_reserva,
        CASE
            WHEN nk_id_cliente IS NULL            THEN 'Reserva sem cliente'
            WHEN nk_id_grupo IS NULL              THEN 'Reserva sem grupo'
            WHEN nk_id_patio_retirada IS NULL     THEN 'Reserva sem pátio de retirada'
            WHEN nk_id_patio_fim IS NULL          THEN 'Reserva sem pátio de fim'
            WHEN data_reserva IS NULL             THEN 'Reserva sem data de reserva'
            WHEN data_retirada_prevista IS NULL   THEN 'Reserva sem data de retirada prevista'
            WHEN data_devolucao_prevista IS NULL  THEN 'Reserva sem data de devolução prevista'
            WHEN data_devolucao_prevista
               <= data_retirada_prevista          THEN 'Data devolução <= data retirada'
            WHEN COALESCE(duracao_prevista_dias, 0) < 1
                                                  THEN 'Duração prevista inválida (< 1 dia)'
        END AS motivo,
        JSON_OBJECT(
            'nk_id_reserva',           nk_id_reserva,
            'nk_id_cliente',           nk_id_cliente,
            'nk_id_grupo',             nk_id_grupo,
            'nk_id_patio_retirada',    nk_id_patio_retirada,
            'nk_id_patio_fim',         nk_id_patio_fim,
            'data_reserva',            data_reserva,
            'data_retirada_prevista',  data_retirada_prevista,
            'data_devolucao_prevista', data_devolucao_prevista,
            'duracao_prevista_dias',   duracao_prevista_dias,
            'status_reserva',          status_reserva
        )
    FROM staging.stg_prique_reserva s
    WHERE nk_frota_origem = 'p-rique'
      AND (
            nk_id_cliente IS NULL
         OR nk_id_grupo IS NULL
         OR nk_id_patio_retirada IS NULL
         OR nk_id_patio_fim IS NULL
         OR data_reserva IS NULL
         OR data_retirada_prevista IS NULL
         OR data_devolucao_prevista IS NULL
         OR data_devolucao_prevista <= data_retirada_prevista
         OR COALESCE(duracao_prevista_dias, 0) < 1
      );

    SET v_rejeit = ROW_COUNT();

    INSERT INTO staging.stg_conf_reserva (
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
        status_reserva
    )
    SELECT
        s.nk_frota_origem,
        s.nk_id_reserva,
        s.nk_id_cliente,
        s.nk_id_grupo,
        s.nk_id_patio_retirada,
        s.nk_id_patio_fim,
        s.data_reserva,
        s.data_retirada_prevista,
        s.data_devolucao_prevista,
        -- T7: duração recalculada para segurança (mínimo 1 dia)
        GREATEST(DATEDIFF(s.data_devolucao_prevista, s.data_retirada_prevista), 1) AS duracao_prevista_dias,
        -- T8: valor previsto original mantido do OLTP Amarelo (não recálculo para preservar descontos)
        COALESCE(s.valor_previsto_reserva, 0)                         AS valor_previsto_reserva,
        -- T6: status mapeado já vem do staging; confirmamos aqui
        CASE UPPER(TRIM(COALESCE(s.status_reserva, '')))
            WHEN 'ATIVA'      THEN 'ATIVA'
            WHEN 'CANCELADA'  THEN 'CANCELADA'
            WHEN 'CONVERTIDA' THEN 'CONVERTIDA'
            ELSE 'ATIVA'     -- default conservador
        END                                                           AS status_reserva
    FROM staging.stg_prique_reserva s
    LEFT JOIN staging.stg_conf_grupo g
        ON g.nk_frota_origem = s.nk_frota_origem
       AND g.nk_id_grupo = s.nk_id_grupo
    WHERE s.nk_frota_origem = 'p-rique'
      AND s.nk_id_cliente IS NOT NULL
      AND s.nk_id_grupo IS NOT NULL
      AND s.nk_id_patio_retirada IS NOT NULL
      AND s.nk_id_patio_fim IS NOT NULL
      AND s.data_reserva IS NOT NULL
      AND s.data_retirada_prevista IS NOT NULL
      AND s.data_devolucao_prevista IS NOT NULL
      AND s.data_devolucao_prevista > s.data_retirada_prevista
      AND COALESCE(s.duracao_prevista_dias, 0) >= 1;

    SET v_total = ROW_COUNT();
END//


--  2.6) sp_prique_transforma_locacao
--       T8  Cálculo e validação do valor_final
--       T9  Validação de datas (retirada < devolução)
--       T10 NULLs críticos → rejeito
DROP PROCEDURE IF EXISTS staging.sp_prique_transforma_locacao//
CREATE PROCEDURE staging.sp_prique_transforma_locacao()
BEGIN
    DECLARE v_total  INT DEFAULT 0;
    DECLARE v_rejeit INT DEFAULT 0;

    -- Remove apenas dados do p-rique
    DELETE FROM staging.stg_conf_locacao WHERE nk_frota_origem = 'p-rique';

    -- T9 + T10: rejeita locações com dados críticos ausentes/inválidos
    INSERT INTO staging.stg_rejeitos_etl
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito, dados_json)
    SELECT
        'stg_prique_locacao',
        nk_frota_origem,
        nk_id_locacao,
        CASE
            WHEN nk_id_cliente IS NULL         THEN 'Locação sem cliente'
            WHEN nk_id_veiculo IS NULL         THEN 'Locação sem veículo'
            WHEN nk_id_grupo IS NULL           THEN 'Locação sem grupo'
            WHEN nk_id_patio_retirada IS NULL  THEN 'Locação sem pátio de retirada'
            WHEN data_retirada IS NULL         THEN 'Locação sem data de retirada'
            WHEN data_prev_devolucao IS NULL   THEN 'Locação sem data prev. devolução'
            WHEN data_real_devolucao IS NOT NULL
             AND data_real_devolucao < data_retirada
                                                THEN 'Data devolução real anterior à retirada'
        END AS motivo,
        JSON_OBJECT(
            'nk_id_locacao',          nk_id_locacao,
            'nk_id_cliente',          nk_id_cliente,
            'nk_id_veiculo',          nk_id_veiculo,
            'nk_id_grupo',            nk_id_grupo,
            'nk_id_patio_retirada',   nk_id_patio_retirada,
            'data_retirada',          data_retirada,
            'data_prev_devolucao',    data_prev_devolucao,
            'data_real_devolucao',    data_real_devolucao,
            'valor_final',            valor_final
        )
    FROM staging.stg_prique_locacao l
    WHERE nk_frota_origem = 'p-rique'
      AND (
            nk_id_cliente IS NULL
         OR nk_id_veiculo IS NULL
         OR nk_id_grupo IS NULL
         OR nk_id_patio_retirada IS NULL
         OR data_retirada IS NULL
         OR data_prev_devolucao IS NULL
         OR (data_real_devolucao IS NOT NULL AND data_real_devolucao < data_retirada)
      );

    SET v_rejeit = ROW_COUNT();

    INSERT INTO staging.stg_conf_locacao (
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
        valor_final
    )
    SELECT
        l.nk_frota_origem,
        l.nk_id_locacao,
        l.nk_id_cliente,
        l.nk_id_veiculo,
        l.nk_id_grupo,
        l.nk_id_patio_retirada,
        -- Pátio de devolução: NULL mantido se locação em andamento
        l.nk_id_patio_devolucao,
        l.data_retirada,
        l.data_prev_devolucao,
        l.data_real_devolucao,
        -- T8: valor_final calculado na extração; aqui fazemos sanity-check
        -- Se negativo (improvável, mas possível por estornos), força 0
        GREATEST(COALESCE(l.valor_final, 0), 0) AS valor_final
    FROM staging.stg_prique_locacao l
    WHERE l.nk_frota_origem = 'p-rique'
      AND nk_id_cliente IS NOT NULL
      AND nk_id_veiculo IS NOT NULL
      AND nk_id_grupo IS NOT NULL
      AND nk_id_patio_retirada IS NOT NULL
      AND data_retirada IS NOT NULL
      AND data_prev_devolucao IS NOT NULL
      AND (data_real_devolucao IS NULL OR data_real_devolucao >= data_retirada);

    SET v_total = ROW_COUNT();
END//


--  2.7) sp_prique_transforma_snapshot_patio
--       Simples passthrough com validação de NULLs críticos.
DROP PROCEDURE IF EXISTS staging.sp_prique_transforma_snapshot_patio//
CREATE PROCEDURE staging.sp_prique_transforma_snapshot_patio()
BEGIN
    DECLARE v_total INT DEFAULT 0;

    -- Remove apenas dados do p-rique
    DELETE FROM staging.stg_conf_snapshot_patio WHERE nk_frota_origem = 'p-rique';

    -- Rejeita registros com NULLs em FKs
    INSERT INTO staging.stg_rejeitos_etl
        (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
    SELECT
        'stg_prique_snapshot_patio', nk_frota_origem, nk_id_veiculo,
        'Snapshot sem pátio, veículo ou grupo válidos'
    FROM staging.stg_prique_snapshot_patio
    WHERE nk_frota_origem = 'p-rique'
      AND (nk_id_patio IS NULL OR nk_id_veiculo IS NULL
           OR nk_id_grupo IS NULL OR data_snapshot IS NULL);

    INSERT INTO staging.stg_conf_snapshot_patio (
        nk_frota_origem,
        nk_id_patio,
        nk_id_veiculo,
        nk_id_grupo,
        data_snapshot
    )
    SELECT
        nk_frota_origem,
        nk_id_patio,
        nk_id_veiculo,
        nk_id_grupo,
        data_snapshot
    FROM staging.stg_prique_snapshot_patio
    WHERE nk_frota_origem = 'p-rique'
      AND nk_id_patio IS NOT NULL
      AND nk_id_veiculo IS NOT NULL
      AND nk_id_grupo IS NOT NULL
      AND data_snapshot IS NOT NULL;

    SET v_total = ROW_COUNT();
END//



-- =========================================================================
--  3) PROCEDURE MAIN DE TRANSFORMAÇÃO
-- =========================================================================

DROP PROCEDURE IF EXISTS staging.sp_prique_transformacao_completa//
CREATE PROCEDURE staging.sp_prique_transformacao_completa()
BEGIN

    -- Ordem: dimensões antes de fatos (fatos referenciam conf_grupo para recalcular valor_previsto_reserva)
    CALL staging.sp_prique_transforma_patio();
    CALL staging.sp_prique_transforma_grupo();
    CALL staging.sp_prique_transforma_veiculo();
    CALL staging.sp_prique_transforma_cliente();
    CALL staging.sp_prique_transforma_reserva();
    CALL staging.sp_prique_transforma_locacao();
    CALL staging.sp_prique_transforma_snapshot_patio();

END//

DELIMITER ;


--  4) TRIGGERS DE TRANSFORMAÇÃO (Event-Driven)
--     Substituem as procedures de transformação para operação em tempo real.
--     Cada INSERT/UPDATE no staging bruto (stg_prique_*) dispara a
--     transformação e grava no staging conformado (stg_conf_*).

DELIMITER //

-- 4.1) Patio
DROP TRIGGER IF EXISTS staging.trg_transforma_prique_patio_ai//
CREATE TRIGGER staging.trg_transforma_prique_patio_ai
AFTER INSERT ON staging.stg_prique_patio
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_conf_patio (
        nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas,
        end_cidade, end_uf, end_pais
    ) VALUES (
        NEW.nk_frota_origem, NEW.nk_id_patio,
        CONCAT(UPPER(LEFT(TRIM(NEW.nome_patio), 1)), LOWER(SUBSTRING(TRIM(NEW.nome_patio), 2))),
        COALESCE(NEW.capacidade_vagas, -1),
        COALESCE(NULLIF(TRIM(NEW.end_cidade), ''), 'NÃO INFORMADO'),
        COALESCE(NULLIF(TRIM(NEW.end_uf), ''), 'XX'), 'Brasil'
    ) ON DUPLICATE KEY UPDATE
        nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas),
        end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf);
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_prique_patio_au//
CREATE TRIGGER staging.trg_transforma_prique_patio_au
AFTER UPDATE ON staging.stg_prique_patio
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_conf_patio (
        nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas,
        end_cidade, end_uf, end_pais
    ) VALUES (
        NEW.nk_frota_origem, NEW.nk_id_patio,
        CONCAT(UPPER(LEFT(TRIM(NEW.nome_patio), 1)), LOWER(SUBSTRING(TRIM(NEW.nome_patio), 2))),
        COALESCE(NEW.capacidade_vagas, -1),
        COALESCE(NULLIF(TRIM(NEW.end_cidade), ''), 'NÃO INFORMADO'),
        COALESCE(NULLIF(TRIM(NEW.end_uf), ''), 'XX'), 'Brasil'
    ) ON DUPLICATE KEY UPDATE
        nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas),
        end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf);
END//

-- 4.2) Grupo
DROP TRIGGER IF EXISTS staging.trg_transforma_prique_grupo_ai//
CREATE TRIGGER staging.trg_transforma_prique_grupo_ai
AFTER INSERT ON staging.stg_prique_grupo
FOR EACH ROW
BEGIN
    IF NEW.valor_diaria IS NULL OR NEW.valor_diaria = 0 THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_prique_grupo', NEW.nk_frota_origem, NEW.nk_id_grupo, 'Grupo sem valor_diaria vigente; será carregado com valor 0,00');
    END IF;

    INSERT INTO staging.stg_conf_grupo (
        nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria
    ) VALUES (
        NEW.nk_frota_origem, NEW.nk_id_grupo,
        CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome_grupo, CONCAT('GRUPO ', NEW.nk_id_grupo))), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome_grupo, CONCAT('GRUPO ', NEW.nk_id_grupo))), 2))),
        COALESCE(NEW.valor_diaria, 0)
    ) ON DUPLICATE KEY UPDATE
        nome_grupo = VALUES(nome_grupo), valor_diaria = VALUES(valor_diaria);
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_prique_grupo_au//
CREATE TRIGGER staging.trg_transforma_prique_grupo_au
AFTER UPDATE ON staging.stg_prique_grupo
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_conf_grupo (
        nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria
    ) VALUES (
        NEW.nk_frota_origem, NEW.nk_id_grupo,
        CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome_grupo, CONCAT('GRUPO ', NEW.nk_id_grupo))), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome_grupo, CONCAT('GRUPO ', NEW.nk_id_grupo))), 2))),
        COALESCE(NEW.valor_diaria, 0)
    ) ON DUPLICATE KEY UPDATE
        nome_grupo = VALUES(nome_grupo), valor_diaria = VALUES(valor_diaria);
END//

-- 4.3) Veiculo
DROP TRIGGER IF EXISTS staging.trg_transforma_prique_veiculo_ai//
CREATE TRIGGER staging.trg_transforma_prique_veiculo_ai
AFTER INSERT ON staging.stg_prique_veiculo
FOR EACH ROW
BEGIN
    IF NEW.nk_id_grupo IS NULL THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_prique_veiculo', NEW.nk_frota_origem, NEW.nk_id_veiculo, 'Veículo sem nk_id_grupo');
    ELSE
        INSERT INTO staging.stg_conf_veiculo (
            nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
            placa, marca, modelo, mecanizacao, tem_ar_condicionado
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_veiculo, NEW.nk_id_grupo, COALESCE(NEW.nk_id_patio_origem, 0),
            UPPER(TRIM(NEW.placa)),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 2))),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 2))),
            CASE UPPER(TRIM(COALESCE(NEW.mecanizacao, ''))) WHEN 'MANUAL' THEN 'MANUAL' WHEN 'AUTOMATICA' THEN 'AUTOMATICO' WHEN 'AUTOMATICO' THEN 'AUTOMATICO' ELSE 'NÃO INFORMADO' END,
            COALESCE(NEW.tem_ar_condicionado, FALSE)
        ) ON DUPLICATE KEY UPDATE
            nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_origem = VALUES(nk_id_patio_origem),
            placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
            mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_prique_veiculo_au//
CREATE TRIGGER staging.trg_transforma_prique_veiculo_au
AFTER UPDATE ON staging.stg_prique_veiculo
FOR EACH ROW
BEGIN
    IF NEW.nk_id_grupo IS NOT NULL THEN
        INSERT INTO staging.stg_conf_veiculo (
            nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
            placa, marca, modelo, mecanizacao, tem_ar_condicionado
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_veiculo, NEW.nk_id_grupo, COALESCE(NEW.nk_id_patio_origem, 0),
            UPPER(TRIM(NEW.placa)),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.marca, 'NÃO INFORMADO')), 2))),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.modelo, 'NÃO INFORMADO')), 2))),
            CASE UPPER(TRIM(COALESCE(NEW.mecanizacao, ''))) WHEN 'MANUAL' THEN 'MANUAL' WHEN 'AUTOMATICA' THEN 'AUTOMATICO' WHEN 'AUTOMATICO' THEN 'AUTOMATICO' ELSE 'NÃO INFORMADO' END,
            COALESCE(NEW.tem_ar_condicionado, FALSE)
        ) ON DUPLICATE KEY UPDATE
            nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_origem = VALUES(nk_id_patio_origem),
            placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
            mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado);
    END IF;
END//

-- 4.4) Cliente
DROP TRIGGER IF EXISTS staging.trg_transforma_prique_cliente_ai//
CREATE TRIGGER staging.trg_transforma_prique_cliente_ai
AFTER INSERT ON staging.stg_prique_cliente
FOR EACH ROW
BEGIN
    IF NEW.tipo_cliente NOT IN ('PF', 'PJ') THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_prique_cliente', NEW.nk_frota_origem, NEW.nk_id_cliente, 'Cliente sem tipo_cliente (PF/PJ)');
    ELSE
        INSERT INTO staging.stg_conf_cliente (
            nk_frota_origem, nk_id_cliente, tipo_cliente, nome, end_cidade, end_uf, end_pais
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_cliente, UPPER(TRIM(NEW.tipo_cliente)),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome, 'NÃO IDENTIFICADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome, 'NÃO IDENTIFICADO')), 2))),
            COALESCE(NULLIF(TRIM(NEW.end_cidade), ''), 'NÃO INFORMADO'),
            COALESCE(NULLIF(TRIM(NEW.end_uf), ''), 'XX'), 'Brasil'
        ) ON DUPLICATE KEY UPDATE
            tipo_cliente = VALUES(tipo_cliente), nome = VALUES(nome),
            end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_prique_cliente_au//
CREATE TRIGGER staging.trg_transforma_prique_cliente_au
AFTER UPDATE ON staging.stg_prique_cliente
FOR EACH ROW
BEGIN
    IF NEW.tipo_cliente IN ('PF', 'PJ') THEN
        INSERT INTO staging.stg_conf_cliente (
            nk_frota_origem, nk_id_cliente, tipo_cliente, nome, end_cidade, end_uf, end_pais
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_cliente, UPPER(TRIM(NEW.tipo_cliente)),
            CONCAT(UPPER(LEFT(TRIM(COALESCE(NEW.nome, 'NÃO IDENTIFICADO')), 1)), LOWER(SUBSTRING(TRIM(COALESCE(NEW.nome, 'NÃO IDENTIFICADO')), 2))),
            COALESCE(NULLIF(TRIM(NEW.end_cidade), ''), 'NÃO INFORMADO'),
            COALESCE(NULLIF(TRIM(NEW.end_uf), ''), 'XX'), 'Brasil'
        ) ON DUPLICATE KEY UPDATE
            tipo_cliente = VALUES(tipo_cliente), nome = VALUES(nome),
            end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf);
    END IF;
END//

-- 4.5) Reserva
DROP TRIGGER IF EXISTS staging.trg_transforma_prique_reserva_ai//
CREATE TRIGGER staging.trg_transforma_prique_reserva_ai
AFTER INSERT ON staging.stg_prique_reserva
FOR EACH ROW
BEGIN
    IF NEW.nk_id_cliente IS NULL OR NEW.nk_id_grupo IS NULL OR NEW.nk_id_patio_retirada IS NULL OR NEW.nk_id_patio_fim IS NULL OR NEW.data_reserva IS NULL OR NEW.data_retirada_prevista IS NULL OR NEW.data_devolucao_prevista IS NULL OR NEW.data_devolucao_prevista <= NEW.data_retirada_prevista OR COALESCE(NEW.duracao_prevista_dias, 0) < 1 THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_prique_reserva', NEW.nk_frota_origem, NEW.nk_id_reserva, 'Reserva inválida');
    ELSE
        INSERT INTO staging.stg_conf_reserva (
            nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim,
            data_reserva, data_retirada_prevista, data_devolucao_prevista, duracao_prevista_dias, valor_previsto_reserva, status_reserva
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_reserva, NEW.nk_id_cliente, NEW.nk_id_grupo, NEW.nk_id_patio_retirada, NEW.nk_id_patio_fim,
            NEW.data_reserva, NEW.data_retirada_prevista, NEW.data_devolucao_prevista,
            GREATEST(DATEDIFF(NEW.data_devolucao_prevista, NEW.data_retirada_prevista), 1),
            COALESCE(NEW.valor_previsto_reserva, 0),
            CASE UPPER(TRIM(COALESCE(NEW.status_reserva, ''))) WHEN 'ATIVA' THEN 'ATIVA' WHEN 'CANCELADA' THEN 'CANCELADA' WHEN 'CONVERTIDA' THEN 'CONVERTIDA' ELSE 'ATIVA' END
        ) ON DUPLICATE KEY UPDATE
            status_reserva = VALUES(status_reserva), valor_previsto_reserva = VALUES(valor_previsto_reserva);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_prique_reserva_au//
CREATE TRIGGER staging.trg_transforma_prique_reserva_au
AFTER UPDATE ON staging.stg_prique_reserva
FOR EACH ROW
BEGIN
    IF NEW.nk_id_cliente IS NOT NULL AND NEW.nk_id_grupo IS NOT NULL AND NEW.nk_id_patio_retirada IS NOT NULL AND NEW.nk_id_patio_fim IS NOT NULL AND NEW.data_reserva IS NOT NULL AND NEW.data_retirada_prevista IS NOT NULL AND NEW.data_devolucao_prevista IS NOT NULL AND NEW.data_devolucao_prevista > NEW.data_retirada_prevista AND COALESCE(NEW.duracao_prevista_dias, 0) >= 1 THEN
        INSERT INTO staging.stg_conf_reserva (
            nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_fim,
            data_reserva, data_retirada_prevista, data_devolucao_prevista, duracao_prevista_dias, valor_previsto_reserva, status_reserva
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_reserva, NEW.nk_id_cliente, NEW.nk_id_grupo, NEW.nk_id_patio_retirada, NEW.nk_id_patio_fim,
            NEW.data_reserva, NEW.data_retirada_prevista, NEW.data_devolucao_prevista,
            GREATEST(DATEDIFF(NEW.data_devolucao_prevista, NEW.data_retirada_prevista), 1),
            COALESCE(NEW.valor_previsto_reserva, 0),
            CASE UPPER(TRIM(COALESCE(NEW.status_reserva, ''))) WHEN 'ATIVA' THEN 'ATIVA' WHEN 'CANCELADA' THEN 'CANCELADA' WHEN 'CONVERTIDA' THEN 'CONVERTIDA' ELSE 'ATIVA' END
        ) ON DUPLICATE KEY UPDATE
            status_reserva = VALUES(status_reserva), valor_previsto_reserva = VALUES(valor_previsto_reserva);
    END IF;
END//

-- 4.6) Locação
DROP TRIGGER IF EXISTS staging.trg_transforma_prique_locacao_ai//
CREATE TRIGGER staging.trg_transforma_prique_locacao_ai
AFTER INSERT ON staging.stg_prique_locacao
FOR EACH ROW
BEGIN
    IF NEW.nk_id_cliente IS NULL OR NEW.nk_id_veiculo IS NULL OR NEW.nk_id_grupo IS NULL OR NEW.nk_id_patio_retirada IS NULL OR NEW.data_retirada IS NULL OR NEW.data_prev_devolucao IS NULL OR (NEW.data_real_devolucao IS NOT NULL AND NEW.data_real_devolucao < NEW.data_retirada) THEN
        INSERT INTO staging.stg_rejeitos_etl (tabela_origem, nk_frota_origem, nk_id_registro, motivo_rejeito)
        VALUES ('stg_prique_locacao', NEW.nk_frota_origem, NEW.nk_id_locacao, 'Locação inválida');
    ELSE
        INSERT INTO staging.stg_conf_locacao (
            nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_devolucao,
            data_retirada, data_prev_devolucao, data_real_devolucao, valor_final
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_locacao, NEW.nk_id_cliente, NEW.nk_id_veiculo, NEW.nk_id_grupo, NEW.nk_id_patio_retirada, NEW.nk_id_patio_devolucao,
            NEW.data_retirada, NEW.data_prev_devolucao, NEW.data_real_devolucao, GREATEST(COALESCE(NEW.valor_final, 0), 0)
        ) ON DUPLICATE KEY UPDATE
            nk_id_patio_devolucao = VALUES(nk_id_patio_devolucao), data_real_devolucao = VALUES(data_real_devolucao), valor_final = VALUES(valor_final);
    END IF;
END//

DROP TRIGGER IF EXISTS staging.trg_transforma_prique_locacao_au//
CREATE TRIGGER staging.trg_transforma_prique_locacao_au
AFTER UPDATE ON staging.stg_prique_locacao
FOR EACH ROW
BEGIN
    IF NEW.nk_id_cliente IS NOT NULL AND NEW.nk_id_veiculo IS NOT NULL AND NEW.nk_id_grupo IS NOT NULL AND NEW.nk_id_patio_retirada IS NOT NULL AND NEW.data_retirada IS NOT NULL AND NEW.data_prev_devolucao IS NOT NULL AND (NEW.data_real_devolucao IS NULL OR NEW.data_real_devolucao >= NEW.data_retirada) THEN
        INSERT INTO staging.stg_conf_locacao (
            nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo, nk_id_grupo, nk_id_patio_retirada, nk_id_patio_devolucao,
            data_retirada, data_prev_devolucao, data_real_devolucao, valor_final
        ) VALUES (
            NEW.nk_frota_origem, NEW.nk_id_locacao, NEW.nk_id_cliente, NEW.nk_id_veiculo, NEW.nk_id_grupo, NEW.nk_id_patio_retirada, NEW.nk_id_patio_devolucao,
            NEW.data_retirada, NEW.data_prev_devolucao, NEW.data_real_devolucao, GREATEST(COALESCE(NEW.valor_final, 0), 0)
        ) ON DUPLICATE KEY UPDATE
            nk_id_patio_devolucao = VALUES(nk_id_patio_devolucao), data_real_devolucao = VALUES(data_real_devolucao), valor_final = VALUES(valor_final);
    END IF;
END//

DELIMITER ;
