local FastID = {}

function FastID.fromName(name: string): number
	local hash = 5381

	for index = 1, #name do
		hash = (hash * 33 + string.byte(name, index)) % 4294967296
	end

	return hash
end

return FastID
