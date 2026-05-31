-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)


-- =============================================================================
-- etl_p-rique_extracao.sql
-- Extração ETL — OLTP Amarelo (locadora_amarelo) → Área de Staging
--
-- Frota de origem : 'p-rique'
-- Banco fonte     : locadora_amarelo
-- Banco staging   : staging  (mesmo schema usado pelo gupessanha)
--
-- Estratégia de extração:
--   • Todas as entidades usam carga full (TRUNCATE + INSERT), pois o OLTP
--     Amarelo não possui colunas de controle de alteração (updated_at).
--   • Os campos dt_extracao registram o momento da execução para auditoria.
--   • O campo nk_frota_origem = 'p-rique' identifica esta fonte no DW.
--
-- Mapeamento OLTP Amarelo → conceitos do DW:
--   Categoria  → Grupo
--   Vaga/Patio → localização física do veículo
--   Endereco   → desnormalizado em staging (cidade, UF, logradouro)
-- =============================================================================


-- Marca o momento desta extração para uso nos metadados
SET @extracao_ts = NOW();


-- =========================================================================
--  1) STAGING: Criação das tabelas (caso ainda não existam)
-- =========================================================================

CREATE SCHEMA IF NOT EXISTS staging;

--  1.1) stg_prique_patio
CREATE TABLE IF NOT EXISTS staging.stg_prique_patio (
    -- Chaves naturais do sistema de origem
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'p-rique',
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

--  1.2) stg_prique_grupo
--       No OLTP Amarelo, "Categoria" corresponde a "Grupo" no modelo DW.
CREATE TABLE IF NOT EXISTS staging.stg_prique_grupo (
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'p-rique',
    nk_id_grupo           INT          NOT NULL,
    nome_grupo            VARCHAR(80),
    codigo_grupo          VARCHAR(10),
    classe_luxo           VARCHAR(30),
    -- Tarifa vigente (valor_diaria_base da Categoria)
    valor_diaria          DECIMAL(12,2),
    dt_extracao           DATETIME     NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_grupo)
);


--  1.3) stg_prique_veiculo
CREATE TABLE IF NOT EXISTS staging.stg_prique_veiculo (
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'p-rique',
    nk_id_veiculo         INT          NOT NULL,
    nk_id_grupo           INT,          -- FK para stg_prique_grupo (Id_categoria)
    nk_id_patio_origem    INT,          -- FK para stg_prique_patio (via Vaga)
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


--  1.4) stg_prique_cliente
CREATE TABLE IF NOT EXISTS staging.stg_prique_cliente (
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'p-rique',
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


--  1.5) stg_prique_reserva
CREATE TABLE IF NOT EXISTS staging.stg_prique_reserva (
    nk_frota_origem           VARCHAR(10)  NOT NULL DEFAULT 'p-rique',
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


--  1.6) stg_prique_locacao
CREATE TABLE IF NOT EXISTS staging.stg_prique_locacao (
    nk_frota_origem           VARCHAR(10)  NOT NULL DEFAULT 'p-rique',
    nk_id_locacao             INT          NOT NULL,
    nk_id_cliente             INT,
    nk_id_veiculo             INT,
    nk_id_grupo               INT,       -- extraído via Veiculo.Id_categoria
    nk_id_patio_retirada      INT,
    nk_id_patio_devolucao     INT,
    -- Datas como DATE
    data_retirada             DATE,
    data_prev_devolucao       DATE,
    data_real_devolucao       DATE,          -- NULL se locação em andamento
    -- Medidas financeiras
    valor_diaria_aplicada     DECIMAL(12,2),
    valor_final               DECIMAL(14,2),
    dt_extracao               DATETIME      NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_locacao)
);


--  1.7) stg_prique_snapshot_patio  (para Fato_Inventario_Patio)
--       Snapshot diário: um registro por veículo em pátio por data.
--       Veículo está no pátio quando Id_vaga IS NOT NULL.
CREATE TABLE IF NOT EXISTS staging.stg_prique_snapshot_patio (
    nk_frota_origem       VARCHAR(20)  NOT NULL DEFAULT 'p-rique',
    nk_id_patio           INT          NOT NULL,
    nk_id_veiculo         INT          NOT NULL,
    nk_id_grupo           INT,
    data_snapshot         DATE         NOT NULL,
    dt_extracao           DATETIME     NOT NULL DEFAULT NOW(),
    PRIMARY KEY (nk_frota_origem, nk_id_patio, nk_id_veiculo, data_snapshot)
);



-- =========================================================================
--  2) PROCEDURES DE EXTRAÇÃO
-- =========================================================================

--  2.1) sp_prique_extrai_patio
--       Carga full. JOIN com Endereco para obter dados de localização.
DELIMITER //
DROP PROCEDURE IF EXISTS staging.sp_prique_extrai_patio//
CREATE PROCEDURE staging.sp_prique_extrai_patio()
BEGIN

    -- Limpa e recarrega (full load — tabela de dimensão pequena/estável)
    TRUNCATE TABLE staging.stg_prique_patio;

    INSERT INTO staging.stg_prique_patio (
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
        'p-rique'            AS nk_frota_origem,
        p.Id_patio           AS nk_id_patio,
        p.Nome_patio         AS nome_patio,
        p.Capacidade         AS capacidade_vagas,
        e.Cidade             AS end_cidade,
        e.Uf                 AS end_uf,
        e.Logradouro         AS end_logradouro,
        NOW()                AS dt_extracao
    FROM locadora_amarelo.Patio p
    LEFT JOIN locadora_amarelo.Endereco e
        ON e.Id_endereco = p.Id_endereco;

END//


--  2.2) sp_prique_extrai_grupo
--       Carga full. No OLTP Amarelo, Categoria = Grupo do DW.
--       valor_diaria_base é direto na tabela Categoria (sem tarifas_grupo separado).
DROP PROCEDURE IF EXISTS staging.sp_prique_extrai_grupo//
CREATE PROCEDURE staging.sp_prique_extrai_grupo()
BEGIN

    TRUNCATE TABLE staging.stg_prique_grupo;

    INSERT INTO staging.stg_prique_grupo (
        nk_frota_origem,
        nk_id_grupo,
        nome_grupo,
        codigo_grupo,
        classe_luxo,
        valor_diaria,
        dt_extracao
    )
    SELECT
        'p-rique'                         AS nk_frota_origem,
        c.Id_categoria                    AS nk_id_grupo,
        c.Nome_categoria                  AS nome_grupo,
        -- Amarelo não possui codigo_grupo nem classe_luxo
        NULL                              AS codigo_grupo,
        NULL                              AS classe_luxo,
        COALESCE(c.Valor_diaria_base, 0)  AS valor_diaria,
        NOW()                             AS dt_extracao
    FROM locadora_amarelo.Categoria c;

END//


--  2.3) sp_prique_extrai_veiculo
--       Carga full. No Amarelo, marca/modelo estão diretamente em Veiculo
--       (não há tabela tipos_veiculo separada como no gupessanha).
--       O pátio de origem é derivado via Vaga → Patio.
DROP PROCEDURE IF EXISTS staging.sp_prique_extrai_veiculo//
CREATE PROCEDURE staging.sp_prique_extrai_veiculo()
BEGIN

    TRUNCATE TABLE staging.stg_prique_veiculo;

    INSERT INTO staging.stg_prique_veiculo (
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
        'p-rique'                           AS nk_frota_origem,
        v.Id_veiculo                        AS nk_id_veiculo,
        v.Id_categoria                      AS nk_id_grupo,
        -- Pátio de origem: via Vaga (NULL se veículo fora do pátio / em locação)
        vg.Id_patio                         AS nk_id_patio_origem,
        v.Placa                             AS placa,
        v.Marca                             AS marca,
        v.Modelo                            AS modelo,
        -- Amarelo não possui campo versão
        NULL                                AS versao,
        -- Normaliza mecanização para valores esperados pelo DW
        CASE UPPER(TRIM(COALESCE(v.Tipo_cambio, '')))
            WHEN 'MANUAL'     THEN 'MANUAL'
            WHEN 'AUTOMATICO' THEN 'AUTOMATICO'
            WHEN 'AUTOMATICA' THEN 'AUTOMATICO'
            ELSE v.Tipo_cambio
        END                                 AS mecanizacao,
        COALESCE(v.Possui_ar_condicionado, 0) AS tem_ar_condicionado,
        v.Ano                               AS ano_fabricacao,
        v.Status_veiculo                    AS situacao,
        NOW()                               AS dt_extracao
    FROM locadora_amarelo.Veiculo v
    LEFT JOIN locadora_amarelo.Vaga vg
        ON vg.Id_vaga = v.Id_vaga;

END//


--  2.4) sp_prique_extrai_cliente
--       Carga full. Consolida herança PF/PJ em linha única.
--       Endereço extraído via JOIN com tabela Endereco do Amarelo.
DROP PROCEDURE IF EXISTS staging.sp_prique_extrai_cliente//
CREATE PROCEDURE staging.sp_prique_extrai_cliente()
BEGIN

    TRUNCATE TABLE staging.stg_prique_cliente;

    INSERT INTO staging.stg_prique_cliente (
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
        'p-rique'                        AS nk_frota_origem,
        c.Id_cliente                     AS nk_id_cliente,
        c.Tipo_cliente                   AS tipo_cliente,
        -- Unifica nome: PF usa Nome_cliente, PJ usa Razao_social
        CASE
            WHEN UPPER(TRIM(c.Tipo_cliente)) = 'PF' THEN pf.Nome_cliente
            WHEN UPPER(TRIM(c.Tipo_cliente)) = 'PJ' THEN pj.Razao_social
            ELSE COALESCE(pf.Nome_cliente, pj.Razao_social, 'NÃO INFORMADO')
        END                              AS nome,
        c.Email_cliente                  AS email,
        -- Cidade de origem (do Endereco vinculado ao cliente)
        e.Cidade                         AS cidade_origem,
        e.Uf                             AS end_uf,
        e.Cidade                         AS end_cidade,
        -- PF: extrai CPF; PJ: NULL
        pf.Cpf_cliente                   AS cpf,
        -- PJ: extrai CNPJ; PF: NULL
        pj.Cnpj_cliente                  AS cnpj,
        pj.Nome_fantasia                 AS nome_fantasia,
        NOW()                            AS dt_extracao
    FROM locadora_amarelo.Cliente c
    LEFT JOIN locadora_amarelo.Cliente_pf pf ON pf.Id_cliente = c.Id_cliente
    LEFT JOIN locadora_amarelo.Cliente_pj pj ON pj.Id_cliente = c.Id_cliente
    LEFT JOIN locadora_amarelo.Endereco e    ON e.Id_endereco = c.Id_endereco;

END//


--  2.5) sp_prique_extrai_reserva
--       Carga full. Status mapeado para vocabulário DW na extração.
DROP PROCEDURE IF EXISTS staging.sp_prique_extrai_reserva//
CREATE PROCEDURE staging.sp_prique_extrai_reserva()
BEGIN

    TRUNCATE TABLE staging.stg_prique_reserva;

    INSERT INTO staging.stg_prique_reserva (
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
        'p-rique'                                               AS nk_frota_origem,
        r.Id_reserva                                            AS nk_id_reserva,
        r.Id_cliente                                            AS nk_id_cliente,
        r.Id_categoria                                          AS nk_id_grupo,
        r.Id_patio_previsto_retirada                            AS nk_id_patio_retirada,
        r.Id_patio_previsto_devolucao                           AS nk_id_patio_fim,
        -- Trunca para DATE (Dim_Tempo usa DATE)
        DATE(r.Data_hora_reserva)                               AS data_reserva,
        DATE(r.Data_previsao_retirada)                          AS data_retirada_prevista,
        DATE(r.Data_previsao_devolucao)                         AS data_devolucao_prevista,
        -- Duração em dias
        DATEDIFF(
            DATE(r.Data_previsao_devolucao),
            DATE(r.Data_previsao_retirada))                     AS duracao_prevista_dias,
        -- Valor previsto: diretamente da reserva no OLTP Amarelo
        COALESCE(r.Valor_previsto, 0)                           AS valor_previsto_reserva,
        -- Mapeamento de estados para vocabulário do DW
        CASE UPPER(TRIM(COALESCE(r.Status_reserva, '')))
            WHEN 'ATIVO'       THEN 'ATIVA'
            WHEN 'ATIVA'       THEN 'ATIVA'
            WHEN 'ACTIVE'      THEN 'ATIVA'
            WHEN 'ABERTA'      THEN 'ATIVA'
            WHEN 'CANCELADO'   THEN 'CANCELADA'
            WHEN 'CANCELADA'   THEN 'CANCELADA'
            WHEN 'CANCEL'      THEN 'CANCELADA'
            WHEN 'CONVERTIDO'  THEN 'CONVERTIDA'
            WHEN 'CONVERTIDA'  THEN 'CONVERTIDA'
            WHEN 'CONCLUIDO'   THEN 'CONVERTIDA'
            WHEN 'CONCLUIDA'   THEN 'CONVERTIDA'
            WHEN 'FINALIZADO'  THEN 'CONVERTIDA'
            WHEN 'FINALIZADA'  THEN 'CONVERTIDA'
            ELSE COALESCE(TRIM(r.Status_reserva), 'ATIVA')
        END                                                     AS status_reserva,
        NOW()                                                   AS dt_extracao
    FROM locadora_amarelo.Reserva r;

END//


--  2.6) sp_prique_extrai_locacao
--       Carga full. Enriquecida com id_cliente (via Reserva) e id_grupo
--       (via Veiculo.Id_categoria) para simplificar transformação e carga.
DROP PROCEDURE IF EXISTS staging.sp_prique_extrai_locacao//
CREATE PROCEDURE staging.sp_prique_extrai_locacao()
BEGIN

    TRUNCATE TABLE staging.stg_prique_locacao;

    INSERT INTO staging.stg_prique_locacao (
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
        'p-rique'                                       AS nk_frota_origem,
        l.Id_locacao                                    AS nk_id_locacao,
        -- Cliente obtido via Reserva
        r.Id_cliente                                    AS nk_id_cliente,
        l.Id_veiculo                                    AS nk_id_veiculo,
        -- Grupo obtido via Veiculo → Categoria
        v.Id_categoria                                  AS nk_id_grupo,
        l.Id_patio_real_retirada                        AS nk_id_patio_retirada,
        -- Pátio real de devolução (NULL se em andamento)
        l.Id_patio_real_devolucao                       AS nk_id_patio_devolucao,
        -- Datas como DATE
        DATE(l.Data_hora_retirada_real)                 AS data_retirada,
        DATE(r.Data_previsao_devolucao)                 AS data_prev_devolucao,
        DATE(l.Data_hora_devolucao_real)                AS data_real_devolucao,
        -- Valor diária: derivado da Categoria do veículo
        COALESCE(cat.Valor_diaria_base, 0)              AS valor_diaria_aplicada,
        -- Valor final: diretamente do OLTP Amarelo
        COALESCE(l.Valor_total_final, 0)                AS valor_final,
        NOW()                                           AS dt_extracao
    FROM locadora_amarelo.Locacao l
    JOIN locadora_amarelo.Reserva r
        ON r.Id_reserva = l.Id_reserva
    JOIN locadora_amarelo.Veiculo v
        ON v.Id_veiculo = l.Id_veiculo
    LEFT JOIN locadora_amarelo.Categoria cat
        ON cat.Id_categoria = v.Id_categoria;

END//


--  2.7) sp_prique_extrai_snapshot_patio
--       Snapshot diário: veículos presentes fisicamente em cada pátio.
--       Lógica Amarelo: veículo está no pátio quando Id_vaga IS NOT NULL.
--       A Vaga é vinculada a um Patio, revelando a posição física do veículo.
DROP PROCEDURE IF EXISTS staging.sp_prique_extrai_snapshot_patio//
CREATE PROCEDURE staging.sp_prique_extrai_snapshot_patio(
    IN p_data_snapshot DATE
)
BEGIN
    DECLARE v_data DATE;
    SET v_data = COALESCE(p_data_snapshot, CURDATE());

    -- Remove snapshot anterior para este dia (re-execução segura)
    DELETE FROM staging.stg_prique_snapshot_patio
    WHERE data_snapshot = v_data
      AND nk_frota_origem = 'p-rique';

    -- Insert: veículos que possuem Vaga atribuída (estão no pátio)
    INSERT INTO staging.stg_prique_snapshot_patio (
        nk_frota_origem,
        nk_id_patio,
        nk_id_veiculo,
        nk_id_grupo,
        data_snapshot,
        dt_extracao
    )
    SELECT
        'p-rique'           AS nk_frota_origem,
        vg.Id_patio         AS nk_id_patio,
        v.Id_veiculo        AS nk_id_veiculo,
        v.Id_categoria      AS nk_id_grupo,
        v_data              AS data_snapshot,
        NOW()               AS dt_extracao
    FROM locadora_amarelo.Veiculo v
    JOIN locadora_amarelo.Vaga vg
        ON vg.Id_vaga = v.Id_vaga
    WHERE v.Id_vaga IS NOT NULL;

END//


-- =========================================================================
--  3) PROCEDURE MAIN DE EXTRAÇÃO
--     Chama todas as extrações na ordem correta (dimensões antes de fatos).
-- =========================================================================

DROP PROCEDURE IF EXISTS staging.sp_prique_extracao_completa//
CREATE PROCEDURE staging.sp_prique_extracao_completa()
BEGIN

    -- Ordem: dimensões antes de fatos
    CALL staging.sp_prique_extrai_patio();
    CALL staging.sp_prique_extrai_grupo();
    CALL staging.sp_prique_extrai_veiculo();
    CALL staging.sp_prique_extrai_cliente();
    CALL staging.sp_prique_extrai_reserva();
    CALL staging.sp_prique_extrai_locacao();
    CALL staging.sp_prique_extrai_snapshot_patio(NULL);

END//

DELIMITER ;


-- =========================================================================
--  4) TRIGGERS DE EXTRAÇÃO (Event-Driven)
--     Substituem as procedures de extração para operação em tempo real.
--     Cada INSERT/UPDATE no OLTP Amarelo replica no staging bruto.
--
--     NOTA: As procedures batch (seção 2 e 3) são mantidas para:
--       - Carga inicial (full load)
--       - Re-execução manual / recuperação
--     As triggers abaixo funcionam para operação contínua.
--
--     NOTA 2: O snapshot de pátio (stg_prique_snapshot_patio) NÃO é coberto
--     por triggers — continua como procedure agendada diariamente.
-- =========================================================================

DELIMITER //

-- 4.1) Patio
DROP TRIGGER IF EXISTS locadora_amarelo.trg_extrai_prique_patio_ai//
CREATE TRIGGER locadora_amarelo.trg_extrai_prique_patio_ai
AFTER INSERT ON locadora_amarelo.Patio
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_prique_patio (
        nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas,
        end_cidade, end_uf, end_logradouro, dt_extracao
    )
    SELECT 'p-rique', NEW.Id_patio, NEW.Nome_patio, NEW.Capacidade,
           e.Cidade, e.Uf, e.Logradouro, NOW()
    FROM locadora_amarelo.Endereco e
    WHERE e.Id_endereco = NEW.Id_endereco
    ON DUPLICATE KEY UPDATE
        nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas),
        end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf),
        end_logradouro = VALUES(end_logradouro), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora_amarelo.trg_extrai_prique_patio_au//
CREATE TRIGGER locadora_amarelo.trg_extrai_prique_patio_au
AFTER UPDATE ON locadora_amarelo.Patio
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_prique_patio (
        nk_frota_origem, nk_id_patio, nome_patio, capacidade_vagas,
        end_cidade, end_uf, end_logradouro, dt_extracao
    )
    SELECT 'p-rique', NEW.Id_patio, NEW.Nome_patio, NEW.Capacidade,
           e.Cidade, e.Uf, e.Logradouro, NOW()
    FROM locadora_amarelo.Endereco e
    WHERE e.Id_endereco = NEW.Id_endereco
    ON DUPLICATE KEY UPDATE
        nome_patio = VALUES(nome_patio), capacidade_vagas = VALUES(capacidade_vagas),
        end_cidade = VALUES(end_cidade), end_uf = VALUES(end_uf),
        end_logradouro = VALUES(end_logradouro), dt_extracao = NOW();
END//

-- 4.2) Grupo (Categoria)
DROP TRIGGER IF EXISTS locadora_amarelo.trg_extrai_prique_grupo_ai//
CREATE TRIGGER locadora_amarelo.trg_extrai_prique_grupo_ai
AFTER INSERT ON locadora_amarelo.Categoria
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_prique_grupo (
        nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria, dt_extracao
    ) VALUES (
        'p-rique', NEW.Id_categoria, NEW.Nome_categoria,
        COALESCE(NEW.Valor_diaria_base, 0), NOW()
    ) ON DUPLICATE KEY UPDATE
        nome_grupo = VALUES(nome_grupo), valor_diaria = VALUES(valor_diaria), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora_amarelo.trg_extrai_prique_grupo_au//
CREATE TRIGGER locadora_amarelo.trg_extrai_prique_grupo_au
AFTER UPDATE ON locadora_amarelo.Categoria
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_prique_grupo (
        nk_frota_origem, nk_id_grupo, nome_grupo, valor_diaria, dt_extracao
    ) VALUES (
        'p-rique', NEW.Id_categoria, NEW.Nome_categoria,
        COALESCE(NEW.Valor_diaria_base, 0), NOW()
    ) ON DUPLICATE KEY UPDATE
        nome_grupo = VALUES(nome_grupo), valor_diaria = VALUES(valor_diaria), dt_extracao = NOW();
END//

-- 4.3) Veiculo
DROP TRIGGER IF EXISTS locadora_amarelo.trg_extrai_prique_veiculo_ai//
CREATE TRIGGER locadora_amarelo.trg_extrai_prique_veiculo_ai
AFTER INSERT ON locadora_amarelo.Veiculo
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_prique_veiculo (
        nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
        placa, marca, modelo, mecanizacao, tem_ar_condicionado,
        ano_fabricacao, situacao, dt_extracao
    )
    SELECT 'p-rique', NEW.Id_veiculo, NEW.Id_categoria, vg.Id_patio,
           NEW.Placa, NEW.Marca, NEW.Modelo,
           CASE UPPER(TRIM(COALESCE(NEW.Tipo_cambio, '')))
               WHEN 'MANUAL' THEN 'MANUAL' WHEN 'AUTOMATICO' THEN 'AUTOMATICO'
               WHEN 'AUTOMATICA' THEN 'AUTOMATICO' ELSE NEW.Tipo_cambio END,
           COALESCE(NEW.Possui_ar_condicionado, 0), NEW.Ano, NEW.Status_veiculo, NOW()
    FROM (SELECT 1) dummy
    LEFT JOIN locadora_amarelo.Vaga vg ON vg.Id_vaga = NEW.Id_vaga
    ON DUPLICATE KEY UPDATE
        nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_origem = VALUES(nk_id_patio_origem),
        placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
        mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado),
        situacao = VALUES(situacao), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora_amarelo.trg_extrai_prique_veiculo_au//
CREATE TRIGGER locadora_amarelo.trg_extrai_prique_veiculo_au
AFTER UPDATE ON locadora_amarelo.Veiculo
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_prique_veiculo (
        nk_frota_origem, nk_id_veiculo, nk_id_grupo, nk_id_patio_origem,
        placa, marca, modelo, mecanizacao, tem_ar_condicionado,
        ano_fabricacao, situacao, dt_extracao
    )
    SELECT 'p-rique', NEW.Id_veiculo, NEW.Id_categoria, vg.Id_patio,
           NEW.Placa, NEW.Marca, NEW.Modelo,
           CASE UPPER(TRIM(COALESCE(NEW.Tipo_cambio, '')))
               WHEN 'MANUAL' THEN 'MANUAL' WHEN 'AUTOMATICO' THEN 'AUTOMATICO'
               WHEN 'AUTOMATICA' THEN 'AUTOMATICO' ELSE NEW.Tipo_cambio END,
           COALESCE(NEW.Possui_ar_condicionado, 0), NEW.Ano, NEW.Status_veiculo, NOW()
    FROM (SELECT 1) dummy
    LEFT JOIN locadora_amarelo.Vaga vg ON vg.Id_vaga = NEW.Id_vaga
    ON DUPLICATE KEY UPDATE
        nk_id_grupo = VALUES(nk_id_grupo), nk_id_patio_origem = VALUES(nk_id_patio_origem),
        placa = VALUES(placa), marca = VALUES(marca), modelo = VALUES(modelo),
        mecanizacao = VALUES(mecanizacao), tem_ar_condicionado = VALUES(tem_ar_condicionado),
        situacao = VALUES(situacao), dt_extracao = NOW();
END//

-- 4.4) Cliente
DROP TRIGGER IF EXISTS locadora_amarelo.trg_extrai_prique_cliente_ai//
CREATE TRIGGER locadora_amarelo.trg_extrai_prique_cliente_ai
AFTER INSERT ON locadora_amarelo.Cliente
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_prique_cliente (
        nk_frota_origem, nk_id_cliente, tipo_cliente, nome,
        email, end_uf, end_cidade, cpf, cnpj, nome_fantasia, dt_extracao
    )
    SELECT 'p-rique', NEW.Id_cliente, NEW.Tipo_cliente,
        CASE WHEN UPPER(TRIM(NEW.Tipo_cliente)) = 'PF' THEN pf.Nome_cliente
             WHEN UPPER(TRIM(NEW.Tipo_cliente)) = 'PJ' THEN pj.Razao_social
             ELSE COALESCE(pf.Nome_cliente, pj.Razao_social, 'NÃO INFORMADO') END,
        NEW.Email_cliente, e.Uf, e.Cidade,
        pf.Cpf_cliente, pj.Cnpj_cliente, pj.Nome_fantasia, NOW()
    FROM (SELECT 1) dummy
    LEFT JOIN locadora_amarelo.Cliente_pf pf ON pf.Id_cliente = NEW.Id_cliente
    LEFT JOIN locadora_amarelo.Cliente_pj pj ON pj.Id_cliente = NEW.Id_cliente
    LEFT JOIN locadora_amarelo.Endereco e    ON e.Id_endereco = NEW.Id_endereco
    ON DUPLICATE KEY UPDATE
        tipo_cliente = VALUES(tipo_cliente), nome = VALUES(nome),
        email = VALUES(email), end_uf = VALUES(end_uf), end_cidade = VALUES(end_cidade),
        dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora_amarelo.trg_extrai_prique_cliente_au//
CREATE TRIGGER locadora_amarelo.trg_extrai_prique_cliente_au
AFTER UPDATE ON locadora_amarelo.Cliente
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_prique_cliente (
        nk_frota_origem, nk_id_cliente, tipo_cliente, nome,
        email, end_uf, end_cidade, cpf, cnpj, nome_fantasia, dt_extracao
    )
    SELECT 'p-rique', NEW.Id_cliente, NEW.Tipo_cliente,
        CASE WHEN UPPER(TRIM(NEW.Tipo_cliente)) = 'PF' THEN pf.Nome_cliente
             WHEN UPPER(TRIM(NEW.Tipo_cliente)) = 'PJ' THEN pj.Razao_social
             ELSE COALESCE(pf.Nome_cliente, pj.Razao_social, 'NÃO INFORMADO') END,
        NEW.Email_cliente, e.Uf, e.Cidade,
        pf.Cpf_cliente, pj.Cnpj_cliente, pj.Nome_fantasia, NOW()
    FROM (SELECT 1) dummy
    LEFT JOIN locadora_amarelo.Cliente_pf pf ON pf.Id_cliente = NEW.Id_cliente
    LEFT JOIN locadora_amarelo.Cliente_pj pj ON pj.Id_cliente = NEW.Id_cliente
    LEFT JOIN locadora_amarelo.Endereco e    ON e.Id_endereco = NEW.Id_endereco
    ON DUPLICATE KEY UPDATE
        tipo_cliente = VALUES(tipo_cliente), nome = VALUES(nome),
        email = VALUES(email), end_uf = VALUES(end_uf), end_cidade = VALUES(end_cidade),
        dt_extracao = NOW();
END//

-- 4.5) Reserva
DROP TRIGGER IF EXISTS locadora_amarelo.trg_extrai_prique_reserva_ai//
CREATE TRIGGER locadora_amarelo.trg_extrai_prique_reserva_ai
AFTER INSERT ON locadora_amarelo.Reserva
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_prique_reserva (
        nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo,
        nk_id_patio_retirada, nk_id_patio_fim,
        data_reserva, data_retirada_prevista, data_devolucao_prevista,
        duracao_prevista_dias, valor_previsto_reserva, status_reserva, dt_extracao
    ) VALUES (
        'p-rique', NEW.Id_reserva, NEW.Id_cliente, NEW.Id_categoria,
        NEW.Id_patio_previsto_retirada, NEW.Id_patio_previsto_devolucao,
        DATE(NEW.Data_hora_reserva), DATE(NEW.Data_previsao_retirada), DATE(NEW.Data_previsao_devolucao),
        DATEDIFF(DATE(NEW.Data_previsao_devolucao), DATE(NEW.Data_previsao_retirada)),
        COALESCE(NEW.Valor_previsto, 0),
        CASE UPPER(TRIM(COALESCE(NEW.Status_reserva, '')))
            WHEN 'ATIVO' THEN 'ATIVA' WHEN 'ATIVA' THEN 'ATIVA'
            WHEN 'CANCELADO' THEN 'CANCELADA' WHEN 'CANCELADA' THEN 'CANCELADA'
            WHEN 'CONVERTIDO' THEN 'CONVERTIDA' WHEN 'CONVERTIDA' THEN 'CONVERTIDA'
            WHEN 'CONCLUIDO' THEN 'CONVERTIDA' WHEN 'FINALIZADO' THEN 'CONVERTIDA'
            ELSE COALESCE(TRIM(NEW.Status_reserva), 'ATIVA') END,
        NOW()
    ) ON DUPLICATE KEY UPDATE
        status_reserva = VALUES(status_reserva), valor_previsto_reserva = VALUES(valor_previsto_reserva),
        dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora_amarelo.trg_extrai_prique_reserva_au//
CREATE TRIGGER locadora_amarelo.trg_extrai_prique_reserva_au
AFTER UPDATE ON locadora_amarelo.Reserva
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_prique_reserva (
        nk_frota_origem, nk_id_reserva, nk_id_cliente, nk_id_grupo,
        nk_id_patio_retirada, nk_id_patio_fim,
        data_reserva, data_retirada_prevista, data_devolucao_prevista,
        duracao_prevista_dias, valor_previsto_reserva, status_reserva, dt_extracao
    ) VALUES (
        'p-rique', NEW.Id_reserva, NEW.Id_cliente, NEW.Id_categoria,
        NEW.Id_patio_previsto_retirada, NEW.Id_patio_previsto_devolucao,
        DATE(NEW.Data_hora_reserva), DATE(NEW.Data_previsao_retirada), DATE(NEW.Data_previsao_devolucao),
        DATEDIFF(DATE(NEW.Data_previsao_devolucao), DATE(NEW.Data_previsao_retirada)),
        COALESCE(NEW.Valor_previsto, 0),
        CASE UPPER(TRIM(COALESCE(NEW.Status_reserva, '')))
            WHEN 'ATIVO' THEN 'ATIVA' WHEN 'ATIVA' THEN 'ATIVA'
            WHEN 'CANCELADO' THEN 'CANCELADA' WHEN 'CANCELADA' THEN 'CANCELADA'
            WHEN 'CONVERTIDO' THEN 'CONVERTIDA' WHEN 'CONVERTIDA' THEN 'CONVERTIDA'
            WHEN 'CONCLUIDO' THEN 'CONVERTIDA' WHEN 'FINALIZADO' THEN 'CONVERTIDA'
            ELSE COALESCE(TRIM(NEW.Status_reserva), 'ATIVA') END,
        NOW()
    ) ON DUPLICATE KEY UPDATE
        status_reserva = VALUES(status_reserva), valor_previsto_reserva = VALUES(valor_previsto_reserva),
        dt_extracao = NOW();
END//

-- 4.6) Locação
DROP TRIGGER IF EXISTS locadora_amarelo.trg_extrai_prique_locacao_ai//
CREATE TRIGGER locadora_amarelo.trg_extrai_prique_locacao_ai
AFTER INSERT ON locadora_amarelo.Locacao
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_prique_locacao (
        nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo,
        nk_id_grupo, nk_id_patio_retirada, nk_id_patio_devolucao,
        data_retirada, data_prev_devolucao, data_real_devolucao,
        valor_diaria_aplicada, valor_final, dt_extracao
    )
    SELECT 'p-rique', NEW.Id_locacao, r.Id_cliente, NEW.Id_veiculo,
           v.Id_categoria, NEW.Id_patio_real_retirada, NEW.Id_patio_real_devolucao,
           DATE(NEW.Data_hora_retirada_real), DATE(r.Data_previsao_devolucao),
           DATE(NEW.Data_hora_devolucao_real),
           COALESCE(cat.Valor_diaria_base, 0), COALESCE(NEW.Valor_total_final, 0), NOW()
    FROM locadora_amarelo.Reserva r
    JOIN locadora_amarelo.Veiculo v ON v.Id_veiculo = NEW.Id_veiculo
    LEFT JOIN locadora_amarelo.Categoria cat ON cat.Id_categoria = v.Id_categoria
    WHERE r.Id_reserva = NEW.Id_reserva
    ON DUPLICATE KEY UPDATE
        nk_id_patio_devolucao = VALUES(nk_id_patio_devolucao),
        data_real_devolucao = VALUES(data_real_devolucao),
        valor_final = VALUES(valor_final), dt_extracao = NOW();
END//

DROP TRIGGER IF EXISTS locadora_amarelo.trg_extrai_prique_locacao_au//
CREATE TRIGGER locadora_amarelo.trg_extrai_prique_locacao_au
AFTER UPDATE ON locadora_amarelo.Locacao
FOR EACH ROW
BEGIN
    INSERT INTO staging.stg_prique_locacao (
        nk_frota_origem, nk_id_locacao, nk_id_cliente, nk_id_veiculo,
        nk_id_grupo, nk_id_patio_retirada, nk_id_patio_devolucao,
        data_retirada, data_prev_devolucao, data_real_devolucao,
        valor_diaria_aplicada, valor_final, dt_extracao
    )
    SELECT 'p-rique', NEW.Id_locacao, r.Id_cliente, NEW.Id_veiculo,
           v.Id_categoria, NEW.Id_patio_real_retirada, NEW.Id_patio_real_devolucao,
           DATE(NEW.Data_hora_retirada_real), DATE(r.Data_previsao_devolucao),
           DATE(NEW.Data_hora_devolucao_real),
           COALESCE(cat.Valor_diaria_base, 0), COALESCE(NEW.Valor_total_final, 0), NOW()
    FROM locadora_amarelo.Reserva r
    JOIN locadora_amarelo.Veiculo v ON v.Id_veiculo = NEW.Id_veiculo
    LEFT JOIN locadora_amarelo.Categoria cat ON cat.Id_categoria = v.Id_categoria
    WHERE r.Id_reserva = NEW.Id_reserva
    ON DUPLICATE KEY UPDATE
        nk_id_patio_devolucao = VALUES(nk_id_patio_devolucao),
        data_real_devolucao = VALUES(data_real_devolucao),
        valor_final = VALUES(valor_final), dt_extracao = NOW();
END//

DELIMITER ;