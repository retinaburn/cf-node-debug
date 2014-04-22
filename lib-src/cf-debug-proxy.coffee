# Licensed under the Apache License. See footer for details.

child_process = require "child_process"

q          = require "q"
_          = require "underscore"
http       = require "http"
cfEnv      = require "cf-env"
httpProxy  = require "http-proxy"
websocket  = require "websocket"

utils       = require "./utils"
v8messenger = require "./v8messenger"

#-------------------------------------------------------------------------------
cfCore = cfEnv.getCore()

PORT_PROXY  = cfCore.port
PORT_TARGET = cfCore.port + 1
PORT_V8     = 5858

#-------------------------------------------------------------------------------
exports.run = (args, opts) ->
  utils.vlog "version: #{utils.VERSION}"
  utils.vlog "args: #{args.join ' '}"
  utils.vlog "opts: #{utils.JL opts}"

  startTarget args, opts
  startProxy opts

#-------------------------------------------------------------------------------
startTarget = (args, opts) ->
  args = args.trim().split /\s+/ if _.isString args
  args.shift() if args[0] is "node"

  if opts.break
    args.unshift "--debug-brk"
  else
    args.unshift "--debug"

  env = _.clone process.env
  env.PORT          = PORT_TARGET
  env.VCAP_APP_PORT = PORT_TARGET

  stdio =  ["ignore", "pipe", "pipe"]

  options = {env, stdio}

  utils.log "starting target process `node #{args.join ' '}`"
  utils.log "target process PORT set to #{env.PORT}"
  child = child_process.spawn "node", args, options

  child.stdout.pipe(process.stdout)
  child.stderr.pipe(process.stderr)

  child.on "error", (err) ->
    utils.log "error running target process: #{err}"
    throw err

  child.on "exit", (code) ->
    message = "target process exited with code: #{code}"
    utils.log message
    throw new Error message

#-------------------------------------------------------------------------------
connectDebugger = (wsConnection) ->

  v8 = v8messenger.create PORT_V8

  v8.on "error", (err) ->
    packet =
      type:   "error"
      message: err.message

    ws.connection.sendUTF JSON.stringify packet, null, 4
    v8.close()

  v8.on "close", -> wsConnection.close()

  v8.on "v8-event", (packet) ->
    ws.connection.sendUTF JSON.stringify packet, null, 4

  wsConnection.on "message", (message) ->
    utils.vlog "ws message: #{message}"

    if message.type is "binary"
      utils.vlog "ws binary message ignored"
      return

    v8.send JSON.parse message.utf8Data

  wsConnection.on "close", (reasonCode, description) ->
    utils.vlog "ws close: #{reasonCode} - #{description}"
    v8.close()

#-------------------------------------------------------------------------------
startProxy = (opts) ->

  proxy = httpProxy.createProxyServer
    target:
      host: "localhost"
      port: PORT_TARGET

  proxyServer = http.createServer (request, response) ->
    proxy.web request, response

  wsServer = new websocket.server
    httpServer:            proxyServer
    autoAcceptConnections: true

  wsServer.on "request", (request) ->
    connection = request.accept "v8-debug", request.origin
    utils.vlog "ws connection accepted"

    connectDebugger connection

  proxyServer.on "upgrade", (request, socket, head) ->
    if request.url is "/#{opts.websocket}"
      return connectDebug request, socket, head

    proxy.ws request, socket, head

  proxy.on "error", (err, request, response) ->
    utils.log "error in proxy: #{err}"
    response.writeHead 500, "Content-Type": "text/plain"
    response.end "error processing request; check server console."

  utils.log "proxy server starting on:      #{cfCore.url}"
  proxyServer.listen PORT_PROXY, ->
    utils.log "proxy server started on:       #{cfCore.url}"

    utils.log "listening for v8 websocket on: #{cfCore.url}/#{opts.websocket}"
    utils.log "everything else goes to:       localhost:#{PORT_TARGET}"

#-------------------------------------------------------------------------------
# Copyright IBM Corp. 2014
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#-------------------------------------------------------------------------------
