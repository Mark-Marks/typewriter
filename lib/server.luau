--!native
--!optimize 2
local root = script.Parent
local net = require(root.util.net)
local signal = require(root.util.signal)

--- Options for the server.
export type options = {
	--- Networking wrapper functions.\
	--- Typewriter can be easily integrated with a networking library / utility, such as ByteNet / ColdNet or zap, and will be best used with them networking performance wise.\
	--- In the case that you aren't using an optimized library, typewriter's built in networking should be good enough.\
	--- Example implementation with zap:
	--- ```lua
	--- -- zap.cfg
	--- event typewriter_server = {
	---     from: Server,
	---     type: Reliable,
	---     call: SingleAsync,
	---     data: buffer -- Typewriter handles serdes automatically
	--- }
	---
	--- event typewriter_client = {
	---     from: Client,
	---     type: Reliable,
	---     call: SingleAsync,
	---     data: buffer -- Typewriter handles serdes automatically
	--- }
	--- ```
	--- ```lua
	--- -- service.luau
	--- local zap = require(path.to.zap.server)
	---
	--- local net_options = {
	---     send = function(player: Player, packet: buffer)
	---         zap.typewriter_server.fire(player, packet)
	---     end,
	---     receive = function(listener: (player: Player, packet: buffer) -> ())
	---         zap.typewriter_client.set_callback(listener)
	--      end,
	--- }
	--- ```
	net: {
		--- @param player Player
		--- @param packet buffer
		send: (player: Player, packet: buffer) -> (),
		--- @param listener f<Player, buffer>
		receive: (listener: (player: Player, packet: buffer) -> ()) -> (),
	}?,
}

--- Typewriter server.
export type server = {
	--- Networking wrapper functions, internal use only.
	net: {
		--- @param player Player
		--- @param packet buffer
		send: (player: Player, packet: buffer) -> (),
		--- @param listener f<Player, buffer>
		receive: (listener: (player: Player, packet: buffer) -> ()) -> (),
	},
	--- Signals for core events.
	signals: {
		--- Fired when the player chooses to go to the next part of dialogue.
		_next: signal.Signal<Player>,
		--- Fired when the player chooses a dialogue option. Uses an internal index - provides no information outside of the internal code.
		_chose: signal.Signal<Player, number>,
		--- Fired when the server is sending a part of dialogue to the player. Consists of the entire part.
		sending: signal.Signal<Player, part>,
		--- Fired when the player chooses a dialogue option. Consists of the entire part equivalent to the option, and the option itself.
		choice: signal.Signal<Player, string, part>,
		--- Fired when the player stops or finishes dialogue.\
		--- This signal should also be fired by your codebase if the player exits out of dialogue.
		stopped: signal.Signal<Player>,
	},
	--- List of players actively in dialogue.
	active: { Player },

	--- Streams dialogue to a player, sending the next part whenever the player either chooses to continue dialogue or selects a choice.
	--- @param self server -- The constructed server.
	--- @param player Player -- Player to stream dialogue to.
	--- @param dialogue part -- Dialogue.
	stream: (self: server, player: Player, dialogue: part) -> (),
}

--- Part of a dialogue.
export type part = {
	--- Message to show.
	message: string,
	--- List of choices, mutually exclusive with `next`.
	choices: { [string]: part }?,
	--- Next part of dialogue, mutually exclusive with `choices`.
	next: part?,
}

local function dynalloc(buff: buffer, cursor: number, bytes: number): buffer
	local length = buffer.len(buff)
	if cursor + bytes < length then
		return buff
	end

	while cursor + bytes > length do
		length *= 2
	end

	local new = buffer.create(length)
	buffer.copy(new, 0, buff)

	return buff
end

local function write_str(buff: buffer, cursor: number, str: string): (buffer, number)
	local len = string.len(str)
	buff = dynalloc(buff, cursor, len + 2)
	buffer.writeu16(buff, cursor, len)
	buffer.writestring(buff, cursor + 2, str)
	return buff, cursor + len + 2
end

local function pack_choices(buff: buffer, cursor: number, msg: string, choices: { string }): buffer
	buff, cursor = write_str(buff, 0, msg)

	for index, choice in choices do
		buff = dynalloc(buff, cursor, 1)
		buffer.writeu8(buff, cursor, index)
		cursor += 1
		buff, cursor = write_str(buff, cursor, choice)
	end

	return buff
end

local function stream(self: server, player: Player, dialogue: part)
	if table.find(self.active, player) then
		return
	end
	table.insert(self.active, player)

	local next = dialogue
	while table.find(self.active, player) do
		local buff = buffer.create(1024)
		local disconnect
		local continue_execution = false

		self.signals.sending:Fire(player, next)

		if next.choices then
			buffer.writeu8(buff, 0, 1)

			local choices = {}
			for _, choice in next.choices do
				table.insert(choices, choice.message)
			end

			self.net.send(player, pack_choices(buff, 1, next.message, choices))

			disconnect = self.signals._chose:Connect(function(client, index)
				if client ~= player then
					return
				end

				local choice_str = choices[index]
				next = next.choices[choice_str]

				self.signals.choice:Fire(player, choice_str, next)

				disconnect()

				continue_execution = true
			end)

			repeat
				task.wait()
			until continue_execution

			continue
		end

		buffer.writeu8(buff, 0, 2)

		local packed = write_str(buff, 1, next.message)
		self.net.send(player, packed)

		disconnect = self.signals._next:Connect(function(client)
			if client ~= player then
				return
			end

			continue_execution = true
		end)

		repeat
			task.wait()
		until continue_execution

		if not next.next then
			self.signals.stopped:Fire(player)
			break
		end
		next = next.next
	end
end

return function(options: options): server
	if not options.net then
		local net = net.server()
		options.net = {
			send = net.fire,
			receive = net.set_listener,
		}
	end

	local net = options.net
	assert(net)

	local server: server = {
		net = net,
		signals = {
			_next = signal(),
			_chose = signal(),
			sending = signal(),
			choice = signal(),
			stopped = signal(),
		},
		active = {},

		stream = stream,
	}

	server.signals.stopped:Connect(function(player: Player)
		local index = table.find(server.active, player)
		if not index then
			return
		end

		table.remove(server.active, index)
	end)

	net.receive(function(player: Player, packet: buffer)
		--- 1 = go to next part
		--- 2 = selected choice
		local ty = buffer.readu8(packet, 0)
		if ty == 1 then
			server.signals._next:Fire(player)
		elseif ty == 2 then
			local choice = buffer.readu8(packet, 1)
			server.signals._chose:Fire(player, choice)
		end
	end)

	return server
end
