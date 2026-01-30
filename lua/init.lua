-- Workspace diagnostics exporter for Yazi

local M = {}

-- ========================
-- Config
-- ========================

local LOG_PATH = vim.fn.stdpath("data") .. "/yazi_lsp_plugin.log"
local OUT_PATH = vim.fn.stdpath("data") .. "/yazi_lsp_data.lua"

M.options = {
	debug = true,
	dev_folder = vim.fn.stdpath("data"),
	enabled = true,
	icons = {
		warning = "🔶",
		error = "🛑",
		info = "ℹ️",
		other = "●",
	},
	memory = {
		max_files = 5000,
		max_lsp_buffer_files = 100,
		files_per_batch = 5,
		debounce_ms = 100,
	},
	files = {
		ignore_types = {
			[".log"] = true,
		},
		ignore_dirs = {
			[".git"] = true,
			["node_modules"] = true,
			["build"] = true,
			["dist"] = true,
			["target"] = true,
			[".venv"] = true,
			[".cache"] = true,
		},
	},
}

-- ========================
-- State
-- ========================

local loaded_clients = {}
local detected_filetypes = {}
local opened_files = {}
local dumping = false
local dump_timer = nil

-- ========================
-- Logging
-- ========================

local function log(level, ...)
	if not M.options.debug then
		return
	end
	local parts = {}
	for _, v in ipairs({ ... }) do
		parts[#parts + 1] = type(v) == "string" and v or vim.inspect(v)
	end
	local line = string.format("[%s] [%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), level, table.concat(parts, " "))
	local f, err = io.open(LOG_PATH, "a")
	if f then
		f:write(line)
		f:close()
	else
		vim.schedule(function()
			vim.notify("Yazi LSP log write failed: " .. tostring(err), vim.log.levels.WARN)
		end)
	end
end

-- ========================
-- Helpers
-- ========================

local function severity_to_icon(sev)
	local s = vim.diagnostic.severity
	return sev == s.ERROR and M.options.icons.error
		or sev == s.WARN and M.options.icons.warning
		or sev == s.INFO and M.options.icons.info
		or M.options.icons.other
end

local function path_to_url(path)
	local real = vim.loop.fs_realpath(path) or path
	return real:gsub(" ", "%%20")
end

-- ========================
-- Filetype detection (IMPROVED for C++/Go)
-- ========================

-- Map common extensions to filetypes for faster lookup
local FILETYPE_MAP = {
	-- C/C++
	c = "c",
	h = "c",
	cpp = "cpp",
	cc = "cpp",
	cxx = "cpp",
	hpp = "cpp",
	hxx = "cpp",
	-- Go
	go = "go",
	-- Lua
	lua = "lua",
	-- Rust
	rs = "rust",
	-- Python
	py = "python",
	-- JavaScript/TypeScript
	js = "javascript",
	ts = "typescript",
	jsx = "javascriptreact",
	tsx = "typescriptreact",
}

local function detect_filetype(path)
	if not path or path == "" then
		return nil
	end

	-- Try extension-based lookup first
	local ext = vim.fn.fnamemodify(path, ":e")
	if FILETYPE_MAP[ext] then
		return FILETYPE_MAP[ext]
	end

	-- Fall back to vim.filetype.match
	local ft = vim.filetype.match({ filename = path })
	if ft then
		return ft
	end

	-- Last resort: load buffer and check
	local bufnr = vim.fn.bufadd(path)
	vim.fn.bufload(bufnr)
	ft = vim.filetype.match({ buf = bufnr })
	vim.api.nvim_buf_delete(bufnr, { force = true })
	return ft
end

local function get_filetype(path)
	local ext = vim.fn.fnamemodify(path, ":e")
	if detected_filetypes[ext] ~= nil then
		return detected_filetypes[ext] or nil
	end
	local ft = detect_filetype(path)
	detected_filetypes[ext] = ft or false
	if not ft then
		log("DEBUG", "Cannot detect filetype for", path)
	else
		log("DEBUG", "Detected filetype", ft, "for", path)
	end
	return ft
end

-- ========================
-- Workspace traversal
-- ========================

local function is_ignored_filetype(name)
	local suffix = name:match("%.[^%.]+$")
	return suffix ~= nil and M.options.files.ignore_types[suffix] == true
end

local function collect_workspace_files(root)
	local files = {}
	local function traverse(dir)
		local fs = vim.loop.fs_scandir(dir)
		if not fs then
			return
		end
		while true do
			if #files >= M.options.memory.max_files then
				log("DEBUG", "Reached max files limit:", M.options.memory.max_files)
				return
			end
			local name, t = vim.loop.fs_scandir_next(fs)
			if not name then
				break
			end
			if M.options.files.ignore_dirs[name] or is_ignored_filetype(name) then
				goto continue
			end
			local full = dir .. "/" .. name
			if t == "directory" then
				traverse(full)
			elseif t == "file" then
				files[#files + 1] = vim.loop.fs_realpath(full) or full
			end
			::continue::
		end
	end
	traverse(root)
	log("INFO", "Collected", #files, "files in root", root)
	return files
end

-- ========================
-- Open buffers for client
-- ========================

local function open_file_for_client(client, path)
	if opened_files[path] then
		log("DEBUG", "File: ", path, " already collected. Skipping")
		return
	end
	opened_files[path] = true

	local ft = get_filetype(path)
	if not ft then
		log("DEBUG", "Skipping file - no filetype:", path)
		return
	end

	-- Check if client supports this filetype
	local supported = false
	if client.config.filetypes then
		for _, supported_ft in ipairs(client.config.filetypes) do
			if ft == supported_ft then
				supported = true
				break
			end
		end
	end

	if not supported then
		log("DEBUG", "Filetype", ft, "not supported by client", client.name, "for file:", path)
		return
	end

	-- Check if file is within root directory
	local root = client.config.root_dir or vim.loop.cwd()
	if not vim.startswith(path, root) then
		log("DEBUG", "File outside root:", path, "root:", root)
		return
	end

	local bufnr = vim.fn.bufnr(path, false)
	if bufnr == -1 then
		bufnr = vim.fn.bufnr(path, true)
		vim.schedule(function()
			vim.fn.bufload(bufnr)
			local params = {
				textDocument = {
					uri = vim.uri_from_fname(path),
					languageId = ft,
					version = 0,
					text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n"),
				},
			}
			log("INFO", "Sent didOpen for", path, "filetype:", ft, "client:", client.name)
			client.notify("textDocument/didOpen", params)
		end)
	else
		log("DEBUG", "Buffer already exists, skipping didOpen:", path)
	end
end

-- ========================
-- Populate workspace (TWO-PHASE: current dir first, then root)
-- ========================

local function populate_workspace(client, bufnr)
	local current = vim.api.nvim_buf_get_name(bufnr)
	local cwd = vim.fn.fnamemodify(current, ":h")
	if cwd == M.options.dev_folder then
		log("DEBUG", "Returning because cwd is dev folder")
		return
	end
	if loaded_clients[client.id] then
		log("DEBUG", "Client already loaded:", client.name)
		return
	end
	loaded_clients[client.id] = true

	if not client:supports_method("textDocument/didOpen") then
		log("DEBUG", "Client doesn't support didOpen:", client.name)
		return
	end

	if not client.config or not client.config.filetypes then
		log("DEBUG", "Client has no config or filetypes:", client.name)
		return
	end

	log("INFO", "Populating workspace for client:", client.name)
	log("INFO", "Supported filetypes:", table.concat(client.config.filetypes, ", "))

	local changed_dir = false
	local files = collect_workspace_files(cwd)
	local i = 1
	log("INFO", "Current directory:", cwd)
	log("INFO", "Current file:", current)

	-- PHASE 1: Scan current directory first
	log("INFO", "Phase 1: Found", #files, "files in current directory")

	local function open_next_batch()
		for _ = 1, M.options.memory.files_per_batch do
			if i > #files then
				break
			end
			local opened_files_count = vim.tbl_count(opened_files)
			log("INFO", opened_files_count)
			if opened_files_count >= M.options.memory.max_files then
				log("INFO", "Reached opened files:", opened_files_count, " max:", M.options.memory.max_files)
				return
			end

			if #vim.api.nvim_list_bufs() >= M.options.memory.max_lsp_buffer_files then
				log("INFO", "Reached max LSP buffer files:", M.options.memory.max_lsp_buffer_files)
				return
			end
			local path = files[i]
			i = i + 1
			if path ~= current then
				open_file_for_client(client, path)
			end
		end

		if i <= #files then
			-- Continue with current file list
			vim.defer_fn(open_next_batch, 50)
		elseif not changed_dir then
			-- PHASE 2: Switch to root directory if we have space and directories differ
			log("INFO", "Phase 1 complete. Opened", vim.tbl_count(opened_files), "files from current directory")
			log("INFO", "Phase 2: Switching to root directory")

			local root = client.config.root_dir or vim.loop.cwd()
			files = collect_workspace_files(root)
			i = 1
			changed_dir = true
			vim.defer_fn(open_next_batch, 50)

			log("INFO", "Phase 2: Found", #files, "files in root directory")
		else
			-- All done
			log(
				"INFO",
				"Finished populating workspace. Opened",
				vim.tbl_count(opened_files),
				"files for client:",
				client.name
			)
		end
	end

	vim.schedule(function()
		open_next_batch()
	end)
end

-- ========================
-- Dump diagnostics
-- ========================

local function dump_lsp_data()
	if dumping then
		return
	end
	dumping = true

	local out = {}
	local diag_buffers = 0

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			local diags = vim.diagnostic.get(bufnr)

			if #diags > 0 then
				diag_buffers = diag_buffers + 1
				local path = vim.api.nvim_buf_get_name(bufnr)
				if path ~= "" then
					local max_sev
					for _, d in ipairs(diags) do
						if not max_sev or d.severity < max_sev then
							max_sev = d.severity
						end
					end
					out[path_to_url(path)] = {
						severity = max_sev,
						icon = severity_to_icon(max_sev),
						count = #diags,
						time = os.date("%Y-%m-%d %H:%M:%S"),
					}
				end
			end
		end
	end

	log("DEBUG", "Dumping diagnostics, buffers:", #vim.api.nvim_list_bufs(), "with diags:", diag_buffers)

	if diag_buffers == 0 then
		dumping = false
		return
	end

	local f, err = io.open(OUT_PATH, "w")
	if not f then
		log("ERROR", "Failed to write output:", err)
		dumping = false
		return
	end

	f:write("return {\n")
	for k, v in pairs(out) do
		f:write(
			string.format(
				"  [%q] = { severity = %d, icon = %q, count = %d, time = %q },\n",
				k,
				v.severity,
				v.icon,
				v.count,
				v.time
			)
		)
	end
	f:write("}\n")
	f:close()

	log("INFO", "Wrote Yazi diagnostics:", OUT_PATH, "entries:", vim.tbl_count(out))
	dumping = false
end

-- ========================
-- Autocommands
-- ========================
function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.options, opts or {})
	vim.api.nvim_create_autocmd("LspAttach", {
		callback = function(args)
			if not M.options.enabled then
				return
			end
			local client = vim.lsp.get_client_by_id(args.data.client_id)
			log("INFO", "LspAttach event - client:", client.name, "buffer:", args.buf)
			populate_workspace(client, args.buf)
		end,
	})

	vim.api.nvim_create_autocmd("DiagnosticChanged", {
		callback = function(args)
			if not M.options.enabled then
				return
			end
			local bufnr = args.buf
			local diags = vim.diagnostic.get(bufnr)
			if #diags > 0 then
				log("DEBUG", "Diagnostics changed for", vim.api.nvim_buf_get_name(bufnr), "count:", #diags)
			end

			if dump_timer then
				dump_timer:stop()
				dump_timer:close()
			end
			dump_timer = vim.loop.new_timer()
			dump_timer:start(M.options.memory.debounce_ms, 0, vim.schedule_wrap(dump_lsp_data))
		end,
	})
end

return M
