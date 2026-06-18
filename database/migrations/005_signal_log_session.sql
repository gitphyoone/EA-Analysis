-- V19 FX Prop Desk — Signal Log Session Column
-- Adds session name (LONDON/NEW_YORK/OVERLAP/OFF_SESSION) to every logged evaluation.
-- Enables session-level filter on the Reasons page.
-- Run once: Get-Content database\migrations\005_signal_log_session.sql | docker exec -i ea_postgres psql -U ea_user -d ea_db

ALTER TABLE signal_log
    ADD COLUMN IF NOT EXISTS session VARCHAR(20);
