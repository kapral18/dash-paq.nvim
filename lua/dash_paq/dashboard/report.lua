-- Facade over the report submodules. Callers require
-- `dash_paq.dashboard.report` and use the names re-exported here; the
-- concrete logic lives in the cohesive submodules under `report/`:
--   parser   - `nvim-pack://confirm` report buffer -> cache parsing
--   pipeline - per-plugin async fetch+status refresh
--   rows     - cache purge and dashboard row assembly
local parser = require("dash_paq.dashboard.report.parser")
local pipeline = require("dash_paq.dashboard.report.pipeline")
local rows = require("dash_paq.dashboard.report.rows")

local M = {}

M.refresh_pack_report_cache_from_report_buffer = parser.refresh_pack_report_cache_from_report_buffer
M.run_refresh_pipeline = pipeline.run
M.ensure_dashboard_cache = rows.ensure_dashboard_cache
M.collect_dashboard_rows = rows.collect_dashboard_rows
M.collect_dashboard_row = rows.collect_dashboard_row

return M
