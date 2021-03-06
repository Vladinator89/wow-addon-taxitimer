local addonName, ns = ...

local CatmulDistance = ns.CatmulDistance
local TaxiPathNode = ns.taxipathnode
local TaxiPath = ns.taxipath
local TaxiNodes = ns.taxinodes

local SHOW_EXTRA_DEBUG_INFO = true

local Speed
do
	local TAXI_SPEED_FALLBACK = 30+1/3
	local TAXI_SPEED_FASTER = 40+1/3

	local fallback = setmetatable({
		[1116] = TAXI_SPEED_FASTER, -- Draenor
		[1220] = TAXI_SPEED_FASTER, -- Broken Isles
		[1647] = TAXI_SPEED_FASTER, -- Shadowlands
	}, {
		__index = function()
			return TAXI_SPEED_FALLBACK
		end,
		__call = function(self, areaID, useLive, noSafety, info, gps)
			if useLive then
				local speed = GetUnitSpeed("player")
				if not noSafety then
					speed = math.max(speed, self[areaID])
				end
				return speed
			elseif areaID then
				return self[areaID]
			else
				return TAXI_SPEED_FALLBACK
			end
		end,
	})

	function Speed(areaID, useLive, noSafety, info, gps)
		return fallback(areaID, useLive == true, noSafety == true, info, gps)
	end
end

local Stopwatch
do
	Stopwatch = {
		Start = function(self, seconds, override)
			if not StopwatchFrame:IsShown() then
				Stopwatch_Toggle()
			end
			if override then
				Stopwatch_Clear()
			end
			if not Stopwatch_IsPlaying() then
				Stopwatch_StartCountdown(0, 0, seconds)
				Stopwatch_Play()
			end
		end,
		Stop = function(self)
			Stopwatch_Clear()
			StopwatchFrame:Hide()
		end,
		Get = function(self)
			return StopwatchTicker.timer
		end,
	}
end

local State
local Frames
do
	local NODE_EDGE_TRIM = 10 -- amount of points to be trimmed for more accurate blizzard like transitions between several taxi nodes
	local TAXI_MAX_SLEEP = 30 -- seconds before we give up waiting on the taxi to start (can happen if lag, or other conditions not being met as we click to fly somewhere)

	local TAXI_TIME_CORRECT = true -- if we wish to change the stopwatch time based on our movement and dynamic speed (if false, uses the original calculation and keeps the timer as-is during the flight)
	local TAXI_TIME_CORRECT_INTERVAL = 2 -- adjusts the timer X amount of times during flight to better calculate actual arrival time (some taxi paths slow down at start, or speed up eventually, this causes some seconds differences, this aims to counter that a bit)
	local TAXI_TIME_CORRECT_IGNORE = 5 -- amount of seconds we need to be wrong, before adjusting the timer

	local TAXI_TIME_CORRECT_MUTE_UPDATES = false -- mute the mid-flight updates
	local TAXI_TIME_CORRECT_MUTE_SUMMARY = false -- mute the end-of-flight summary

	local SHADOWLANDS_SPEED = Speed(1647)
	local SHADOWLANDS_WARP_SPEED = 200 -- estimation
	local SHADOWLANDS_ORIBOS_LIGHTSPEED_PADDING_DISTANCE = SHADOWLANDS_WARP_SPEED*40 -- estimation
	local SHADOWLANDS_ORIBOS_REVENDRETH_DISTANCE = SHADOWLANDS_SPEED*80 -- ?
	local SHADOWLANDS_ORIBOS_BASTION_DISTANCE = SHADOWLANDS_SPEED*75
	local SHADOWLANDS_ORIBOS_MALDRAXXUS_DISTANCE = SHADOWLANDS_SPEED*80 -- ?
	local SHADOWLANDS_ORIBOS_ARDENWEALD_DISTANCE = SHADOWLANDS_SPEED*80 -- ?

	local SHADOWLANDS_DISTANCE = {
		[7916] = SHADOWLANDS_ORIBOS_REVENDRETH_DISTANCE, -- Oribos > Revendreth, Pridefall Hamlet
		[7917] = SHADOWLANDS_ORIBOS_REVENDRETH_DISTANCE, -- Revendreth, Pridefall Hamlet > Oribos
		[8013] = SHADOWLANDS_ORIBOS_BASTION_DISTANCE, -- Oribos > Bastion, Aspirant's Rest
		[8012] = SHADOWLANDS_ORIBOS_BASTION_DISTANCE, -- Bastion, Aspirant's Rest > Oribos
		[8318] = SHADOWLANDS_ORIBOS_MALDRAXXUS_DISTANCE, -- Oribos > Maldraxxus, Theater of Pain
		[8319] = SHADOWLANDS_ORIBOS_MALDRAXXUS_DISTANCE, -- Maldraxxus, Theater of Pain > Oribos
		[8431] = SHADOWLANDS_ORIBOS_ARDENWEALD_DISTANCE, -- Oribos > Ardenweald, Tirna Vaal
		[8432] = SHADOWLANDS_ORIBOS_ARDENWEALD_DISTANCE, -- Ardenweald, Tirna Vaal > Oribos
	}

	local DISTANCE_ADJUSTMENT = function(pathId, nodes)
		for i = #nodes, 3, -1 do
			nodes[i] = nil
		end
		local d = SHADOWLANDS_DISTANCE[pathId] or 0
		nodes[1].x, nodes[1].y, nodes[1].z = 1, 1, 1
		nodes[2].x, nodes[2].y, nodes[2].z = d + 1, 1, 1
		return SHADOWLANDS_ORIBOS_LIGHTSPEED_PADDING_DISTANCE, SHADOWLANDS_WARP_SPEED
	end

	local PATH_ADJUSTMENT = {
		[7916] = DISTANCE_ADJUSTMENT,
		[8013] = DISTANCE_ADJUSTMENT,
		[8318] = DISTANCE_ADJUSTMENT,
		[8431] = DISTANCE_ADJUSTMENT,
		[7917] = DISTANCE_ADJUSTMENT,
		[8012] = DISTANCE_ADJUSTMENT,
		[8319] = DISTANCE_ADJUSTMENT,
		[8432] = DISTANCE_ADJUSTMENT,
	}

	local function GetTaxiPathNodes(pathId, trimEdges, whatEdge)
		local nodes = {}
		local exists = false

		for i = 1, #TaxiPathNode do
			local taxiPathChunk = TaxiPathNode[i]

			for j = 1, #taxiPathChunk do
				local taxiPathNode = taxiPathChunk[j]

				if taxiPathNode[ns.TAXIPATHNODE.PATHID] == pathId then
					exists = true

					table.insert(nodes, {taxiPathNode[ns.TAXIPATHNODE.ID], x = taxiPathNode[ns.TAXIPATHNODE.LOC_0], y = taxiPathNode[ns.TAXIPATHNODE.LOC_1], z = taxiPathNode[ns.TAXIPATHNODE.LOC_2], pathId = pathId})
				end
			end
		end

		if trimEdges and #nodes > trimEdges then
			if whatEdge == nil or whatEdge == 1 then
				for i = 1, trimEdges do
					table.remove(nodes, 1)
				end
			end

			if whatEdge == nil or whatEdge == 2 then
				for i = 1, trimEdges do
					table.remove(nodes, #nodes)
				end
			end
		end

		local paddingDistance, paddingSpeed
		if nodes[2] then
			local pathAdjustment = PATH_ADJUSTMENT[pathId]
			if pathAdjustment then
				paddingDistance, paddingSpeed = pathAdjustment(pathId, nodes)
			end
		end

		return exists, nodes[1] and nodes or nil, paddingDistance, paddingSpeed
	end

	local function GetTaxiPath(from, to, trimEdges, whatEdge)
		local pathId

		for i = 1, #TaxiPath do
			local taxiPathChunk = TaxiPath[i]

			for j = 1, #taxiPathChunk do
				local taxiPath = taxiPathChunk[j]
				local fromId, toId = taxiPath[ns.TAXIPATH.FROMTAXINODE], taxiPath[ns.TAXIPATH.TOTAXINODE]

				if fromId == from and toId == to then
					pathId = taxiPath[ns.TAXIPATH.ID]
					break
				end
			end

			if pathId then
				break
			end
		end

		if pathId then
			return GetTaxiPathNodes(pathId, trimEdges, whatEdge)
		end
	end

	local function GetPointsFromNodes(nodes)
		local points = {}
		local numNodes = #nodes
		local paddingDistance, paddingSpeed

		for i = 2, numNodes do
			local from, to = nodes[i - 1], nodes[i]
			local trimEdges, whatEdge = NODE_EDGE_TRIM

			if numNodes < 3 then
				trimEdges = nil -- pointless if there are no jumps between additional nodes
			end

			if i == 2 then
				whatEdge = 2 -- at the beginning we trim the right side points
			elseif i == numNodes then
				whatEdge = 1 -- at the end we trim the left side points
			end

			local exists, temp, padding, pspeed = GetTaxiPath(from.nodeID, to.nodeID, trimEdges, whatEdge)
			if exists and temp then
				for j = 1, #temp do
					table.insert(points, temp[j])
				end
				paddingDistance = padding
				paddingSpeed = pspeed
			end
		end

		return points, paddingDistance, paddingSpeed
	end

	local function GetTimeStringFromSeconds(timeAmount, asMs, dropZeroHours)
		local seconds = asMs and floor(timeAmount / 1000) or timeAmount
		local displayZeroHours = not (dropZeroHours and hours == 0)
		return SecondsToClock(seconds, displayZeroHours)
	end

	State = {
		areaID = 0,
		from = nil,
		to = nil,
		nodes = {},

		Update = function(self)
			self.areaID, self.from, self.to = GetTaxiMapID() or 0, nil
			table.wipe(self.nodes)

			if not self.areaID then
				return
			end

			local taxiNodes = C_TaxiMap.GetAllTaxiNodes(self.areaID)
			for i = 1, #taxiNodes do
				local taxiNode = taxiNodes[i]

				if taxiNode.state == Enum.FlightPathState.Current then
					self.from = taxiNode
				end

				self.nodes[taxiNode.slotIndex] = taxiNode
			end
		end,

		IsValidState = function(self)
			return self.areaID > 0 and self.from and next(self.nodes)
		end,

		UpdateButton = function(self, button)
			if not self:IsValidState() then
				self:Update()
			end

			if button.taxiNodeData then
				self.to = self.nodes[button.taxiNodeData.slotIndex]
			else
				self.to = self.nodes[button:GetID()]
			end

			if self.to and self.to.state == Enum.FlightPathState.Unreachable then
				self.to = nil
			end
		end,

		GetFlightInfo = function(self)
			if not self.from or not self.to or self.from == self.to then
				return
			end

			local nodes = {}

			local slotIndex = self.to.slotIndex
			local numRoutes = GetNumRoutes(slotIndex)

			for routeIndex = 1, numRoutes do
				local sourceSlotIndex = TaxiGetNodeSlot(slotIndex, routeIndex, true)
				local destinationSlotIndex = TaxiGetNodeSlot(slotIndex, routeIndex, false)

				local sourceNode = self.nodes[sourceSlotIndex]
				local destinationNode = self.nodes[destinationSlotIndex]

				if sourceNode and destinationNode then

					if not nodes[sourceNode] then
						nodes[sourceNode] = true

						table.insert(nodes, sourceNode)
					end

					if not nodes[destinationNode] then
						nodes[destinationNode] = true

						table.insert(nodes, destinationNode)
					end

				end
			end

			local points, paddingDistance, paddingSpeed = GetPointsFromNodes(nodes)
			if points and points[1] then
				local distance = CatmulDistance(points)

				if distance and distance > 0 then
					local info = {
						distance = distance,
						nodes = nodes,
						points = points,
						paddingDistance = paddingDistance,
						paddingSpeed = paddingSpeed,
					}
					info.speed = Speed(self.areaID, nil, nil, info)
					if paddingDistance then
						info.distance = info.distance + paddingDistance
					end
					if paddingSpeed then
						info.speed = (info.speed + paddingSpeed)/2
					end
					-- info.donotadjustarrivaltime = paddingDistance or paddingSpeed
					return info
				end
			end
		end,

		ButtonTooltip = function(self, button)
			local info = self:GetFlightInfo()

			if info then
				
				if SHOW_EXTRA_DEBUG_INFO then
					local pathIds = {}

					GameTooltip:AddLine(" ")
					for i = 1, #info.nodes do
						local node = info.nodes[i]
						local pathId = pathIds[i]
						GameTooltip:AddLine(i .. ". " .. node.name .. (pathId and " (" .. pathId .. ")" or ""), .8, .8, .8, false)
					end

					GameTooltip:AddLine(" ")
					GameTooltip:AddLine("Number of nodes: " .. #info.nodes, .8, .8, .8, false)
					GameTooltip:AddLine("Number of points: " .. #info.points, .8, .8, .8, false)
					GameTooltip:AddLine("Approx. speed: " .. info.speed, .8, .8, .8, false)
					GameTooltip:AddLine("Distance: ~ " .. info.distance .. " yards", .8, .8, .8, false)
				end

				GameTooltip:AddLine(" ")
				GameTooltip:AddLine("~ " .. GetTimeStringFromSeconds(info.distance / info.speed, false, true) .. " flight time", 1, 1, 1, false)

				GameTooltip:Show()
			end
		end,

		PlotCourse = function(self)
			local info = self:GetFlightInfo()

			if info then
				local gps, _ = {
					wasOnTaxi = false,
					waitingOnTaxi = GetTime(),
				}

				if self.gps then
					Stopwatch:Stop()
					self.gps:Cancel()
				end

				self.gps = C_Timer.NewTicker(.5, function()
					if not gps.distance then
						gps.distance = info.distance

						if TAXI_TIME_CORRECT and TAXI_TIME_CORRECT_INTERVAL and not info.donotadjustarrivaltime then
							gps.timeCorrection = { progress = info.distance, chunk = gps.distance * (1 / (TAXI_TIME_CORRECT_INTERVAL + 1)), adjustments = 0 }
						end
					end

					if UnitOnTaxi("player") then
						gps.wasOnTaxi = true
						gps.speed = Speed(self.areaID, true, nil, info, gps)
						gps.x, gps.y, _, gps.mapID = UnitPosition("player")

						if gps.lastSpeed then
							if gps.mapID and gps.lastMapID and gps.mapID ~= gps.lastMapID then
								gps.lastX = nil
							end

							if gps.lastX then
								gps.distance = gps.distance - math.sqrt((gps.lastX - gps.x)^2 + (gps.lastY - gps.y)^2)
								gps.distancePercent = gps.distance / info.distance

								if gps.distance > 0 and gps.speed > 0 then
									local timeCorrection = TAXI_TIME_CORRECT

									-- DEBUG: current progress
									-- DEFAULT_CHAT_FRAME:AddMessage(format("Flight progress |cffFFFFFF%d|r yd (%.1f%%)", gps.distance, gps.distancePercent * 100), 1, 1, 0)

									-- if time correction is enabled to correct in intervals we will do the logic here
									if gps.timeCorrection then
										timeCorrection = false

										-- make sure we are at a checkpoint before calculating the new time
										if gps.timeCorrection.progress > gps.distance then
											timeCorrection = true

											-- set next checkpoint, and calculate time difference
											gps.timeCorrection.progress = gps.timeCorrection.progress - gps.timeCorrection.chunk
											gps.timeCorrection.difference = math.floor(Stopwatch:Get() - (gps.distance / gps.speed))

											-- check if time difference is within acceptable boundaries
											if TAXI_TIME_CORRECT_IGNORE > 0 and math.abs(gps.timeCorrection.difference) < TAXI_TIME_CORRECT_IGNORE then
												timeCorrection = false

											elseif gps.stopwatchSet then
												gps.timeCorrection.adjustments = gps.timeCorrection.adjustments + gps.timeCorrection.difference

												-- announce the stopwatch time adjustments if significant enough to be noteworthy, and if we have more than just one interval (we then just summarize at the end)
												if not TAXI_TIME_CORRECT_MUTE_UPDATES and TAXI_TIME_CORRECT_INTERVAL > 1 then
													DEFAULT_CHAT_FRAME:AddMessage("Expected arrival time adjusted by |cffFFFFFF" .. math.abs(gps.timeCorrection.difference) .. " seconds|r.", 1, 1, 0)
												end
											end
										end
									end

									-- set or override the stopwatch based on time correction mode
									Stopwatch:Start(gps.distance / gps.speed, timeCorrection)

									-- stopwatch was set at least once
									gps.stopwatchSet = true
								end
							end
						end

						gps.lastSpeed = gps.speed
						gps.lastX, gps.lastY, gps.lastMapID = gps.x, gps.y, gps.mapID

					elseif not gps.wasOnTaxi then
						gps.wasOnTaxi = GetTime() - gps.waitingOnTaxi > TAXI_MAX_SLEEP

					elseif gps.wasOnTaxi then
						-- announce the time adjustments, if any
						if not TAXI_TIME_CORRECT_MUTE_SUMMARY and gps.timeCorrection then
							local absAdjustments = math.abs(gps.timeCorrection.adjustments)

							if absAdjustments > TAXI_TIME_CORRECT_IGNORE then
								DEFAULT_CHAT_FRAME:AddMessage("Your trip was |cffFFFFFF" .. absAdjustments .. " seconds|r " .. (gps.timeCorrection.adjustments < 0 and "longer" or "shorter") .. " than indicated.", 1, 1, 0)
							end
						end

						Stopwatch:Stop()
						self.gps:Cancel()
						table.wipe(gps)
						self:Arrived()
					end
				end)
			end
		end,

		OnEnter = function(button)
			State:UpdateButton(button)
			State:ButtonTooltip(button)
		end,

		OnClick = function(button)
			State:UpdateButton(button)
			State:PlotCourse()
		end,

		Arrived = function(self)
			PlaySound(34089, "Master", true)
			FlashClientIcon()
		end,
	}

	Frames = {
		FlightMapFrame = {
			OnLoad = function(manifest, frame)
				frame:HookScript("OnShow", function() State:Update() end)
				hooksecurefunc(FlightMap_FlightPointPinMixin, "OnMouseEnter", State.OnEnter)
				hooksecurefunc(FlightMap_FlightPointPinMixin, "OnClick", State.OnClick)
			end,
		},
		TaxiFrame = {
			OnLoad = function(manifest, frame)
				frame:HookScript("OnShow", function() State:Update() manifest:OnShow() end)
			end,
			OnShow = function(manifest)
				for i = 1, NumTaxiNodes(), 1 do
					local button = _G["TaxiButton" .. i]

					if button and not manifest[button] then
						manifest[button] = true

						button:HookScript("OnEnter", State.OnEnter)
						button:HookScript("OnClick", State.OnClick)
					end
				end
			end,
		},
	}
end

local addon = CreateFrame("Frame")
addon:SetScript("OnEvent", function(self, event, ...) self[event](self, event, ...) end)

function addon:ADDON_LOADED(event)
	local numLoaded, numTotal = 0, 0

	for name, manifest in pairs(Frames) do
		local frame = _G[name]

		if frame then
			if not manifest.loaded then
				manifest.loaded = true
				manifest:OnLoad(frame)
			end

			numLoaded = numLoaded + 1
		end

		numTotal = numTotal + 1
	end

	if numLoaded == numTotal then
		addon:UnregisterEvent(event)
	end
end

addon:RegisterEvent("ADDON_LOADED")
