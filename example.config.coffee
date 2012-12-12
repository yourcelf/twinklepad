base_config = require '../base_config'
_           = require 'underscore'

conf = _.extend {}, base_config
conf.port = 9004
conf.intertwinkles.api_key = "one"
conf.dbname = "twinklepad"
conf.etherpad = {
  api_key: "PuHTWuOXv7m0UziZMBGfxyJwotYEO6Qy"
  url: "http://localhost:9005"
}

module.exports = conf
