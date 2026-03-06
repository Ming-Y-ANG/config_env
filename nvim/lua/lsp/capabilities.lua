-- lua/lsp/capabilities.lua
local M = {}

function M.get()
  local ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
  if ok then
    return cmp_lsp.default_capabilities(
      vim.lsp.protocol.make_client_capabilities()
    )
  end
  return vim.lsp.protocol.make_client_capabilities()
end

return M
