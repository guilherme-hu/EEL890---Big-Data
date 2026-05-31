-- Grupo:
-- Bernardo Brandão Pozzato Carvalho Costa (123289593)
-- Enzo de Carvalho Sampaio (123386206)
-- Giovanni Faletti Almeida (123184214)
-- Guilherme En Shih Hu (123224674)
-- Maria Victoria França Silva Ramos (123311073)
-- =============================================================================
-- DW_agendamento.sql
-- Configuração do MySQL Event Scheduler para Cargas Diárias (Batch)
--
-- Como as fases de Extração e Transformação (exceto Snapshot) foram
-- migradas para uma arquitetura Event-Driven (Triggers), o agendamento
-- diário fica responsável apenas por:
--   1) Extrair e transformar os snapshots de pátio diários.
--   2) Executar a Carga Completa (Load) do Staging Conformado para o DW.
-- =============================================================================

-- Habilita o Event Scheduler no MySQL (caso não esteja ativo)
SET GLOBAL event_scheduler = ON;

DELIMITER //

DROP EVENT IF EXISTS staging.evt_carga_diaria_dw//

CREATE EVENT staging.evt_carga_diaria_dw
ON SCHEDULE EVERY 1 DAY
STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 2 HOUR) -- Executa todo dia às 02:00 da manhã
DO
BEGIN
    -- 1) Processar Snapshots de Pátio (não cobertos por triggers)
    -- p-rique
    CALL staging.sp_prique_extrai_snapshot_patio(NULL);
    CALL staging.sp_prique_transforma_snapshot_patio();
    
    -- gupessanha
    CALL staging.sp_gupessanha_extrai_snapshot_patio(NULL);
    CALL staging.sp_gupessanha_transforma_snapshot_patio();

    -- 2) Executar Cargas para o Data Warehouse
    -- gupessanha
    CALL staging.sp_gupessanha_carga_completa();
    
    -- p-rique
    CALL staging.sp_prique_carga_completa();
    
END//

DELIMITER ;
