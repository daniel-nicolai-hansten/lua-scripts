--[[
  This file is part of darktable,
  copyright (c) 2024 Giorgio Massussi
  copyright (c) 2026 Colin Holzman

  darktable is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  darktable is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with darktable.  If not, see <http://www.gnu.org/licenses/>.
]]
--[[
IMMICH
Upload selection to an Immich server

USAGE
This plugin allows you to upload selected photos to an Immich server (https://immich.app/)
Each image is tracked with darktable tags so re-exporting is safe and cheap:
* an "immich|asset|<id>" tag remembers the uploaded asset id for that image
* an "immich|change|<timestamp>" tag remembers the darktable change timestamp at export time
If an image's change timestamp still matches the cached tag, the export is skipped
locally without contacting the Immich server at all (see the "Skip unchanged" options
below). If the image changed since the last export, the "Re-export Behavior" option
controls what happens to the previous asset on the server: delete/trash it, stack the
new upload with it, or both.

Album assignment is controlled by the "Album mode" option:
* No album: exported assets are not added to any album
* Custom / Copy existing + Custom: assets are added to the album named in the "Album Title" field
* Copy albums from existing asset: assets are added to whatever albums the previous
  version of the asset already belonged to on the server
* Use Album Title: same as Custom, using the "Album Title" field as the album name
The "Album Title" field is prefilled with the folder name of the exported image when
a title-based mode is selected, but can be edited freely.

In the lua options you must specify:
* the hostname of the server immich
* an api key generated in the Account settings - API Keys menu of the immich server

USAGE
* install luasec, cjson, and luasocket for darktable's Lua version (currently 5.4) on your system
* if darktable can't find them (common on macOS/Windows, where it bundles its own
  Lua), set the "immich: Lua module install prefix" preference in the lua options
  to the folder containing share/lua/<ver> and lib/lua/<ver>, then restart

]]
local dt = require "darktable"
local du = require "lib/dtutils"
local df = require "lib/dtutils.file"
local log = require "lib/dtutils.log"

local gettext = dt.gettext.gettext

local function _(msgid)
    return gettext(msgid)
end

-- forward declaration so store_image() (defined above its widget) resolves this
-- as an upvalue rather than a nil global
local title_widget
local album_mode_widget
local album_title_row_widget
local existing_asset_action_widget
local prefill_title_widget_from_images

local ALBUM_MODE_NONE = 1
local ALBUM_MODE_TITLE = 2
local ALBUM_MODE_COPY_EXISTING = 3
local ALBUM_MODE_COPY_AND_TITLE = 4
local ALBUM_MODE_USE_ALBUM_TITLE = 5

local EXISTING_ASSET_ACTION_DELETE = 1
local EXISTING_ASSET_ACTION_STACK = 2
local EXISTING_ASSET_ACTION_DELETE_AND_STACK = 3
local EXISTING_ASSET_ACTION_DELETE_REUPLOAD = 4
local EXISTING_ASSET_ACTION_STACK_REUPLOAD = 5
local EXISTING_ASSET_ACTION_DELETE_AND_STACK_REUPLOAD = 6

local function is_reupload_variant(existing_asset_action)
  return existing_asset_action == EXISTING_ASSET_ACTION_DELETE_REUPLOAD
      or existing_asset_action == EXISTING_ASSET_ACTION_STACK_REUPLOAD
      or existing_asset_action == EXISTING_ASSET_ACTION_DELETE_AND_STACK_REUPLOAD
end

-- Immich requires a deviceId on every uploaded asset, but we no longer use it to
-- look up previously uploaded assets -- that's handled entirely by the local
-- "immich|asset|..." / "immich|change|..." darktable tags -- so a fixed value is fine.
local IMMICH_DEVICE_ID = "darktable"

-- The version (e.g. "5.4") of the Lua interpreter darktable is running -- bundled
-- on macOS/Windows, the system Lua on Linux. Derived from _VERSION rather than
-- hardcoded, so the search paths and user-facing messages keep working if
-- darktable's Lua changes.
local lua_version = _VERSION:match("(%d+%.%d+)") or "5.4"
local DEFAULT_LOG_LEVEL = log.debug

local function debug_log(message)
  local enabled = dt.preferences.read("immich", "immich_debug_logging", "bool")
  if enabled then
    log.msg(log.debug, "[immich] " .. tostring(message))
  end
end

local function image_can_skip_remote_work(image, existing_asset_action)
  if is_reupload_variant(existing_asset_action) then
    return false
  end

  local cached_asset_id = nil
  local cached_change_marker = nil
  local tags = image.get_tags(image)
  if tags == nil then
    return false
  end

  for _,tag in ipairs(tags) do
    if tag ~= nil and tag.name ~= nil then
      if cached_asset_id == nil then
        cached_asset_id = tag.name:match("^immich%|asset%|(.-)$")
      end
      if cached_change_marker == nil then
        cached_change_marker = tag.name:match("^immich%|change%|(.-)$")
      end
      if cached_asset_id ~= nil and cached_change_marker ~= nil then
        break
      end
    end
  end

  if cached_asset_id == nil or cached_change_marker == nil then
    return false
  end

  return cached_change_marker == tostring(image.change_timestamp or "")
end



-- darktable can't always find where luasocket/luasec/lua-cjson were installed: on
-- macOS and Windows it bundles its own Lua whose search paths point into the app
-- bundle, so Homebrew/luarocks dirs are invisible. The "immich_lua_root" pref
-- below lets the user name the install prefix -- the folder that contains
-- share/lua/<ver> and lib/lua/<ver> -- and we add it to package.path/cpath before
-- requiring. It is pre-populated with an OS-appropriate guess; on Linux the system
-- Lua already covers the standard locations, so the guess is empty (no-op).
local function default_lua_root()
  local os_name = dt.configuration.running_os
  local candidates = {}
  if os_name == "macos" then
    local home = os.getenv("HOME")
    if home then candidates[#candidates + 1] = home .. "/.luarocks" end  -- user tree (luarocks default)
    candidates[#candidates + 1] = "/opt/homebrew"   -- Homebrew (Apple Silicon)
    candidates[#candidates + 1] = "/usr/local"      -- Homebrew (Intel)
  elseif os_name == "windows" then
    candidates[#candidates + 1] = "C:\\luarocks"    -- typical luarocks install prefix
  else
    return ""                                       -- Linux: system Lua already finds them
  end
  -- prefer a candidate that actually holds the C modules for this Lua version
  for _, c in ipairs(candidates) do
    if df.test_file(c .. "/lib/lua/" .. lua_version, "d") then
      return c
    end
  end
  return candidates[1] or ""                        -- fall back to the most likely root
end

dt.preferences.register("immich", "immich_lua_root", "string",
  _("immich: Lua module install prefix"),
  _("RESTART REQUIRED: changes take effect only after darktable is restarted. Folder containing share/lua/<ver> and lib/lua/<ver> for luasocket, luasec and lua-cjson. Leave blank if darktable's Lua already finds them."),
  default_lua_root())

dt.preferences.register("immich", "immich_debug_logging", "bool",
  _("Immich debug logging"),
  _("Enable verbose debug messages for Immich uploads and album updates."),
  false)

log.log_level(DEFAULT_LOG_LEVEL)

local lua_root = dt.preferences.read("immich", "immich_lua_root", "string")
if lua_root == nil or lua_root == "" then
  lua_root = default_lua_root()
end
if lua_root ~= "" then
  local ext = dt.configuration.running_os == "windows" and "dll" or "so"
  package.path  = package.path
    .. ";" .. lua_root .. "/share/lua/" .. lua_version .. "/?.lua"
    .. ";" .. lua_root .. "/share/lua/" .. lua_version .. "/?/init.lua"
  package.cpath = package.cpath .. ";" .. lua_root .. "/lib/lua/" .. lua_version .. "/?." .. ext
end

-- Load optional deps defensively so a missing one yields an actionable message.
local missing = {}
local function need(modname, rock)
  local ok, mod = pcall(require, modname)
  if not ok then missing[#missing + 1] = string.format("'%s' (%s)", modname, rock) end
  return ok and mod or nil
end

local cjson = need("cjson.safe",  "lua-cjson")
local https = need("ssl.https",   "luasec")
local http  = need("socket.http", "luasocket")
local ltn12 = need("ltn12",       "luasocket")

du.check_min_api_version("7.0.0", "immich") 

local function call_immich_api(method,api,body,content_type) 
  local immichserver = dt.preferences.read("immich","immich_server","string")
  local client = string.find(immichserver,"^https") ~= nil and https or http
  local headers = { }
  headers["x-api-key"] = dt.preferences.read("immich","immich_key","string")
  local source = nil
  if body == nil then
  elseif (content_type == nil or content_type == "application/json") then
    headers["Content-Type"] = "application/json"
    source = cjson.encode(body)
    headers["Content-Length"] = string.len(source)
    source = ltn12.source.string(source)
  elseif (content_type == "multipart/form-data") then 
    local boundary = "----DarktableImmichBoundary" .. math.random(1, 1e16)
    headers["Content-Type"] = "multipart/form-data; boundary="..boundary
    source = ltn12.source.empty()
    local content_length = 0
    for name,value in pairs(body) do 
      if (value.filename ~= nil) then 
        local form_data_table = {}
        if (content_length > 0) then
          table.insert(form_data_table,"")
        end
        table.insert(form_data_table, "--"..boundary)
        table.insert(form_data_table, "Content-Disposition: form-data; name=\""..name.."\"; filename=\"".. value.filename .. "\"")
        table.insert(form_data_table, "Content-Type: application/octet-stream")
        table.insert(form_data_table, "")
        table.insert(form_data_table, "")
        local form_data = table.concat(form_data_table, "\r\n")
        content_length = content_length+value.file:seek("end")+string.len(form_data)
        value.file:seek("set",0)
        source = ltn12.source.simplify(ltn12.source.cat(source,
          ltn12.source.string(form_data),
          ltn12.source.file(value.file)))
      else 
        local form_data_table = {}
        if (content_length > 0) then
          table.insert(form_data_table,"")
        end
        table.insert(form_data_table, "--"..boundary)
        table.insert(form_data_table, "Content-Disposition: form-data; name=\""..name.."\"")
        table.insert(form_data_table, "")
        table.insert(form_data_table, value)
        local form_data = table.concat(form_data_table, "\r\n")
        content_length = content_length+string.len(form_data)
        source = ltn12.source.cat(source,ltn12.source.string(form_data))
      end
    end
    content_length = content_length+6+string.len(boundary)
    source = ltn12.source.cat(source,ltn12.source.string("\r\n--"..boundary.."--"))
    headers["Content-Length"] = content_length
  end
  
  debug_log("request " .. method .. " /api/" .. api)
  local res_table={}
  local res, err, response_headers = client.request{
    method=method,
    url=immichserver.."/api/"..api,
    headers=headers,
    source=source,
    sink=ltn12.sink.table(res_table)
  }
  if response_headers ~= nil and response_headers["content-type"] == "application/json; charset=utf-8" then
    local body_text = table.concat(res_table)
    debug_log("response " .. tostring(err) .. " for /api/" .. api .. " -> " .. body_text)
    return cjson.decode(body_text), err, response_headers
  end
  local body_text = table.concat(res_table)
  debug_log("response " .. tostring(err) .. " for /api/" .. api .. " -> " .. body_text)
  return body_text, err, response_headers
end

local function initialize(storage,format,images,high_quality,extra_data)
  if #missing > 0 then
    -- Stash the message for finalize: a dt.print here would be overwritten by
    -- darktable's own "no image to export" that follows the empty return.
    extra_data.error = string.format(_("immich: missing Lua libraries (luasocket, luasec, lua-cjson) for Lua %s — install them, set the 'Lua module install prefix' preference if needed, then restart"), lua_version)
    return {}   -- cancels the export
  end
  debug_log("initialize started for " .. tostring(#images) .. " images")
  extra_data.album_assets = {}
  extra_data.album_asset_updates = {}
  extra_data.remote_albums = {}
  extra_data.existing_asset_action = existing_asset_action_widget ~= nil
      and existing_asset_action_widget.selected or EXISTING_ASSET_ACTION_STACK
  extra_data.album_mode = album_mode_widget ~= nil and album_mode_widget.selected or ALBUM_MODE_NONE
  if extra_data.album_mode == ALBUM_MODE_TITLE
      or extra_data.album_mode == ALBUM_MODE_COPY_AND_TITLE
      or extra_data.album_mode == ALBUM_MODE_USE_ALBUM_TITLE then
    prefill_title_widget_from_images(images)
  end

  local all_images_skip_remote = #images > 0
  for _,image in ipairs(images) do
    if not image_can_skip_remote_work(image, extra_data.existing_asset_action) then
      all_images_skip_remote = false
      break
    end
  end
  if all_images_skip_remote then
    debug_log("all images matched local cache tags; skipping Immich auth and album lookups")
    return images
  end

  local _auth_res, auth_err = call_immich_api("GET", "auth/status")
  if auth_err == 403 then
    debug_log("authentication failed")
    extra_data.error = "Authentication error. Check your Immich API key in LUA settings."
    return {}
  elseif auth_err ~= 200 then
    debug_log("authentication check returned HTTP " .. tostring(auth_err))
    extra_data.error = "Error contacting Immich server: HTTP " .. auth_err
    return {}
  end

  if extra_data.album_mode == ALBUM_MODE_TITLE
      or extra_data.album_mode == ALBUM_MODE_COPY_AND_TITLE
      or extra_data.album_mode == ALBUM_MODE_USE_ALBUM_TITLE then
    local res_albums, err_albums = call_immich_api("GET","albums")

    if err_albums == 200 then
      debug_log("loaded " .. tostring(#res_albums) .. " existing albums")
      for _,album in ipairs(res_albums) do
        extra_data.remote_albums[album.albumName] = album.id
      end
    end
  else
    debug_log("album mode does not require album names; skipping full album list lookup")
  end

  return images
end

local function iso_exif_datetime_taken(image) 
  local yr,mo,dy,h,m,s = string.match(image.exif_datetime_taken, "(%d-):(%d-):(%d-) (%d-):(%d-):(%d+)")
  local timestamp = os.time{year=yr, month=mo, day=dy, hour=h, min=m, sec=s}
  return os.date("!%Y-%m-%dT%H:%M:%S", timestamp) .. "Z"
end
local function is_remote_asset_trashed(remote_asset)
  if remote_asset == nil then
    return false
  end

  local trashed = remote_asset.isTrashed
  if trashed == nil then
    trashed = remote_asset.trashed
  end
  if trashed == nil then
    trashed = remote_asset.is_deleted
  end

  return trashed == true or trashed == "true" or trashed == 1
end

local function get_asset_details(asset_id)
  if asset_id == nil or asset_id == "" then
    return nil, nil
  end

  local res_asset, err_asset = call_immich_api("GET", "assets/" .. tostring(asset_id))
  if err_asset ~= 200 or res_asset == nil then
    return nil, err_asset
  end

  return res_asset, err_asset
end

local function fetch_asset_album_ids(asset_id)
  local ids = {}
  if asset_id == nil or asset_id == "" then
    return ids
  end

  local res_albums, err_albums = call_immich_api("GET", "albums?assetId=" .. tostring(asset_id))
  if err_albums ~= 200 or res_albums == nil then
    debug_log("failed to look up albums for existing asset " .. tostring(asset_id) .. " with HTTP " .. tostring(err_albums))
    return ids
  end

  for _,album in ipairs(res_albums) do
    if album ~= nil and album.id ~= nil and album.id ~= "" then
      ids[#ids + 1] = album.id
    end
  end

  return ids
end

local function queue_asset_for_album_id(extra_data, album_id, asset_id)
  if album_id == nil or album_id == "" or asset_id == nil or asset_id == "" then
    return
  end

  local album_assets = extra_data.album_asset_updates[album_id]
  if album_assets == nil then
    album_assets = {}
    extra_data.album_asset_updates[album_id] = album_assets
  end
  table.insert(album_assets, asset_id)
end

local function basename_from_path(path)
  if path == nil or path == "" then
    return ""
  end

  local name = ""
  for part in string.gmatch(path, "[^/\\]+") do
    name = part
  end
  return name
end

local function default_album_name_from_images(images)
  if images == nil or #images == 0 then
    return ""
  end

  local first = images[1]
  if first == nil or first.path == nil then
    return ""
  end

  return basename_from_path(first.path)
end

prefill_title_widget_from_images = function(images)
  if title_widget == nil then
    return
  end

  if title_widget.text ~= nil and title_widget.text ~= "" then
    return
  end

  local default_name = default_album_name_from_images(images)
  if default_name ~= "" then
    title_widget.text = default_name
  end
end

local function prefill_title_widget_from_selection()
  local ok, action_images = pcall(function()
    return dt.gui.action_images
  end)
  if ok then
    prefill_title_widget_from_images(action_images)
  end
end

local function update_album_title_row_visibility()
  if album_title_row_widget == nil then
    return
  end

  local mode = album_mode_widget ~= nil and album_mode_widget.selected or ALBUM_MODE_NONE
  album_title_row_widget.visible = (mode == ALBUM_MODE_TITLE
      or mode == ALBUM_MODE_COPY_AND_TITLE)
  if album_title_row_widget.visible then
    prefill_title_widget_from_selection()
  end
end

local function upload_image(image,filename) 
  local date = iso_exif_datetime_taken(image)
  local form_data = {
    deviceAssetId=tostring(image.id),
    deviceId=IMMICH_DEVICE_ID,
    fileCreatedAt=date,
    fileModifiedAt=date,
    assetData={
      filename=df.get_filename(filename),
      file=io.open(filename)
    }
  }
  debug_log("uploading new asset for image " .. tostring(image.id))
  local res,err = call_immich_api("POST","assets",form_data,"multipart/form-data")
  if err == 201 then
    debug_log("upload succeeded with asset id " .. tostring(res.id))
    return res.id
  end
  return nil
end

local function delete_asset(asset_id)
  if asset_id == nil or asset_id == "" then
    return false
  end

  debug_log("deleting previous asset " .. tostring(asset_id))
  local _delete_res, delete_err = call_immich_api("DELETE", "assets", {ids={asset_id}, force=false})
  if delete_err == 200 or delete_err == 204 then
    debug_log("delete succeeded for asset " .. tostring(asset_id))
    return true
  end

  debug_log("delete failed for asset " .. tostring(asset_id) .. " with HTTP " .. tostring(delete_err))
  return false
end

local function create_stack_with_existing_asset(image,filename,existing_asset_id) 
  debug_log("uploading new asset for image " .. tostring(image.id) .. " and stacking with existing asset " .. tostring(existing_asset_id))
  local new_asset_id, upload_err = upload_image(image,filename)
  if new_asset_id == nil then
    debug_log("upload failed while preparing stack for image " .. tostring(image.id))
    return nil
  end

  local stack_res, stack_err = call_immich_api("POST","stacks",{assetIds={new_asset_id, existing_asset_id}})
  if stack_err == 201 then
    debug_log("created stack with primary asset " .. tostring(new_asset_id) .. " and existing asset " .. tostring(existing_asset_id))
    return new_asset_id
  end

  debug_log("stack creation failed for image " .. tostring(image.id) .. " with HTTP " .. tostring(stack_err))
  return new_asset_id
end

local function get_cached_asset_id(image)
  local tags = image.get_tags(image)
  if tags ~= nil then
    debug_log("checking tags for cached asset id on image " .. tostring(image.id))
    for _,tag in ipairs(tags) do
      if tag ~= nil and tag.name ~= nil then
        local asset_id = tag.name:match("^immich%|asset%|(.-)$")
        if asset_id ~= nil and asset_id ~= "" then
          debug_log("found cached asset id " .. tostring(asset_id) .. " in tag " .. tostring(tag.name))
          return asset_id
        end
      end
    end
  end

  local id = dt.preferences.read("immich", "asset_" .. tostring(image.id), "string")
  if id == nil or id == "" then
    debug_log("no cached asset id found in preferences for image " .. tostring(image.id))
    return nil
  end
  debug_log("found cached asset id " .. tostring(id) .. " in preferences for image " .. tostring(image.id))
  return id
end

local function get_cached_change_tag(image)
  local tags = image.get_tags(image)
  if tags ~= nil then
    debug_log("checking tags for cached change marker on image " .. tostring(image.id))
    for _,tag in ipairs(tags) do
      if tag ~= nil and tag.name ~= nil then
        local change_marker = tag.name:match("^immich%|change%|(.-)$")
        if change_marker ~= nil and change_marker ~= "" then
          debug_log("found cached change marker " .. tostring(change_marker) .. " in tag " .. tostring(tag.name))
          return change_marker
        end
      end
    end
  end

  return nil
end

local function set_cached_asset_id(image, asset_id)
  debug_log("writing cached asset id " .. tostring(asset_id) .. " for image " .. tostring(image.id))
  dt.preferences.write("immich", "asset_" .. tostring(image.id), "string", asset_id)

  local tag_name = "immich|asset|" .. tostring(asset_id)
  debug_log("ensuring tag " .. tostring(tag_name) .. " exists for image " .. tostring(image.id))
  local tag = dt.tags.find(tag_name)
  if tag == nil then
    tag = dt.tags.create(tag_name)
  end

  -- Keep only the latest Immich asset tag on the image.
  local tags = image.get_tags(image)
  if tags ~= nil then
    for _,existing_tag in ipairs(tags) do
      if existing_tag ~= nil and existing_tag.name ~= nil
          and existing_tag.name:match("^immich%|asset%|") ~= nil
          and existing_tag.name ~= tag_name then
        debug_log("detaching old tag " .. tostring(existing_tag.name) .. " from image " .. tostring(image.id))
        image:detach_tag(existing_tag)
      end
    end
  end

  if tag ~= nil then
    local already_attached = false
    if tags ~= nil then
      for _,existing_tag in ipairs(tags) do
        if existing_tag ~= nil and existing_tag.name == tag_name then
          already_attached = true
          break
        end
      end
    end
    if not already_attached then
      debug_log("attaching tag " .. tostring(tag_name) .. " to image " .. tostring(image.id))
      image:attach_tag(tag)
    else
      debug_log("tag " .. tostring(tag_name) .. " already attached to image " .. tostring(image.id))
    end
  else
    debug_log("could not create or find tag " .. tostring(tag_name) .. " for image " .. tostring(image.id))
  end
end

local function set_cached_change_tag(image, change_marker)
  if change_marker == nil or change_marker == "" then
    debug_log("no change marker available to cache for image " .. tostring(image.id))
    return
  end

  local tag_name = "immich|change|" .. tostring(change_marker)
  debug_log("ensuring change marker tag " .. tostring(tag_name) .. " exists for image " .. tostring(image.id))
  local tag = dt.tags.find(tag_name)
  if tag == nil then
    tag = dt.tags.create(tag_name)
  end

  local tags = image.get_tags(image)
  if tags ~= nil then
    for _,existing_tag in ipairs(tags) do
      if existing_tag ~= nil and existing_tag.name ~= nil
          and existing_tag.name:match("^immich%|change%|") ~= nil
          and existing_tag.name ~= tag_name then
        debug_log("detaching old change marker tag " .. tostring(existing_tag.name) .. " from image " .. tostring(image.id))
        image:detach_tag(existing_tag)
      end
    end
  end

  if tag ~= nil then
    local already_attached = false
    if tags ~= nil then
      for _,existing_tag in ipairs(tags) do
        if existing_tag ~= nil and existing_tag.name == tag_name then
          already_attached = true
          break
        end
      end
    end
    if not already_attached then
      debug_log("attaching change marker tag " .. tostring(tag_name) .. " to image " .. tostring(image.id))
      image:attach_tag(tag)
    else
      debug_log("change marker tag " .. tostring(tag_name) .. " already attached to image " .. tostring(image.id))
    end
  else
    debug_log("could not create or find change marker tag " .. tostring(tag_name) .. " for image " .. tostring(image.id))
  end
end

local function store_image(storage,image,format,filename,number,total,high_quality,extra_data)
  debug_log("storing image " .. tostring(image.id) .. " (" .. tostring(number) .. "/" .. tostring(total) .. ")")
  local asset_id = nil
  local replaced = false
  local existing_asset_action = extra_data.existing_asset_action or EXISTING_ASSET_ACTION_STACK
  local cached_id = get_cached_asset_id(image)
  local cached_change_marker = get_cached_change_tag(image)
  local local_change_timestamp = tostring(image.change_timestamp or "")
  if cached_id ~= nil and cached_change_marker ~= nil and cached_change_marker == local_change_timestamp
      and not is_reupload_variant(existing_asset_action) then
    debug_log("cached change marker matches local change timestamp for image " .. tostring(image.id) .. "; reusing cached asset id " .. tostring(cached_id) .. " without metadata lookup")
    asset_id = cached_id
    replaced = true
  end
  local existing_asset_id = nil
  local existing_asset = nil

  if asset_id == nil and cached_id ~= nil then
    debug_log("looking up cached asset id " .. tostring(cached_id) .. " for image " .. tostring(image.id))
    local asset_details, asset_err = get_asset_details(cached_id)
    if asset_details ~= nil then
      existing_asset_id = cached_id
      existing_asset = asset_details
    else
      debug_log("cached asset id " .. tostring(cached_id) .. " no longer exists on server (HTTP " .. tostring(asset_err) .. "); uploading new")
    end
  end

  if existing_asset_id ~= nil then
    if is_remote_asset_trashed(existing_asset) then
      debug_log("existing remote asset is trashed; ignoring cached asset id " .. tostring(existing_asset_id) .. " and uploading a fresh copy")
      existing_asset_id = nil
      existing_asset = nil
    end
  end

  local copied_album_ids = {}
  local requested_album_mode = extra_data.album_mode or ALBUM_MODE_NONE
  if existing_asset_id ~= nil and asset_id == nil
      and (requested_album_mode == ALBUM_MODE_COPY_EXISTING or requested_album_mode == ALBUM_MODE_COPY_AND_TITLE) then
    copied_album_ids = fetch_asset_album_ids(existing_asset_id)
    debug_log("found " .. tostring(#copied_album_ids) .. " album(s) on existing asset " .. tostring(existing_asset_id) .. " to copy for image " .. tostring(image.id))
  end

  if asset_id ~= nil then
    debug_log("using cached asset id " .. tostring(asset_id) .. " for image " .. tostring(image.id) .. "; skipping remote asset actions")
  elseif existing_asset_id ~= nil then
    if existing_asset_action == EXISTING_ASSET_ACTION_DELETE
        or existing_asset_action == EXISTING_ASSET_ACTION_DELETE_REUPLOAD then
      debug_log("existing-asset action is delete/trash; uploading replacement for existing asset id " .. tostring(existing_asset_id))
      asset_id = upload_image(image,filename)
      if asset_id ~= nil then
        delete_asset(existing_asset_id)
      end
    else
      local stacked_asset_id = create_stack_with_existing_asset(image,filename,existing_asset_id)
      if stacked_asset_id ~= nil then
        asset_id = stacked_asset_id
        replaced = false
        if existing_asset_action == EXISTING_ASSET_ACTION_DELETE_AND_STACK
            or existing_asset_action == EXISTING_ASSET_ACTION_DELETE_AND_STACK_REUPLOAD then
          debug_log("existing-asset action is delete-and-stack; deleting existing asset id " .. tostring(existing_asset_id) .. " after stacking")
          delete_asset(existing_asset_id)
        end
      else
        debug_log("stack creation failed for existing asset id " .. tostring(existing_asset_id) .. ", falling back to standalone upload")
        asset_id = upload_image(image,filename)
        replaced = false
        if asset_id ~= nil and (existing_asset_action == EXISTING_ASSET_ACTION_DELETE_AND_STACK
            or existing_asset_action == EXISTING_ASSET_ACTION_DELETE_AND_STACK_REUPLOAD) then
          debug_log("delete-and-stack fallback path; deleting existing asset id " .. tostring(existing_asset_id) .. " after standalone upload")
          delete_asset(existing_asset_id)
        end
      end
    end
  else
    debug_log("no existing remote asset found for image " .. tostring(image.id) .. ", uploading new")
    asset_id = upload_image(image,filename)
  end

  if asset_id == nil then 
    debug_log("upload failed for image " .. tostring(image.id))
    extra_data.error = "Error uploading some image"
    return
  end

  if not replaced then
    debug_log("caching asset id " .. tostring(asset_id) .. " for image " .. tostring(image.id))
    set_cached_change_tag(image, image.change_timestamp)
    set_cached_asset_id(image, asset_id)
  end

  if not replaced then
    local album_mode = extra_data.album_mode or ALBUM_MODE_NONE
    if album_mode == ALBUM_MODE_TITLE
        or album_mode == ALBUM_MODE_COPY_AND_TITLE
        or album_mode == ALBUM_MODE_USE_ALBUM_TITLE then
      local album_name = title_widget.text or ""
      if album_name == "" then
        debug_log("album mode is title but no title was provided; skipping album assignment")
      else
        debug_log("album mode is title; resolved album name '" .. tostring(album_name) .. "' for image " .. tostring(image.id))
        local album_assets = extra_data.album_assets[album_name]
        if album_assets == nil then
          album_assets = {}
          extra_data.album_assets[album_name] = album_assets
        end
        table.insert(album_assets,asset_id)
        debug_log("queued asset " .. tostring(asset_id) .. " for album " .. tostring(album_name))
      end
    end

    if album_mode == ALBUM_MODE_COPY_EXISTING or album_mode == ALBUM_MODE_COPY_AND_TITLE then
      if #copied_album_ids == 0 then
        debug_log("album copy mode selected but no albums found on existing asset for image " .. tostring(image.id))
      else
        for _,album_id in ipairs(copied_album_ids) do
          queue_asset_for_album_id(extra_data, album_id, asset_id)
          debug_log("queued asset " .. tostring(asset_id) .. " for existing album id " .. tostring(album_id))
        end
      end
    else
      debug_log("album mode is none; skipping album assignment for image " .. tostring(image.id))
    end
  end
end

local function finalize(storage,image_table,extra_data)
  if extra_data.album_assets ~= nil then 
    local album_count = 0
    for _ in pairs(extra_data.album_assets) do
      album_count = album_count + 1
    end
    debug_log("finalizing album updates for " .. tostring(album_count) .. " album(s)")
    for album_name,album_assets in pairs(extra_data.album_assets) do
      local album_id = extra_data.remote_albums[album_name]
      if album_id == nil then
        debug_log("creating new album: " .. album_name)
        call_immich_api("POST","albums",{albumName=album_name,assetIds=album_assets})
      else
        debug_log("adding assets to album: "..album_name)
        call_immich_api("PUT","albums/"..album_id.."/assets",{ids=album_assets})
      end
    end
  end
  if extra_data.album_asset_updates ~= nil then
    local album_update_count = 0
    for _ in pairs(extra_data.album_asset_updates) do
      album_update_count = album_update_count + 1
    end
    debug_log("finalizing copy-to-existing-album updates for " .. tostring(album_update_count) .. " album(s)")
    for album_id,album_assets in pairs(extra_data.album_asset_updates) do
      debug_log("adding assets to existing album id: " .. tostring(album_id))
      call_immich_api("PUT","albums/"..album_id.."/assets",{ids=album_assets})
    end
  end
  if extra_data.error ~= nil then
    debug_log("finalizing with error: " .. tostring(extra_data.error))
    log.msg(log.error, extra_data.error)
  end
end

local function destroy()
  dt.destroy_storage("immich")
end

dt.preferences.register(
   "immich","immich_server","string",
    _("Immich server"),
    _("The url of the Immich server to upload"),
    "http://localhost:2283")

dt.preferences.register(
   "immich","immich_key","string",
    _("Immich API key"),
    _("A valid Immich API key"),
    "<your api key>")

title_widget = dt.new_widget("entry") {
    placeholder=_("No album")
}
album_mode_widget = dt.new_widget("combobox") {
  label = _("Album mode"),
  tooltip = _("Choose how exported assets are assigned to albums."),
  selected = ALBUM_MODE_COPY_EXISTING,
  changed_callback = function(_)
    update_album_title_row_visibility()
  end,
  _("No album"),
  _("Custom"),
  _("Copy albums from existing asset"),
  _("Copy existing + Custom"),
  _("Use Album Title")
}
existing_asset_action_widget = dt.new_widget("combobox") {
  label = _("Re-export Behavior"),
  tooltip = _("Choose what to do on server when exporting an already-exported image that has changed."),
  selected = EXISTING_ASSET_ACTION_DELETE_AND_STACK,
  _("Skip unchanged, Delete/Trash old existing asset on server"),
  _("Skip unchanged, Stack with existing asset"),
  _("Skip unchanged, Delete/Trash & Stack"),
  _("Delete/Trash existing asset on server"),
  _("Stack with existing asset"),
  _("Delete/Trash & Stack")
}
album_title_row_widget = dt.new_widget("box") {
    orientation=horizontal,
  dt.new_widget("label"){label = _("Album Title"), tooltip = _("Used only when Album mode is set to 'Custom'. Leave empty to skip album assignment.") },
    title_widget
}

local widget = dt.new_widget("box") {
  orientation=vertical,
  album_mode_widget,
  album_title_row_widget,
  existing_asset_action_widget
}

update_album_title_row_visibility()

dt.register_storage("immich",_("immich"),
    store_image,
    finalize,
    nil,
    initialize,
    widget)

local script_data = {}

script_data.metadata = {
  name = "immich",
  purpose = _("upload all selected images to Immich server"),
  author = "Giorgio Massussi"
}

script_data.destroy = destroy -- function to destory the script
script_data.destroy_method = nil -- set to hide for libs since we can't destroy them commpletely yet, otherwise leave as nil
script_data.restart = nil -- how to restart the (lib) script after it's been hidden - i.e. make it visible again
script_data.show = nil -- only required for libs since the destroy_method only hides them

return script_data
--
-- vim: shiftwidth=2 expandtab tabstop=2 cindent syntax=lua
