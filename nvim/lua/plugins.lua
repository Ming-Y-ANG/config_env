-- lazypath: ~/.local/share/nvim/lazy/lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end

vim.opt.rtp:prepend(lazypath)

local nvim_tree = {
	"nvim-tree/nvim-tree.lua",
	version = "*",
	dependencies = {"nvim-tree/nvim-web-devicons"},
	config = function()
		require("nvim-tree").setup{}
		vim.keymap.set(
			"n",
			"<leader>nt",
			":NvimTreeToggle<CR>",
			{ noremap = true, silent = true, desc = "Toggle NvimTree" }
			)
	end,
}

local lualine = {
    'nvim-lualine/lualine.nvim',
    config = function()
		require('lualine').setup({
				options = { theme = 'gruvbox' }
			}
		)
    end
}

local nvim_surround = {
    "kylechui/nvim-surround",
    version = "^4.0.0", -- Use for stability; omit to use `main` branch for the latest features
    event = "VeryLazy",
    -- Optional: See `:h nvim-surround.configuration` and `:h nvim-surround.setup` for details
    -- config = function()
    --     require("nvim-surround").setup({
    --         -- Put your configuration here
    --     })
    -- end
}

local nvim_autopairs = {
    'windwp/nvim-autopairs',
    event = "InsertEnter",
    config = true
    -- use opts = {} for passing setup options
    -- this is equivalent to setup({}) function
}

local which_key = {
	"folke/which-key.nvim",
	event = "VeryLazy",
	opts = {
		-- your configuration comes here
		-- or leave it empty to use the default settings
		-- refer to the configuration section below
	},
	keys = {
		{
			"<leader>?",
			function()
				--require("which-key").show({ global = false })
				require("which-key").show()
			end,
			desc = "which-key",
		},
	},
}

--dep: npm install -g tree-sitter-cli
--vim cmd: :TSInstall c|cpp|lua  --> ~/.local/share/nvim/lazy/nvim-treesitter/parser/
local treesitter = {
	'nvim-treesitter/nvim-treesitter',
	lazy = false,
	build = ':TSUpdate',
	--event = "BufReadPost",
	config = function()
		require("nvim-treesitter").setup {
			ensure_installed = { "c", "cpp", "lua" },
			highlight = { enable = true },
			indent = { enable = true },
			folding = { enable = true },
		}
	end,
}

local gruvbox = { 
	"ellisonleao/gruvbox.nvim", 
	priority = 1000 ,
	config = true, 
}

local opencode = {
	"nickjvandyke/opencode.nvim",
	version = "*", -- Latest stable release
	dependencies = {
		{
			-- `snacks.nvim` integration is recommended, but optional
			---@module "snacks" <- Loads `snacks.nvim` types for configuration intellisense
			"folke/snacks.nvim",
			optional = true,
			opts = {
				input = {}, -- Enhances `ask()`
				picker = { -- Enhances `select()`
					actions = {
						opencode_send = function(...) return require("opencode").snacks_picker_send(...) end,
					},
					win = {
						input = {
							keys = {
								["<a-a>"] = { "opencode_send", mode = { "n", "i" } },
							},
						},
					},
				},
			},
		},
	},
	config = function()
		---@type opencode.Opts
		vim.g.opencode_opts = {
			-- Your configuration, if any; goto definition on the type or field for details
		}

		vim.o.autoread = true -- Required for `opts.events.reload`

		-- Recommended/example keymaps
		vim.keymap.set({ "n", "x" }, "<C-a>", function() require("opencode").ask("@this: ", { submit = true }) end, { desc = "Ask opencode…" })
		vim.keymap.set({ "n", "x" }, "<C-x>", function() require("opencode").select() end,                          { desc = "Execute opencode action…" })
		vim.keymap.set({ "n", "t" }, "<C-.>", function() require("opencode").toggle() end,                          { desc = "Toggle opencode" })

		vim.keymap.set({ "n", "x" }, "go",  function() return require("opencode").operator("@this ") end,        { desc = "Add range to opencode", expr = true })
		vim.keymap.set("n",          "goo", function() return require("opencode").operator("@this ") .. "_" end, { desc = "Add line to opencode", expr = true })

		vim.keymap.set("n", "<S-C-u>", function() require("opencode").command("session.half.page.up") end,   { desc = "Scroll opencode up" })
		vim.keymap.set("n", "<S-C-d>", function() require("opencode").command("session.half.page.down") end, { desc = "Scroll opencode down" })

		-- You may want these if you use the opinionated `<C-a>` and `<C-x>` keymaps above — otherwise consider `<leader>o…` (and remove terminal mode from the `toggle` keymap)
		vim.keymap.set("n", "+", "<C-a>", { desc = "Increment under cursor", noremap = true })
		vim.keymap.set("n", "-", "<C-x>", { desc = "Decrement under cursor", noremap = true })
	end,
}

local snacks = {
	"folke/snacks.nvim",
	priority = 1000,
	lazy = false,
	---@type snacks.Config
	opts = {
		-- your configuration comes here
		-- or leave it empty to use the default settings
		-- refer to the configuration section below
		bigfile = { enabled = true },
		dashboard = { enabled = true },
		explorer = { enabled = true },
		indent = { enabled = true },
		input = { enabled = true },
		picker = { enabled = true },
		notifier = { enabled = true },
		quickfile = { enabled = true },
		scope = { enabled = true },
		scroll = { enabled = true },
		statuscolumn = { enabled = true },
		words = { enabled = true },
	},
}

local barbar = {
	'romgrk/barbar.nvim',
	dependencies = {
		'lewis6991/gitsigns.nvim', -- OPTIONAL: for git status
		'nvim-tree/nvim-web-devicons', -- OPTIONAL: for file icons
	},
	init = function() vim.g.barbar_auto_setup = false end,
	opts = {
		-- lazy.nvim will automatically call setup for you. put your options here, anything missing will use the default:
		-- animation = true,
		-- insert_at_start = true,
		-- …etc.
	},
	keys = {
		{ "<leader>nt", "<cmd>NvimTreeToggle<CR>", desc = "Toggle NvimTree" },
		{ "<Tab>", "<cmd>BufferNext<CR>", desc = "BufferNext NvimTree" },
		{ "<S-Tab>", "<cmd>BufferPrevious<CR>", desc = "BufferPrevious NvimTree" },
	},

	version = '^1.0.0', -- optional: only update when a new 1.x version is released
}

local tagbar = {
	"preservim/tagbar",
	cmd = { "TagbarToggle", "TagbarOpen" }, -- 懒加载
	keys = {
		{ "<F2>", "<cmd>TagbarToggle<CR>", desc = "TagbarToggle" },
	},
}

local cmp = {
	"hrsh7th/nvim-cmp",
	event = "InsertEnter",
	version = false,
	dependencies = {
		"hrsh7th/cmp-nvim-lsp",
		"hrsh7th/cmp-buffer",
		"hrsh7th/cmp-path",
	},
	opts = function()
		local cmp = require("cmp")
		local defaults = require("cmp.config.default")()
		vim.api.nvim_set_hl(0, "CmpGhostText", { link = "Comment", default = true })
		return {
			completion = {
				completeopt = "menu,menuone,noinsert",
			},
			preselect = cmp.PreselectMode.Item,
			mapping = cmp.mapping.preset.insert({
					["<C-b>"] = cmp.mapping.scroll_docs(-4),
					["<C-f>"] = cmp.mapping.scroll_docs(4),

					["<C-n>"] = cmp.mapping.select_next_item(),
					["<C-p>"] = cmp.mapping.select_prev_item(),

					["<C-Space>"] = cmp.mapping.complete(),

					["<CR>"] = cmp.mapping.confirm({ select = true }),
					["<C-y>"] = cmp.mapping.confirm({ select = true }),

					["<Tab>"] = cmp.mapping.select_next_item(),
					["<S-Tab>"] = cmp.mapping.select_prev_item(),

					["<C-CR>"] = function(fallback)
						cmp.abort()
						fallback()
					end,
				}),
			sources = cmp.config.sources({
					{ name = "nvim_lsp" },
					{ name = "path" },
				}, {
					{ name = "buffer" },
				}),
			formatting = {
				format = function(_, item)
					local kind_icons = {
						Text = "󰉿 ",
						Method = "󰆧 ",
						Function = "󰊕 ",
						Constructor = " ",
						Field = "󰜢 ",
						Variable = "󰀫 ",
						Class = "󰠱 ",
						Interface = " ",
						Module = " ",
						Property = "󰜢 ",
						Unit = "󰑭 ",
						Value = "󰎠 ",
						Enum = " ",
						Keyword = "󰌋 ",
						Snippet = " ",
						Color = "󰏘 ",
						File = "󰈙 ",
						Reference = "󰈇 ",
						Folder = "󰉋 ",
						EnumMember = " ",
						Constant = "󰏿 ",
						Struct = "󰙅 ",
						Event = " ",
						Operator = "󰆕 ",
						TypeParameter = "󰊄 ",
					}
					if kind_icons[item.kind] then
						item.kind = kind_icons[item.kind] .. item.kind
					end
					return item
				end,
			},
			experimental = {
				ghost_text = false,
			},
			sorting = defaults.sorting,
		}
	end,
}

local lsp = {
	"neovim/nvim-lspconfig",
}

local alpha_nvim = {
	'goolord/alpha-nvim',
	dependencies = { 'nvim-mini/mini.icons' },
	config = function ()
		require'alpha'.setup(require'alpha.themes.startify'.config)
	end
};

--dep: sudo apt install ripgrep fd-find
local telescope = {
    'nvim-telescope/telescope.nvim', version = '*',
    dependencies = {
        'nvim-lua/plenary.nvim',
        -- optional but recommended
        { 'nvim-telescope/telescope-fzf-native.nvim', build = 'make' },
    },
    keys = {
        {
            "<leader>ff",
            function() require("telescope.builtin").find_files() end,
            desc = "Find Files"
        },
        {
            "<leader>fg",
            function() require("telescope.builtin").live_grep() end,
            desc = "Live Grep"
        },
        {
            "<leader>fb",
            function() require("telescope.builtin").buffers() end,
            desc = "Buffers"
        },
        {
            "<leader>fh",
            function() require("telescope.builtin").help_tags() end,
            desc = "Help Tags"
        },
        {
            "<leader>fs",
            function() require("telescope.builtin").lsp_document_symbols() end,
            desc = "File symbols (functions)"
        },
    },
}

local nvim_ufo = {
	"kevinhwang91/nvim-ufo",
	dependencies = { "kevinhwang91/promise-async" },
	event = "VeryLazy",  -- 懒加载时机，可改成 BufReadPost
	config = function()
		-- 基础折叠选项
		vim.o.foldcolumn = '1'
		vim.o.foldlevel = 99
		vim.o.foldlevelstart = 99
		vim.o.foldenable = true
		-- 折叠快捷键
		vim.keymap.set('n', 'zR', require('ufo').openAllFolds)
		vim.keymap.set('n', 'zM', require('ufo').closeAllFolds)
		vim.keymap.set("n", "<space>", "za", { desc = "Toggle fold under cursor" })
		require('ufo').setup()
	end
}

local plugins = {
	nvim_tree,
	lualine,
	nvim_surround,
	nvim_autopairs,
	which_key,
	treesitter,
	gruvbox,
	opencode,
	snacks,
	barbar,
	tagbar,
	cmp,
	lsp,
	alpha_nvim,
	telescope,
	nvim_ufo,
}

require("lazy").setup(plugins)
