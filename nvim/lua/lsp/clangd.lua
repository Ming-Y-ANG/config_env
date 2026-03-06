-- https://blog.roj.ac.cn/nvim-for-oi/clangd.html
-- lua/lsp/clangd.lua

local on_attach = require("lsp.on_attach")
local capabilities = require("lsp.capabilities").get()

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "c", "cpp", "objc", "objcpp", "cuda" },
  callback = function(args)
    vim.lsp.start({
      name = "clangd",
      cmd = {
        "clangd",
        "--query-driver=/usr/bin/gcc,**/gcc-*,/usr/bin/g++-*,**/g++-*",
        "--background-index",
        "--clang-tidy",
        "--completion-style=detailed",
      },
      -- 新的 root 查找方式（替代 lspconfig.util.root_pattern）
      root_dir = vim.fs.root(args.buf, {
        "compile_commands.json",
        "compile_flags.txt",
        ".git",
      }),
      filetypes = { "c", "cpp", "objc", "objcpp", "cuda" },
      on_attach = on_attach,
      capabilities = capabilities,
	  reuse_client = function()
		return false
	  end,
	})
  end,
})
