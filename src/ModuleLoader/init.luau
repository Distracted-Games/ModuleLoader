--!strict

--[[
    ModuleLoader
    @author DistractedGames
    @version 3.0.1

    This module implements a two-pass loading system for ModuleScripts using Promises.
    It is designed to run on both the server and the client to create a unified module
    framework.

    The loader operates in two distinct phases or "lifecycles":
    1.  Setup: The loader first requires all modules and calls the `Setup()`
        method on any module that has one. This phase runs concurrently and is
        intended for initialization tasks that do not depend on other modules
        being active, such as setting up internal state, local variables, and
        independent logic.

    2.  Start: After all modules have successfully completed the Setup phase,
        the loader executes the `Start()` method concurrently. This phase is
        for logic that may or may not depend on other modules having completed
        their own setup, such as connecting to events, or activating core
        functionality. You can safely assume each module has set up internal
        state but cannot assume their own `Start()` logic has run yet.

    This approach helps manage dependencies implicitly without needing a complex
    dependency graph.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Promise = require(script.LeanPromise)
local Signal = require(script.Signal)

-- Configuration for the loader's behavior.
local config = {
	ATTEMPT_LIMIT = 3, -- How many times to try running a lifecycle method before failing.
	RETRY_DELAY = 1, -- Seconds to wait between failed attempts.
	Debug = false, -- When true, prints detailed logs for each step.
}

type Promise<T> = Promise.Promise<T>

-- Determine the environment and root directory for modules.
local isServer = RunService:IsServer()
-- On the client, modules are expected to be in a "Source" folder within ReplicatedStorage.
local rootDirectory = if isServer then ServerScriptService else ReplicatedStorage
local moduleDirectory = if isServer
	then rootDirectory :: ServerScriptService
	else (rootDirectory :: ReplicatedStorage):WaitForChild("Source") :: Folder

local ModuleLoader = {}

-- A global signal that can be used by the single Script, or LocalScript where
-- ModuleLoader is required, if needed.
ModuleLoader.GameReadySignal = Signal.new() :: Signal.Signal<>

--[[
    Logs a formatted message to the output.
    Uses `warn` for warnings and `print` for debug messages.
    The log includes the calling function's name and line for easier debugging.
    @param message The core message to log.
    @param isWarning If true, formats the message as a warning.
]]
local function log(message: string, isWarning: "warn"?)
	local prefix = `{script.Name} `
	local source, line, funcName = debug.info(2, "sln")
	local formattedSource = `{string.match(source, "@(.*)") or source}`
	local logHeader = `{prefix} [{funcName or formattedSource}:{line}]`

	if isWarning and isWarning == "warn" then
		warn(`{logHeader} {message}`)
	elseif config.Debug then
		print(`{logHeader} {message}`)
	end
end

--[[
    Executes a lifecycle method with retry logic wrapped ina  single Promise.
	This safely bypasses edge cases with nested Promise flattening by ensuring
	the resolve/reject state is only mutated once per module.
	@param methodName The Name of the lifecycle method being called (for logging).
	@param methodFunc The actual function to execute.
	@param attempts The number of remaining retry attempts.
	@return A Promise that resolves on success or rejects on total failure.
]]
local function retryWithPromise(methodName: string, methodFunc: () -> (), attempts: number): Promise<any>
	return Promise.new(function(resolve, reject)
		-- Internal function to handle the asynchronous execution loop
		local function executeAttempt(remainingAttempts: number)
			if remainingAttempts <= 0 then
				return reject(`Max retry attempts reached for {methodName}.`)
			end

			local success, result = pcall(methodFunc)

			if success then
				-- The lifecycle method suceeded! Pass the result forward.
				resolve(result)
				return
			end

			-- It failed. Check if we have remaining attempts.
			if remainingAttempts > 1 then
				log(`{methodName} lifecycle failed. Retrying in {config.RETRY_DELAY}s...\nError: {tostring(result)}`, "warn")

				-- Wait using Promise.delay, then recursively try again.
				Promise.delay(config.RETRY_DELAY):andThen(function()
					executeAttempt(remainingAttempts - 1)
				end)
			else
				-- Out of attempts. Fail the gate.
				reject(`Max retry attempts reached for {methodName}. Final Error: {tostring(result)}`)
			end
		end

		-- Start the first attempt
		executeAttempt(attempts)
	end)
end

--[[
	The main entry point for the module loader.
	Executes the Setup and Start lifecycle passes in concurrent, synchronized gates.
	This function handles its own asynchronous execution and emits a signal upon completion.
]]
function ModuleLoader.Init()
	log("Bootstrapping framework...")

	local discoveredModules = {}

	-- Gather and require all modules safely
	for _, moduleScript in moduleDirectory:GetDescendants() do
		if not moduleScript:IsA("ModuleScript") then
			continue
		end
		if moduleScript.Name == script.Name then
			continue
		end

		local success, module = pcall(require, moduleScript)

		if not success then
			log(`Failed to require '{moduleScript.Name}': {tostring(module)}`, "warn")
			continue
		end

		if typeof(module) == "table" then
			discoveredModules[moduleScript.Name] = module
		end
	end

	local setupPromises: { Promise.Promise<any> } = {}

	-- Gate 1: Setup Phase
	for name, module in discoveredModules do
		if typeof(module.Setup) ~= "function" then
			continue
		end

		local setupPromise = retryWithPromise(`{name}:Setup}`, module.Setup, config.ATTEMPT_LIMIT)
		table.insert(setupPromises, setupPromise)
	end

	-- Promise Setup gate, then proceed to Start gate internally.
	Promise.all(setupPromises)
		:andThen(function()
			log("Setup phase complete. Proceeding to Start phase.")

			local startPromises: { Promise.Promise<any> } = {}

			-- Gate 2: Start Phase
			for name, module in discoveredModules do
				if typeof(module.Start) ~= "function" then
					continue
				end

				-- Casting `module.Start` type to satisfy type solver.
				local startPromise = retryWithPromise(`{name}:Start`, module.Start :: () -> (), config.ATTEMPT_LIMIT)
				table.insert(startPromises, startPromise)
			end

			-- Evaluate Start promises independently to ensure clean error catching.
			Promise.all(startPromises)
			:andThen(function()
				log("All modules have been loaded and started.")
				ModuleLoader.GameReadySignal:Fire()
			end)
			:catch(function(err)
				log(`Critical framework boot failure (Start Phase): {tostring(err)}`, "warn")
			end)
		end)
		:catch(function(err)
			log(`Critical framework boot failure (Setup Phase): {tostring(err)}`, "warn")
		end)
end

return ModuleLoader
