--- Treesitter-based markdown highlighting for agent chat messages.
---
--- Agent messages are streamed into the chat buffer as raw markdown. This
--- module parses a message's region with the `markdown` parser and applies the
--- matching highlight groups via extmarks, so `**bold**`, `` `code` ``,
--- headings, lists, and fenced code blocks (with their own language's syntax
--- highlighting) render like a normal markdown buffer.
---
--- A single namespace is reused across all blocks. Each block's marks live
--- within its own row range, so we can clear and re-apply a block in place as
--- its text grows during streaming.

local M = {}

local NS = vim.api.nvim_create_namespace("agent_nvim_chat_markdown")

local function parser_ok(lang)
  return pcall(vim.treesitter.query.get, lang, "highlights")
end

--- Apply markdown highlights to buffer rows [start_row, end_row) (start_row
--- inclusive, end_row exclusive). Clears any prior marks in that range first.
function M.apply(buf, start_row, end_row)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.treesitter then
    return
  end
  local total = vim.api.nvim_buf_line_count(buf)
  start_row = math.max(0, math.floor(start_row or 0))
  end_row = math.min(total, math.floor(end_row or start_row))

  -- Clear prior marks in this region first.
  vim.api.nvim_buf_clear_namespace(buf, NS, start_row, end_row)

  local lines = vim.api.nvim_buf_get_lines(buf, start_row, end_row, false)
  local text = table.concat(lines, "\n")
  if text == "" then
    return
  end

  local ok, parser = pcall(vim.treesitter.get_string_parser, text, "markdown")
  if not ok then
    return
  end
  parser:parse()
  local root = parser:parse()[1]:root()

  -- 1. Block-level markdown highlights (headings, lists, code fences, ...).
  local ok_q, q = pcall(vim.treesitter.query.get, "markdown", "highlights")
  if ok_q and q then
    for id, node in q:iter_captures(root, text, 0, -1) do
      local name = q.captures[id]
      if name and name:sub(1, 1) ~= "_" then
        local sr, sc, er, ec = node:range()
        vim.api.nvim_buf_set_extmark(buf, NS, start_row + sr, sc, {
          end_row = start_row + er,
          end_col = ec,
          hl_group = "@" .. name,
        })
      end
    end
  end

  -- 2. Inline markdown (bold, italic, code, links). Conceal the delimiter
  -- markers (**, `, ...) so inline syntax reads cleanly.
  local ok_iq, iq = pcall(vim.treesitter.query.get, "markdown_inline", "highlights")
  if ok_iq and iq then
    -- Each `inline` node's text is a substring of the block, so a sub-node's
    -- columns come back relative to the inline node's own text. Convert them
    -- back to absolute coordinates.
    --
    -- The inline node's text contains newlines, but a sub-node's column is a
    -- byte offset INTO ITS OWN LINE, not from the inline node's start. So the
    -- inline start column may only be added for sub-nodes on the inline node's
    -- FIRST line (isr == 0):
    --
    --   * inline starts at (row 0, col 20), sub-node at rel (0, 2) -> 22  OK
    --   * inline starts at (row 0, col 20), sub-node at rel (1, 2) -> col 2
    --     (adding 20 would shift the range right and conceal the wrong bytes)
    --
    -- Getting this wrong makes concealment run past its marker and delete
    -- characters from the rendered text.
    local function inline(node)
      if node:type() == "inline" then
        local ir, ic = node:range()
        local itext = vim.treesitter.get_node_text(node, text)
        local ok_p, ip = pcall(vim.treesitter.get_string_parser, itext, "markdown_inline")
        if ok_p then
          ip:parse()
          local iroot = ip:parse()[1]:root()
          for iid, inode in iq:iter_captures(iroot, itext, 0, -1) do
            local nm = iq.captures[iid]
            if nm and nm:sub(1, 1) ~= "_" then
              local isr, isc, ier, iec = inode:range()
              local col = isr == 0 and (ic + isc) or isc
              local end_col = ier == 0 and (ic + iec) or iec
              local row = start_row + ir + isr
              local end_row = start_row + ir + ier
              -- A range that crosses lines is not a delimiter; skip it rather
              -- than letting it span text it does not own.
              if row == end_row and end_col > col then
                if nm == "conceal" then
                  vim.api.nvim_buf_set_extmark(buf, NS, row, col, {
                    end_row = end_row,
                    end_col = end_col,
                    conceal = "",
                  })
                else
                  vim.api.nvim_buf_set_extmark(buf, NS, row, col, {
                    end_row = end_row,
                    end_col = end_col,
                    hl_group = "@" .. nm,
                  })
                end
              end
            end
          end
        end
      end
      for ch in node:iter_children() do
        inline(ch)
      end
    end
    inline(root)
  end

  -- 3. Fenced code blocks: highlight with the fence's own language parser.
  local function fences(node)
    if node:type() == "fenced_code_block" then
      local lang, content = nil, nil
      for ch in node:iter_children() do
        if ch:type() == "info_string" then
          for g in ch:iter_children() do
            if g:type() == "language" then
              lang = vim.treesitter.get_node_text(g, text)
            end
          end
        elseif ch:type() == "code_fence_content" then
          content = ch
        end
      end
      if lang and content and parser_ok(lang) then
        local csr, _, cer, _ = content:range()
        local ctext = vim.treesitter.get_node_text(content, text)
        local ok_p, lp = pcall(vim.treesitter.get_string_parser, ctext, lang)
        if ok_p then
          lp:parse()
          local lq = vim.treesitter.query.get(lang, "highlights")
          for lid, lnode in lq:iter_captures(lp:parse()[1]:root(), ctext, 0, -1) do
            local nm = lq.captures[lid]
            if nm and nm:sub(1, 1) ~= "_" then
              local lsr, lsc, ler, lec = lnode:range()
              vim.api.nvim_buf_set_extmark(buf, NS, start_row + csr + lsr, lsc, {
                end_row = start_row + csr + ler,
                end_col = lec,
                hl_group = "@" .. lang .. "." .. nm,
              })
            end
          end
        end
      end
    end
    for ch in node:iter_children() do
      fences(ch)
    end
  end
  fences(root)
end

return M
