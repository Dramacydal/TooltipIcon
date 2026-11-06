-- TooltipIcon
-- Spell icon inside the tooltip (top-left, no border). The header lines
-- (name/rank, cost/range, cast time/cooldown) are shifted right of the icon
-- with a transparent inline texture; the description stays below the icon.

local ADDON, ns = ...

local SPACER = "Interface\\AddOns\\" .. ADDON .. "\\blank.tga"
local TOOLTIP_PADDING = 20 -- left + right inner margin of a tooltip
local WHITE = 0.9 -- minimum color component of a header line
local LINE_SPACING = 2 -- estimate for the first, uncached layout
local MAX_SIZE = 64
local MIN_ICON_SIZE = 16 -- lowest value of the minimum icon size
local MAX_GAP = 16 -- highest gap between the icon and the text
local FACTION_ICON_SIZE = 16 -- faction crest inside a text line
local CLASS_ICON_SIZE = 14 -- class icon inside a text line
local INLINE_ICON_OFFSET = -2 -- their horizontal shift (the texture margins make them look indented)
local MAX_FIT_PASSES = 2 -- width corrections per tooltip build
local PAD_DESCENT = 4 -- measured: a line is 4 px taller than its pad texture
local MAX_PASSES = 3 -- layout correction passes per uncached header line count
local CROP = 0.07 -- trims the built-in dark border of spell icons (unless "Show the icon border" is on)

local defaults = { size = 32, gap = 6, unitClassMode = 2 } -- 2: class and faction icon on the level line
local db

local GetSpellTexture = C_Spell and C_Spell.GetSpellTexture or GetSpellTexture
local GetItemIcon = C_Item and C_Item.GetItemIconByID or GetItemIcon
local issecret = issecretvalue or function() return false end

-- Measurements (widths, heights) can be secret numbers while tainted code reads tooltip lines
-- (e.g. action bar tooltips): arithmetic on them is an error. Returns nil for secret values.
local function Plain(value)
	if value == nil or issecret(value) then
		return nil
	end
	return value
end

local debugMode = false

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffff8000TooltipIcon:|r " .. msg, .9, .9, .9)
end

local missing = {} -- names of game constants this client doesn't have, shown by `/tti debug`
local kinds = {} -- tooltip kinds, filled in below
local states = {} -- [tooltip] = { icon, orig, count, size, pending }
local pending = {}
local HookProcessInfo -- hooks ProcessInfo of the tooltips again (defined below, needs the data handlers)
local MAX_REHOOKS = 5 -- how many times the hooks are moved behind a later hooker of ProcessInfo
local REHOOK_DELAY = 1 -- seconds between noticing a rewritten header and hooking again
local rehooks, rehookScheduled, rehookGaveUp = 0, false, false

--------------------------------------------------------------------------------
-- LAYOUT
--------------------------------------------------------------------------------

local function Line(tooltip, side, i)
	return _G[tooltip:GetName() .. side .. i]
end

-- The line of the tooltip data that was added as line `i` of the tooltip. The data may hold lines that were
-- not added (empty ones: line 2 of "Will of the Forsaken" is empty in the data and absent on the screen
-- outside of combat), so its index is not the index of the line on the screen: lineIndex is.
local function DataLine(tooltipData, i)
	local lines = tooltipData and tooltipData.lines
	if type(lines) ~= "table" then
		return nil
	end
	local info = lines[i]
	if info and info.lineIndex == i then
		return info
	end
	local processed = false
	for _, line in ipairs(lines) do
		if line.lineIndex == i then
			return line
		end
		processed = processed or line.lineIndex ~= nil
	end
	-- data the handler did not number: the same index; otherwise the line is not from the data (added by an addon)
	return not processed and info or nil
end

local function Clamp(size)
	return math.min(size, MAX_SIZE)
end

local function EstimateBlockHeight(tooltip, count)
	local height = 0
	for i = 1, count do
		local left, right = Line(tooltip, "TextLeft", i), Line(tooltip, "TextRight", i)
		local h = Plain(left:GetStringHeight()) or 0
		if right:IsShown() then
			h = math.max(h, Plain(right:GetStringHeight()) or 0)
		end
		height = height + h
	end
	return height + LINE_SPACING * (count - 1)
end

local function MeasureBlockHeight(tooltip, count)
	local top = Line(tooltip, "TextLeft", 1):GetTop()
	local bottom = Line(tooltip, "TextLeft", count):GetBottom()
	if top and bottom and not issecret(top) and not issecret(bottom) then
		return top - bottom
	end
end

-- Pad height needed for the header block (natural height) to reach the icon size.
-- The pad texture sets the height of the whole last line, so the line's own height is added.
-- Pad height needed for the header block (natural height) to reach the icon size.
-- The pad texture sets the height of the whole last header line, so the line's own height is added.
-- `bodyGap` of a kind: free pixels between the header block and the body text, below the icon.
-- Only when some text follows the header (removed lines stay in the tooltip as empty ones).
local function BodyGap(tooltip, kind, count)
	local gap = kinds[kind].bodyGap
	if not gap then
		return 0
	end
	for i = count + 1, tooltip:NumLines() do
		local text = Line(tooltip, "TextLeft", i):GetText()
		local right = Line(tooltip, "TextRight", i)
		local rightText = right:IsShown() and right:GetText()
		if issecret(text) or issecret(rightText) or (text and text ~= "") or (rightText and rightText ~= "") then
			return gap
		end
	end
	return 0
end

local function InitialPad(tooltip, kind, count, size, natural)
	local gap = BodyGap(tooltip, kind, count)
	-- a line with a pad texture is taller than the texture by the space under the letters; kinds with a
	-- body gap have their gap tuned by hand and keep the old formula
	local descent = kinds[kind].bodyGap and 0 or PAD_DESCENT
	return math.ceil(size - natural + gap - descent + (Plain(Line(tooltip, "TextLeft", count):GetStringHeight()) or 0))
end

-- The tooltip is rebuilt every 0.2s. Layout values are measured once per header line count and cached
-- separately for every tooltip kind (memory only, per session), otherwise the estimate -> measure
-- correction would make the tooltip jump on every rebuild.
local layoutCache = {} -- [kind][header line count] = { size, natural, padH }

local function KindCache(kind)
	local cache = layoutCache[kind]
	if not cache then
		cache = {}
		layoutCache[kind] = cache
	end
	return cache
end

local function GetCache(kind, count)
	local cache = KindCache(kind)[count]
	if cache and cache.size == db.size then
		return cache
	end
end

-- Height of a header of kinds[kind].minLines lines: the icon of a kind is never smaller than that
-- (the measured height when a header of that length was seen, an estimate from the first two lines otherwise).
local function MinBlockHeight(tooltip, kind)
	local lines = kinds[kind].minLines
	if not lines or (kinds[kind].nameOnlyKey and db[kinds[kind].nameOnlyKey]) then
		return 0
	end
	local cache = GetCache(kind, lines)
	if cache then
		return cache.natural
	end
	local first = Plain(Line(tooltip, "TextLeft", 1):GetStringHeight()) or 0
	-- the height of a plain line from its font: inline icons make a line taller than the lines of other tooltips
	local _, fontSize = Line(tooltip, "TextLeft", 2):GetFont()
	local second = Plain(fontSize) and fontSize + 1 or first
	return first + (lines - 1) * (second + LINE_SPACING)
end

-- icon size for a header block of the given natural height
local function TargetSize(tooltip, kind, natural)
	return Clamp(math.max(natural, db.size, MinBlockHeight(tooltip, kind)))
end

-- returns size, padHeight, natural block height, isCached
local function Plan(tooltip, kind, count)
	local cache = GetCache(kind, count)
	local natural = cache and cache.natural or EstimateBlockHeight(tooltip, count)
	local size = TargetSize(tooltip, kind, natural)
	local padH = 0
	if size - natural + BodyGap(tooltip, kind, count) > 0.5 then
		-- a kind with a body gap computes its pad every time: the gap depends on the lines that follow
		padH = (cache and not kinds[kind].bodyGap and cache.padH) or InitialPad(tooltip, kind, count, size, natural)
	end
	return size, padH, natural, cache ~= nil
end

-- Inline texture width is not rendered 1:1 in every line font (the header font is larger),
-- so the spacer is calibrated against the width the line actually reports.
local function WidthSpacer(line, target)
	local spacer = ("|T%s:1:%.1f|t"):format(SPACER, target)
	line:SetText(spacer)
	local rendered = line:GetStringWidth()
	if rendered and not issecret(rendered) and rendered > 0 and math.abs(rendered - target) > 0.5 then
		spacer = ("|T%s:1:%.1f|t"):format(SPACER, target * target / rendered)
	end
	return spacer
end

-- Header lines must not wrap or truncate: the spacer makes them longer than the width the engine
-- gave them for the original text. Every tooltip line has word wrap enabled by default.
-- on: no wrap, automatic width. off: back to the original width and wrapping.
local function SetHeaderFlow(tooltip, st, on)
	-- undo only what this addon changed on the tooltip (once); otherwise stale values of an earlier
	-- tooltip would be written into lines the addon doesn't touch
	if not on and not st.flow then
		return
	end
	st.flow = on
	for i = 1, st.count or 0 do
		local line = Line(tooltip, "TextLeft", i)
		line:SetWordWrap(not on)
		line:SetWidth(on and 0 or st.origWidth[i] or 0)
	end
	if not on and st.origJustifyV then
		Line(tooltip, "TextLeft", st.count):SetJustifyV(st.origJustifyV)
		Line(tooltip, "TextRight", st.count):SetJustifyV(st.origRightJustifyV)
	end
end

-- The engine sizes the tooltip and the lines for the original text; the spacer makes the left text of the
-- header lines longer, so they can run into their right text, past the right edge or get cut off.
-- SetMinimumWidth can't be used: with a minimum width the engine stops wrapping the body text at the
-- default width and stretches the tooltip to its longest line. The right padding widens only the frame.
-- Returns true when the tooltip was widened (the layout has to be measured again).
local function FitHeader(tooltip, st)
	local needed = 0
	for i = 1, st.count do
		local left, right = Line(tooltip, "TextLeft", i), Line(tooltip, "TextRight", i)
		local leftWidth = left:GetStringWidth()
		if not leftWidth or issecret(leftWidth) then
			return false
		end
		local lineNeeded = leftWidth + TOOLTIP_PADDING
		if right:IsShown() and (right:GetText() or "") ~= "" then
			lineNeeded = lineNeeded + (Plain(right:GetStringWidth()) or 0) + TOOLTIP_PADDING -- the second padding is the gap between the texts
		end
		needed = math.max(needed, lineNeeded)
	end

	local width = Plain(tooltip:GetWidth())
	if not width then
		return false
	end
	if needed > width + 1 and st.fitPasses < MAX_FIT_PASSES then
		local right, bottom, left, top = tooltip:GetPadding()
		if issecret(right) then
			return false
		end
		local extra = math.ceil(needed - width)
		st.fitPasses = st.fitPasses + 1
		st.paddingAdded = (st.paddingAdded or 0) + extra
		tooltip:SetPadding(right + extra, bottom, left, top)
		if debugMode then
			Print(("header needs %d, tooltip %d: right padding +%d"):format(needed, width, extra))
		end
		return true
	end

	-- the engine gives a line the width of the original text: let the longer header lines use their own width
	for i = 1, st.count do
		local line = Line(tooltip, "TextLeft", i)
		local lineWidth, textWidth = Plain(line:GetWidth()), Plain(line:GetStringWidth())
		if lineWidth and textWidth and lineWidth + 1 < textWidth then
			line:SetWidth(math.ceil(textWidth) + 1)
			if debugMode then
				Print(("line %d width %.1f -> %d"):format(i, lineWidth, math.ceil(textWidth) + 1))
			end
		end
	end
	return false
end

-- Prefixes the header lines with a transparent spacer as wide as the icon.
-- The last header line also gets a tall spacer when the icon is higher than the header block.
local function ApplyLayout(tooltip, st, size, padH)
	local padSpacer = padH > 0 and ("|T%s:%d:1|t"):format(SPACER, padH) or ""

	st.applied = {}
	for i = 1, st.count do
		local line = Line(tooltip, "TextLeft", i)
		local widthSpacer = WidthSpacer(line, size + db.gap)
		local text = widthSpacer .. (i == st.count and padSpacer or "") .. st.orig[i]
		line:SetText(text)
		st.applied[i] = text
	end
	-- the text of a taller line is centered; some kinds keep it at the top (the space goes below the header)
	-- (both columns of the line: the right text would otherwise sink to the bottom of the taller line)
	if kinds[st.kind].padTop then
		Line(tooltip, "TextLeft", st.count):SetJustifyV(padH > 0 and "TOP" or st.origJustifyV)
		Line(tooltip, "TextRight", st.count):SetJustifyV(padH > 0 and "TOP" or st.origRightJustifyV)
		-- the right text is centered on the line: it needs the same height to stand at the top as well
		if st.origRightText then
			Line(tooltip, "TextRight", st.count):SetText(padSpacer .. st.origRightText)
		end
	end

	if debugMode then
		Print(("layout %s: header=%d size=%.1f pad=%d numlines=%d"):format(
			st.kind, st.count, size, padH, tooltip:NumLines()))
	end
	SetHeaderFlow(tooltip, st, true)

	st.size, st.padH = size, padH
	st.icon:SetSize(size, size)
	st.icon:Show()
	tooltip:Show() -- relayout
end

-- Complete state (text, colors, right text) of a tooltip line, used to reorder lines.
local function GetLineState(tooltip, i)
	local left, right = Line(tooltip, "TextLeft", i), Line(tooltip, "TextRight", i)
	local text, rightText = left:GetText(), right:GetText()
	local r, g, b = left:GetTextColor()
	local rr, rg, rb = right:GetTextColor()
	if issecret(text) or issecret(rightText) or issecret(r) or issecret(rr) then
		return
	end
	return { text = text, r = r, g = g, b = b, rightText = rightText, rr = rr, rg = rg, rb = rb, rightShown = right:IsShown() }
end

local function SetLineState(tooltip, i, state)
	local left, right = Line(tooltip, "TextLeft", i), Line(tooltip, "TextRight", i)
	left:SetText(state.text)
	left:SetTextColor(state.r, state.g, state.b)
	right:SetText(state.rightText)
	right:SetTextColor(state.rr, state.rg, state.rb)
	right:SetShown(state.rightShown)
end

-- Moves line `from` up to position `to`, the lines in between shift down by one.
-- Returns the original states (to restore them) or nil when a line can't be read.
local function MoveLine(tooltip, from, to)
	local saved = {}
	for i = to, from do
		saved[i] = GetLineState(tooltip, i)
		if not saved[i] then
			return
		end
	end
	SetLineState(tooltip, to, saved[from])
	for i = to + 1, from do
		SetLineState(tooltip, i, saved[i - 1])
	end
	return { from = from, to = to, states = saved }
end

local function Restore(tooltip, st)
	if st.active then
		for i = 1, st.count do
			Line(tooltip, "TextLeft", i):SetText(st.orig[i])
		end
		if st.origRightText then
			Line(tooltip, "TextRight", st.count):SetText(st.origRightText)
		end
		SetHeaderFlow(tooltip, st, false)
		st.active = nil
	end
	if st.moved then
		for i = st.moved.to, st.moved.from do
			SetLineState(tooltip, i, st.moved.states[i])
		end
		st.moved = nil
	end
	st.icon:Hide()
end

-- Compares the layout with the real one (only available a frame later) and adjusts it.
-- Returns true when the layout is final and has been cached.
local function Correct(tooltip, st)
	local measured = MeasureBlockHeight(tooltip, st.count)
	if not measured or measured < 8 or measured > 200 then
		return true
	end
	st.pass = st.pass + 1
	if debugMode then
		Print(("measure %s: header=%d measured=%.1f pass=%d"):format(st.kind, st.count, measured, st.pass))
	end
	local natural = st.natural
	local size, padH = st.size, st.padH

	if padH == 0 then
		natural = measured
		size = TargetSize(tooltip, st.kind, natural)
		if size - natural + BodyGap(tooltip, st.kind, st.count) > 0.5 then
			padH = InitialPad(tooltip, st.kind, st.count, size, natural)
		end
		st.natural = natural
		if st.pass < MAX_PASSES and (padH > 0 or math.abs(size - st.size) > 1) then
			ApplyLayout(tooltip, st, size, padH)
			return false
		end
	elseif st.pass < MAX_PASSES and math.abs(measured - (size + BodyGap(tooltip, st.kind, st.count))) > 1 then
		ApplyLayout(tooltip, st, size, math.max(1, padH + math.floor(size + BodyGap(tooltip, st.kind, st.count) - measured + 0.5)))
		return false
	end

	KindCache(st.kind)[st.count] = { size = db.size, natural = natural, padH = st.padH }
	return true
end

-- The header lines hold the text we wrote last (st.applied). When one of them differs, some other addon has
-- rewritten it after us: it hooks ProcessInfo behind our hook. Hooks can't be removed, but a new hook
-- stands behind every earlier one, and the older hooks of ours are switched off (see HookProcessInfo).
local function HeaderOverwritten(tooltip, st)
	for i = 1, st.count do
		local text = Line(tooltip, "TextLeft", i):GetText()
		if not issecret(text) and text ~= st.applied[i] then
			return true
		end
	end
	return false
end

local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(self)
	self:Hide()
	local list = {}
	for tooltip in pairs(pending) do
		list[#list + 1] = tooltip
	end
	wipe(pending)
	for _, tooltip in ipairs(list) do
		local st = states[tooltip]
		if st and st.active and tooltip:IsShown() then
			local overwritten = HeaderOverwritten(tooltip, st)
			if debugMode then
				local text = Line(tooltip, "TextLeft", 1):GetText()
				Print(("header check %s: %s, line 1 = %s"):format(st.kind, overwritten and "OVERWRITTEN" or "intact",
					issecret(text) and "<secret>" or (tostring(text):gsub("|", "||"))))
			end
			if overwritten then
				if rehooks < MAX_REHOOKS and not rehookScheduled then
					rehookScheduled = true
					rehooks = rehooks + 1
					if debugMode then
						Print(("header lines were rewritten after us: hooking ProcessInfo again in %d s (%d)"):format(
							REHOOK_DELAY, rehooks))
					end
					C_Timer.After(REHOOK_DELAY, function()
						rehookScheduled = false
						HookProcessInfo()
					end)
				elseif rehooks >= MAX_REHOOKS and not rehookScheduled and not rehookGaveUp then
					-- the last hook was rewritten as well: another addon keeps changing the lines after us
					rehookGaveUp = true
					Print(TTI_MSG_OVERWRITTEN)
				end
			elseif FitHeader(tooltip, st) or (not st.cached and not Correct(tooltip, st)) then
				pending[tooltip] = true
				self:Show()
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- HOOKS
--------------------------------------------------------------------------------

-- Tooltip kinds. Every kind has its own header detection and its own layout cache (layoutCache[kind]),
-- so tuning one kind can't break another.
--   maxHeader: maximum number of lines shown next to the icon
--   isDescription(tooltip, tooltipData, i): true when line i (>= 2) already belongs to the body

-- Spell header lines (cost, cast time, "Passive", ...) are white, the description is yellow,
-- warnings ("Requires ...") are red. Word wrap and text length don't separate them.
-- A white line with color codes or line breaks inside ("Reagents: <red names>") is a long, wrapping
-- text, not a header field.
local function IsColoredLine(tooltip, i)
	local line = Line(tooltip, "TextLeft", i)
	local text = line:GetText()
	if text and not issecret(text) and (text:find("|c", 1, true) or text:find("|n", 1, true) or text:find("\n", 1, true)) then
		return true
	end
	local r, g, b = line:GetTextColor()
	if not r or issecret(r) or issecret(g) or issecret(b) then
		return false
	end
	return r < WHITE or g < WHITE or b < WHITE
end

-- The rank line of a talent ("Rank 0/5") is a header line wherever it comes from; the format has no
-- constant of its own that is known in this client, so it is recognised by its shape: text, number/number.
local function IsTalentRankLine(tooltip, i)
	local text = Line(tooltip, "TextLeft", i):GetText()
	if not text or issecret(text) then
		return false
	end
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") -- color codes may wrap the text
	return text:find("^%s*%D+%s%d+/%d+%s*$") ~= nil
end

-- Talent tooltip of the ClassicUIForever talent window: only the name and the rank line are the header
-- (it follows the "Spells" category of the settings).
kinds.talent = {
	maxHeader = 2,
	category = "spell",
	nameOnlyKey = "spellNameOnly",
	isDescription = function(tooltip, _, i)
		return not IsTalentRankLine(tooltip, i)
	end,
}

kinds.spell = {
	maxHeader = 3,
	nameOnlyKey = "spellNameOnly",
	isDescription = function(tooltip, tooltipData, i)
		if IsTalentRankLine(tooltip, i) then
			return false
		end
		-- the header of a talent ends with its rank line
		if i > 2 and IsTalentRankLine(tooltip, i - 1) then
			return true
		end
		local info = DataLine(tooltipData, i)
		if info and info.type == Enum.TooltipDataLineType.SpellDescription then
			return true
		end
		return IsColoredLine(tooltip, i)
	end,
}

-- Companion pet: name, then white lines ("Instant", cast time) like a spell; the description is yellow.
kinds.companion = {
	maxHeader = 3,
	nameOnlyKey = "companionNameOnly",
	isDescription = function(tooltip, tooltipData, i)
		local info = DataLine(tooltipData, i)
		if info and info.type == Enum.TooltipDataLineType.SpellDescription then
			return true
		end
		return IsColoredLine(tooltip, i)
	end,
}

-- Mount: name, then white lines (cast time) like a spell; the description is yellow, requirements are red.
kinds.mount = {
	maxHeader = 3,
	nameOnlyKey = "mountNameOnly",
	isDescription = function(tooltip, tooltipData, i)
		local info = DataLine(tooltipData, i)
		if info and info.type == Enum.TooltipDataLineType.SpellDescription then
			return true
		end
		return IsColoredLine(tooltip, i)
	end,
}

-- Transmog appearance: only the item name sits next to the icon; the rest is gray hint text.
kinds.transmog = {
	maxHeader = 1,
	isDescription = function() return true end,
}

-- Only the aura name sits next to the icon for now; see `/tti debug` for the line layout of auras.
kinds.aura = {
	maxHeader = 1,
	isDescription = function() return true end,
}

-- Item header: name, then the property lines (binding, item level, slot, "Unique", "Conjured Item", ...).
-- Lines are recognised by the tooltip line type or, for untyped lines, by the game's own localized
-- strings, so the detection doesn't depend on the client language.
local itemHeaderTypes = {}
for _, name in ipairs({ "ItemName", "ItemQuality", "ItemLevel", "ItemUpgradeLevel", "ItemBinding", "EquipSlot" }) do
	local lineType = Enum.TooltipDataLineType[name]
	if lineType then
		itemHeaderTypes[lineType] = true
	else
		missing[#missing + 1] = "Enum.TooltipDataLineType." .. name
	end
end

-- format string -> pattern: escape magic characters, %d / %s become wildcards
local function BuildPatterns(names)
	local patterns = {}
	for _, name in ipairs(names) do
		local text = _G[name]
		if type(text) == "string" then
			local pattern = text:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0"):gsub("%%d", "%%d+"):gsub("%%s", ".+")
			patterns[#patterns + 1] = "^" .. pattern .. "$"
		else
			missing[#missing + 1] = name
		end
	end
	return patterns
end

local function MatchesAny(text, patterns)
	if not text or issecret(text) then
		return false
	end
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	for _, pattern in ipairs(patterns) do
		if text:find(pattern) then
			return true
		end
	end
	return false
end

-- Lines moved into the header when they are found below it.
-- "Crafting Reagent" has the same text under several names in this client.
local itemPromotedPatterns = BuildPatterns({
	"PROFESSIONS_USED_IN_COOKING", "PROFESSIONS_MODIFIED_CRAFTING_REAGENT_BASIC", "ITEM_COSMETIC", "TOY",
})

local itemHeaderPatterns = BuildPatterns({
	"ITEM_UNIQUE", "ITEM_UNIQUE_MULTIPLE", "ITEM_UNIQUE_EQUIPPABLE", "ITEM_CONJURED",
	"ITEM_SOULBOUND", "ITEM_BIND_ON_PICKUP", "ITEM_BIND_ON_EQUIP", "ITEM_BIND_ON_USE",
	"ITEM_BIND_TO_ACCOUNT", "ITEM_BIND_TO_BNETACCOUNT", "ITEM_ACCOUNTBOUND", "ITEM_BNETACCOUNTBOUND", "ITEM_BIND_QUEST",
	"CONTAINER_SLOTS", -- "6 Slot Bag"
})
for _, pattern in ipairs(itemPromotedPatterns) do
	itemHeaderPatterns[#itemHeaderPatterns + 1] = pattern
end

kinds.item = {
	maxHeader = 4,
	nameOnlyKey = "itemNameOnly",
	isDescription = function(tooltip, tooltipData, i)
		local info = DataLine(tooltipData, i)
		if info and itemHeaderTypes[info.type] then
			return false
		end
		return not MatchesAny(Line(tooltip, "TextLeft", i):GetText(), itemHeaderPatterns)
	end,
	-- a promoted line ("Crafting Reagent", "Cosmetic") below the header is moved to the end of the header
	isPromoted = function(text)
		return MatchesAny(text, itemPromotedPatterns)
	end,
}

-- Toy header: name, binding and the "Toy" line; see `/tti debug` for the line types of a toy tooltip.
local toyHeaderTypes = {}
for _, name in ipairs({ "ToyName", "ItemBinding" }) do
	local lineType = Enum.TooltipDataLineType[name]
	if lineType then
		toyHeaderTypes[lineType] = true
	else
		missing[#missing + 1] = "Enum.TooltipDataLineType." .. name
	end
end

-- Lines moved into the header when they are found below it.
local toyPromotedPatterns = BuildPatterns({ "TOY" })

kinds.toy = {
	maxHeader = 3,
	nameOnlyKey = "toyNameOnly",
	isDescription = function(tooltip, tooltipData, i)
		local info = DataLine(tooltipData, i)
		if info and toyHeaderTypes[info.type] then
			return false
		end
		return not MatchesAny(Line(tooltip, "TextLeft", i):GetText(), toyPromotedPatterns)
	end,
	isPromoted = function(text)
		return MatchesAny(text, toyPromotedPatterns)
	end,
}

-- Unit: the header ends with the level line ("Level 12 Human Warrior"), followed by the creature type line
-- of an NPC ("Humanoid") or the dead status ("Corpse"); a guild or title line before the level line belongs
-- to the header. Without a level line within the first lines only the name is in the header.
-- Unit lines carry no line type in this client (type=0), so they are recognised by their text only.
local unitLevelPatterns = BuildPatterns({
	"TOOLTIP_UNIT_LEVEL", "TOOLTIP_UNIT_LEVEL_TYPE", "TOOLTIP_UNIT_LEVEL_RACE", "TOOLTIP_UNIT_LEVEL_RACE_TYPE",
	"UNIT_LEVEL_TEMPLATE", "UNIT_TYPE_LEVEL_TEMPLATE", "UNIT_PLUS_LEVEL_TEMPLATE", "UNIT_TYPE_PLUS_LEVEL_TEMPLATE",
	"UNIT_LEVEL_DEAD_TEMPLATE", "UNIT_TYPE_LEVEL_FACTION_TEMPLATE",
	"TOOLTIP_WILDBATTLEPET_LEVEL_CLASS", "TOOLTIP_WILDBATTLEPET_LEVEL",
})
local unitDeadPatterns = BuildPatterns({ "CORPSE", "DEAD" })

-- the line is the creature type of the unit: text equal to UnitCreatureType(unit) or the dead status text
local function IsCreatureTypeLine(tooltip, i)
	local text = Line(tooltip, "TextLeft", i):GetText()
	if MatchesAny(text, unitDeadPatterns) then
		return true
	end
	local unit = TooltipUtil and TooltipUtil.GetDisplayedUnit and select(2, TooltipUtil.GetDisplayedUnit(tooltip))
	if not unit or issecret(unit) then
		return false
	end
	local creatureType = UnitCreatureType(unit)
	return creatureType ~= nil and text ~= nil and not issecret(creatureType) and not issecret(text) and text == creatureType
end

-- The level line: a "Level ..." text from the game's templates, or any line that holds the level of the unit
-- and its creature type ("Pet Level 1 Critter" of a pet, which has no template of its own).
local function IsUnitLevelLine(tooltip, i)
	local text = Line(tooltip, "TextLeft", i):GetText()
	if not text or issecret(text) then
		return false
	end
	if MatchesAny(text, unitLevelPatterns) then
		return true
	end
	local unit = TooltipUtil and TooltipUtil.GetDisplayedUnit and select(2, TooltipUtil.GetDisplayedUnit(tooltip))
	if not unit or issecret(unit) or not UnitExists(unit) then
		return false
	end
	local level, creatureType = UnitLevel(unit), UnitCreatureType(unit)
	if not level or level < 1 or not creatureType or issecret(level) or issecret(creatureType) then
		return false
	end
	return text:find("%f[%d]" .. level .. "%f[%D]") ~= nil and text:find(creatureType, 1, true) ~= nil
end

-- Player class / faction handling (setting db.unitClassMode, see ns.unitClassModes):
-- 1 the faction moves to the right column of the class line,
-- 2 the class line and the faction line are removed, a faction crest and a class icon are put before the level line.
-- The lines that follow the header are shifted up; the last line is left blank.
local BLANK_LINE = { text = "", r = 1, g = 1, b = 1, rightText = "", rr = 1, rg = 1, rb = 1, rightShown = false }

local function ClassIconMarkup(classFile, size, offsetX)
	local atlas = "classicon-" .. classFile:lower()
	if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
		return CreateAtlasMarkup(atlas, size, size, offsetX, 0) .. " "
	end
	local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]
	if coords and CreateTextureMarkup then
		return CreateTextureMarkup("Interface/GLUES/CHARACTERCREATE/UI-CHARACTERCREATE-CLASSES", 256, 256, size, size,
			coords[1], coords[2], coords[3], coords[4], offsetX, 0) .. " "
	end
end

-- Saves the state of all lines (restored by Restore). Returns false when a line can't be read.
local function SnapshotLines(tooltip, st)
	local numLines = tooltip:NumLines()
	local states = {}
	for i = 1, numLines do
		states[i] = GetLineState(tooltip, i)
		if not states[i] then
			return false
		end
	end
	st.moved = { from = numLines, to = 1, states = states }
	return true
end

-- Removes `removed` lines starting at `index`: the following lines shift up, the last lines are left blank.
-- The lines are read as they are now, so several removals can follow each other.
local function DropLines(tooltip, index, numLines, removed)
	for i = index, numLines - removed do
		SetLineState(tooltip, i, GetLineState(tooltip, i + removed))
	end
	for i = numLines - removed + 1, numLines do
		SetLineState(tooltip, i, BLANK_LINE)
	end
end

-- Faction crest for the Horde and the Alliance (nothing for neutral players).
local FACTION_ICON_FILES = {
	Horde = "Interface/TargetingFrame/UI-PVP-Horde",
	Alliance = "Interface/TargetingFrame/UI-PVP-Alliance",
}

local function FactionIconMarkup(factionGroup, size, offsetX)
	local file = FACTION_ICON_FILES[factionGroup]
	if file and CreateTextureMarkup then
		return CreateTextureMarkup(file, 64, 64, size, size, 0, 0.59375, 0, 0.59375, offsetX, 0) .. " "
	end
end

local function EditPlayerLines(tooltip, count)
	local mode = db.unitClassMode
	local unit = TooltipUtil and TooltipUtil.GetDisplayedUnit and select(2, TooltipUtil.GetDisplayedUnit(tooltip))
	if not unit or issecret(unit) or not UnitExists(unit) or not UnitIsPlayer(unit) then
		return
	end
	local className, classFile = UnitClass(unit)
	local classIndex = count + 1 -- the class line follows the level line
	local numLines = tooltip:NumLines()
	if not className or not classFile or issecret(className) or issecret(classFile) or classIndex > numLines then
		return
	end
	local classText = Line(tooltip, "TextLeft", classIndex):GetText()
	if issecret(classText) or classText ~= className then
		return
	end

	-- the faction line follows the class line
	local factionGroup, factionName = UnitFactionGroup(unit)
	local factionIndex = classIndex + 1
	local hasFactionLine = false
	if factionName and not issecret(factionName) and factionIndex <= numLines then
		local factionText = Line(tooltip, "TextLeft", factionIndex):GetText()
		hasFactionLine = not issecret(factionText) and factionText == factionName
	end

	if mode == 1 then
		if not hasFactionLine then
			return
		end
		local faction, right = GetLineState(tooltip, factionIndex), Line(tooltip, "TextRight", classIndex)
		right:SetText(faction.text)
		right:SetTextColor(faction.r, faction.g, faction.b)
		right:Show()
		DropLines(tooltip, factionIndex, numLines, 1)
		return
	end

	-- mode 2: the class line is removed; a faction crest and a class icon go to the start of the level line and
	-- the faction line is removed too (only when there is a crest to show instead)
	local classMarkup = ClassIconMarkup(classFile, CLASS_ICON_SIZE, INLINE_ICON_OFFSET)
	if not classMarkup then
		return
	end
	local factionMarkup = hasFactionLine and factionGroup and not issecret(factionGroup)
		and FactionIconMarkup(factionGroup, FACTION_ICON_SIZE, INLINE_ICON_OFFSET)

	local level = Line(tooltip, "TextLeft", count)
	level:SetText((factionMarkup or "") .. classMarkup .. level:GetText())
	DropLines(tooltip, classIndex, numLines, factionMarkup and 2 or 1)
end

-- NPC: the faction line ("Undercity") that is followed by the "PvP" line joins the header, "PvP" moves to its
-- right column and its own line is removed. Returns the new header line count.
local pvpPatterns = BuildPatterns({ "PVP_ENABLED" })

-- A "Skinnable" line below the header moves to the right column of the last header line ("Corpse").
local skinnablePatterns = BuildPatterns({ "UNIT_SKINNABLE_LEATHER" })

local function MoveSkinnable(tooltip, count)
	local skinIndex = count + 1
	if count < 2 or skinIndex > tooltip:NumLines()
		or not MatchesAny(Line(tooltip, "TextLeft", skinIndex):GetText(), skinnablePatterns) then
		return false
	end
	local right = Line(tooltip, "TextRight", count)
	local rightText = right:IsShown() and right:GetText()
	if rightText and (issecret(rightText) or rightText ~= "") then
		return false
	end
	local skin = GetLineState(tooltip, skinIndex)
	right:SetText(skin.text)
	right:SetTextColor(skin.r, skin.g, skin.b)
	right:Show()
	DropLines(tooltip, skinIndex, tooltip:NumLines(), 1)
	return true
end

local function EditNpcLines(tooltip, count)
	if MoveSkinnable(tooltip, count) then
		return count
	end
	local factionIndex, pvpIndex = count + 1, count + 2
	if count >= kinds.unit.maxHeader or pvpIndex > tooltip:NumLines()
		or not MatchesAny(Line(tooltip, "TextLeft", pvpIndex):GetText(), pvpPatterns) then
		return count
	end
	local factionText = Line(tooltip, "TextLeft", factionIndex):GetText()
	if not factionText or issecret(factionText) or factionText == "" then
		return count
	end
	local pvp, right = GetLineState(tooltip, pvpIndex), Line(tooltip, "TextRight", factionIndex)
	right:SetText(pvp.text)
	right:SetTextColor(pvp.r, pvp.g, pvp.b)
	right:Show()
	DropLines(tooltip, pvpIndex, tooltip:NumLines(), 1)
	return factionIndex
end

-- Player: the "PvP" line (after the class and faction lines, if they are still there) moves to the right
-- column of the name line and its own line is removed.
local function MovePlayerPvp(tooltip, count)
	local numLines = tooltip:NumLines()
	local right = Line(tooltip, "TextRight", 1)
	local rightText = right:IsShown() and right:GetText()
	if rightText and (issecret(rightText) or rightText ~= "") then
		return
	end
	for i = count + 1, math.min(numLines, count + 4) do
		if MatchesAny(Line(tooltip, "TextLeft", i):GetText(), pvpPatterns) then
			local pvp = GetLineState(tooltip, i)
			right:SetText(pvp.text)
			right:SetTextColor(pvp.r, pvp.g, pvp.b)
			right:Show()
			DropLines(tooltip, i, numLines, 1)
			return
		end
	end
end

-- Option "Color player names by class": the name of a player gets the class color. Only the name is colored:
-- the "PvP" text in the right column of the name line keeps its own color.
local function ColorPlayerName(tooltip, unit)
	if not db.unitClassColor then
		return
	end
	local _, classFile = UnitClass(unit)
	if not classFile or issecret(classFile) then
		return
	end
	local color = C_ClassColor and C_ClassColor.GetClassColor(classFile) or RAID_CLASS_COLORS[classFile]
	if color then
		Line(tooltip, "TextLeft", 1):SetTextColor(color.r, color.g, color.b)
	end
end

-- Option "name only" for spells: only the name is next to the icon. The rank of a spell already stands in the
-- right column of the name line; the rank line of a talent ("Rank 0/5") is moved there as well.
local function EditSpellRank(tooltip, st, count)
	if not db.spellNameOnly or count ~= 1 or tooltip:NumLines() < 2 or not IsTalentRankLine(tooltip, 2) then
		return count
	end
	local right = Line(tooltip, "TextRight", 1)
	local rightText = right:IsShown() and right:GetText()
	if (rightText and (issecret(rightText) or rightText ~= "")) or not SnapshotLines(tooltip, st) then
		return count
	end
	local rank = GetLineState(tooltip, 2)
	right:SetText(rank.text)
	right:SetTextColor(rank.r, rank.g, rank.b)
	right:Show()
	DropLines(tooltip, 2, tooltip:NumLines(), 1)
	return count
end

kinds.spell.edit = EditSpellRank
kinds.talent.edit = EditSpellRank

local function EditUnitLines(tooltip, st, count)
	local unit = TooltipUtil and TooltipUtil.GetDisplayedUnit and select(2, TooltipUtil.GetDisplayedUnit(tooltip))
	if not unit or issecret(unit) or not UnitExists(unit) or not SnapshotLines(tooltip, st) then
		return count
	end
	-- with "name only" the lines below the name are not rearranged (the faction, class and level lines stay
	-- as they are); the PvP text still goes next to the name of a player and the name keeps the class color
	local nameOnly = db.unitNameOnly
	if UnitIsPlayer(unit) then
		if not nameOnly then
			EditPlayerLines(tooltip, count)
		end
		MovePlayerPvp(tooltip, count)
		ColorPlayerName(tooltip, unit)
		return count
	end
	if nameOnly then
		return count
	end
	return EditNpcLines(tooltip, count)
end

kinds.unit = {
	maxHeader = 4,
	noBorder = true, -- a portrait has no border: it is never cut
	nameOnlyKey = "unitNameOnly",
	minLines = 3, -- the portrait is as big as for a header of three lines
	bodyGap = 4, -- the body starts 4 px lower than the header block (the portrait keeps its size)
	padTop = true, -- the last header line keeps its text at the top: the extra height goes below the header
	edit = EditUnitLines,
	headerCount = function(tooltip)
		local numLines = tooltip:NumLines()
		for i = 2, math.min(4, numLines) do
			if IsUnitLevelLine(tooltip, i) then
				return (i < numLines and IsCreatureTypeLine(tooltip, i + 1)) and i + 1 or i
			end
		end
		return 1
	end,
}

-- how many lines may be next to the icon: one while the "name only" option of the kind is on
local function MaxHeader(kind)
	return kind.nameOnlyKey and db[kind.nameOnlyKey] and 1 or kind.maxHeader
end

local function GetHeaderCount(tooltip, tooltipData, kind)
	if kind.nameOnlyKey and db[kind.nameOnlyKey] then
		return 1
	end
	if kind.headerCount then
		return kind.headerCount(tooltip, tooltipData)
	end
	local count = 1
	local numLines = math.min(MaxHeader(kind), tooltip:NumLines())
	while count < numLines and not kind.isDescription(tooltip, tooltipData, count + 1) do
		count = count + 1
	end
	return count
end

-- /tti debug: prints type / color / right text of every line of a tooltip
local function DumpLines(tooltip, tooltipData, kindName)
	-- text and colors of the lines can be secret (in combat): a secret value only goes through tostring
	local function Show(value)
		if value == nil then
			return "nil"
		elseif issecret(value) then
			return "<secret>"
		end
		return (tostring(value):gsub("|", "||")) -- "||" makes color codes visible in the chat
	end

	Print("kind " .. kindName)
	for i = 1, tooltip:NumLines() do
		local info = DataLine(tooltipData, i)
		local left, right = Line(tooltip, "TextLeft", i), Line(tooltip, "TextRight", i)
		local r, g, b = left:GetTextColor()
		local color = (issecret(r) or issecret(g) or issecret(b)) and "<secret>"
			or ("%.2f,%.2f,%.2f"):format(r or 0, g or 0, b or 0)
		Print(("%d type=%s color=%s right=%s | %s"):format(i, Show(info and info.type), color,
			Show(right:IsShown() and right:GetText()), Show(left:GetText())))
		if info and (issecret(left:GetText()) or issecret(right:GetText())) then
			-- the same line in the tooltip data, which is not secret
			Print(("   data: left=%s right=%s"):format(Show(info.leftText), Show(info.rightText)))
		end
	end
end

-- Moves the first promoted line found below the header (kind.isPromoted) to the end of the header.
-- Only plain text lines may be shifted; money lines (sell price) end the search.
local function PromoteLine(tooltip, tooltipData, st, kind, count)
	local sellPrice = Enum.TooltipDataLineType.SellPrice
	for i = count + 1, tooltip:NumLines() do
		local info = DataLine(tooltipData, i)
		if info and info.type == sellPrice then
			break
		end
		if kind.isPromoted(Line(tooltip, "TextLeft", i):GetText()) then
			st.moved = MoveLine(tooltip, i, count + 1)
			return st.moved and count + 1 or count
		end
	end
	return count
end

-- Tooltip categories of the settings panel: { kind, name, tooltip }
ns.kindList = {
	{ "spell", TTI_KIND_SPELL, TTI_KIND_SPELL_DESC },
	{ "aura", TTI_KIND_AURA, TTI_KIND_AURA_DESC },
	{ "item", TTI_KIND_ITEM, TTI_KIND_ITEM_DESC },
	{ "toy", TTI_KIND_TOY, TTI_KIND_TOY_DESC },
	{ "companion", TTI_KIND_COMPANION, TTI_KIND_COMPANION_DESC },
	{ "mount", TTI_KIND_MOUNT, TTI_KIND_MOUNT_DESC },
	{ "transmog", TTI_KIND_TRANSMOG, TTI_KIND_TRANSMOG_DESC },
	{ "unit", TTI_KIND_UNIT, TTI_KIND_UNIT_DESC },
}

-- Player class / faction display modes of the settings panel: { value, name, tooltip }
ns.unitClassModes = {
	{ 1, TTI_CLASS_MODE_1, TTI_CLASS_MODE_1_DESC },
	{ 2, TTI_CLASS_MODE_2, TTI_CLASS_MODE_2_DESC },
}

-- "Name only next to the icon" options of the tooltip kinds, by their saved variable (kind.nameOnlyKey)
function ns.IsNameOnly(key)
	return db[key]
end

function ns.SetNameOnly(key, value)
	db[key] = value and true or false
end

-- icon size and gap (the sliders of the settings); the layout cache depends on both
function ns.IsRoundPortraits()
	return db.roundPortraits
end

function ns.SetRoundPortraits(value)
	db.roundPortraits = value and true or false
end

function ns.IsIconBorder()
	return db.iconBorder
end

function ns.SetIconBorder(value)
	db.iconBorder = value and true or false
end

function ns.GetIconSize()
	return db.size
end

ns.ICON_SIZE_MIN, ns.ICON_SIZE_MAX = MIN_ICON_SIZE, MAX_SIZE
ns.ICON_GAP_MIN, ns.ICON_GAP_MAX = 0, MAX_GAP

local function Clamped(value, minValue, maxValue)
	return math.min(math.max(math.floor(value + 0.5), minValue), maxValue)
end

function ns.SetIconSize(value)
	db.size = Clamped(value, MIN_ICON_SIZE, MAX_SIZE)
	wipe(layoutCache)
end

function ns.GetIconGap()
	return db.gap
end

function ns.SetIconGap(value)
	db.gap = Clamped(value, 0, MAX_GAP)
	wipe(layoutCache)
end

function ns.IsUnitClassColor()
	return db.unitClassColor
end

function ns.SetUnitClassColor(value)
	db.unitClassColor = value and true or false
end

function ns.GetUnitClassMode()
	return db.unitClassMode
end

function ns.SetUnitClassMode(value)
	db.unitClassMode = value
end

function ns.IsEnabled()
	return db.enabled
end

function ns.IsKindEnabled(kindName)
	return db.kinds[kindName] ~= false
end

-- takes the icon off the tooltips that are visible right now (a setting was turned off)
local function RestoreVisible(kindName)
	for tooltip, st in pairs(states) do
		if not kindName or (st.kind and (kinds[st.kind].category or st.kind) == kindName) then
			Restore(tooltip, st)
		end
	end
end

function ns.SetEnabled(value)
	db.enabled = value and true or false
	if not db.enabled then
		RestoreVisible()
	end
end

function ns.SetKindEnabled(kindName, value)
	db.kinds[kindName] = value and true or false
	if not value then
		RestoreVisible(kindName)
	end
end

-- the icon is cut at the edges to drop the border built into its texture, unless the border is shown;
-- a portrait has no border and is never cut
local function SetIconCrop(icon, kindName)
	local crop = (db.iconBorder or kinds[kindName].noBorder) and 0 or CROP
	icon:SetTexCoord(crop, 1 - crop, crop, 1 - crop)
end

local function ShowIcon(tooltip, tooltipData, kindName, texture)
	local st = states[tooltip]
	if debugMode then
		local id = tooltipData and tooltipData.id
		Print(("%s: %s, id=%s, icon=%s"):format(kindName, tooltip:GetName() or "?",
			issecret(id) and "<secret>" or tostring(id), tostring(texture)))
		Print(("start: tooltip width=%s minwidth=%s name width=%s"):format(
			tostring(Plain(tooltip:GetWidth())), tostring(Plain(tooltip:GetMinimumWidth())), tostring(Plain(Line(tooltip, "TextLeft", 1):GetWidth()))))
		if not st then
			Print("tooltip is not hooked")
		end
		if tooltipData then
			local fields = {}
			for key, value in pairs(tooltipData) do
				if type(value) ~= "table" and type(value) ~= "function" and not issecret(value) then
					fields[#fields + 1] = key .. "=" .. tostring(value)
				end
			end
			Print("data: " .. table.concat(fields, " "))
		end
	end
	if not st or not texture then
		return
	end
	Restore(tooltip, st)
	if not db.enabled or db.kinds[kinds[kindName].category or kindName] == false then
		return
	end
	if debugMode then
		DumpLines(tooltip, tooltipData, kindName)
	end

	local kind = kinds[kindName]
	local count = GetHeaderCount(tooltip, tooltipData, kind)
	if kind.isPromoted and count < MaxHeader(kind) then
		count = PromoteLine(tooltip, tooltipData, st, kind, count)
	end
	if kind.edit then
		count = kind.edit(tooltip, st, count) or count -- a kind may move lines into the header
	end

	st.orig = {}
	for i = 1, count do
		local text = Line(tooltip, "TextLeft", i):GetText()
		if not text or issecret(text) then
			Restore(tooltip, st)
			return
		end
		st.orig[i] = text
	end

	st.kind, st.count = kindName, count
	st.origJustifyV = kind.padTop and Line(tooltip, "TextLeft", count):GetJustifyV() or nil
	st.origRightJustifyV = kind.padTop and Line(tooltip, "TextRight", count):GetJustifyV() or nil
	st.origRightText = nil
	if kind.padTop then
		local right = Line(tooltip, "TextRight", count)
		local rightText = right:IsShown() and right:GetText()
		if rightText and not issecret(rightText) and rightText ~= "" then
			st.origRightText = rightText
		end
	end
	st.origWidth = {}
	for i = 1, count do
		-- a width equal to the text width is an automatic one: restore it as 0, not as a fixed width
		local line = Line(tooltip, "TextLeft", i)
		local width, textWidth = Plain(line:GetWidth()), Plain(line:GetStringWidth())
		-- an unreadable (secret) width is restored as automatic
		st.origWidth[i] = (not width or not textWidth or math.abs(width - textWidth) <= 1) and 0 or width
	end
	if debugMode then
		Print(("header lines: %d%s"):format(count, st.moved and " (lines edited)" or ""))
	end
	st.active = true
	SetIconCrop(st.icon, kindName)
	if type(texture) == "function" then
		texture(st.icon) -- e.g. SetPortraitTexture
	else
		st.icon:SetTexture(texture)
	end
	local size, padH, natural, cached = Plan(tooltip, kindName, count)
	st.natural, st.pass, st.fitPasses = natural, 0, 0
	ApplyLayout(tooltip, st, size, padH)

	st.cached = cached
	pending[tooltip] = true
	driver:Show()
end

local function SpellTexture(id)
	if id and not issecret(id) then
		return GetSpellTexture(id)
	end
end

local function ItemTexture(id)
	if id and not issecret(id) then
		return GetItemIcon(id)
	end
end

local function ToyTexture(id)
	if id and not issecret(id) and C_ToyBox and C_ToyBox.GetToyInfo then
		local _, _, icon = C_ToyBox.GetToyInfo(id)
		return icon
	end
end

-- the tooltip id of a companion pet is its species id
local function CompanionTexture(speciesID)
	if speciesID and not issecret(speciesID) and C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
		return (select(2, C_PetJournal.GetPetInfoBySpeciesID(speciesID)))
	end
end

local function OnCompanion(tooltip, tooltipData)
	ShowIcon(tooltip, tooltipData, "companion", CompanionTexture(tooltipData and tooltipData.id))
end

-- The companion tooltip data has no species id; the pet is only known from the SetCompanionPet argument.
local function OnSetCompanionPet(tooltip, petID)
	if petID and not issecret(petID) and C_PetJournal and C_PetJournal.GetPetInfoByPetID then
		ShowIcon(tooltip, nil, "companion", CompanionTexture((C_PetJournal.GetPetInfoByPetID(petID))))
	end
end

-- the tooltip id of a mount is its mount id
local function MountTexture(mountID)
	if mountID and not issecret(mountID) and C_MountJournal and C_MountJournal.GetMountInfoByID then
		return (select(3, C_MountJournal.GetMountInfoByID(mountID)))
	end
end

local function OnMount(tooltip, tooltipData)
	ShowIcon(tooltip, tooltipData, "mount", MountTexture(tooltipData and tooltipData.id))
end

-- Transmog tooltips are built by CollectionWardrobeUtil.SetAppearanceTooltip without tooltip data.
-- The icon is the one of the primary source's item, or of the first source.
local function OnSetAppearanceTooltip(tooltip, appearanceData, primarySourceID)
	local sources = type(appearanceData) == "table" and appearanceData.sources
	if not sources then
		return
	end
	local item = sources[1]
	for _, source in ipairs(sources) do
		if source.sourceID == primarySourceID then
			item = source
			break
		end
	end
	ShowIcon(tooltip, nil, "transmog", ItemTexture(item and item.itemID))
end

-- the portrait of the displayed unit, drawn into the icon texture by SetPortraitTexture
local function OnUnit(tooltip, tooltipData)
	local unit = TooltipUtil and TooltipUtil.GetDisplayedUnit and select(2, TooltipUtil.GetDisplayedUnit(tooltip))
	if not unit or issecret(unit) or not UnitExists(unit) then
		return
	end
	ShowIcon(tooltip, tooltipData, "unit", function(icon)
		-- the third argument switches the round mask off: the portrait is square unless the option is on
		SetPortraitTexture(icon, unit, not db.roundPortraits)
	end)
end

-- The talent window of ClassicUIForever builds its tooltip by hand (SetText / AddLine), so no tooltip data
-- is processed and no post-call fires. The button that owns the tooltip carries the talent: the icon is
-- drawn when the tooltip is shown (our own Show calls while laying it out are skipped).
local showBusy

local function OnShowOwnedByTalent(tooltip)
	local st = states[tooltip]
	if showBusy or not st or st.active then
		return
	end
	local owner = tooltip:GetOwner()
	local talent = type(owner) == "table" and owner.talent
	local spellID = type(talent) == "table" and talent.spellID
	if not spellID then
		return
	end
	showBusy = true
	local ok, err = pcall(ShowIcon, tooltip, nil, "talent", SpellTexture(spellID))
	showBusy = false
	if not ok then
		geterrorhandler()(err)
	end
end

local function OnToy(tooltip, tooltipData)
	ShowIcon(tooltip, tooltipData, "toy", ToyTexture(tooltipData and tooltipData.id))
end

local function OnSpell(tooltip, tooltipData)
	ShowIcon(tooltip, tooltipData, "spell", SpellTexture(tooltipData and tooltipData.id))
end

local function OnAura(tooltip, tooltipData)
	ShowIcon(tooltip, tooltipData, "aura", SpellTexture(tooltipData and tooltipData.id))
end

local function OnItem(tooltip, tooltipData)
	ShowIcon(tooltip, tooltipData, "item", ItemTexture(tooltipData and tooltipData.id))
end

local function OnMacro(tooltip, tooltipData)
	local info = tooltipData and tooltipData.lines and tooltipData.lines[1]
	if not info then
		return
	end
	if info.tooltipType == Enum.TooltipDataType.Spell then
		ShowIcon(tooltip, tooltipData, "spell", SpellTexture(info.tooltipID))
	elseif info.tooltipType == Enum.TooltipDataType.Item then
		ShowIcon(tooltip, tooltipData, "item", ItemTexture(info.tooltipID))
	end
end

local function OnCleared(tooltip)
	local st = states[tooltip]
	if st then
		-- lines are rebuilt by the engine, nothing to restore
		st.active, st.moved = nil, nil
		SetHeaderFlow(tooltip, st, false)
		if st.paddingAdded then
			local right, bottom, left, top = tooltip:GetPadding()
			if not issecret(right) then
				tooltip:SetPadding(math.max(0, right - st.paddingAdded), bottom, left, top)
			end
			st.paddingAdded = nil
		end
		st.icon:Hide()
		pending[tooltip] = nil
	end
end

local function HookTooltip(tooltip)
	if not tooltip or states[tooltip] or not tooltip.HookScript then
		return
	end
	local icon = tooltip:CreateTexture(nil, "OVERLAY")
	icon:SetPoint("TOPLEFT", Line(tooltip, "TextLeft", 1), "TOPLEFT", 0, 0)
	icon:SetTexCoord(CROP, 1 - CROP, CROP, 1 - CROP)
	icon:Hide()
	states[tooltip] = { icon = icon }
	tooltip:HookScript("OnTooltipCleared", OnCleared)
end

--------------------------------------------------------------------------------
-- STARTUP / SLASH
--------------------------------------------------------------------------------

local function SlashCommand(msg)
	local cmd, value = strmatch(strlower(msg), "^(%S+)%s*(%S*)")
	if not cmd or cmd == "config" or cmd == "options" or cmd == "settings" then
		if ns.OpenSettings then
			ns.OpenSettings()
		end
		return
	end
	if cmd == "on" or cmd == "off" or cmd == "toggle" then
		ns.SetEnabled(cmd == "toggle" and not db.enabled or cmd == "on")
		Print(db.enabled and "icons enabled" or "icons disabled")
		return
	end
	if cmd == "class" then
		local mode = tonumber(value)
		if mode and ns.unitClassModes[mode] then
			ns.SetUnitClassMode(mode)
			Print(("player class and faction: %s"):format(ns.unitClassModes[mode][2]))
		else
			Print("/tti class 1-2: " .. ns.unitClassModes[1][2] .. "; " .. ns.unitClassModes[2][2])
		end
		return
	end
	if cmd == "debug" then
		debugMode = not debugMode
		Print("debug " .. (debugMode and "on" or "off"))
		if #missing > 0 then
			Print("missing constants: " .. table.concat(missing, ", "))
		end
		return
	end
	if cmd == "reset" then
		db.size, db.gap = defaults.size, defaults.gap
		wipe(layoutCache)
		if ns.ResetSettings then
			ns.ResetSettings()
		end
		Print(("reset: size = %d, gap = %d, all categories enabled"):format(db.size, db.gap))
		return
	end
	value = tonumber(value)
	if cmd == "size" or cmd == "gap" then
		local minValue, maxValue = ns.ICON_SIZE_MIN, ns.ICON_SIZE_MAX
		if cmd == "gap" then
			minValue, maxValue = ns.ICON_GAP_MIN, ns.ICON_GAP_MAX
		end
		if value and value >= minValue and value <= maxValue then
			(cmd == "size" and ns.SetIconSize or ns.SetIconGap)(value)
			Print(("%s = %d"):format(cmd, db[cmd]))
		else
			Print(("/tti %s: a number from %d to %d, now %d"):format(cmd, minValue, maxValue, db[cmd]))
		end
	else
		Print(("icons %s, size = %d (minimum icon size), gap = %d"):format(db.enabled and "on" or "off", db.size, db.gap))
		Print("/tti [options] | on | off | toggle | size <n> | gap <n> | reset | debug")
	end
end

-- Tooltip data is processed by TooltipDataHandlerMixin:ProcessInfo: it adds the lines, runs all post-calls of
-- all addons (in the order they registered, which we can't control: Leatrix Plus rewrites the lines of unit
-- tooltips there) and returns. A post-hook of ProcessInfo therefore runs after every post-call, whatever the
-- load order of the addons is, and sees the lines in their final state.
local dataHandlers = {} -- [Enum.TooltipDataType] = function(tooltip, tooltipData)

for typeName, handler in pairs({
	Spell = OnSpell, Macro = OnMacro, UnitAura = OnAura, Item = OnItem, CompanionPet = OnCompanion,
	Unit = OnUnit, Mount = OnMount, Toy = OnToy,
}) do
	local dataType = Enum.TooltipDataType[typeName]
	if dataType then
		dataHandlers[dataType] = handler
	end
end

local hookGeneration = 0

local function OnProcessInfo(tooltip, info)
	local tooltipData = type(info) == "table" and info.tooltipData
	local handler = tooltipData and dataHandlers[tooltipData.type]
	if handler then
		handler(tooltip, tooltipData)
	end
end

-- Every call hooks ProcessInfo of the tooltips once more and makes the earlier hooks do nothing.
HookProcessInfo = function()
	hookGeneration = hookGeneration + 1
	local generation = hookGeneration
	for tooltip in pairs(states) do
		if tooltip.ProcessInfo then
			hooksecurefunc(tooltip, "ProcessInfo", function(...)
				if generation == hookGeneration then
					OnProcessInfo(...)
				end
			end)
		end
	end
end

local function RegisterHandlers()
	HookProcessInfo()
	hooksecurefunc(GameTooltip, "Show", OnShowOwnedByTalent)
	if CollectionWardrobeUtil and CollectionWardrobeUtil.SetAppearanceTooltip then
		hooksecurefunc(CollectionWardrobeUtil, "SetAppearanceTooltip", OnSetAppearanceTooltip)
	end
	if GameTooltip.SetCompanionPet then
		hooksecurefunc(GameTooltip, "SetCompanionPet", OnSetCompanionPet)
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, _, name)
	if name ~= ADDON then
		return
	end
	self:UnregisterEvent("ADDON_LOADED")

	TooltipIconDB = TooltipIconDB or {}
	db = TooltipIconDB
	for key, value in pairs(defaults) do
		if type(db[key]) ~= "number" then
			db[key] = value
		end
	end
	db.size = Clamped(db.size, MIN_ICON_SIZE, MAX_SIZE)
	db.gap = Clamped(db.gap, 0, MAX_GAP)
	if type(db.enabled) ~= "boolean" then
		db.enabled = true
	end
	if type(db.unitClassColor) ~= "boolean" then
		db.unitClassColor = true
	end
	if type(db.iconBorder) ~= "boolean" then
		db.iconBorder = false
	end
	if type(db.roundPortraits) ~= "boolean" then
		db.roundPortraits = false
	end
	for _, key in ipairs({ "spellNameOnly", "itemNameOnly", "toyNameOnly", "companionNameOnly", "mountNameOnly", "unitNameOnly" }) do
		if type(db[key]) ~= "boolean" then
			db[key] = false
		end
	end
	if type(db.kinds) ~= "table" then
		db.kinds = {}
	end
	if not db.unitModesRevised then
		-- old modes: 1 under the icon and 3 class color (gone: the default), 2 faction on the class line, 4 icons
		db.unitClassMode = db.unitClassMode == 2 and 1 or 2
		db.unitModesRevised = true
	end
	db.cache, db.cacheVersion = nil, nil -- the layout cache used to be saved
	db.unitIconSize, db.unitIconOffset = nil, nil -- tuning values that are constants now

	HookTooltip(GameTooltip)
	HookTooltip(ItemRefTooltip)
	HookTooltip(BuffFrameTooltip)
	HookTooltip(ShoppingTooltip1)
	HookTooltip(ShoppingTooltip2)
	HookTooltip(ItemRefShoppingTooltip1)
	HookTooltip(ItemRefShoppingTooltip2)
	RegisterHandlers()

	if ns.RegisterSettings then
		ns.RegisterSettings()
	end

	SLASH_TOOLTIPICON1 = "/tooltipicon"
	SLASH_TOOLTIPICON2 = "/tti"
	SlashCmdList.TOOLTIPICON = SlashCommand
end)
