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
local INLINE_SIZE_MIN, INLINE_SIZE_MAX = 10, 32 -- class and faction icons inside a text line
local INLINE_OFFSET_MIN, INLINE_OFFSET_MAX = -10, 10 -- their horizontal shift
local MAX_FIT_PASSES = 2 -- width corrections per tooltip build
local PAD_DESCENT = 4 -- measured: a line is 4 px taller than its pad texture
local MAX_PASSES = 3 -- layout correction passes per uncached header line count
local CROP = 0.07 -- trims the built-in dark border of spell icons (unless "Show the icon border" is on)

-- unitClassMode 2: class and faction icon on the level line; the offset -2 compensates the texture margins
local defaults = {
	size = 32, gap = 6, unitClassMode = 2,
	classIconSize = 16, classIconOffset = -2, factionIconSize = 20, factionIconOffset = -2,
}
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
local debugCycle = 0 -- number of the debug output of one tooltip build, see ShowIcon

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

-- Text and color of line `i`. In combat the line on the screen can be secret while the tooltip data still holds
-- plain values: those are used then. Whatever stays secret is nil.
local function LineValues(tooltip, tooltipData, i)
	local line = Line(tooltip, "TextLeft", i)
	local text = line:GetText()
	local r, g, b = line:GetTextColor()
	if issecret(text) or issecret(r) or issecret(g) or issecret(b) then
		local info = DataLine(tooltipData, i)
		if issecret(text) then
			text = info and info.leftText
		end
		if issecret(r) or issecret(g) or issecret(b) then
			local color = info and info.leftColor
			if color and not issecret(color) then -- the color table itself can be secret
				r, g, b = color.r, color.g, color.b
			else
				r, g, b = nil, nil, nil
			end
		end
	end
	if issecret(text) then
		text = nil
	end
	if issecret(r) or issecret(g) or issecret(b) then
		r, g, b = nil, nil, nil
	end
	return text, r, g, b
end

-- Height of a line: measured, or (when the measurement is secret) from the font of the line.
local function LineHeightOf(line)
	local height = Plain(line:GetStringHeight())
	if height then
		return height
	end
	local _, fontSize = line:GetFont()
	return Plain(fontSize) or 12 -- measured: a header of three lines (14 + 12 + 12 + 2 x 2) is 42 high
end

-- Writes `prefix .. text` to a line. A secret text can't be joined in Lua, but SetFormattedText accepts it as
-- an argument. Returns the text written, or nil when it is secret.
local function SetLineText(line, prefix, text)
	if issecret(text) then
		line:SetFormattedText(prefix .. "%s", text)
		return nil
	end
	local full = prefix .. text
	line:SetText(full)
	return full
end

local function Clamp(size)
	return math.min(size, MAX_SIZE)
end

-- Height of the inline class / faction icons of line i of a unit tooltip (0: the line has none).
local function InlineIconHeight(tooltip, i)
	local icons = states[tooltip] and states[tooltip].inlineIcons
	return icons and icons.line == i and icons.height or 0
end

local function EstimateBlockHeight(tooltip, count)
	local height = 0
	for i = 1, count do
		local left, right = Line(tooltip, "TextLeft", i), Line(tooltip, "TextRight", i)
		local h = math.max(LineHeightOf(left), InlineIconHeight(tooltip, i))
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
	return math.ceil(size - natural + gap - descent + LineHeightOf(Line(tooltip, "TextLeft", count)))
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

-- A header with inline icons is taller than one without: the cache keeps them apart.
local function CacheKey(tooltip, count)
	local icons = states[tooltip] and states[tooltip].inlineIcons
	return icons and icons.line <= count and (count .. "/" .. icons.height) or count
end

local function GetCache(tooltip, kind, count)
	local cache = KindCache(kind)[CacheKey(tooltip, count)]
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
	local cache = GetCache(tooltip, kind, lines)
	if cache then
		return cache.natural
	end
	local first = LineHeightOf(Line(tooltip, "TextLeft", 1))
	-- the height of a plain line from its font: inline icons make a line taller than the lines of other tooltips
	local _, fontSize = Line(tooltip, "TextLeft", 2):GetFont()
	local second = Plain(fontSize) and fontSize + 1 or first
	local height = first + (lines - 1) * LINE_SPACING
	for i = 2, lines do
		height = height + math.max(second, InlineIconHeight(tooltip, i))
	end
	return height
end

-- icon size for a header block of the given natural height
local function TargetSize(tooltip, kind, natural)
	return Clamp(math.max(natural, db.size, MinBlockHeight(tooltip, kind)))
end

-- returns size, padHeight, natural block height, isCached
local function Plan(tooltip, kind, count)
	local cache = GetCache(tooltip, kind, count)
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
-- A line whose text is secret (combat) is indented with plain spaces: the client does not draw textures of an
-- addon in such a line. The width of a space comes from a FontString of our own (its text is not secret).
local spaceMeter
local spaceWidths = {}

local function SpaceWidth(line)
	local font, size, flags = line:GetFont()
	if not font or issecret(font) or not Plain(size) then
		return 4
	end
	local key = font .. "|" .. size .. "|" .. tostring(flags)
	if not spaceWidths[key] then
		spaceMeter = spaceMeter or UIParent:CreateFontString(nil, "BACKGROUND")
		spaceMeter:SetFont(font, size, flags)
		spaceMeter:SetText(("          "):rep(2))
		spaceWidths[key] = Plain(spaceMeter:GetStringWidth()) and spaceMeter:GetStringWidth() / 20 or 4
	end
	return math.max(spaceWidths[key], 1)
end

local function WidthSpacer(line, target, secretText)
	local spacer = ("|T%s:1:%.1f|t"):format(SPACER, target)
	if secretText then
		return (" "):rep(math.max(1, math.floor(target / SpaceWidth(line) + 0.5)))
	end
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

	local previous = st.applied or {}
	st.applied = {}
	for i = 1, st.count do
		local line = Line(tooltip, "TextLeft", i)
		local indent = st.crestLine == i and st.crestIndent or 0 -- room for the crest drawn by coordinates
		local widthSpacer = WidthSpacer(line, size + db.gap + indent, issecret(st.orig[i]))
		local text = st.orig[i]
		-- the game appends text to a line after us (the key binding of a bag): it stays
		local current, written = line:GetText(), previous[i]
		if written and not issecret(text) and current and not issecret(current) and current ~= written
			and current:sub(1, #written) == written then
			text = text .. current:sub(#written + 1)
		end
		st.applied[i] = SetLineText(line, widthSpacer .. (i == st.count and padSpacer or ""), text)
	end
	-- the text of a taller line is centered; some kinds keep it at the top (the space goes below the header)
	-- (both columns of the line: the right text would otherwise sink to the bottom of the taller line)
	-- (a last line with inline icons stays centered: the client aligns the icons and the text itself)
	if kinds[st.kind].padTop then
		local top = padH > 0 and not (st.inlineIcons and st.inlineIcons.line == st.count)
		Line(tooltip, "TextLeft", st.count):SetJustifyV(top and "TOP" or st.origJustifyV)
		Line(tooltip, "TextRight", st.count):SetJustifyV(top and "TOP" or st.origRightJustifyV)
		-- the right text is centered on the line: it needs the same height to stand at the top as well
		if st.origRightText then
			Line(tooltip, "TextRight", st.count):SetText((top and padSpacer or "") .. st.origRightText)
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
	if st.crest then
		if st.crestLine then
			-- a texture of its own at the start of the line (an inline texture is not drawn in a secret line)
			st.crest:SetTexture(st.crestFile)
			st.crest:SetTexCoord(0, 0.59375, 0, 0.59375)
			st.crest:SetSize(st.crestSize, st.crestSize)
			st.crest:ClearAllPoints()
			st.crest:SetPoint("LEFT", Line(tooltip, "TextLeft", st.crestLine), "LEFT", size + db.gap + db.factionIconOffset, 0)
			st.crest:Show()
		else
			st.crest:Hide()
		end
	end
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
	if st.crest then
		st.crest:Hide()
	end
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

	KindCache(st.kind)[CacheKey(tooltip, st.count)] = { size = db.size, natural = natural, padH = st.padH }
	return true
end

-- The header lines hold the text we wrote last (st.applied). When one of them differs, some other addon has
-- rewritten it after us: it hooks ProcessInfo behind our hook. Hooks can't be removed, but a new hook
-- stands behind every earlier one, and the older hooks of ours are switched off (see HookProcessInfo).
local lastMismatch -- what the last check found: kind, line, expected and actual text
local function Escaped(text)
	return (tostring(text):gsub("|", "||"):gsub("\n", "\\n"))
end

local function HeaderOverwritten(tooltip, st)
	for i = 1, st.count do
		local text = Line(tooltip, "TextLeft", i):GetText()
		local written = st.applied[i]
		-- text appended to the line (the key binding of a bag) is not a rewrite
		if not issecret(text) and text ~= written and not (written and text and text:sub(1, #written) == written) then
			lastMismatch = ("%s line %d/%d: expected [%s], found [%s]"):format(st.kind, i, st.count,
				Escaped(st.applied[i]), Escaped(text))
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
				Print(("header check #%s %s: %s, line 1 = %s"):format(tostring(st.cycle), st.kind, overwritten and "OVERWRITTEN" or "intact",
					issecret(text) and "<secret>" or (tostring(text):gsub("|", "||"))))
				Print(("icon #%s: shown=%s visible=%s alpha=%s size=%sx%s tooltip alpha=%s"):format(tostring(st.cycle), tostring(st.icon:IsShown()),
					tostring(st.icon:IsVisible()), tostring(Plain(st.icon:GetAlpha())), tostring(Plain(st.icon:GetWidth())),
					tostring(Plain(st.icon:GetHeight())), tostring(Plain(tooltip:GetAlpha()))))
			end
			if overwritten then
				if rehooks < MAX_REHOOKS and not rehookScheduled then
					rehookScheduled = true
					rehooks = rehooks + 1
					if debugMode then
						Print(lastMismatch)
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
local function IsColoredLine(tooltip, tooltipData, i)
	local text, r, g, b = LineValues(tooltip, tooltipData, i)
	if text and (text:find("|c", 1, true) or text:find("|n", 1, true) or text:find("\n", 1, true)) then
		return true
	end
	if not r then
		return false
	end
	return r < WHITE or g < WHITE or b < WHITE
end

-- The rank line of a talent ("Rank 0/5") is a header line wherever it comes from; the format has no
-- constant of its own that is known in this client, so it is recognised by its shape: text, number/number.
local function IsTalentRankLine(tooltip, tooltipData, i)
	local text = LineValues(tooltip, tooltipData, i)
	if not text then
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
	isDescription = function(tooltip, tooltipData, i)
		return not IsTalentRankLine(tooltip, tooltipData, i)
	end,
}

kinds.spell = {
	maxHeader = 3,
	nameOnlyKey = "spellNameOnly",
	isDescription = function(tooltip, tooltipData, i)
		if IsTalentRankLine(tooltip, tooltipData, i) then
			return false
		end
		-- the header of a talent ends with its rank line
		if i > 2 and IsTalentRankLine(tooltip, tooltipData, i - 1) then
			return true
		end
		local info = DataLine(tooltipData, i)
		if info and info.type == Enum.TooltipDataLineType.SpellDescription then
			return true
		end
		return IsColoredLine(tooltip, tooltipData, i)
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
		return IsColoredLine(tooltip, tooltipData, i)
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
		return IsColoredLine(tooltip, tooltipData, i)
	end,
}

-- Transmog appearance: only the item name sits next to the icon; the rest is gray hint text.
kinds.transmog = {
	maxHeader = 1,
	isDescription = function() return true end,
}

-- Only the aura name sits next to the icon for now; see `/tti debug` for the line layout of auras.
-- Currency: only the name is next to the icon, the description and the totals are below
kinds.currency = {
	maxHeader = 1,
	isDescription = function() return true end,
}
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

-- format string -> pattern: escape magic characters, %d / %s become wildcards;
-- positional arguments (%1$d) and plural forms (|4one:few:many;) of other locales are handled too
local function BuildPatterns(names)
	local patterns = {}
	for _, name in ipairs(names) do
		local text = _G[name]
		if type(text) == "string" then
			local pattern = text:gsub("%%%d%$", "%%"):gsub("|4[^;]*;", "\1")
			pattern = pattern:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0"):gsub("%%d", "%%d+"):gsub("%%s", ".+")
			pattern = pattern:gsub("\1", "%%S+")
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
		local text = LineValues(tooltip, tooltipData, i)
		-- a line of several rows (the crafted item of a recipe: a line break, then the item name) is not a
		-- header field, whatever its type is
		if text and (text:find("\n", 1, true) or text:find("|n", 1, true)) then
			return true
		end
		local info = DataLine(tooltipData, i)
		if info and itemHeaderTypes[info.type] then
			return false
		end
		return not MatchesAny(text, itemHeaderPatterns)
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
		return not MatchesAny((LineValues(tooltip, tooltipData, i)), toyPromotedPatterns)
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
-- and its creature type or race ("Pet Level 1 Critter" of a pet; a player's line in a locale whose templates
-- differ from the patterns).
local function IsUnitLevelLine(tooltip, i, tooltipData)
	local text = LineValues(tooltip, tooltipData, i) -- a secret line on the screen: its text from the data
	if not text or issecret(text) then
		return false
	end
	if MatchesAny(text, unitLevelPatterns) then
		return true
	end
	local unit = TooltipUtil and TooltipUtil.GetDisplayedUnit and select(2, TooltipUtil.GetDisplayedUnit(tooltip))
	if not unit or issecret(unit) or not UnitExists(unit) then
		-- The unit is hidden (a battleground match): a player's race comes from the GUID of the data and must be in
		-- the line; for other units (a pet) the first line with a number is the level line.
		local guid = tooltipData and tooltipData.guid
		local race = guid and not issecret(guid) and GetPlayerInfoByGUID and select(3, GetPlayerInfoByGUID(guid))
		local plain = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
		if not plain:find("%d") and not plain:find("??", 1, true) then -- the level: digits, or "??" above ours
			return false
		end
		if race and not issecret(race) and race ~= "" then
			return plain:find(race, 1, true) ~= nil
		end
		return true
	end
	-- the level and the creature type or, for a player, the race
	local level = UnitLevel(unit)
	local kind = UnitIsPlayer(unit) and UnitRace(unit) or UnitCreatureType(unit)
	local kindHidden = issecret(kind) -- the race of an enemy player: the level alone has to do
	if not level or issecret(level) then
		return false
	end
	if kindHidden then
		kind = nil
	end
	-- the color code of the level ("|cffffd100") ends with digits that would stick to the level
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	-- the game writes "??" instead of the level when it is far above ours, whatever UnitLevel returns
	local hasLevel = (level >= 1 and text:find("%f[%d]" .. level .. "%f[%D]")) or text:find("??", 1, true)
	if not hasLevel then
		return false
	end
	-- an NPC: the type of the creature may be on the next line
	return (kind and text:find(kind, 1, true) ~= nil) or kindHidden
		or (i < tooltip:NumLines() and IsCreatureTypeLine(tooltip, i + 1))
end

-- Player class / faction handling (setting db.unitClassMode, see ns.unitClassModes):
-- 1 the faction moves to the right column of the class line,
-- 2 the class line and the faction line are removed, a faction crest and a class icon are put before the level line.
-- The lines that follow the header are shifted up; the last line is left blank.
local BLANK_LINE = { text = "", r = 1, g = 1, b = 1, rightText = "", rr = 1, rg = 1, rb = 1, rightShown = false }
-- an empty line of the full height of a line (a space; an empty text is only a few pixels high)
local SPACE_LINE = { text = " ", r = 1, g = 1, b = 1, rightText = "", rr = 1, rg = 1, rb = 1, rightShown = false }

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

-- The class line of a player, found by its text: the line after the level line holds a localized class name
-- (the unit and its GUID are not needed). Returns the class name and the class file.
local classByName

local function ClassFromText(tooltip, count)
	if count + 1 > tooltip:NumLines() then
		return
	end
	local text = Line(tooltip, "TextLeft", count + 1):GetText()
	if not text or issecret(text) then
		return
	end
	if not classByName then
		classByName = {}
		for _, list in ipairs({ LOCALIZED_CLASS_NAMES_MALE or {}, LOCALIZED_CLASS_NAMES_FEMALE or {} }) do
			for classFile, name in pairs(list) do
				classByName[name] = classFile
			end
		end
	end
	local classFile = classByName[(text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))]
	return classFile and text, classFile
end

-- The player of a tooltip: the unit, or (when the unit is hidden) the values of its GUID: class name, class file,
-- race ..., the race ID last.
local function PlayerClass(tooltip, tooltipData)
	local unit = TooltipUtil and TooltipUtil.GetDisplayedUnit and select(2, TooltipUtil.GetDisplayedUnit(tooltip))
	if unit and not issecret(unit) and UnitExists(unit) then
		if UnitIsPlayer(unit) then
			return unit, UnitClass(unit)
		end
		return unit
	end
	local guid = tooltipData and tooltipData.guid
	if guid and not issecret(guid) and guid:find("^Player%-") and GetPlayerInfoByGUID then
		return nil, GetPlayerInfoByGUID(guid)
	end
end

local function EditPlayerLines(tooltip, st, count, tooltipData)
	local mode = db.unitClassMode
	-- the 9th value: the race ID of a player found by the GUID
	local unit, className, classFile, _, _, _, _, _, raceID = PlayerClass(tooltip, tooltipData)
	if not className or issecret(className) or issecret(classFile) then
		className, classFile = ClassFromText(tooltip, count) -- the class of the unit is hidden: the text of its line
	end
	if not className then
		return
	end
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
	local factionGroup, factionName
	if unit then
		factionGroup, factionName = UnitFactionGroup(unit)
	else
		-- the faction of the race (GUID), else the text of the line
		local info = raceID and C_CreatureInfo and C_CreatureInfo.GetFactionInfo and C_CreatureInfo.GetFactionInfo(raceID)
		if info and not issecret(info) then
			factionGroup, factionName = info.groupTag, info.name
		elseif classIndex < numLines then
			local text = Line(tooltip, "TextLeft", classIndex + 1):GetText()
			if not issecret(text) and (text == FACTION_ALLIANCE or text == FACTION_HORDE) then
				factionGroup, factionName = text == FACTION_ALLIANCE and "Alliance" or "Horde", text
			end
		end
	end
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
	local function Markup()
		local classMarkup = ClassIconMarkup(classFile, db.classIconSize, db.classIconOffset)
		local factionMarkup = hasFactionLine and factionGroup and not issecret(factionGroup)
			and FactionIconMarkup(factionGroup, db.factionIconSize, db.factionIconOffset)
		return classMarkup and (factionMarkup or "") .. classMarkup, factionMarkup
	end
	local prefix, factionMarkup = Markup()
	if not prefix then
		return
	end

	local level = Line(tooltip, "TextLeft", count)
	local levelText = level:GetText()
	if not levelText or issecret(levelText) then
		return
	end
	level:SetText(prefix .. levelText)
	st.inlineIcons = {
		line = count,
		height = math.max(db.classIconSize, factionMarkup and db.factionIconSize or 0),
	}
	if count < kinds.unit.minLines then
		-- the header is shorter than the portrait: the class line stays as an empty line of the header, so the
		-- client lays the lines out by itself (instead of a pad texture on the last line); only the faction line goes
		SetLineState(tooltip, classIndex, SPACE_LINE)
		if factionMarkup then
			DropLines(tooltip, classIndex + 1, numLines, 1)
		end
		return count + 1
	end
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

-- Names of all factions of the reputation data: the line of an NPC that holds one of them is its faction.
local factionNames

local function IsFactionName(text)
	if not factionNames then
		factionNames = {}
		if C_Reputation and C_Reputation.GetFactionDataByID then
			for id = 1, 3500 do
				local data = C_Reputation.GetFactionDataByID(id)
				local name = data and data.name
				if name and not issecret(name) and name ~= "" then
					factionNames[name] = true
				end
			end
		end
	end
	return factionNames[(text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))] == true
end

local function EditNpcLines(tooltip, count)
	if MoveSkinnable(tooltip, count) then
		return count
	end
	local numLines = tooltip:NumLines()
	local factionIndex, pvpIndex = count + 1, count + 2
	if count >= kinds.unit.maxHeader or factionIndex > numLines then
		return count
	end
	local factionText = Line(tooltip, "TextLeft", factionIndex):GetText()
	if not factionText or issecret(factionText) or factionText == "" then
		return count
	end
	-- the faction joins the header when it is followed by "PvP" or when its text is the name of a faction
	local hasPvp = pvpIndex <= numLines and MatchesAny(Line(tooltip, "TextLeft", pvpIndex):GetText(), pvpPatterns)
	if not hasPvp and not IsFactionName(factionText) then
		return count
	end
	if hasPvp then
		-- "PvP" moves to the right column of the faction line
		local pvp, right = GetLineState(tooltip, pvpIndex), Line(tooltip, "TextRight", factionIndex)
		right:SetText(pvp.text)
		right:SetTextColor(pvp.r, pvp.g, pvp.b)
		right:Show()
		DropLines(tooltip, pvpIndex, numLines, 1)
	end
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
local function ColorPlayerName(tooltip, classFile)
	if not db.unitClassColor then
		return
	end
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
	if not db.spellNameOnly or count ~= 1 or tooltip:NumLines() < 2 or not IsTalentRankLine(tooltip, nil, 2) then
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

-- A pet has a line of the type "owner" (its type stays readable when the text is secret).
local function HasOwnerLine(tooltipData, numLines)
	local ownerType = Enum.TooltipDataLineType.UnitOwner
	for i = 2, numLines do
		local info = DataLine(tooltipData, i)
		if info and ownerType and info.type == ownerType then
			return true
		end
	end
	return false
end

-- A battleground: every player is flagged, and the "PvP" line is the last line of the tooltip.
-- Its text is secret here: it is handed to the right column of the name line and the line itself is emptied
-- (the lines below can't be moved up, a blank row stays).
local function MoveSecretPvp(tooltip, count, tooltipData)
	local _, instanceType = IsInInstance()
	local isPlayer = UnitIsPlayer("mouseover")
	local numLines = tooltip:NumLines()
	if instanceType ~= "pvp" or count + 1 > numLines then
		return
	end
	-- a player, or a pet (it has the line of its owner)
	if issecret(isPlayer) or not (isPlayer or HasOwnerLine(tooltipData, numLines)) then
		return
	end
	local left = Line(tooltip, "TextLeft", numLines) -- the last line
	local text = left:GetText()
	if not issecret(text) then
		return -- a readable text is moved by MovePlayerPvp
	end
	local right = Line(tooltip, "TextRight", 1)
	local rightText = right:IsShown() and right:GetText()
	if rightText and (issecret(rightText) or rightText ~= "") then
		return
	end
	right:SetFormattedText("%s", text)
	right:Show()
	pcall(right.SetTextColor, right, left:GetTextColor())
	left:SetText("")
end

-- A player in a battleground, everything secret: the lines end with level, class, faction, "PvP". The faction is
-- plain through the unit ("mouseover"): its crest is drawn at the start of the class line (mode 2; a texture of
-- its own, the text of the line is indented) or its text goes to the right column of the class line (mode 1), and
-- the faction line is emptied. Returns the new header count.
local function HideSecretFaction(tooltip, st, count)
	local _, instanceType = IsInInstance()
	local isPlayer = UnitIsPlayer("mouseover")
	local numLines = tooltip:NumLines()
	if instanceType ~= "pvp" or issecret(isPlayer) or not isPlayer or count ~= numLines - 1 or numLines < 5 then
		return count
	end
	local factionLine = Line(tooltip, "TextLeft", count)
	local factionText = factionLine:GetText()
	if not issecret(factionText) then
		return count -- a readable text is handled by EditPlayerLines
	end
	local factionGroup = UnitFactionGroup("mouseover")
	if not factionGroup or issecret(factionGroup) then
		-- the opposite of the own faction for an enemy
		local mine, enemy = UnitFactionGroup("player"), UnitIsEnemy("player", "mouseover")
		if not mine or issecret(mine) or issecret(enemy) then
			return count
		end
		factionGroup = enemy and (mine == "Horde" and "Alliance" or "Horde") or mine
	end
	if db.unitClassMode == 1 then
		local right = Line(tooltip, "TextRight", count - 1) -- the class line
		right:SetFormattedText("%s", factionText)
		right:Show()
		pcall(right.SetTextColor, right, factionLine:GetTextColor())
	else
		local file = FACTION_ICON_FILES[factionGroup]
		if not file then
			return count
		end
		local size = db.factionIconSize
		st.crest = st.crest or tooltip:CreateTexture(nil, "OVERLAY")
		st.crestLine, st.crestFile, st.crestSize = count - 1, file, size
		st.crestIndent = math.max(size + db.factionIconOffset + 2, 0)
	end
	factionLine:SetText("")
	return count - 1
end

-- A header of two lines gets an empty third line right after it, whatever the two lines are: the client then
-- lays the lines out by itself and the portrait has the height of three lines. The line is added at the end and
-- moved up (the lines below shift down); the text of the lines is readable here (the lines were snapshotted).
local function PadHeader(tooltip, st, count)
	if count ~= 2 or tooltip:NumLines() < 2 then
		return count
	end
	tooltip:AddLine(" ")
	local added = tooltip:NumLines()
	if st.moved then
		st.moved.states[added], st.moved.from = BLANK_LINE, added -- restored as an empty line
	end
	if added > 3 and not MoveLine(tooltip, added, 3) then
		return count
	end
	return 3
end

local function EditUnitLines(tooltip, st, count, tooltipData)
	local unit, _, classFile = PlayerClass(tooltip, tooltipData)
	if not unit and not classFile then
		_, classFile = ClassFromText(tooltip, count) -- the unit is hidden and there is no GUID: the class line
	end
	local isPlayer = classFile ~= nil -- a player, also when the unit itself is hidden
	if not (unit or isPlayer) then
		MoveSecretPvp(tooltip, count, tooltipData)
		return HideSecretFaction(tooltip, st, count)
	end
	if not SnapshotLines(tooltip, st) then
		return count
	end
	-- with "name only" the lines below the name are not rearranged (the faction, class and level lines stay
	-- as they are); the PvP text still goes next to the name of a player and the name keeps the class color
	local nameOnly = db.unitNameOnly
	if isPlayer then
		local newCount
		if not nameOnly then
			newCount = EditPlayerLines(tooltip, st, count, tooltipData)
		end
		MovePlayerPvp(tooltip, count)
		ColorPlayerName(tooltip, classFile)
		return PadHeader(tooltip, st, newCount or count)
	end
	if nameOnly then
		return count
	end
	local newCount = EditNpcLines(tooltip, count)
	if newCount == count then
		-- no faction line took the "PvP" text (a pet): it goes next to the name as with players
		MovePlayerPvp(tooltip, count)
	end
	return PadHeader(tooltip, st, newCount)
end

-- Everything is secret (a battleground match): the text of the lines can't be read, their types can. The lines
-- of a player are counted by what stays readable of the unit; for other units the plain lines after the name
-- (owner and level of a pet) make the header, as many as the kind allows; a line of another type ends it.
local function SecretUnitHeaderCount(tooltip, tooltipData, numLines)
	local _, instanceType = IsInInstance()
	-- A player: whether it is one and whether it has a guild stays readable through "mouseover", so the lines are
	-- known: name, guild, level, class, faction ("PvP" and the rest stay below).
	local isPlayer = UnitIsPlayer("mouseover")
	if not issecret(isPlayer) and isPlayer then
		-- in a battleground the last line of a player is always "PvP": everything before it is the header
		if instanceType == "pvp" then
			return math.max(numLines - 1, 1)
		end
		local guild = GetGuildInfo("mouseover")
		if not issecret(guild) then
			return math.min(1 + (guild and 1 or 0) + 3, numLines)
		end
	end
	-- a pet in a battleground: the last line is "PvP" as well
	if instanceType == "pvp" and HasOwnerLine(tooltipData, numLines) then
		return math.max(numLines - 1, 1)
	end
	local lineTypes = Enum.TooltipDataLineType
	local count = 1
	for i = 2, math.min(kinds.unit.maxHeader, numLines) do
		local info = DataLine(tooltipData, i)
		local lineType = info and info.type
		if lineType ~= nil and lineType ~= lineTypes.None and lineType ~= lineTypes.UnitOwner then
			break
		end
		count = i
	end
	return count
end

kinds.unit = {
	maxHeader = 4,
	noBorder = true, -- a portrait has no border: it is never cut
	nameOnlyKey = "unitNameOnly",
	minLines = 3, -- the portrait is as big as for a header of three lines
	bodyGap = 4, -- the body starts 4 px lower than the header block (the portrait keeps its size)
	padTop = true, -- the last header line keeps its text at the top: the extra height goes below the header
	edit = EditUnitLines,
	headerCount = function(tooltip, tooltipData)
		local numLines = tooltip:NumLines()
		if debugMode then
			local unit = TooltipUtil and TooltipUtil.GetDisplayedUnit and select(2, TooltipUtil.GetDisplayedUnit(tooltip))
			local exists = unit and not issecret(unit) and UnitExists(unit)
			local level = exists and UnitLevel(unit)
			local race = exists and UnitRace(unit)
			Print(("level line search: unit=%s exists=%s level=%s race=%s lines=%d"):format(
				not unit and "nil" or issecret(unit) and "<secret>" or tostring(unit), tostring(exists),
				issecret(level) and "<secret>" or tostring(level), issecret(race) and "<secret>" or tostring(race), numLines))
		end
		for i = 2, math.min(4, numLines) do
			local found = IsUnitLevelLine(tooltip, i, tooltipData)
			if debugMode then
				local text = LineValues(tooltip, tooltipData, i)
				Print(("level line search: line %d %s [%s]"):format(i, found and "FOUND" or "no",
					text and (text:gsub("|", "||")) or "<secret>"))
			end
			if found then
				return (i < numLines and IsCreatureTypeLine(tooltip, i + 1)) and i + 1 or i
			end
		end
		if LineValues(tooltip, tooltipData, 2) == nil then
			return SecretUnitHeaderCount(tooltip, tooltipData, numLines)
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
	{ "currency", TTI_KIND_CURRENCY, TTI_KIND_CURRENCY_DESC },
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

function ns.IsSkipBgEnemies()
	return db.skipBgEnemies
end

function ns.SetSkipBgEnemies(value)
	db.skipBgEnemies = value and true or false
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
ns.INLINE_SIZE_MIN, ns.INLINE_SIZE_MAX = INLINE_SIZE_MIN, INLINE_SIZE_MAX
ns.INLINE_OFFSET_MIN, ns.INLINE_OFFSET_MAX = INLINE_OFFSET_MIN, INLINE_OFFSET_MAX

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

-- sizes and shifts of the class and faction icons inside the level line
for _, icon in ipairs({ "class", "faction" }) do
	local Name = icon:gsub("^%l", string.upper)
	local sizeKey, offsetKey = icon .. "IconSize", icon .. "IconOffset"
	ns["Get" .. Name .. "IconSize"] = function()
		return db[sizeKey]
	end
	ns["Set" .. Name .. "IconSize"] = function(value)
		db[sizeKey] = Clamped(value, INLINE_SIZE_MIN, INLINE_SIZE_MAX)
		wipe(layoutCache)
	end
	ns["Get" .. Name .. "IconOffset"] = function()
		return db[offsetKey]
	end
	ns["Set" .. Name .. "IconOffset"] = function(value)
		db[offsetKey] = Clamped(value, INLINE_OFFSET_MIN, INLINE_OFFSET_MAX)
		wipe(layoutCache)
	end
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
		debugCycle = debugCycle + 1
		if st then
			st.cycle = debugCycle
		end
		Print(("======== #%d %s t=%.2f ========"):format(debugCycle, kindName, GetTime()))
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
	st.inlineIcons, st.crestLine = nil, nil
	local count = GetHeaderCount(tooltip, tooltipData, kind)
	if kind.isPromoted and count < MaxHeader(kind) then
		count = PromoteLine(tooltip, tooltipData, st, kind, count)
	end
	if kind.edit then
		count = kind.edit(tooltip, st, count, tooltipData) or count -- a kind may move lines into the header
	end

	st.orig = {}
	for i = 1, count do
		local text = Line(tooltip, "TextLeft", i):GetText()
		if text == nil then
			Restore(tooltip, st)
			return
		end
		st.orig[i] = text -- may be secret (combat): it is only passed on to SetFormattedText / SetText
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
	-- a secret header line can't get the pad texture (see SpaceWidth): the icon is as high as the header block
	for i = 1, count do
		if issecret(st.orig[i]) then
			size, padH = Clamp(math.max(natural, MIN_ICON_SIZE)), 0
			break
		end
	end
	st.natural, st.pass, st.fitPasses = natural, 0, 0
	st.applied = nil
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

local function CurrencyTexture(currencyID)
	if currencyID and not issecret(currencyID) and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
		local info = C_CurrencyInfo.GetCurrencyInfo(currencyID)
		return info and info.iconFileID
	end
end

local function OnCurrency(tooltip, tooltipData)
	ShowIcon(tooltip, tooltipData, "currency", CurrencyTexture(tooltipData and tooltipData.id))
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
local lastPortraitInfo

-- /tti debug: when the texture of the portrait changes, with the time
local function DebugPortraitTexture(st, label)
	if debugMode then
		local key = tostring(st.icon:GetTexture())
		if key ~= st.lastPortraitTexture then
			st.lastPortraitTexture = key
			Print(("portrait texture [%s]: %s, try %s, t=%.2f"):format(label, key, tostring(st.portraitTries), GetTime()))
		end
	end
end

-- An enemy player or pet in a battleground (what the "skip" option leaves untouched): readable through the plain
-- unit calls, whatever is secret about the unit; a pet has the line of its owner in the data.
local function IsBattlegroundEnemy(tooltip, unit, tooltipData)
	local _, instanceType = IsInInstance()
	if instanceType ~= "pvp" then
		return false
	end
	local isEnemy = UnitIsEnemy("player", unit)
	if issecret(isEnemy) or not isEnemy then
		return false
	end
	local isPlayer = UnitIsPlayer(unit)
	if not issecret(isPlayer) and isPlayer then
		return true
	end
	return HasOwnerLine(tooltipData, tooltip:NumLines())
end

local function OnUnit(tooltip, tooltipData)
	local unit = TooltipUtil and TooltipUtil.GetDisplayedUnit and select(2, TooltipUtil.GetDisplayedUnit(tooltip))
	if unit and issecret(unit) then
		-- the identity of an enemy player is hidden in a battleground match: SetPortraitTexture takes a secret token
		-- only from untainted code, a plain "mouseover" works (the tooltip is shown for the unit under the mouse)
		unit = "mouseover"
	end
	local exists = unit and UnitExists(unit)
	if not unit or (not issecret(exists) and not exists) then
		if debugMode then
			Print(("unit tooltip skipped: unit=%s"):format(not unit and "nil" or tostring(unit) .. " (does not exist)"))
		end
		return
	end
	if db.skipBgEnemies and IsBattlegroundEnemy(tooltip, unit, tooltipData) then
		if debugMode then
			Print("unit tooltip skipped: an enemy player or pet in a battleground (option)")
		end
		return
	end
	ShowIcon(tooltip, tooltipData, "unit", function(icon)
		-- the third argument switches the round mask off: the portrait is square unless the option is on
		SetPortraitTexture(icon, unit, not db.roundPortraits)
		states[tooltip].portraitUnit, states[tooltip].portraitTries = unit, 0
		DebugPortraitTexture(states[tooltip], "build")
		if debugMode then
			local guid, visible = UnitGUID(unit), UnitIsVisible(unit)
			local identity = C_Secrets and C_Secrets.ShouldUnitIdentityBeSecret and C_Secrets.ShouldUnitIdentityBeSecret(unit)
			local info = ("portrait: unit=%s guid=%s visible=%s identitySecret=%s"):format(tostring(unit),
				issecret(guid) and "<secret>" or tostring(guid), issecret(visible) and "<secret>" or tostring(visible),
				tostring(identity))
			if info ~= lastPortraitInfo then -- once per change, not per rebuild
				lastPortraitInfo = info
				Print(info)
			end
		end
	end)
end

-- The data of a portrait may arrive after the tooltip is shown (an enemy player far away): it is requested
-- again when the client reports an update, as the unit frames do, and a few times while the tooltip stays
-- (a tooltip that is not rebuilt would keep an empty portrait).
local PORTRAIT_RETRIES, PORTRAIT_RETRY_DELAY = 20, 0.05

-- Asks for the portrait again, but only while the unit exists: after the mouse has left, the tooltip fades
-- out and an empty "mouseover" would clear the portrait at once.
local function RequestPortrait(st)
	local unit = st.portraitUnit
	if not unit then
		return
	end
	local exists = UnitExists(unit)
	if not issecret(exists) and exists then
		SetPortraitTexture(st.icon, unit, not db.roundPortraits)
		DebugPortraitTexture(st, "retry")
	end
end

local portraitFrame = CreateFrame("Frame")
local portraitElapsed = 0
portraitFrame:SetScript("OnUpdate", function(_, elapsed)
	portraitElapsed = portraitElapsed + elapsed
	if portraitElapsed < PORTRAIT_RETRY_DELAY then
		return
	end
	portraitElapsed = 0
	for tooltip, st in pairs(states) do
		local unit = st.portraitUnit
		if unit and (st.portraitTries or PORTRAIT_RETRIES) < PORTRAIT_RETRIES and st.active and st.kind == "unit"
			and tooltip:IsShown() then
			st.portraitTries = st.portraitTries + 1
			RequestPortrait(st)
		end
	end
end)
portraitFrame:RegisterEvent("UNIT_PORTRAIT_UPDATE")
portraitFrame:RegisterEvent("UNIT_MODEL_CHANGED")
portraitFrame:SetScript("OnEvent", function(_, _, changed)
	if not changed or issecret(changed) then
		return
	end
	for tooltip, st in pairs(states) do
		local unit = st.portraitUnit
		-- in a battleground the result of the comparison can be secret: it is not tested then
		if unit and st.active and st.kind == "unit" and tooltip:IsShown() then
			local same = UnitIsUnit(unit, changed)
			if not issecret(same) and same then
				RequestPortrait(st)
			end
		end
	end
end)

-- The portrait of a unit is also requested whenever the tooltip is shown: a request made while the tooltip
-- data is processed gave no portrait of an enemy player in a battleground.
local function RefreshPortraitOnShow(tooltip)
	local st = states[tooltip]
	if st and st.active and st.kind == "unit" then
		RequestPortrait(st)
	end
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
		if st.crest then
			st.crest:Hide()
		end
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
	Unit = OnUnit, Mount = OnMount, Toy = OnToy, Currency = OnCurrency,
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
	hooksecurefunc(GameTooltip, "Show", RefreshPortraitOnShow)
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
	for _, icon in ipairs({ "class", "faction" }) do
		db[icon .. "IconSize"] = Clamped(db[icon .. "IconSize"], INLINE_SIZE_MIN, INLINE_SIZE_MAX)
		db[icon .. "IconOffset"] = Clamped(db[icon .. "IconOffset"], INLINE_OFFSET_MIN, INLINE_OFFSET_MAX)
	end
	if type(db.enabled) ~= "boolean" then
		db.enabled = true
	end
	if type(db.unitClassColor) ~= "boolean" then
		db.unitClassColor = true
	end
	if type(db.iconBorder) ~= "boolean" then
		db.iconBorder = false
	end
	if type(db.skipBgEnemies) ~= "boolean" then
		db.skipBgEnemies = false
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
