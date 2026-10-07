local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(script.Config)
local Codec = require(script.shared.Codec)
local FastID = require(script.util.FastID)

local isServer = RunService:IsServer()
local Bifrost = {}

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
	Destroy: (self: Connection) -> (),
}

export type PlayerGroup = { kind: string, players: { Player }? }
export type Target = Player | PlayerGroup

export type ServerBridge = {
	Name: string,
	Fire: (self: ServerBridge, ...any) -> (),
	Connect: (self: ServerBridge, callback: (Player, ...any) -> ()) -> Connection,
	Once: (self: ServerBridge, callback: (Player, ...any) -> ()) -> Connection,
	Wait: (self: ServerBridge) -> (Player, ...any),
}

export type ClientBridge = {
	Name: string,
	Fire: (self: ClientBridge, ...any) -> (),
	Connect: (self: ClientBridge, callback: (...any) -> ()) -> Connection,
	Once: (self: ClientBridge, callback: (...any) -> ()) -> Connection,
	Wait: (self: ClientBridge) -> ...any,
}

export type ServerFunctionBridge = {
	Name: string,
	OnInvoke: (self: ServerFunctionBridge, callback: (Player, ...any) -> ...any) -> (),
	Invoke: (self: ServerFunctionBridge, player: Player, ...any) -> ...any,
	InvokeAsync: (self: ServerFunctionBridge, player: Player, data: any, callback: (boolean, ...any) -> (), timeout: number?) -> (),
}

export type ClientFunctionBridge = {
	Name: string,
	OnInvoke: (self: ClientFunctionBridge, callback: (...any) -> ...any) -> (),
	Invoke: (self: ClientFunctionBridge, ...any) -> ...any,
	InvokeAsync: (self: ClientFunctionBridge, data: any, callback: (boolean, ...any) -> (), timeout: number?) -> (),
}

local bridgesByName = {}
local bridgesById = {}
local functionsByName = {}
local functionsById = {}
local namesById = {}
local nextListenerId = 0
local root
local eventRemote
local functionRemote
local allPlayers = { kind = "all" }
local playerGroupMarker = {}
local pendingServer = {}
local pendingClient = {}

local function registerName(name: string)
	assert(type(name) == "string" and #name > 0, "Bridge name must be a nonempty string")
	local id = FastID.fromName(name)
	local collision = namesById[id]
	assert(collision == nil or collision == name, `Bridge hash collision: {name} and {collision}`)
	namesById[id] = name
	return id
end

local function getRemote(className: string, name: string)
	local existing = root:FindFirstChild(name)
	if existing then
		assert(existing.ClassName == className, `Bifrost remote {name} has the wrong class`)
		return existing
	end
	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = root
	return remote
end

if isServer then
	root = ReplicatedStorage:FindFirstChild("__Bifrost")
	if not root then
		root = Instance.new("Folder")
		root.Name = "__Bifrost"
		root.Parent = ReplicatedStorage
	end
	assert(root:IsA("Folder"), "Bifrost root must be a Folder")
	eventRemote = getRemote("RemoteEvent", "Event")
	functionRemote = getRemote("RemoteFunction", "Function")
end

local function clientRemotes()
	if not root then
		root = ReplicatedStorage:WaitForChild("__Bifrost")
	end
	if not eventRemote then
		eventRemote = root:WaitForChild("Event")
	end
	if not functionRemote then
		functionRemote = root:WaitForChild("Function")
	end
end

local function decodePacket(packet, references)
	assert(type(packet) == "string" and #packet >= 5, "Invalid Bifrost packet")
	local id = string.unpack("<I4", packet)
	return id, Codec.DecodeTuple(packet, references, 5)
end

local function deliver(bridge, player, values)
	for id, listener in pairs(bridge.listeners) do
		if listener.once then
			bridge.listeners[id] = nil
			listener.connection.Connected = false
		end
		if isServer then
			task.spawn(listener.callback, player, table.unpack(values, 1, values.n))
		else
			task.spawn(listener.callback, table.unpack(values, 1, values.n))
		end
	end
end

local function receiveSingleEvent(player, packet, references)
	local ok, id, values = pcall(decodePacket, packet, references)
	if not ok then
		return
	end
	local bridge = bridgesById[id]
	if bridge then
		deliver(bridge, player, values)
	end
end

local function receiveEvent(player, packet, references, batched)
	if not batched then
		receiveSingleEvent(player, packet, references)
		return
	end
	if type(packet) ~= "string" then
		return
	end
	local offset = 1
	local index = 0
	while offset <= #packet and index < 256 do
		if offset + 3 > #packet then
			return
		end
		local length = string.unpack("<I4", packet, offset)
		offset += 4
		if length < 5 or offset + length - 1 > #packet then
			return
		end
		index += 1
		receiveSingleEvent(player, string.sub(packet, offset, offset + length - 1), if type(references) == "table" then references[index] else nil)
		offset += length
	end
end

local function packMessages(messages, first, last)
	if first == last then
		return messages[first].packet, messages[first].references, false
	end
	local chunks = {}
	local references = {}
	local hasReferences = false
	for index = first, last do
		local message = messages[index]
		local slot = index - first + 1
		chunks[slot] = string.pack("<I4", #message.packet) .. message.packet
		references[slot] = message.references or false
		if message.references then
			hasReferences = true
		end
	end
	return table.concat(chunks), if hasReferences then references else nil, true
end

local function sendMessages(messages, player)
	for first = 1, #messages, 256 do
		local packet, references, batched = packMessages(messages, first, math.min(first + 255, #messages))
		if player then
			eventRemote:FireClient(player, packet, references, batched)
		else
			eventRemote:FireServer(packet, references, batched)
		end
	end
end

local function queueFor(player, packet, references)
	local queue = pendingServer[player]
	if not queue then
		queue = {}
		pendingServer[player] = queue
	end
	queue[#queue + 1] = { packet = packet, references = references }
end

RunService.Heartbeat:Connect(function()
	if isServer then
		if next(pendingServer) == nil then
			return
		end
		local current = pendingServer
		pendingServer = {}
		for player, messages in pairs(current) do
			if player.Parent == Players then
				sendMessages(messages, player)
			end
		end
	elseif eventRemote and #pendingClient > 0 then
		local current = pendingClient
		pendingClient = {}
		sendMessages(current, nil)
	end
end)

local function receiveFunction(player, packet, references)
	local ok, id, values = pcall(decodePacket, packet, references)
	if not ok then
		return false, "Invalid Bifrost request"
	end
	local bridge = functionsById[id]
	if not bridge or not bridge.handler then
		return false, "FunctionBridge has no handler"
	end
	local results
	if isServer then
		results = table.pack(pcall(bridge.handler, player, table.unpack(values, 1, values.n)))
	else
		results = table.pack(pcall(bridge.handler, table.unpack(values, 1, values.n)))
	end
	if not results[1] then
		return false, tostring(results[2])
	end
	local encoded, resultPacket, resultReferences = pcall(Codec.EncodeTuple, nil, table.unpack(results, 2, results.n))
	if not encoded then
		return false, tostring(resultPacket)
	end
	return true, resultPacket, resultReferences
end

if isServer then
	eventRemote.OnServerEvent:Connect(receiveEvent)
	functionRemote.OnServerInvoke = receiveFunction
else
	task.spawn(function()
		clientRemotes()
		eventRemote.OnClientEvent:Connect(function(packet, references, batched)
			receiveEvent(nil, packet, references, batched)
		end)
		functionRemote.OnClientInvoke = function(packet, references)
			return receiveFunction(nil, packet, references)
		end
	end)
end

local function addListener(bridge, callback, once)
	assert(type(callback) == "function", "Bridge listener must be a function")
	nextListenerId += 1
	local listenerId = nextListenerId
	local connection = { Connected = true }
	local listeners = bridge.listeners
	function connection:Disconnect()
		if self.Connected then
			self.Connected = false
			listeners[listenerId] = nil
		end
	end

	connection.Destroy = connection.Disconnect
	listeners[listenerId] = { callback = callback, once = once, connection = connection }
	return connection
end

local bridgeMethods = {}

local function encodeAfterTarget(prefix, _, ...)
	return Codec.EncodeTuple(prefix, ...)
end

local function isTarget(target)
	if typeof(target) == "Instance" and target:IsA("Player") then
		return true
	end
	return target == allPlayers or (type(target) == "table" and target.marker == playerGroupMarker)
end

function bridgeMethods:Fire(...)
	if isServer then
		local target = select(1, ...)
		local packet
		local references
		if isTarget(target) then
			packet, references = encodeAfterTarget(self.prefix, ...)
		else
			target = allPlayers
			packet, references = Codec.EncodeTuple(self.prefix, ...)
		end
		if typeof(target) == "Instance" and target:IsA("Player") then
			queueFor(target, packet, references)
		elseif target == allPlayers then
			for _, player in Players:GetPlayers() do
				queueFor(player, packet, references)
			end
		elseif type(target) == "table" and target.kind == "players" then
			for _, player in target.players do
				queueFor(player, packet, references)
			end
		elseif type(target) == "table" and target.kind == "except" then
			local excluded = {}
			for _, player in target.players do
				excluded[player] = true
			end
			for _, player in Players:GetPlayers() do
				if not excluded[player] then
					queueFor(player, packet, references)
				end
			end
		else
			error("Bridge:Fire requires a Player or player group on the server")
		end
	else
		local packet, references = Codec.EncodeTuple(self.prefix, ...)
		pendingClient[#pendingClient + 1] = { packet = packet, references = references }
	end
end

function bridgeMethods:Connect(callback)
	return addListener(self, callback, false)
end

function bridgeMethods:Once(callback)
	return addListener(self, callback, true)
end

function bridgeMethods:Wait()
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

local functionMethods = {}

function functionMethods:OnInvoke(callback)
	assert(type(callback) == "function", "FunctionBridge:OnInvoke requires a function")
	self.handler = callback
end

function functionMethods:Invoke(...)
	local packet
	local references
	local success
	local response
	local responseReferences
	if isServer then
		local target = select(1, ...)
		assert(typeof(target) == "Instance" and target:IsA("Player"), "FunctionBridge:Invoke requires a Player on the server")
		packet, references = encodeAfterTarget(self.prefix, ...)
		success, response, responseReferences = functionRemote:InvokeClient(target, packet, references)
	else
		clientRemotes()
		packet, references = Codec.EncodeTuple(self.prefix, ...)
		success, response, responseReferences = functionRemote:InvokeServer(packet, references)
	end
	if not success then
		error(response, 2)
	end
	local values = Codec.DecodeTuple(response, responseReferences)
	return table.unpack(values, 1, values.n)
end

function functionMethods:InvokeAsync(target, data, callback, timeout)
	local onResult = if isServer then callback else data
	local duration = if isServer then timeout else callback
	assert(type(onResult) == "function", "FunctionBridge:InvokeAsync requires a callback")
	duration = duration or 10
	assert(type(duration) == "number" and duration > 0, "FunctionBridge timeout must be positive")
	local completed = false
	local worker = task.spawn(function()
		local results
		if isServer then
			results = table.pack(pcall(self.Invoke, self, target, data))
		else
			results = table.pack(pcall(self.Invoke, self, target))
		end
		if not completed then
			completed = true
			onResult(table.unpack(results, 1, results.n))
		end
	end)
	task.delay(duration, function()
		if not completed then
			completed = true
			pcall(task.cancel, worker)
			onResult(false, "FunctionBridge timed out")
		end
	end)
end

function Bifrost.AllPlayers()
	return allPlayers
end

function Bifrost.Players(players: { Player })
	return { kind = "players", players = players, marker = playerGroupMarker }
end

function Bifrost.PlayersExcept(players: { Player })
	return { kind = "except", players = players, marker = playerGroupMarker }
end

function Bifrost.ReferenceIdentifier(name: string)
	return Codec.Identifier(name)
end

function Bifrost.Bridge(name: string): ServerBridge | ClientBridge
	local existing = bridgesByName[name]
	if existing then
		return existing
	end
	local id = registerName(name)
	local bridge = setmetatable({ Name = name, prefix = string.pack("<I4", id), listeners = {} }, { __index = bridgeMethods })
	bridgesByName[name] = bridge
	bridgesById[id] = bridge
	return bridge
end

function Bifrost.FunctionBridge(name: string): ServerFunctionBridge | ClientFunctionBridge
	local existing = functionsByName[name]
	if existing then
		return existing
	end
	local id = registerName(name)
	local bridge = setmetatable({ Name = name, prefix = string.pack("<I4", id) }, { __index = functionMethods })
	functionsByName[name] = bridge
	functionsById[id] = bridge
	return bridge
end

local clientFolder = ReplicatedStorage:FindFirstChild("client")
local modulesFolder = clientFolder and clientFolder:FindFirstChild("modules")
local clientData = modulesFolder and modulesFolder:FindFirstChild("ClientData")
local version = Config.Version .. (if clientData and clientData:IsA("ModuleScript") then "a" else "")

Bifrost.Version = version
print(`Bifrost v{version}`)

return Bifrost
