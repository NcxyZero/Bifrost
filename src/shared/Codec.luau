local FastID = require(script.Parent.Parent.util.FastID)

local Codec = {}
local kinds = {}
local readers = {}
local nativeKinds = {
	EnumItem = true,
	NumberSequence = true,
	ColorSequence = true,
	PhysicalProperties = true,
	Faces = true,
	Axes = true,
	Font = true,
}
local identifiersByName = {}
local identifiersById = {}
local identifierMetatable = {}

local NIL = 0
local FALSE = 1
local TRUE = 2
local INT16 = 3
local INT32 = 4
local FLOAT64 = 5
local STRING8 = 6
local STRING32 = 7
local ARRAY = 8
local MAP = 9
local VECTOR2 = 10
local VECTOR3 = 11
local CFRAME = 12
local COLOR3 = 13
local UDIM = 14
local UDIM2 = 15
local SMALL_INT = 16
local RECT = 48
local NUMBER_RANGE = 49
local INSTANCE = 50
local IDENTIFIER = 51
local BUFFER = 52
local COLOR8 = 53
local VECTOR2_INT16 = 54
local VECTOR3_INT16 = 55
local RAY = 56
local BRICK_COLOR = 57
local NATIVE = 58
local MAX_DEPTH = 32
local MAX_ITEMS = 65535

function Codec.Identifier(name: string)
	assert(type(name) == "string" and #name > 0, "Identifier name must be a nonempty string")
	local existing = identifiersByName[name]
	if existing then
		return existing
	end
	local id = FastID.fromName(name)
	local collision = identifiersById[id]
	assert(collision == nil, `Identifier hash collision: {name} and {collision.name}`)
	local identifier = setmetatable({ name = name, id = id }, identifierMetatable)
	table.freeze(identifier)
	identifiersByName[name] = identifier
	identifiersById[id] = identifier
	return identifier
end

local function add(chunks, value)
	chunks[#chunks + 1] = value
end

local encodeValue

kinds["nil"] = function(_, chunks)
	add(chunks, string.char(NIL))
end

kinds["boolean"] = function(value, chunks)
	add(chunks, string.char(if value then TRUE else FALSE))
end

kinds["number"] = function(value, chunks)
	if value % 1 == 0 and value >= -16 and value <= 15 then
		add(chunks, string.char(SMALL_INT + value + 16))
	elseif value % 1 == 0 and value >= -32768 and value <= 32767 then
		add(chunks, string.char(INT16) .. string.pack("<i2", value))
	elseif value % 1 == 0 and value >= -2147483648 and value <= 2147483647 then
		add(chunks, string.char(INT32) .. string.pack("<i4", value))
	else
		add(chunks, string.char(FLOAT64) .. string.pack("<d", value))
	end
end

kinds["string"] = function(value, chunks)
	if #value <= 255 then
		add(chunks, string.char(STRING8) .. string.pack("<s1", value))
	else
		assert(#value <= 4294967295, "Bifrost string is too long")
		add(chunks, string.char(STRING32) .. string.pack("<s4", value))
	end
end

kinds["Vector2"] = function(value, chunks)
	add(chunks, string.char(VECTOR2) .. string.pack("<ff", value.X, value.Y))
end

kinds["Vector3"] = function(value, chunks)
	add(chunks, string.char(VECTOR3) .. string.pack("<fff", value.X, value.Y, value.Z))
end

kinds["Vector2int16"] = function(value, chunks)
	add(chunks, string.char(VECTOR2_INT16) .. string.pack("<i2i2", value.X, value.Y))
end

kinds["Vector3int16"] = function(value, chunks)
	add(chunks, string.char(VECTOR3_INT16) .. string.pack("<i2i2i2", value.X, value.Y, value.Z))
end

kinds["Ray"] = function(value, chunks)
	local origin = value.Origin
	local direction = value.Direction
	add(chunks, string.char(RAY) .. string.pack("<ffffff", origin.X, origin.Y, origin.Z, direction.X, direction.Y, direction.Z))
end

kinds["BrickColor"] = function(value, chunks)
	add(chunks, string.char(BRICK_COLOR) .. string.pack("<I2", value.Number))
end

kinds["CFrame"] = function(value, chunks)
	local x, y, z = value:ToOrientation()
	local position = value.Position
	local scale = 32767 / math.pi
	add(chunks, string.char(CFRAME) .. string.pack("<fffi2i2i2", position.X, position.Y, position.Z, math.round(x * scale), math.round(y * scale), math.round(z * scale)))
end

kinds["Color3"] = function(value, chunks)
	local r = math.round(value.R * 255)
	local g = math.round(value.G * 255)
	local b = math.round(value.B * 255)
	if r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and b <= 255 and math.abs(value.R - r / 255) < 0.000001 and math.abs(value.G - g / 255) < 0.000001 and math.abs(value.B - b / 255) < 0.000001 then
		add(chunks, string.char(COLOR8) .. string.pack("<I1I1I1", r, g, b))
	else
		add(chunks, string.char(COLOR3) .. string.pack("<fff", value.R, value.G, value.B))
	end
end

kinds["UDim"] = function(value, chunks)
	add(chunks, string.char(UDIM) .. string.pack("<fi4", value.Scale, value.Offset))
end

kinds["UDim2"] = function(value, chunks)
	add(chunks, string.char(UDIM2) .. string.pack("<fi4fi4", value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset))
end

kinds["Rect"] = function(value, chunks)
	add(chunks, string.char(RECT) .. string.pack("<ffff", value.Min.X, value.Min.Y, value.Max.X, value.Max.Y))
end

kinds["NumberRange"] = function(value, chunks)
	add(chunks, string.char(NUMBER_RANGE) .. string.pack("<ff", value.Min, value.Max))
end

kinds["Instance"] = function(value, chunks, _, references)
	assert(#references < MAX_ITEMS, "Bifrost has too many Instance references")
	references[#references + 1] = value
	add(chunks, string.char(INSTANCE) .. string.pack("<I2", #references))
end

kinds["native"] = function(value, chunks, _, references)
	assert(#references < MAX_ITEMS, "Bifrost has too many native references")
	references[#references + 1] = value
	add(chunks, string.char(NATIVE) .. string.pack("<I2", #references))
end

kinds["buffer"] = function(value, chunks)
	add(chunks, string.char(BUFFER) .. string.pack("<s4", buffer.tostring(value)))
end

kinds["table"] = function(value, chunks, seen, references, depth)
	if getmetatable(value) == identifierMetatable then
		add(chunks, string.char(IDENTIFIER) .. string.pack("<I4", value.id))
		return
	end
	assert(not seen[value], "Bifrost cannot encode cyclic tables")
	seen[value] = true
	local count = 0
	local arrayLength = #value
	local isArray = arrayLength > 0
	for key in pairs(value) do
		count += 1
		assert(count <= MAX_ITEMS, "Bifrost table is too large")
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > arrayLength then
			isArray = false
		end
	end
	if isArray and count == arrayLength then
		add(chunks, string.char(ARRAY) .. string.pack("<I2", count))
		for index = 1, count do
			encodeValue(value[index], chunks, seen, references, depth + 1)
		end
	else
		add(chunks, string.char(MAP) .. string.pack("<I2", count))
		for key, item in pairs(value) do
			encodeValue(key, chunks, seen, references, depth + 1)
			encodeValue(item, chunks, seen, references, depth + 1)
		end
	end
	seen[value] = nil
end

encodeValue = function(value, chunks, seen, references, depth)
	assert(depth <= MAX_DEPTH, "Bifrost value is too deeply nested")
	local kind = typeof(value)
	local writer = kinds[kind] or (nativeKinds[kind] and kinds.native)
	assert(writer, `Bifrost cannot encode {kind}`)
	writer(value, chunks, seen, references, depth)
end

function Codec.EncodeTuple(prefix: string?, ...)
	local chunks = {}
	local references = {}
	if prefix then
		add(chunks, prefix)
	end
	local count = select("#", ...)
	assert(count <= 255, "Bifrost tuple is too large")
	add(chunks, string.pack("<I1", count))
	local seen = {}
	for index = 1, count do
		encodeValue(select(index, ...), chunks, seen, references, 0)
	end
	return table.concat(chunks), if #references > 0 then references else nil
end

local function check(bytes: string, offset: number, length: number)
	assert(length >= 0 and offset + length - 1 <= #bytes, "Invalid Bifrost packet")
end

local decodeValue

readers[NIL] = function(_, offset)
	return nil, offset
end

readers[FALSE] = function(_, offset)
	return false, offset
end

readers[TRUE] = function(_, offset)
	return true, offset
end

readers[INT16] = function(bytes, offset)
	check(bytes, offset, 2)
	local value = string.unpack("<i2", bytes, offset)
	return value, offset + 2
end

readers[INT32] = function(bytes, offset)
	check(bytes, offset, 4)
	local value = string.unpack("<i4", bytes, offset)
	return value, offset + 4
end

readers[FLOAT64] = function(bytes, offset)
	check(bytes, offset, 8)
	local value = string.unpack("<d", bytes, offset)
	return value, offset + 8
end

readers[STRING8] = function(bytes, offset)
	check(bytes, offset, 1)
	return string.unpack("<s1", bytes, offset)
end

readers[STRING32] = function(bytes, offset)
	check(bytes, offset, 4)
	return string.unpack("<s4", bytes, offset)
end

readers[BUFFER] = function(bytes, offset)
	check(bytes, offset, 4)
	local value, nextOffset = string.unpack("<s4", bytes, offset)
	return buffer.fromstring(value), nextOffset
end

readers[ARRAY] = function(bytes, offset, references, depth)
	check(bytes, offset, 2)
	local count = string.unpack("<I2", bytes, offset)
	offset += 2
	local result = {}
	for index = 1, count do
		result[index], offset = decodeValue(bytes, offset, references, depth + 1)
	end
	return result, offset
end

readers[MAP] = function(bytes, offset, references, depth)
	check(bytes, offset, 2)
	local count = string.unpack("<I2", bytes, offset)
	offset += 2
	local result = {}
	for _ = 1, count do
		local key
		local value
		key, offset = decodeValue(bytes, offset, references, depth + 1)
		value, offset = decodeValue(bytes, offset, references, depth + 1)
		assert(key ~= nil, "Invalid Bifrost table key")
		result[key] = value
	end
	return result, offset
end

readers[VECTOR2] = function(bytes, offset)
	check(bytes, offset, 8)
	local x, y = string.unpack("<ff", bytes, offset)
	return Vector2.new(x, y), offset + 8
end

readers[VECTOR3] = function(bytes, offset)
	check(bytes, offset, 12)
	local x, y, z = string.unpack("<fff", bytes, offset)
	return Vector3.new(x, y, z), offset + 12
end

readers[VECTOR2_INT16] = function(bytes, offset)
	check(bytes, offset, 4)
	local x, y = string.unpack("<i2i2", bytes, offset)
	return Vector2int16.new(x, y), offset + 4
end

readers[VECTOR3_INT16] = function(bytes, offset)
	check(bytes, offset, 6)
	local x, y, z = string.unpack("<i2i2i2", bytes, offset)
	return Vector3int16.new(x, y, z), offset + 6
end

readers[RAY] = function(bytes, offset)
	check(bytes, offset, 24)
	local ox, oy, oz, dx, dy, dz = string.unpack("<ffffff", bytes, offset)
	return Ray.new(Vector3.new(ox, oy, oz), Vector3.new(dx, dy, dz)), offset + 24
end

readers[BRICK_COLOR] = function(bytes, offset)
	check(bytes, offset, 2)
	local number = string.unpack("<I2", bytes, offset)
	return BrickColor.new(number), offset + 2
end

readers[CFRAME] = function(bytes, offset)
	check(bytes, offset, 18)
	local px, py, pz, rx, ry, rz = string.unpack("<fffi2i2i2", bytes, offset)
	local scale = math.pi / 32767
	return CFrame.new(px, py, pz) * CFrame.fromOrientation(rx * scale, ry * scale, rz * scale), offset + 18
end

readers[COLOR3] = function(bytes, offset)
	check(bytes, offset, 12)
	local r, g, b = string.unpack("<fff", bytes, offset)
	return Color3.new(r, g, b), offset + 12
end

readers[COLOR8] = function(bytes, offset)
	check(bytes, offset, 3)
	local r, g, b = string.unpack("<I1I1I1", bytes, offset)
	return Color3.fromRGB(r, g, b), offset + 3
end

readers[UDIM] = function(bytes, offset)
	check(bytes, offset, 8)
	local scale, position = string.unpack("<fi4", bytes, offset)
	return UDim.new(scale, position), offset + 8
end

readers[UDIM2] = function(bytes, offset)
	check(bytes, offset, 16)
	local xs, xo, ys, yo = string.unpack("<fi4fi4", bytes, offset)
	return UDim2.new(xs, xo, ys, yo), offset + 16
end

readers[RECT] = function(bytes, offset)
	check(bytes, offset, 16)
	local x1, y1, x2, y2 = string.unpack("<ffff", bytes, offset)
	return Rect.new(x1, y1, x2, y2), offset + 16
end

readers[NUMBER_RANGE] = function(bytes, offset)
	check(bytes, offset, 8)
	local minimum, maximum = string.unpack("<ff", bytes, offset)
	return NumberRange.new(minimum, maximum), offset + 8
end

readers[INSTANCE] = function(bytes, offset, references)
	check(bytes, offset, 2)
	local index = string.unpack("<I2", bytes, offset)
	assert(references and references[index], "Missing Bifrost Instance reference")
	return references[index], offset + 2
end

readers[NATIVE] = readers[INSTANCE]

readers[IDENTIFIER] = function(bytes, offset)
	check(bytes, offset, 4)
	local id = string.unpack("<I4", bytes, offset)
	local identifier = identifiersById[id]
	assert(identifier, `Unknown Bifrost identifier {id}`)
	return identifier, offset + 4
end

decodeValue = function(bytes, offset, references, depth)
	assert(depth <= MAX_DEPTH, "Bifrost value is too deeply nested")
	check(bytes, offset, 1)
	local tag = string.byte(bytes, offset)
	offset += 1
	if tag >= SMALL_INT and tag < SMALL_INT + 32 then
		return tag - SMALL_INT - 16, offset
	end
	local reader = readers[tag]
	assert(reader, `Unknown Bifrost type {tag}`)
	return reader(bytes, offset, references, depth)
end

function Codec.DecodeTuple(bytes: string, references, offset: number?)
	assert(type(bytes) == "string", "Invalid Bifrost packet")
	local nextOffset = offset or 1
	check(bytes, nextOffset, 1)
	local count = string.byte(bytes, nextOffset)
	nextOffset += 1
	local values = { n = count }
	for index = 1, count do
		values[index], nextOffset = decodeValue(bytes, nextOffset, references, 0)
	end
	assert(nextOffset == #bytes + 1, "Invalid Bifrost packet length")
	return values
end

function Codec.Encode(value, prefix: string?)
	return Codec.EncodeTuple(prefix, value)
end

function Codec.Decode(bytes: string, references, offset: number?)
	local values = Codec.DecodeTuple(bytes, references, offset)
	return values[1]
end

return Codec
