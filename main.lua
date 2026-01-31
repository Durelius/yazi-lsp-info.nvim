local M = {}

-- Logging helper: writes to ~/.local/share/yazi/yazi-lsp-info.log
local function log(level, ...)
	local args = { ... }
	local parts = {}
	for i, v in ipairs(args) do
		if type(v) == "table" then
			table.insert(parts, require("vim.inspect")(v, { depth = nil }))
		else
			table.insert(parts, tostring(v))
		end
	end
	local line = string.format("[%s] [%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), level, table.concat(parts, " "))
	local log_path = os.getenv("HOME") .. "/.local/share/yazi/yazi_lsp_plugin.log"
	local f = io.open(log_path, "a")
	if f then
		f:write(line)
		f:close()
	end
end

local function table_size(t)
	local count = 0
	for _ in pairs(t) do
		count = count + 1
	end
	return count
end
local diagnostics_data = {}

local function fetch()
	local data_file = "/home/durelius/.local/share/nvim/yazi_lsp_data.lua"
	local ok, data_or_err = pcall(dofile, data_file)
	if not ok then
		log("ERROR", "Failed to load diagnostics data:", data_or_err)
		diagnostics_data = {}
	elseif type(data_or_err) == "table" then
		diagnostics_data = data_or_err
		log("INFO", "Loaded diagnostics data, entries:", table_size(diagnostics_data))
	else
		log("WARN", "Diagnostics file returned non-table:", type(data_or_err))
		diagnostics_data = {}
	end

	return true
end

local function setup(st, opts)
	fetch()
	Linemode:children_add(function(self)
		local url = tostring(self._file.url or "")
		local spans = {}

		-- Check if this file has diagnostics
		local diag = diagnostics_data[url]
		log("INFO", url)
		if diag then
			local count = diag.count or 1

			spans[#spans + 1] = ui.Span(count .. " " .. diag.icon .. "  ")
		end

		-- Optional: add filename
		return ui.Line(spans)
	end, 500)
end
-- Store diagnostics data

-- Fetch function: loads Lua table from file

return {
	fetch = fetch,
	setup = setup,
}
