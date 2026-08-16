# ModuleLoader
**A robust, two-pass, Promise-driven bootstrapper for modern Roblox experiences.**

If you've ever had a script break because it tried to talk to another script that hadn't finished loading yet, or if you're tired of manually managing a giant list of `require()` statements and want to step into a better way of doing things, this framework is for you.

`ModuleLoader` acts as the engine ignition for your game. It automatically finds, requires, and safely starts every module in your codebase in a highly predictable, concurrent, and crash-resistant order.

## Key Features
*	**Two-Pass Architecture:** Separates initialization (`Setup`) from execution (`Start`), entirely eliminating race conditions.
*	**Resilient Retry Logic:** Automatically catches yielding failures or network timeouts and safely retries them without lagging the rest of the game.
*	**Strictly Typed:** Written in strict modern Luau (`--!strict`), establishing a clean standard for your codebase.
*	**Drop-in Ready:** Ships with `LeanPromise` and `Signal` directly nested as dependencies. You don't need to hunt down external libraries to make it work.
*	**(NEW) Server Authority Support:** When the `ServerAuthority` config is set to `true` at the top of the module, the server will find the necessary shared simulation modules in `ReplicatedStorage` as well as its normal `ServerScriptService` modules.
	
	> ***Note**: I recommend moving both of these libraries into a `Libs` folder within `ReplicatedStorage/Source` and updating the `require()` paths in `ModuleLoader` so you can use them elsewhere without needing the additional path.*

## How to Get Started

### 1. Installation
1. Navigate to the [Releases](https://github.com/Distracted-Games/ModuleLoader/releases/latest) page and download the latest `ModuleLoader.rbxm` file (or grab the source code).
2. Drag and drop the `.rbxm` file into Roblox Studio (if you grabbed the source code, copy into your editor).
3. From inside the model, place `ModuleLoader` in `ReplicatedStorage` (or inside `ReplicatedStorage.Source` alongside your other client modules — the loader automatically skips itself during the discovery phase).

### 2. File Structure
For the loader to find your modules, they must be placed in the correct directories:
*	**Server Modules:** Place anywhere inside `ServerScriptService`.
*	**Client Modules:** Place anywhere inside a folder named `Source` within `ReplicatedStorage` (`ReplicatedStorage.Source`).
*	**Simulation Modules (Server Authority):** When `ServerAuthority` is enabled in configuration, place shared simulation modules inside `ReplicatedStorage.Source.Simulation`. The server loader will automatically scan both `ServerScriptService` and `ReplicatedStorage.Source.Simulation`. The client loader's scan will automatically include the `Simulation` modules.

> ***Important:** Ensure all module names are unique across your codebase. If two modules share the same name (even across different directories), the loader will register the last discovered module and overwrite the earlier one.*

### 3. Usage
You only need two standard scripts in your entire game to trigger the framework: one on the server, and one on the client. They act as "dumb triggers" to start the engine.

**ServerStart** (Place in `ServerScriptService`)
```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModuleLoader = require(ReplicatedStorage.Source.ModuleLoader)

-- If the entry script needs to do something after loading (optional):
ModuleLoader.GameReadySignal:Once(function()
    print(`{script.Name} acknowledges game is fully loaded!`)
end)

ModuleLoader.Init()
```
**ClientStart** (Place in `ReplicatedFirst` or `StarterPlayerScripts` depending if you want to tie this into a loading screen or not)
```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sourceFolder = ReplicatedStorage:WaitForChild("Source")
local ModuleLoader = require(sourceFolder.ModuleLoader)

-- If the entry script needs to do something after loading (optional):
ModuleLoader.GameReadySignal:Once(function()
    print(`{script.Name} acknowledges game is fully loaded!`)
end)

ModuleLoader.Init()
```

## Writing Modules
To hook into the framework, your `ModuleScript` simply needs to expose a `Setup` and/or `Start` function using dot notation.
```lua
--!strict
local MyModule = {}

-- Phase 1: Run isolated setup logic.
function MyModule.Setup()
    print("Setting up internal state...")
    -- Do NOT interact with other modules here.
end

-- Phase 2: Interact with the rest of the game.
function MyModule.Start()
    print("The whole game is loaded. Safe to connect events and methods!")
end

return MyModule
```

## Technical Documentation
*If you're a more experienced developer, or want to know more about how this works, this section is for you.*

`ModuleLoader` enforces a strict structural boundary and handles asynchronous state via a custom execution pipeline.

### The Two-Phase Pipeline
The loader operates in two distinct, synchronized gates via `Promise.all` (technically three, see below):

1.	**Gate 1: Setup Phase**
	*	The loader iterates through all discovered modules and executes `Module.Setup()`.
	*	**The Rule:** Code inside `Setup` must have **zero external dependencies**. It is used solely to establish internal state and perform isolated operations.
	*	Modules execute concurrently. If a module yields (e.g., fetching a DataStore), it does not block the initialization of other modules.

2. **Gate 2: Start Phase**
	*	The loader waits until every single module has successfully cleared the Setup phase. Only then does it proceed to execute `Module.Start()`.
	*	**The Rule:** By the time `Start` runs, you are guaranteed that every other module in the game exists and has prepared its internal state. You can safely fetch other modules, read their data, and bind to their events. You *cannot* assume their specific `Start` logic has finished yet.

> ***Note:** These rules are not hardcoded into the system. It's up to you to enforce them.*

### Error Handling & Retries
The lifecycles are heavily sandboxed. Both `Setup` and `Start` methods are executed within a recursive `pcall` loop wrapped in a single, flattened `Promise`.

*	If a lifecycle method fails or throws a runtime error, the framework catches it, waits for a designated `RETRY_DELAY` (default: 1 second), and tries again.
*	It will retry up to the `ATTEMPT_LIMIT` (default: 3 times).
*	If a critical module exhausts all its retry attempts, the `Promise` cleanly rejects, skipping subsequent phases and bubbling the critical framework failure directly to the output console, preventing the game from launching in a corrupted, half-loaded state (mostly).

### Typing & Context
To ensure strict type safety and eliminate runtime errors related to dynamic scoping, `ModuleLoader` evaluates lifecycle methods as pure procedural functions (`() -> ()`: no arguments, no return values).

You should ideally define your lifecycle methods using dot notation (`function Module.Setup()`), rather than colon notation (`function Module:Setup()`), as the loader does not pass a `self` context when invoking the lifecycles, although it's not going to usually hurt anything if you do.

### Configuration
`ModuleLoader` includes a `config` table near the top of the module script for customization:
*	`ATTEMPT_LIMIT` (*number*, default: `3`): How many times to try running a lifecycle method before failing.
*	`RETRY_DELAY` (*number*, default: `1`): Seconds to wait between failed attempts.
*	`Debug` (*boolean*, default: `false`): When `true`, prints detailed logs for each step.
*	`ServerAuthority` (*boolean*, default: `false`): When `true`, the server loader also discovers and executes modules in `ReplicatedStorage.Source.Simulation` alongside `ServerScriptService`.

