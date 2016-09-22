_G.TURBO_SSL = true
local turbo = require("turbo")
local fetch = require("turbo-fetch")

local WIT_API_HOST = "https://api.wit.ai"
local WIT_API_VERSION = "20160516"
local DEFAULT_MAX_STEPS = 5
local INTERACTIVE_PROMPT = "> "
local LEARN_MORE = "Learn more at https://wit.ai/docs/quickstart"

local Wit = class("WIT")

local request = function(access_token, meth, path, params, kwargs, callback)
  local full_url = WIT_API_HOST .. path
  turbo.log.debug(string.format('%s %s %s', meth, full_url, params))
  fetch(turbo, full_url, turbo.utils.tablemerge({
    method = meth,
    on_headers = function(headers)
      headers:add("authorization", "Bearer " .. access_token)
      headers:add("accept", "application/vnd.wit." .. WIT_API_VERSION .. "+json")
    end,
    params = params
  }, kwargs or {}), function(response)
    if not response then
      error("No response from Wit")
      return
    end
    if response.error then
      error("Wit responded with status: " .. response.error.code .. " (" .. response.error.code .. ")")
      return
    end
    local ok, json = pcall(turbo.util.json_decode, response.body)
    if ok then
      callback(json)
    else
      turbo.log.error("Invalid response from Wit (" .. response.body .. ")")
    end
    return
  end)
end

local validate_actions = function(actions)
  if type(actions) ~= "table" then
    turbo.log.warning("The second parameter should be a dictionary.")
  end
  for _, action in pairs({"send"}) do
    if not actions[actions] then
      turbo.log.warning("The '" .. action .. "' action is missing. " .. LEARN_MORE)
    end
  end
  for _, value in pairs(actions) do
    if type(value) ~= "function" then
      turbo.log.warning("The '" .. value .. "' action should be a function.")
    end
  end
  return actions
end

function Wit:initialize(access_token, actions)
  self.access_token = access_token
  if actions then
      self.actions = validate_actions(actions)
  end
end

function Wit:message(msg, verbose, callback)
  local params = {}
  if verbose then
      params["verbose"] = true
  end
  if msg then
    params["q"] = msg
  end
  request(self.access_token, 'GET', '/message', params, nil, callback)
end

function Wit:converse(session_id, message, context, reset, verbose, callback)
  if not context then
    context = {}
  end
  local params = {
    session_id = session_id
  }
  if verbose then
      params["verbose"] = true
  end
  if message then
    params["q"] = message
  end
  if reset then
      params["reset"] = true
  end
  request(self.access_token, "POST", "/converse", params, {
      body = turbo.util.json_encode(context or {})
  }, callback)
end

function Wit:__run_actions(session_id, current_request, message, context, i, verbose, callback)
  if i <= 0 then
    error("Max steps reached, stopping.")
  end
  self:converse(session_id, message, context, verbose, function(json)
    if not json.type then
      error("Couldn\'t find type in Wit response")
    end
    if current_request ~= self._sessions.session_id then
      return context
    end
    turbo.log.debug(string.format("Context: %s", context))
    turbo.log.debug(string.format("Response type: %s", json.type))

    -- backwards-cpmpatibility with API version 20160516
    if json.type == 'merge' then
      json.type = "action"
      json.action = "merge"
    end
    
    if json.type == "error" then
      error('Oops, I don\'t know what to do.')
    end
    
    if json.type == "stop" then
      return context
    end
    
    local req = {
      session_id = session_id,
      context = {context},
      text = message,
      entities = json.entities
    }
    
    if json.type == "msg" then
      self:throw_if_action_missing("send")
      local res = {
        text = json.msg,
        quickreplies = json.quickreplies
      }
      (self.actions.send)(self, req, res)
    elseif json.type == "action" then
      local action = json.action
      self:throw_if_action_missing(action)
      context = (self.actions[action])(self, req)
      if not context then
        turbo.log.warning('missing context - did you forget to return it?')
        context = {}
      end
    else
      error("unknown type: " + json.type)
    end

    if current_request ~= self._sessions.session_id then
      return context
    end
    
    if not callback then
      callback = function() end
    end
    callback(self:__run_actions(session_id, current_request, nil, context, i - 1, verbose))
  end)
end

function Wit:run_actionss(session_id, message, context, max_steps, verbose, callback)
  if not max_steps then
    max_steps = DEFAULT_MAX_STEPS
  end

  if not self.actions then
    self:throw_must_have_actions()
  end
  
  if not context then
    context = {}
  end
  
  -- Figuring out whether we need to reset the last turn.
  -- Each new call increments an index for the session.
  -- We only care about the last call to run_actions.
  -- All the previous ones are discarded (preemptive exit).
  local current_request = 1
  if self._sessions.session_id then
    current_request = self._sessions.session_id + 1
  end
  
  self._sessions.session_id = current_request
  
  self:__run_actions(session_id, current_request, message, context, max_steps, verbose, function(context)
    if current_request == self._sessions.session_id then
      self._session.session_id = nil
    end
    
    callback(context)
  end)
end

function Wit:throw_if_action_missing(action_name)
  if not self.actions.action_name then
    error("unknown action: " .. action_name)
  end
end

function Wit:throw_must_have_actions()
  error("You must provide the `actions` parameter to be able to use runActions. " .. LEARN_MORE)
end
