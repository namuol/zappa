zappa = exports
express = require 'express'
fs = require 'fs'
sys = require 'sys'
puts = sys.puts
coffee = null
jquery = require 'jquery'
io = null
coffeekup = null

class Zappa
  constructor: ->
    @context = {}
    @apps = {}
    @current_app = null

    @locals =
      app: (name) => @app name
      include: (path) => @include path
      require: require

    for name in 'get|post|put|del|route|at|msg|client|using|def|helper|postrender|layout|view|style'.split '|'
      @locals[name] = =>
        @ensure_app 'default' unless @current_app?
        @current_app[name].apply @current_app, arguments

  app: (name) ->
    @ensure_app name
    @current_app = @apps[name]
  
  include: (file) ->
    @define_with @read_and_compile(file)

  define_with: (code) ->
    scoped(code)(@context, @locals)

  ensure_app: (name) ->
    @apps[name] = new App(name) unless @apps[name]?
    @current_app = @apps[name] unless @current_app?

  read_and_compile: (file) ->
    coffee = require 'coffee-script'
    code = @read file
    coffee.compile code
  
  read: (file) -> fs.readFileSync file, 'utf8'
  
  run_file: (file, options) ->
    code = if file.match /\.coffee$/ then @read_and_compile file else @read file
    @run code, options
  
  run: (code, options) ->
    options ?= {}

    @define_with code
    
    i = 0
    for k, a of @apps
      opts = {}
      if options.port
        opts.port = if options.port[i]? then options.port[i] else v.port + i
      else if i isnt 0
        opts.port = v.port + i

      a.start opts
      i++

class App
  constructor: (@name) ->
    @name ?= 'default'
    @port = 5678
    
    @http_server = express.createServer()
    if coffeekup?
      @http_server.register '.coffee', coffeekup
      @http_server.set 'view engine', 'coffee'
    @http_server.configure =>
      @http_server.use express.staticProvider("#{process.cwd()}/public")
      @http_server.use express.bodyDecoder()
      @http_server.use express.cookieDecoder()
      @http_server.use express.session()

    # App-level vars, exposed to handlers as [app]."
    @vars = {}
    
    @defs = {}
    @helpers = {}
    @postrenders = {}
    @socket_handlers = {}
    @msg_handlers = {}

    @views = {}
    @layouts = {}
    @layouts.default = ->
      doctype 5
      html ->
        head ->
          title @title if @title
          if @scripts
            for s in @scripts
              script src: s + '.js'
          script(src: @script + '.js') if @script
          if @stylesheets
            for s in @stylesheets
              link rel: 'stylesheet', href: s + '.css'
          link(rel: 'stylesheet', href: @stylesheet + '.css') if @stylesheet
          style @style if @style
        body @content
    
  start: (options) ->
    options ?= {}
    @port = options.port if options.port

    if io?
      @ws_server = io.listen @http_server, {log: ->}
      @ws_server.on 'connection', (client) => @socket_handlers.connection?.execute client
      @ws_server.on 'clientDisconnect', (client) => @socket_handlers.disconnection?.execute client
      @ws_server.on 'clientMessage', (raw_msg, client) =>
        msg = parse_msg raw_msg
        @msg_handlers[msg.title]?.execute client, msg.params

    @http_server.listen @port
    puts "App \"#{@name}\" listening on port #{@port}..."
    @http_server

  get: -> @route 'get', arguments
  post: -> @route 'post', arguments
  put: -> @route 'put', arguments
  del: -> @route 'del', arguments
  route: (verb, args) ->
    if typeof args[0] isnt 'object'
      @register_route verb, args[0], args[1]
    else
      for k, v of args[0]
        @register_route verb, k, v

  register_route: (verb, path, response) ->
    if typeof response isnt 'function'
      @http_server[verb] path, (req, res) -> res.send String(response)
    else
      handler = new RequestHandler(response, @defs, @helpers, @postrenders, @views, @layouts, @vars)
      @http_server[verb] path, (req, res, next) ->
        handler.execute(req, res, next)

  using: ->
    pairs = {}
    for a in arguments
      pairs[a] = require(a)
    @def pairs
   
  def: (pairs) ->
    for k, v of pairs
      @defs[k] = v
   
  helper: (pairs) ->
    for k, v of pairs
      @helpers[k] = scoped(v)

  postrender: (pairs) ->
    jsdom = require 'jsdom'
    for k, v of pairs
      @postrenders[k] = scoped(v)

  at: (pairs) ->
    io = require 'socket.io'
    for k, v of pairs
      @socket_handlers[k] = new MessageHandler(v, @defs, @helpers, @postrenders, @views, @layouts, @vars)

  msg: (pairs) ->
    io = require 'socket.io'
    for k, v of pairs
      @msg_handlers[k] = new MessageHandler(v, @defs, @helpers, @postrenders, @views, @layouts, @vars)

  layout: (arg) ->
    pairs = if typeof arg is 'object' then arg else {default: arg}
    coffeekup = require 'coffeekup'
    for k, v of pairs
      @layouts[k] = v
   
  view: (arg) ->
    pairs = if typeof arg is 'object' then arg else {default: arg}
    coffeekup = require 'coffeekup'
    for k, v of pairs
      @views[k] = v

  client: (arg) ->
    pairs = if typeof arg is 'object' then arg else {default: arg}
    for k, v of pairs
      code = ";(#{v})();"
      @http_server.get "/#{k}.js", (req, res) ->
        res.contentType 'bla.js'
        res.send code

  style: (arg) ->
    pairs = if typeof arg is 'object' then arg else {default: arg}
    for k, v of pairs
      @http_server.get "/#{k}.css", (req, res) ->
        res.contentType 'bla.css'
        res.send v

class RequestHandler
  constructor: (handler, @defs, @helpers, @postrenders, @views, @layouts, @vars) ->
    @handler = scoped(handler)
    @locals = null

  init_locals: ->
    @locals = {}
    @locals.app = @vars
    @locals.render = @render
    @locals.redirect = @redirect
    @locals.send = @send
  
    for k, v of @defs
      @locals[k] = v

    for k, v of @helpers
      @locals[k] = ->
        v(@context, @, arguments)

    @locals.postrenders = @postrenders
    @locals.views = @views
    @locals.layouts = @layouts

  execute: (request, response, next) ->
    @init_locals() unless @locals?

    @locals.context = {}
    @locals.params = @locals.context

    @locals.request = request
    @locals.response = response
    @locals.next = next

    @locals.session = request.session
    @locals.cookies = request.cookies

    for k, v of request.query
      @locals.context[k] = v
    for k, v of request.params
      @locals.context[k] = v
    for k, v of request.body
      @locals.context[k] = v

    result = @handler(@locals.context, @locals)

    if typeof result is 'string'
      response.send result
    else
      result

  redirect: -> @response.redirect.apply @response, arguments
  send: -> @response.send.apply @response, arguments

  render: (what, options) ->
    options ?= {}
    options.layout ?= yes
    layout = @layouts.default

    view = if typeof what is 'function' then what else @views[what]

    inner = coffeekup.render view, context: @context

    if typeof options.apply is 'string'
      postrender = @postrenders[options.apply]
      body = jquery 'body'
      body.empty().html inner
      postrender @context, $: jquery
      result = body.html()
      if options.layout
        @context.content = result
        html = coffeekup.render layout, context: @context
        @response.send html
      else @response.send result
    else
      if options.layout
        @context.content = inner
        @response.send(coffeekup.render layout, context: @context)
      else
        @response.send inner

    null

class MessageHandler
  constructor: (handler, @defs, @helpers, @postrenders, @views, @layouts, @vars) ->
    @handler = scoped(handler)
    @locals = null

  init_locals: ->
    @locals = {}
    @locals.app = @vars
    @locals.render = @render
  
    for k, v of @defs
      @locals[k] = v

    for k, v of @helpers
      @locals[k] = ->
        v(@context, @, arguments)

    @locals.postrenders = @postrenders
    @locals.views = @views
    @locals.layouts = @layouts

  execute: (client, params) ->
    @init_locals() unless @locals?

    @locals.context = {}
    @locals.params = @locals.context
    @locals.client = client
    @locals.id = client.sessionId
    @locals.send = (title, data) -> client.send build_msg(title, data)
    @locals.broadcast = (title, data) -> client.broadcast build_msg(title, data)

    for k, v of params
      @locals.context[k] = v

    @handler(@locals.context, @locals)

  render: (what, options) ->
    options ?= {}
    layout = @layouts.default
    view = if typeof what is 'function' then what else @views[what]

    inner = coffeekup.render view, context: @context

    if typeof options.apply is 'string'
      postrender = @postrenders[options.apply]
      body = jquery 'body'
      body.empty().html inner
      postrender @context, $: jquery
      result = body.html()
      if options.layout
        @context.content = result
        html = coffeekup.render layout, context: @context
        @send 'render', value: html
    else
      @context.content = inner
      @send 'render', value: (coffeekup.render layout, context: @context)

build_msg = (title, data) ->
  obj = {}
  obj[title] = data
  JSON.stringify(obj)

parse_msg = (raw_msg) ->
  obj = JSON.parse(raw_msg)
  for k, v of obj
    return {title: k, params: v}

scoped = (code) ->
  bind = 'var __bind = function(func, context){return function(){return func.apply(context, arguments);};};'
  code = String(code)
  code = "function () {#{code}}" unless code.indexOf('function') is 0
  code = "#{bind} with(locals) {return (#{code}).apply(context, args);}"
  new Function('context', 'locals', 'args', code)

publish_api = (from, to, methods) ->
  for name in methods.split '|'
    if typeof from[name] is 'function'
      to[name] = -> from[name].apply from, arguments
    else
      to[name] = from[name]
  
z = new Zappa()
zappa.version = '0.1.1'
zappa.run = -> z.run.apply z, arguments
zappa.run_file = -> z.run_file.apply z, arguments
