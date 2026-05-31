-- ============================================================================
-- SCRIPT DE CRIAÇÃO DO DATA WAREHOUSE (DDL MYSQL)
-- ============================================================================
--  Estrutura:
--      Schema dw
--      ├── Dimensões
--      │   ├── dim_endereco
--      │   ├── dim_tempo        (pré-populada: 2015-01-01 → 2035-12-31)
--      │   ├── dim_cliente
--      │   ├── dim_veiculo
--      │   ├── dim_grupo
--      │   └── dim_patio
--      └── Fatos
--          ├── fato_inventario_patio
--          ├── fato_locacao
--          └── fato_reserva
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS dw;
USE dw;

-- ----------------------------------------------------------------------------
-- 1. TABELAS DE DIMENSÃO
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Tabela: dim_endereco
-- Descrição: Armazena a hierarquia geográfica.
-- Estrutura: Chave substituta artificial (sk_endereco) e a composição natural 
-- única formada por País, Estado e Cidade.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.dim_endereco (
    sk_endereco INT NOT NULL AUTO_INCREMENT,
    cidade VARCHAR(100) NOT NULL,
    estado VARCHAR(100) NOT NULL,
    pais VARCHAR(100) NOT NULL,
    CONSTRAINT pk_dim_endereco PRIMARY KEY (sk_endereco),
    CONSTRAINT uk_dim_endereco_nk UNIQUE (pais, estado, cidade)
);

-- ----------------------------------------------------------------------------
-- Tabela: dim_cliente
-- Descrição: Consolida o cadastro de clientes (Pessoa Física ou Jurídica).
-- Estrutura: Unicidade garantida pela frota de origem com o id do sistema OLTP. 
-- Relaciona-se com dim_endereco (Snowflake).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.dim_cliente (
    sk_cliente INT NOT NULL AUTO_INCREMENT,
    nk_frota_origem VARCHAR(100) NOT NULL,
    nk_id_cliente INT NOT NULL,
    tipo_cliente VARCHAR(2),
    nome VARCHAR(150),
    sk_endereco INT,
    CONSTRAINT pk_dim_cliente PRIMARY KEY (sk_cliente),
    CONSTRAINT uk_dim_cliente_nk UNIQUE (nk_frota_origem, nk_id_cliente),
    CONSTRAINT fk_dim_cliente_endereco FOREIGN KEY (sk_endereco) 
        REFERENCES dw.dim_endereco (sk_endereco),
    CONSTRAINT ck_dim_cliente_tipo CHECK (tipo_cliente IN ('PF', 'PJ'))
);

-- ----------------------------------------------------------------------------
-- Tabela: dim_veiculo
-- Descrição: Dimensão que mapeia a frota de veículos disponíveis.
-- Estrutura: Mantém a rastreabilidade via chave composta de origem 
-- (nk_frota_origem, nk_id_veiculo).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.dim_veiculo (
    sk_veiculo INT NOT NULL AUTO_INCREMENT,
    nk_frota_origem VARCHAR(100) NOT NULL,
    nk_id_veiculo INT NOT NULL,
    placa VARCHAR(10),
    marca VARCHAR(50),
    modelo VARCHAR(60),
    mecanizacao VARCHAR(20),
    tem_ar_condicionado BOOLEAN,
    CONSTRAINT pk_dim_veiculo PRIMARY KEY (sk_veiculo),
    CONSTRAINT uk_dim_veiculo_nk UNIQUE (nk_frota_origem, nk_id_veiculo),
    CONSTRAINT ck_dim_veiculo_mec CHECK (mecanizacao IN ('MANUAL', 'AUTOMATICO', 'NÃO INFORMADO'))
);

-- ----------------------------------------------------------------------------
-- Tabela: dim_grupo
-- Descrição: Classificação de agrupamento de veículos e suas tarifas.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.dim_grupo (
    sk_grupo INT NOT NULL AUTO_INCREMENT,
    nk_frota_origem VARCHAR(100) NOT NULL,
    nk_id_grupo INT NOT NULL,
    nome_grupo VARCHAR(80),
    valor_diaria DECIMAL(10,2),
    CONSTRAINT pk_dim_grupo PRIMARY KEY (sk_grupo),
    CONSTRAINT uk_dim_grupo_nk UNIQUE (nk_frota_origem, nk_id_grupo),
    CONSTRAINT ck_dim_grupo_diaria CHECK (valor_diaria >= 0)
);

-- ----------------------------------------------------------------------------
-- Tabela: dim_patio
-- Descrição: Representa os locais físicos de retirada, devolução e parqueamento.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.dim_patio (
    sk_patio INT NOT NULL AUTO_INCREMENT,
    nk_frota_origem VARCHAR(100) NOT NULL,
    nk_id_patio INT NOT NULL,
    nome_patio VARCHAR(100),
    capacidade_vagas_patio INT DEFAULT -1,
    sk_endereco INT,
    CONSTRAINT pk_dim_patio PRIMARY KEY (sk_patio),
    CONSTRAINT uk_dim_patio_nk UNIQUE (nk_frota_origem, nk_id_patio),
    CONSTRAINT fk_dim_patio_endereco FOREIGN KEY (sk_endereco) 
        REFERENCES dw.dim_endereco (sk_endereco)
);

-- ----------------------------------------------------------------------------
-- Tabela: dim_tempo
-- Descrição: Dimensão conformada de data. sk_tempo possui o formato numérico 
-- YYYYMMDD para otimização de particionamento.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.dim_tempo (
    sk_tempo INT NOT NULL,
    data DATE NOT NULL,
    ano INT,
    trimestre INT,
    mes INT,
    semana_ano INT,
    dia_semana INT,
    nome_mes VARCHAR(20),
    nome_dia VARCHAR(20),
    CONSTRAINT pk_dim_tempo PRIMARY KEY (sk_tempo),
    CONSTRAINT uk_dim_tempo_nk UNIQUE (data)
);

-- ----------------------------------------------------------------------------
-- PRÉ-POPULAÇÃO DA DIMENSÃO TEMPO (MYSQL)
-- ----------------------------------------------------------------------------
-- Ajuste da profundidade máxima de recursão da CTE para suportar o intervalo
-- temporal exigido.
SET SESSION cte_max_recursion_depth = 10000;

INSERT INTO dw.dim_tempo (sk_tempo, data, ano, trimestre, mes, semana_ano, dia_semana, nome_mes, nome_dia)
WITH RECURSIVE Datas_CTE AS (
    SELECT CAST('2015-01-01' AS DATE) AS data_ref
    UNION ALL
    SELECT DATE_ADD(data_ref, INTERVAL 1 DAY)
    FROM Datas_CTE
    WHERE data_ref < CAST('2035-12-31' AS DATE)
)
SELECT 
    CAST(DATE_FORMAT(data_ref, '%Y%m%d') AS UNSIGNED) AS sk_tempo,
    data_ref AS data,
    YEAR(data_ref) AS ano,
    QUARTER(data_ref) AS trimestre,
    MONTH(data_ref) AS mes,
    WEEK(data_ref, 3) AS semana_ano,
    WEEKDAY(data_ref) + 1 AS dia_semana,
    DATE_FORMAT(data_ref, '%M') AS nome_mes,
    DATE_FORMAT(data_ref, '%W') AS nome_dia
FROM Datas_CTE
WHERE NOT EXISTS (SELECT 1 FROM dw.dim_tempo LIMIT 1);

-- ----------------------------------------------------------------------------
-- 2. TABELAS DE FATOS
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Tabela: fato_inventario_patio
-- Grão: Um registro por veículo estacionado, por pátio, por dia.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.fato_inventario_patio (
    sk_tempo_referencia INT NOT NULL,
    sk_patio INT NOT NULL,
    sk_veiculo INT NOT NULL,
    sk_grupo INT NOT NULL,
    qtde_veiculos_presentes INT DEFAULT 1 NOT NULL,
    CONSTRAINT pk_fato_inventario_patio PRIMARY KEY (sk_tempo_referencia, sk_patio, sk_veiculo),
    CONSTRAINT fk_fato_inventario_tempo FOREIGN KEY (sk_tempo_referencia) 
        REFERENCES dw.dim_tempo (sk_tempo),
    CONSTRAINT fk_fato_inventario_patio FOREIGN KEY (sk_patio) 
        REFERENCES dw.dim_patio (sk_patio),
    CONSTRAINT fk_fato_inventario_veiculo FOREIGN KEY (sk_veiculo) 
        REFERENCES dw.dim_veiculo (sk_veiculo),
    CONSTRAINT fk_fato_inventario_grupo FOREIGN KEY (sk_grupo) 
        REFERENCES dw.dim_grupo (sk_grupo),
    CONSTRAINT ck_inv_qtde CHECK (qtde_veiculos_presentes = 1)
);

-- ----------------------------------------------------------------------------
-- Tabela: fato_locacao
-- Grão: Uma linha por contrato/evento físico de locação.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.fato_locacao (
    nk_frota_origem VARCHAR(100) NOT NULL,
    nk_id_locacao INT NOT NULL,
    sk_tempo_retirada INT NOT NULL,
    sk_tempo_prev_devolucao INT NOT NULL,
    sk_tempo_real_devolucao INT,
    sk_cliente INT NOT NULL,
    sk_veiculo INT NOT NULL,
    sk_grupo INT NOT NULL,
    sk_patio_retirada INT NOT NULL,
    sk_patio_devolucao_real INT,
    valor_final DECIMAL(10,2) DEFAULT 0.00,
    qtde_locacoes INT DEFAULT 1 NOT NULL,
    CONSTRAINT pk_fato_locacao PRIMARY KEY (nk_frota_origem, nk_id_locacao),
    CONSTRAINT fk_fato_locacao_tempo_retirada FOREIGN KEY (sk_tempo_retirada) 
        REFERENCES dw.dim_tempo (sk_tempo),
    CONSTRAINT fk_fato_locacao_tempo_prev_dev FOREIGN KEY (sk_tempo_prev_devolucao) 
        REFERENCES dw.dim_tempo (sk_tempo),
    CONSTRAINT fk_fato_locacao_tempo_real_dev FOREIGN KEY (sk_tempo_real_devolucao) 
        REFERENCES dw.dim_tempo (sk_tempo),
    CONSTRAINT fk_fato_locacao_cliente FOREIGN KEY (sk_cliente) 
        REFERENCES dw.dim_cliente (sk_cliente),
    CONSTRAINT fk_fato_locacao_veiculo FOREIGN KEY (sk_veiculo) 
        REFERENCES dw.dim_veiculo (sk_veiculo),
    CONSTRAINT fk_fato_locacao_grupo FOREIGN KEY (sk_grupo) 
        REFERENCES dw.dim_grupo (sk_grupo),
    CONSTRAINT fk_fato_locacao_patio_retirada FOREIGN KEY (sk_patio_retirada) 
        REFERENCES dw.dim_patio (sk_patio),
    CONSTRAINT fk_fato_locacao_patio_dev_real FOREIGN KEY (sk_patio_devolucao_real) 
        REFERENCES dw.dim_patio (sk_patio),
    CONSTRAINT ck_loc_qtde CHECK (qtde_locacoes = 1),
    CONSTRAINT ck_loc_valor CHECK (valor_final >= 0)
);

-- ----------------------------------------------------------------------------
-- Tabela: fato_reserva
-- Grão: Uma linha por intenção de reserva no sistema OLTP.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.fato_reserva (
    nk_frota_origem VARCHAR(100) NOT NULL,
    nk_id_reserva INT NOT NULL,
    sk_tempo_reserva INT NOT NULL,
    sk_tempo_prev_retirada INT NOT NULL,
    sk_tempo_prev_devolucao INT NOT NULL,
    sk_cliente INT NOT NULL,
    sk_grupo INT NOT NULL,
    sk_patio_retirada INT NOT NULL,
    sk_patio_fim INT NOT NULL,
    duracao_prevista_dias INT NOT NULL,
    valor_previsto_reserva DECIMAL(10,2) DEFAULT 0.00 NOT NULL,
    dd_status_reserva VARCHAR(100) DEFAULT 'ATIVA' NOT NULL,
    qtde_reservas INT DEFAULT 1 NOT NULL,
    CONSTRAINT pk_fato_reserva PRIMARY KEY (nk_frota_origem, nk_id_reserva),
    CONSTRAINT fk_fato_reserva_tempo_reserva FOREIGN KEY (sk_tempo_reserva) 
        REFERENCES dw.dim_tempo (sk_tempo),
    CONSTRAINT fk_fato_reserva_tempo_prev_ret FOREIGN KEY (sk_tempo_prev_retirada) 
        REFERENCES dw.dim_tempo (sk_tempo),
    CONSTRAINT fk_fato_reserva_tempo_prev_dev FOREIGN KEY (sk_tempo_prev_devolucao) 
        REFERENCES dw.dim_tempo (sk_tempo),
    CONSTRAINT fk_fato_reserva_cliente FOREIGN KEY (sk_cliente) 
        REFERENCES dw.dim_cliente (sk_cliente),
    CONSTRAINT fk_fato_reserva_grupo FOREIGN KEY (sk_grupo) 
        REFERENCES dw.dim_grupo (sk_grupo),
    CONSTRAINT fk_fato_reserva_patio_retirada FOREIGN KEY (sk_patio_retirada) 
        REFERENCES dw.dim_patio (sk_patio),
    CONSTRAINT fk_fato_reserva_patio_fim FOREIGN KEY (sk_patio_fim) 
        REFERENCES dw.dim_patio (sk_patio),
    CONSTRAINT ck_res_status CHECK (dd_status_reserva IN ('ATIVA','CANCELADA','CONVERTIDA')),
    CONSTRAINT ck_res_duracao CHECK (duracao_prevista_dias >= 1),
    CONSTRAINT ck_res_valor CHECK (valor_previsto_reserva >= 0),
    CONSTRAINT ck_res_qtde CHECK (qtde_reservas = 1)
);
