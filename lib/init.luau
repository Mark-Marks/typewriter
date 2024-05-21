local client = require(script.client)
local net = require(script.util.net)
local server = require(script.server)

return {
	server = server,
	client = client,

	net = net,
}
