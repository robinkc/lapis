local path = require("lapis.cmd.path")
local find_nginx
do
  local nginx_bin = "nginx"
  local nginx_search_paths = {
    "/usr/local/openresty/nginx/sbin/",
    "/usr/sbin/",
    ""
  }
  local nginx_path
  find_nginx = function()
    if nginx_path then
      return nginx_path
    end
    for _index_0 = 1, #nginx_search_paths do
      local prefix = nginx_search_paths[_index_0]
      local cmd = tostring(prefix) .. tostring(nginx_bin) .. " -v 2>&1"
      local handle = io.popen(cmd)
      local out = handle:read()
      handle:close()
      if out:match("^nginx version: ngx_openresty/") then
        nginx_path = tostring(prefix) .. tostring(nginx_bin)
        return nginx_path
      end
    end
  end
end
local filters = {
  pg = function(url)
    local user, password, host, db = url:match("^postgres://(.*):(.*)@(.*)/(.*)$")
    if not (user) then
      error("failed to parse postgres server url")
    end
    return ("%s dbname=%s user=%s password=%s"):format(host, db, user, password)
  end
}
local start_nginx
start_nginx = function(environment, background)
  if background == nil then
    background = false
  end
  local nginx = find_nginx()
  if not (nginx) then
    return nil, "can't find nginx"
  end
  path.mkdir("logs")
  os.execute("touch logs/error.log")
  os.execute("touch logs/access.log")
  local cmd = nginx .. ' -p "$(pwd)"/ -c "nginx.conf.compiled"'
  if environment then
    cmd = "LAPIS_ENVIRONMENT='" .. tostring(environment) .. "' " .. cmd
  end
  if background then
    cmd = cmd .. " > /dev/null 2>&1 &"
  end
  return os.execute(cmd)
end
local compile_config
compile_config = function(config, opts)
  if opts == nil then
    opts = { }
  end
  local env = setmetatable({ }, {
    __index = function(self, key)
      local v = os.getenv("LAPIS_" .. key:upper())
      if v ~= nil then
        return v
      end
      return opts[key:lower()]
    end
  })
  local out = config:gsub("(${%b{}})", function(w)
    local name = w:sub(4, -3)
    local filter_name, filter_arg = name:match("^(%S+)%s+(.+)$")
    do
      local filter = filters[filter_name]
      if filter then
        local value = env[filter_arg]
        if value == nil then
          return w
        else
          return filter(value)
        end
      else
        local value = env[name]
        if value == nil then
          return w
        else
          return value
        end
      end
    end
  end)
  return out
end
local write_config_for
write_config_for = function(environment, out_fname)
  if out_fname == nil then
    out_fname = "nginx.conf.compiled"
  end
  local config = require("lapis.config")
  do
    local _obj_0 = require("lapis.cmd.nginx")
    compile_config = _obj_0.compile_config
  end
  local vars = config.get(environment)
  local compiled = compile_config(path.read_file("nginx.conf"), vars)
  return path.write_file("nginx.conf.compiled", compiled)
end
local get_pid
get_pid = function()
  local pidfile = io.open("logs/nginx.pid")
  if not (pidfile) then
    return 
  end
  local pid = pidfile:read("*a")
  pidfile:close()
  return pid:match("[^%s]+")
end
local send_hup
send_hup = function()
  do
    local pid = get_pid()
    if pid then
      os.execute("kill -HUP " .. tostring(pid))
      return pid
    end
  end
end
local send_term
send_term = function()
  do
    local pid = get_pid()
    if pid then
      os.execute("kill " .. tostring(pid))
      return pid
    end
  end
end
local with_server
with_server = function(environment, fn)
  local fresh_server
  if not (send_hup()) then
    start_nginx(environment, true)
    fresh_server = true
  end
  os.execute("sleep 0.1")
  if not (get_pid()) then
    return nil, "nginx failed to start, check error log"
  end
  local out = {
    fn()
  }
  if fresh_server then
    send_term()
  else
    write_config_for(environment)
    send_hup()
  end
  return unpack(out)
end
local execute_on_server
execute_on_server = function(code, environment)
  assert(loadstring(code))
  local config = require("lapis.config")
  local vars = config.get(environment)
  local compiled = compile_config(path.read_file("nginx.conf"), vars)
  code = [[    print = function(...)
      local str = table.concat({...}, "\t")
      io.stdout:write(str .. "\n")
      ngx.say(str)
    end

    local success, err = pcall(function()
     ]] .. code .. [[    end)

    if not success then
      print(err)
    end
  ]]
  code = code:gsub("\\", "\\\\"):gsub('"', '\\"')
  local random_string
  do
    local _obj_0 = require("lapis.cmd.util")
    random_string = _obj_0.random_string
  end
  local command_url = "/" .. tostring(random_string(20))
  local inserted_server = false
  local replace_server
  replace_server = function(server)
    if inserted_server then
      return ""
    end
    inserted_server = true
    return [[      server {
        listen ]] .. vars.port .. [[;

        location = ]] .. command_url .. [[ {
          default_type 'text/plain';
          allow 127.0.0.1;
          deny all;

          content_by_lua "
            ]] .. code .. [[
          ";
        }

        location / {
          return 503;
        }

        location = /query {
          internal;
          postgres_pass database;
          postgres_query $echo_request_body;
        }
      }
    ]]
  end
  local lpeg = require("lpeg")
  local R, S, V, P
  R, S, V, P, V = lpeg.R, lpeg.S, lpeg.V, lpeg.P, lpeg.V
  local C, Cs, Ct, Cmt, Cg, Cb, Cc
  C, Cs, Ct, Cmt, Cg, Cb, Cc = lpeg.C, lpeg.Cs, lpeg.Ct, lpeg.Cmt, lpeg.Cg, lpeg.Cb, lpeg.Cc
  local white = S(" \t\r\n") ^ 0
  local parse = P({
    V("root"),
    balanced = P("{") * (V("balanced") + (1 - P("}"))) ^ 0 * P("}"),
    server_block = S(" \t") ^ 0 * P("server") * white * V("balanced") / replace_server,
    root = Cs((V("server_block") + 1) ^ 1 * -1)
  })
  local temp_config = parse:match(compiled)
  assert(inserted_server, "Failed to find server directive in config")
  path.write_file("nginx.conf.compiled", temp_config)
  return assert(with_server(environment, function()
    local http = require("socket.http")
    local res
    res, code = http.request("http://127.0.0.1:" .. tostring(vars.port) .. "/" .. tostring(command_url))
    return res
  end))
end
return {
  compile_config = compile_config,
  filters = filters,
  find_nginx = find_nginx,
  start_nginx = start_nginx,
  send_hup = send_hup,
  send_term = send_term,
  get_pid = get_pid,
  execute_on_server = execute_on_server,
  write_config_for = write_config_for
}
