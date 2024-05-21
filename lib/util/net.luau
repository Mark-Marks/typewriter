--!native
--!optimize 2

--[[
    This library is solely made as a default in case a net handler isn't provided.
    It is preferred to use a networking library such as zap or bytenet / coldnet, and let it handle
    sending / receiving the buffer with the dialogue payload, as it'll be way more optimized.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local run_context: "server" | "client" = if RunService:IsServer() then "server" else "client"
local fresh_channel_size: number = 1024

local function setup_remote(): RemoteEvent
	if run_context == "server" then
		local remote = Instance.new("RemoteEvent")
		remote.Name = "typewriter_net"
		remote.Parent = ReplicatedStorage

		return remote
	end

	return ReplicatedStorage:WaitForChild("typewriter_net") :: RemoteEvent
end

local remote = setup_remote()

type server = {
	fire: (player: Player, packet: buffer) -> (),
	set_listener: (f: (player: Player, packet: buffer) -> ()) -> (),
}

type client = {
	fire: (packet: buffer) -> (),
	set_listener: (f: (packet: buffer) -> ()) -> (),
}

type channel = {
	buff: buffer,
	cursor: number,
}

local function empty_channel(): channel
	return {
		buff = buffer.create(fresh_channel_size),
		cursor = 0,
	}
end

local ref: channel = empty_channel()
local ref_buff: buffer = ref.buff
local ref_cursor: number = ref.cursor

local function load_channel(channel: channel)
	if ref == channel then
		return
	end

	ref = channel
	ref_buff = channel.buff
	ref_cursor = channel.cursor
end

local function save_channel()
	ref.buff = ref_buff
	ref.cursor = ref_cursor
end

local function dynalloc(bytes: number)
	local length = buffer.len(ref_buff)
	if ref_cursor + bytes < length then
		return
	end

	while ref_cursor + bytes > length do
		length *= 2
	end

	local new = buffer.create(length)
	buffer.copy(new, 0, ref_buff)

	ref_buff = new
end

return {
	server = function(): server
		local server = {} :: server

		local listener: (player: Player, packet: buffer) -> () = nil

		local outbound: { [Player]: channel } = {}

		function server.fire(player: Player, packet: buffer)
			load_channel(outbound[player])

			local length = buffer.len(packet)
			dynalloc(length + 2)

			buffer.writeu16(ref_buff, ref_cursor, length)
			buffer.copy(ref_buff, ref_cursor + 2, packet)
			ref_cursor += length + 2

			save_channel()
			outbound[player] = ref
		end

		function server.set_listener(f: (player: Player, packet: buffer) -> ())
			listener = f
		end

		local function loop(event: RBXScriptSignal)
			while true do
				local player, packet = event:Wait()

				task.spawn(listener, player, packet)
			end
		end

		local function player_adding(player: Player)
			if outbound[player] then
				return
			end

			outbound[player] = empty_channel()
		end

		local function player_removing(player: Player)
			if not outbound[player] then
				return
			end

			outbound[player] = nil
		end

		for _, player in Players:GetPlayers() do
			player_adding(player)
		end

		Players.PlayerAdded:Connect(player_adding)
		Players.PlayerRemoving:Connect(player_removing)

		task.spawn(loop, remote.OnClientEvent)

		RunService.Heartbeat:Connect(function()
			for player, channel in outbound do
				if channel.cursor == 0 then
					continue
				end

				remote:FireClient(player, channel.buff)

				outbound[player] = empty_channel()
			end
		end)

		return server
	end,

	client = function(): client
		local client = {} :: client

		local listener: (packet: buffer) -> () = nil

		function client.fire(packet: buffer)
			local length = buffer.len(packet)
			dynalloc(length + 2)

			buffer.writeu16(ref_buff, ref_cursor, length)
			buffer.copy(ref_buff, ref_cursor + 2, packet)
			ref_cursor += length + 2
		end

		function client.set_listener(f: (packet: buffer) -> ())
			listener = f
		end

		local function loop(event: RBXScriptSignal)
			while true do
				local packet = event:Wait()

				task.spawn(listener, packet)
			end
		end

		RunService.Heartbeat:Connect(function()
			if ref_cursor == 0 then
				return
			end

			remote:FireServer(ref_buff)

			load_channel(empty_channel())
		end)

		task.spawn(loop, remote.OnServerEvent)

		return client
	end,
}
