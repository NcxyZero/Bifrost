# Bifrost

A compact networking library for Roblox, inspired by [BridgeNet2](https://github.com/ffrostfall/BridgeNet2). Bridges share one `RemoteEvent`; function bridges share one `RemoteFunction`.

## Install

After publishing the package:

```toml
[dependencies]
Bifrost = "ncxyzero/bifrost@0.0.1"
```

## Bridges

```luau
local Bifrost = require(game.ReplicatedStorage.Packages.Bifrost)
local bridge = Bifrost.Bridge("Bridge") :: Bifrost.ServerBridge

bridge:Connect(function(player, a, b)
	bridge:Fire(player, a + b, a - b)
end)
```

On the client:

```luau
local Bifrost = require(game.ReplicatedStorage.Packages.Bifrost)
local bridge = Bifrost.Bridge("Bridge") :: Bifrost.ClientBridge

bridge:Connect(function(sum, difference)
	print(sum, difference)
end)

bridge:Fire(1, 2)
```

Server targets also include `Bifrost.AllPlayers()`, `Bifrost.Players({ playerA, playerB })`, and `Bifrost.PlayersExcept({ playerA })`. Calling `Fire` on the server without a target broadcasts to all players. Bridges support `Connect`, `Once`, and `Wait`; tuples preserve `nil` values.

## Function bridges

```luau
local inventory = Bifrost.FunctionBridge("Inventory")

inventory:OnInvoke(function(player, itemId)
	return { owned = true, id = itemId }
end)
```

On the client, call `inventory:Invoke(itemId)` for a response or `inventory:InvokeAsync(itemId, function(ok, result) ... end)` to keep the caller running. `Invoke` accepts and returns tuples. Async calls time out after 10 seconds by default. `Invoke` yields only its calling thread while the `RemoteFunction` responds.

## Data

Bifrost packs strings with `string.pack`, uses compact integer tags, and converts common Roblox types such as vectors, CFrames, and colors to numbers. It also supports tables, buffers, and replicated `Instance` references. Vector components and CFrame positions use 32-bit floats; CFrame angles use 16-bit integers.

Use `Bifrost.ReferenceIdentifier("key")` on both sides for repeated keys or values. Event calls made in one frame are batched per recipient. Bridge names and identifiers use deterministic 4-byte IDs, without UUID generation.
