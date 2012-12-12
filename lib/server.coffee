express        = require 'express'
socketio       = require 'socket.io'
mongoose       = require 'mongoose'
intertwinkles  = require 'node-intertwinkles'
RoomManager    = require('iorooms').RoomManager
RedisStore     = require('connect-redis')(express)
_              = require 'underscore'
url            = require 'url'
etherpadClient = require 'etherpad-lite-client'
async          = require 'async'

start = (config) ->
  db = mongoose.connect(
    "mongodb://#{config.dbhost}:#{config.dbport}/#{config.dbname}"
  )
  schema = require('./schema').load(config)
  sessionStore = new RedisStore()
  app = express.createServer()

  #
  # Config
  #
  
  app.configure ->
    app.use require('connect-assets')()
    app.use express.bodyParser()
    app.use express.cookieParser()
    app.use express.session
      secret: config.secret
      key: 'express.sid'
      store: sessionStore

  app.configure 'development', ->
      app.use '/static', express.static(__dirname + '/../assets')
      app.use '/static', express.static(__dirname + '/../node_modules/node-intertwinkles/assets')
      app.use express.errorHandler {dumpExceptions: true, showStack: true}

  app.configure 'production', ->
    # Cache long time in production.
    app.use '/static', express.static(__dirname + '/../assets', { maxAge: 1000*60*60*24 })
    app.use '/static', express.static(__dirname + '/../node_modules/node-intertwinkles/assets', { maxAge: 1000*60*60*24 })

  app.set 'view engine', 'jade'
  app.set 'view options', {layout: false}

  #
  # Sockets
  #

  io = socketio.listen(app, {"log level": 0})
  iorooms = new RoomManager("/iorooms", io, sessionStore)
  intertwinkles.attach(config, app, iorooms)
  iorooms.authorizeJoinRoom = (session, name, callback) ->
    schema.TwinklePad.findOne {pad_name: name}, 'sharing', (err, doc) ->
      return callback(err) if err?
      if intertwinkles.can_view(session, doc)
        callback(null)
      else
        callback("Permission denied")

  iorooms.on "disconnect", (data) ->
    if data.socket.session?.etherpad_session_id
      etherpad.deleteSession {
        sessionID: data.socket.session.etherpad_session_id
      }, (err, data) ->
        console.error(err) if err?

  #
  # Routes
  #
  
  context = (req, obj, initial_data) ->
    return _.extend({
      initial_data: _.extend(
        intertwinkles.get_initial_data(req?.session),
        initial_data or {}
      )
      conf: {
        api_url: config.intertwinkles.api_url
        apps: config.intertwinkles.apps
      }
      flash: req.flash()
    }, obj)

  server_error = (req, res, err) ->
    res.statusCode = 500
    console.error(err)
    return res.send("Server error") # TODO pretty 500 page

  not_found = (req, res) ->
    return res.send("Not found", 404) # TODO pretty 404 page

  permission_denied = (req, res) ->
    return res.send("Not found", 403) # TODO pretty 403 page

  pad_url_parts = url.parse(config.etherpad.url)
  etherpad = etherpadClient.connect({
    apikey: config.etherpad.api_key
    host: pad_url_parts.hostname
    port: pad_url_parts.port
  })

  app.get '/', (req, res) ->
    intertwinkles.list_accessible_documents schema.TwinklePad, req.session, (err, docs) ->
      render 'index', context(req, {
        title: "Etherpads"
        listed_pads: docs
      })

  app.get '/p/:pad_name', (req, res) ->
    #
    # The strategy for InterTwinkles etherpads is to use the Etherpad API to
    # create one group per pad, and to add a one-time-use session for each user
    # on every pad page load. The session is cleared when the user breaks their
    # iorooms websocket (above).
    #
    # http://etherpad.org/doc/v1.2.1/#index_overview
    #
    # Since the Etherpad API doesn't allow us to establish a "read only"
    # session. We serve read-only versions of the pad to viewers lacking edit
    # permissions, but the possibility exists for a visitor with "view"
    # permission who previously had "edit" permission to continue to edit, if
    # they remember the URL to the pad.  The only way around this is to put
    # etherpad behind another proxy, or to add a read-only-session API to
    # etherpad.
    #

    async.waterfall [
      # Retrieve and maybe create the pad.
      (done) ->
        schema.TwinklePad.findOne {pad_name: req.params.pad_name}, (err, doc) ->
          return server_error(req, res, err) if err?
          if not doc?
            doc = new schema.TwinklePad {pad_name: req.params.pad_name}
            doc.save(done)
          else
            done(null, doc)
    ], (err, doc) ->
      return server_error(req, res, err) if err?
      
      # Check that we can view this pad.
      if intertwinkles.can_edit(req.session, doc)
        embed_url = doc.url
      else if intertwinkles.can_view(req.session, doc)
        embed_url = doc.read_only_url
      else
        return permission_denied(req, res)

      # Get the author mapper / author name
      if intertwinkles.is_authenticated(req.session)
        author_mapper = req.session.auth.user_id
        author_name = req.session.users[req.session.auth.user_id].name
        author_color = req.session.users[req.session.auth.user_id].icon?.color
        embed_url += "?userName=#{author_name}&userColor=%23#{author_color}"
      else
        author_mapper = req.session.anon_id
        author_name = undefined

      etherpad.createAuthorIfNotExistsFor {
        authorMapper: author_mapper,
        name: author_name
      }, (err, data) ->
        return server_error(req, res, err) if err?
        author_id = data.authorID

        # Set an arbitrary session length of 1 day; though that only matters if
        # the user leaves a tab open and connected for that long.
        maxAge = 24 * 60 * 60
        valid_until = (new Date().getTime()) + maxAge
        if doc.public_edit_until? or doc.public_view_until?
          valid_until = Math.min(valid_until,
            new Date(doc.public_edit_until or doc.public_view_until).getTime())

        etherpad.createSession {
          groupID: doc.etherpad_group_id
          authorID: author_id
          validUntil: valid_until
        }, (err, data) ->
          return server_error(req, res, err) if err?
          req.session.etherpad_session_id = data.sessionID
          res.cookie("sessionID", data.sessionID, {
            maxAge: maxAge
            domain: config.etherpad.cookie_domain
          })
          res.render "pad", context(req, {
            title: "#{req.params.pad_name} | Etherpad"
            twinklepad: doc
            embed_url: embed_url
          }, {
            pad_name: req.params.pad_name
            sharing: intertwinkles.clean_sharing(req.session, doc)
          })

  app.listen (config.port)

module.exports = {start}
