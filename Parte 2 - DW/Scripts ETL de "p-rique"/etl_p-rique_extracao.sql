-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)

-- =============================================================================
-- 01_amarelo_extract.sql
-- Extração ETL — Amarelo OLTP → Área de Staging
--
-- Frota de origem : 'AMARELO'
-- Banco fonte     : locadora_amarelo (deploy do script script-modelagem.sql)
--                   *** ATENÇÃO: o grupo Amarelo nomeou seu banco 'locadora_dw'
--                   em seu DDL original. Ao implantar em ambiente de integração,
--                   o banco deve ser renomeado/reconfigurado para 'locadora_amarelo'
--                   para evitar conflito com outros sistemas. ***
-- Banco staging   : staging_dw
--
-- Periodicidade de acionamento (conforme modelo DW):
--   • Dimensões (endereço, cliente, veículo, grupo, pátio)
--       → Full extract diário: 00:00 ou janela de baixo tráfego
--   • Fato Reserva
--       → Full extract diário (status muda ao longo do dia): 23:00
--   • Fato Locação
--       → Full extract diário (inclui locações em aberto e concluídas): 23:00
--   • Inventário de Pátio (snapshot)
--       → Diário ao final do expediente: 23:59
--
-- Premissas:
--   • Todas as tabelas de staging são truncadas antes de cada carga full.
--   • Os campos dt_extracao registram o momento da execução para auditoria.
--   • O campo frota_origem = 'AMARELO' é adicionado em todas as tabelas.
-- =============================================================================

CREATE DATABASE IF NOT EXISTS staging_dw
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE staging_dw;

-- =============================================================================
-- PARTE 1 — CRIAÇÃO DAS TABELAS DE STAGING (executado uma única vez)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- STG_AMAR_ENDERECO
-- Espelha locadora_amarelo.Endereco com metadados de extração.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_amar_endereco (
    id_endereco     INT             NOT NULL,
    uf              CHAR(2)         NULL,
    cep             VARCHAR(8)      NULL,
    cidade          VARCHAR(100)    NULL,
    bairro          VARCHAR(100)    NULL,
    logradouro      VARCHAR(150)    NULL,
    numero          VARCHAR(20)     NULL,
    complemento     VARCHAR(100)    NULL,
    dt_extracao     DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_stg_amar_endereco PRIMARY KEY (id_endereco)
) COMMENT = 'Staging: endereços extraídos do OLTP Amarelo';

-- ---------------------------------------------------------------------------
-- STG_AMAR_CLIENTE
-- Consolida herança PF/PJ em linha única. Campos exclusivos de PF e PJ
-- ficam NULL quando não aplicáveis.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_amar_cliente (
    id_cliente              INT             NOT NULL,
    id_endereco             INT             NULL,
    tipo_cliente            CHAR(2)         NULL     COMMENT 'PF ou PJ',
    email_cliente           VARCHAR(100)    NULL,
    telefone_cliente        VARCHAR(20)     NULL,
    -- Atributos exclusivos de PF (null quando PJ)
    nome_pf                 VARCHAR(100)    NULL,
    cpf_cliente             VARCHAR(11)     NULL,
    data_nascimento         DATE            NULL,
    -- Atributos exclusivos de PJ (null quando PF)
    razao_social            VARCHAR(100)    NULL,
    nome_fantasia           VARCHAR(100)    NULL,
    cnpj_cliente            VARCHAR(14)     NULL,
    dt_extracao             DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_stg_amar_cliente PRIMARY KEY (id_cliente)
) COMMENT = 'Staging: clientes PF+PJ extraídos do OLTP Amarelo';

-- ---------------------------------------------------------------------------
-- STG_AMAR_VEICULO
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_amar_veiculo (
    id_veiculo              INT             NOT NULL,
    id_empresa              INT             NULL,
    id_categoria            INT             NULL,
    id_vaga                 INT             NULL COMMENT 'NULL = veículo locado/fora do pátio',
    placa                   VARCHAR(7)      NULL,
    chassi                  VARCHAR(17)     NULL,
    marca                   VARCHAR(50)     NULL,
    modelo                  VARCHAR(50)     NULL,
    ano                     INT             NULL,
    tipo_cambio             VARCHAR(20)     NULL,
    possui_ar_condicionado  TINYINT(1)      NULL,
    status_veiculo          VARCHAR(30)     NULL,
    dt_extracao             DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_stg_amar_veiculo PRIMARY KEY (id_veiculo)
) COMMENT = 'Staging: frota de veículos extraída do OLTP Amarelo';

-- ---------------------------------------------------------------------------
-- STG_AMAR_CATEGORIA
-- "Categoria" no OLTP Amarelo corresponde a "Grupo" no modelo DW.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_amar_categoria (
    id_categoria        INT             NOT NULL,
    nome_categoria      VARCHAR(50)     NULL,
    descricao_categoria TEXT            NULL,
    valor_diaria_base   DECIMAL(10,2)   NULL,
    dt_extracao         DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_stg_amar_categoria PRIMARY KEY (id_categoria)
) COMMENT = 'Staging: categorias (grupos) extraídas do OLTP Amarelo';

-- ---------------------------------------------------------------------------
-- STG_AMAR_PATIO
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_amar_patio (
    id_patio        INT             NOT NULL,
    id_empresa      INT             NULL,
    id_endereco     INT             NULL,
    nome_patio      VARCHAR(100)    NULL,
    capacidade      INT             NULL,
    dt_extracao     DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_stg_amar_patio PRIMARY KEY (id_patio)
) COMMENT = 'Staging: pátios extraídos do OLTP Amarelo';

-- ---------------------------------------------------------------------------
-- STG_AMAR_RESERVA
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_amar_reserva (
    id_reserva                      INT             NOT NULL,
    id_cliente                      INT             NULL,
    id_categoria                    INT             NULL,
    id_patio_previsto_retirada      INT             NULL,
    id_patio_previsto_devolucao     INT             NULL,
    data_hora_reserva               DATETIME        NULL,
    data_previsao_retirada          DATETIME        NULL,
    data_previsao_devolucao         DATETIME        NULL,
    valor_previsto                  DECIMAL(10,2)   NULL,
    status_reserva                  VARCHAR(30)     NULL,
    dt_extracao                     DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_stg_amar_reserva PRIMARY KEY (id_reserva)
) COMMENT = 'Staging: reservas extraídas do OLTP Amarelo';

-- ---------------------------------------------------------------------------
-- STG_AMAR_LOCACAO
-- Enriquecida durante a extração com id_cliente (via Reserva)
-- e id_categoria (via Veiculo), evitando joins desnecessários na carga.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_amar_locacao (
    id_locacao                  INT             NOT NULL,
    id_reserva                  INT             NULL,
    id_veiculo                  INT             NULL,
    id_cliente                  INT             NULL COMMENT 'Recuperado via Reserva',
    id_categoria                INT             NULL COMMENT 'Recuperado via Veiculo',
    id_patio_real_retirada      INT             NULL,
    id_patio_real_devolucao     INT             NULL,
    data_hora_retirada_real     DATETIME        NULL,
    data_hora_devolucao_real    DATETIME        NULL COMMENT 'NULL enquanto locação em aberto',
    data_previsao_devolucao     DATETIME        NULL COMMENT 'Recuperado via Reserva',
    km_retirada                 INT             NULL,
    km_devolucao                INT             NULL,
    valor_total_final           DECIMAL(10,2)   NULL COMMENT 'NULL enquanto locação em aberto',
    status_locacao              VARCHAR(30)     NULL,
    dt_extracao                 DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_stg_amar_locacao PRIMARY KEY (id_locacao)
) COMMENT = 'Staging: locações extraídas do OLTP Amarelo';

-- ---------------------------------------------------------------------------
-- STG_AMAR_INVENTARIO_PATIO
-- Snapshot diário: veículos presentes fisicamente em cada pátio.
-- Um veículo está no pátio quando seu campo Id_vaga IS NOT NULL.
-- Chave: (id_veiculo, dt_snapshot) — permite histórico de snapshots.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_amar_inventario_patio (
    id_veiculo      INT     NOT NULL,
    id_patio        INT     NOT NULL,
    id_categoria    INT     NULL,
    dt_snapshot     DATE    NOT NULL COMMENT 'Data do snapshot diário',
    dt_extracao     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_stg_amar_inventario PRIMARY KEY (id_veiculo, dt_snapshot)
) COMMENT = 'Staging: snapshot diário de veículos em pátio — OLTP Amarelo';


-- =============================================================================
-- PARTE 2 — EXTRAÇÃO: CARGA DO OLTP AMARELO → STAGING
-- (Executado diariamente conforme periodicidade definida acima)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- E1. ENDEREÇOS
-- Full extract: carga completa a cada execução
-- ---------------------------------------------------------------------------
TRUNCATE TABLE stg_amar_endereco;

INSERT INTO stg_amar_endereco (
    id_endereco, uf, cep, cidade, bairro,
    logradouro, numero, complemento
)
SELECT
    e.Id_endereco,
    e.Uf,
    e.Cep,
    e.Cidade,
    e.Bairro,
    e.Logradouro,
    e.Numero,
    e.Complemento
FROM locadora_amarelo.Endereco e;

-- ---------------------------------------------------------------------------
-- E2. CLIENTES (consolida herança PF + PJ em linha única)
-- Full extract: carga completa a cada execução
-- ---------------------------------------------------------------------------
TRUNCATE TABLE stg_amar_cliente;

INSERT INTO stg_amar_cliente (
    id_cliente, id_endereco, tipo_cliente,
    email_cliente, telefone_cliente,
    nome_pf, cpf_cliente, data_nascimento,
    razao_social, nome_fantasia, cnpj_cliente
)
SELECT
    c.Id_cliente,
    c.Id_endereco,
    c.Tipo_cliente,
    c.Email_cliente,
    c.Telefone_cliente,
    -- Campos PF (NULL para clientes PJ)
    pf.Nome_cliente             AS nome_pf,
    pf.Cpf_cliente              AS cpf_cliente,
    pf.Data_nascimento_cliente  AS data_nascimento,
    -- Campos PJ (NULL para clientes PF)
    pj.Razao_social             AS razao_social,
    pj.Nome_fantasia            AS nome_fantasia,
    pj.Cnpj_cliente             AS cnpj_cliente
FROM locadora_amarelo.Cliente      c
LEFT JOIN locadora_amarelo.Cliente_pf  pf ON c.Id_cliente = pf.Id_cliente
LEFT JOIN locadora_amarelo.Cliente_pj  pj ON c.Id_cliente = pj.Id_cliente;

-- ---------------------------------------------------------------------------
-- E3. VEÍCULOS
-- Full extract: carga completa a cada execução
-- ---------------------------------------------------------------------------
TRUNCATE TABLE stg_amar_veiculo;

INSERT INTO stg_amar_veiculo (
    id_veiculo, id_empresa, id_categoria, id_vaga,
    placa, chassi, marca, modelo, ano,
    tipo_cambio, possui_ar_condicionado, status_veiculo
)
SELECT
    v.Id_veiculo,
    v.Id_empresa,
    v.Id_categoria,
    v.Id_vaga,
    v.Placa,
    v.Chassi,
    v.Marca,
    v.Modelo,
    v.Ano,
    v.Tipo_cambio,
    v.Possui_ar_condicionado,
    v.Status_veiculo
FROM locadora_amarelo.Veiculo v;

-- ---------------------------------------------------------------------------
-- E4. CATEGORIAS (→ Dim_Grupo)
-- Full extract: carga completa a cada execução
-- ---------------------------------------------------------------------------
TRUNCATE TABLE stg_amar_categoria;

INSERT INTO stg_amar_categoria (
    id_categoria, nome_categoria, descricao_categoria, valor_diaria_base
)
SELECT
    c.Id_categoria,
    c.Nome_categoria,
    c.Descricao_categoria,
    c.Valor_diaria_base
FROM locadora_amarelo.Categoria c;

-- ---------------------------------------------------------------------------
-- E5. PÁTIOS
-- Full extract: carga completa a cada execução
-- ---------------------------------------------------------------------------
TRUNCATE TABLE stg_amar_patio;

INSERT INTO stg_amar_patio (
    id_patio, id_empresa, id_endereco, nome_patio, capacidade
)
SELECT
    p.Id_patio,
    p.Id_empresa,
    p.Id_endereco,
    p.Nome_patio,
    p.Capacidade
FROM locadora_amarelo.Patio p;

-- ---------------------------------------------------------------------------
-- E6. RESERVAS
-- Full extract diário: status (Ativa/Cancelada/Convertida) muda frequentemente.
-- ---------------------------------------------------------------------------
TRUNCATE TABLE stg_amar_reserva;

INSERT INTO stg_amar_reserva (
    id_reserva, id_cliente, id_categoria,
    id_patio_previsto_retirada, id_patio_previsto_devolucao,
    data_hora_reserva, data_previsao_retirada, data_previsao_devolucao,
    valor_previsto, status_reserva
)
SELECT
    r.Id_reserva,
    r.Id_cliente,
    r.Id_categoria,
    r.Id_patio_previsto_retirada,
    r.Id_patio_previsto_devolucao,
    r.Data_hora_reserva,
    r.Data_previsao_retirada,
    r.Data_previsao_devolucao,
    r.Valor_previsto,
    r.Status_reserva
FROM locadora_amarelo.Reserva r;

-- ---------------------------------------------------------------------------
-- E7. LOCAÇÕES
-- Full extract diário: inclui locações ativas (sem devolução) e encerradas.
-- Enriquecida com id_cliente (via Reserva) e id_categoria (via Veiculo)
-- para reduzir complexidade das etapas de transformação e carga.
-- ---------------------------------------------------------------------------
TRUNCATE TABLE stg_amar_locacao;

INSERT INTO stg_amar_locacao (
    id_locacao, id_reserva, id_veiculo, id_cliente, id_categoria,
    id_patio_real_retirada, id_patio_real_devolucao,
    data_hora_retirada_real, data_hora_devolucao_real, data_previsao_devolucao,
    km_retirada, km_devolucao, valor_total_final, status_locacao
)
SELECT
    l.Id_locacao,
    l.Id_reserva,
    l.Id_veiculo,
    r.Id_cliente                AS id_cliente,          -- via Reserva
    v.Id_categoria              AS id_categoria,        -- via Veiculo
    l.Id_patio_real_retirada,
    l.Id_patio_real_devolucao,
    l.Data_hora_retirada_real,
    l.Data_hora_devolucao_real,
    r.Data_previsao_devolucao   AS data_previsao_devolucao, -- via Reserva
    l.Km_retirada,
    l.Km_devolucao,
    l.Valor_total_final,
    l.Status_locacao
FROM locadora_amarelo.Locacao  l
JOIN locadora_amarelo.Reserva  r ON l.Id_reserva = r.Id_reserva
JOIN locadora_amarelo.Veiculo  v ON l.Id_veiculo  = v.Id_veiculo;

-- ---------------------------------------------------------------------------
-- E8. INVENTÁRIO DE PÁTIO (Snapshot diário — executar às 23:59)
-- Lógica: veículo está no pátio quando seu Id_vaga IS NOT NULL.
-- A Vaga é vinculada a um Patio, revelando a posição física do veículo.
-- Nota: locações em aberto têm Id_vaga = NULL no Veiculo (veículo fora do pátio).
-- ---------------------------------------------------------------------------
-- Remove snapshot do dia atual antes de reinserir (idempotência)
DELETE FROM stg_amar_inventario_patio
WHERE dt_snapshot = CURDATE();

INSERT INTO stg_amar_inventario_patio (
    id_veiculo, id_patio, id_categoria, dt_snapshot
)
SELECT
    v.Id_veiculo,
    vg.Id_patio,
    v.Id_categoria,
    CURDATE() AS dt_snapshot
FROM locadora_amarelo.Veiculo v
JOIN locadora_amarelo.Vaga    vg ON v.Id_vaga = vg.Id_vaga
WHERE v.Id_vaga IS NOT NULL;