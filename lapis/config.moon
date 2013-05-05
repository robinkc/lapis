
import insert from table

local *

default_config = {
  port: "8080"
  num_workers: "1"
}

scope_meta = {
  __index: do
    set = (k, v) =>
      if type(k) == "table"
        for sub_k, sub_v in pairs k
          merge_set @_conf, sub_k, sub_v
      else
        if type(v) == "function"
          @_conf[k] = run_with_scope v, {}
        else
          merge_set @_conf, k, v

    (name) =>
      val = _G[name]
      return val unless val == nil

      with val = switch name
          when "set"
            (...) -> set @, ...
          when "unset"
            (...) ->
              for k in *{...}
                @_conf[k] = nil
          when "include"
            (fn) -> run_with_scope fn, @_conf
          else
            (v) -> set @, name, v

        @[name] = val
}

configs = {}
config = (environment, fn) ->
  configs[environment] or= {}
  table.insert configs[environment], fn
  nil

reset = (env) ->
  if env == true
    for k in pairs configs
      configs[k] = nil
  else
    configs[env] = nil

run_with_scope = (fn, conf) ->
  old_env = getfenv fn
  env = setmetatable { _conf: conf }, scope_meta
  setfenv fn, env
  fn!
  setfenv fn, old_env
  conf

merge_set = (t, k, v) ->
  existing = t[k]
  if existing and type(existing) == "table" and type(v) == "table"
    for sub_k, sub_v in pairs v
      merge_set existing, sub_k, sub_v
  else
    t[k] = v

get_env = ->
  os.getenv"LAPIS_ENVIRONMENT" or "development"

get = do
  cache = {}
  loaded_config = false

  (name=get_env!) ->
    error "missing environment name" unless name

    unless loaded_config
      loaded_config = true
      success, err = pcall -> require "config"
      unless success or err\match "module 'config' not found"
        error err

    return cache[name] if cache[name]
    conf = if fns = configs[name]
      with c = {}
        for fn in *fns
          run_with_scope fn, c
    else
      {}

    conf._name = name
    cache[name] = conf
    conf

{ :get, :config, :merge_set, :default_config, :reset }
