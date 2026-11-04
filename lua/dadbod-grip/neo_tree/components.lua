-- neo_tree/components.lua: how the grip source's nodes are drawn. The marks
-- and highlight groups are the built-in sidebar's (schema.lua's render), so
-- the two trees read the same.

local common = require("neo-tree.sources.common.components")
local highlights = require("neo-tree.ui.highlights")

local M = {}

--- Groups and folders read as headings, like the built-in sidebar's.
local HEADINGS = { schema = true, header = true, facet = true, partitions = true }

--- Icons after a table's or view's fold mark. Override per renderer, e.g.
--- { "grip_icon", table = "T", view = "V" }; an empty string drops the icon.
local OBJECT_ICONS = { table = "󰓫", view = "󰈈" }

function M.grip_icon(config, node)
  local extra = node.extra or {}
  local text
  if extra.kind == "root" or extra.kind == "message" then
    return { text = "" }
  elseif node.type == "directory" then
    text = node:is_expanded() and "▼" or "▶"
    if extra.kind == "table" and not extra.is_file then
      local object = extra.type == "view" and "view" or "table"
      local icon = config[object] or OBJECT_ICONS[object]
      if icon ~= "" then
        return {
          { text = text .. " ", highlight = highlights.FILE_ICON },
          { text = icon .. " ", highlight = highlights.DIRECTORY_ICON },
        }
      end
    end
  elseif extra.kind == "routine" then
    text = extra.type == "procedure" and "◇" or "ƒ"
  elseif extra.kind == "column" then
    text = extra.pk and (extra.fk and "🔑🔗" or "🔑") or (extra.fk and "🔗" or " ")
  else
    text = extra.icon or " "
  end
  return { text = text .. " ", highlight = HEADINGS[extra.kind] and "GripHeader" or highlights.FILE_ICON }
end

function M.grip_name(_, node)
  local extra = node.extra or {}
  local highlight = highlights.FILE_NAME
  if extra.kind == "root" then
    highlight = "GripConnAccentBold"
  elseif HEADINGS[extra.kind] then
    highlight = "GripHeader"
  end
  return { text = node.name, highlight = highlight }
end

--- A column's abbreviated type, dimmed, after its name.
function M.grip_detail(_, node)
  local extra = node.extra or {}
  if extra.kind ~= "column" or not extra.data_type then return {} end
  local abbrev = require("dadbod-grip.schema").abbrev_type(extra.data_type)
  if abbrev == "" then return {} end
  return { text = "  " .. abbrev, highlight = "GripReadonly" }
end

return vim.tbl_deep_extend("force", common, M)
