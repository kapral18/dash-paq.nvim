-- Facade over the report submodules. Callers require
-- `pack_companion.dashboard.report` and use the names re-exported here; the
-- concrete logic lives in the cohesive submodules under `report/`:
--   notify   - user-facing check progress/result notifications
--   parser   - `nvim-pack://confirm` report buffer -> cache parsing
--   pipeline - per-plugin async fetch+status refresh
--   rows     - cache purge and dashboard row assembly
local notify = require("pack_companion.dashboard.report.notify")
local parser = require("pack_companion.dashboard.report.parser")
local pipeline = require("pack_companion.dashboard.report.pipeline")
local rows = require("pack_companion.dashboard.report.rows")

local M = {}

M.notify_err = notify.notify_err
M.refresh_pack_report_cache_from_report_buffer = parser.refresh_pack_report_cache_from_report_buffer
M.run_refresh_pipeline = pipeline.run
M.ensure_dashboard_cache = rows.ensure_dashboard_cache
M.collect_dashboard_rows = rows.collect_dashboard_rows
M.collect_dashboard_row = rows.collect_dashboard_row

return M
