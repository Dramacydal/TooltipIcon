-- Native Blizzard AddOn settings panel (Interface Options): a master switch and a checkbox per tooltip category.
-- Every option is a proxy setting (getter/setter over TooltipIconDB, see TooltipIcon.lua).

local ADDON, ns = ...

local category

function ns.RegisterSettings()
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory("TooltipIcon")
	Settings.RegisterAddOnCategory(category)

	local settings = {}

	local function AddCheckbox(variable, name, tooltip, getValue, setValue, default)
		if default == nil then
			default = true
		end
		local setting = Settings.RegisterProxySetting(category, "TOOLTIPICON_" .. variable, Settings.VarType.Boolean,
			name, default, getValue, setValue)
		settings[#settings + 1] = setting
		return setting, Settings.CreateCheckbox(category, setting, tooltip)
	end

	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(
		(TTI_OPTIONS_VERSION):format(C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?")))

	local enabledSetting = AddCheckbox("ENABLED", TTI_OPTIONS_ENABLE,
		TTI_OPTIONS_ENABLE_DESC,
		ns.IsEnabled,
		function(value)
			ns.SetEnabled(value)
			-- the options below are greyed out by the switch but are not its children: refresh them
			local repair = Settings.RepairDisplay or (SettingsInbound and SettingsInbound.RepairDisplay)
			if repair then
				repair()
			end
		end)

	local function MasterOn()
		return enabledSetting:GetValue()
	end

	local function AddSlider(variable, name, tooltip, default, minValue, maxValue, step, getValue, setValue)
		local setting = Settings.RegisterProxySetting(category, "TOOLTIPICON_" .. variable, Settings.VarType.Number,
			name, default, getValue, setValue)
		settings[#settings + 1] = setting
		local options = Settings.CreateSliderOptions(minValue, maxValue, step)
		options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
			return string.format("%d", value)
		end)
		local initializer = Settings.CreateSlider(category, setting, options, tooltip)
		if initializer and initializer.AddModifyPredicate then
			initializer:AddModifyPredicate(MasterOn)
		end
		return setting, initializer
	end

	AddSlider("ICON_SIZE", TTI_OPTIONS_ICON_SIZE, TTI_OPTIONS_ICON_SIZE_DESC, 32, ns.ICON_SIZE_MIN, ns.ICON_SIZE_MAX, 1,
		ns.GetIconSize, ns.SetIconSize)
	AddSlider("ICON_GAP", TTI_OPTIONS_ICON_GAP, TTI_OPTIONS_ICON_GAP_DESC, 6, ns.ICON_GAP_MIN, ns.ICON_GAP_MAX, 1,
		ns.GetIconGap, ns.SetIconGap)

	local _, borderInitializer = AddCheckbox("ICON_BORDER", TTI_OPTIONS_ICON_BORDER, TTI_OPTIONS_ICON_BORDER_DESC,
		ns.IsIconBorder, ns.SetIconBorder, false)
	borderInitializer:AddModifyPredicate(MasterOn)

	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(TTI_OPTIONS_CATEGORIES))

	-- "name only next to the icon" of a tooltip kind: saved variable and the text of the option
	local function NameOnly(variable, dbKey, desc)
		return { variable = variable, key = dbKey, name = TTI_OPTIONS_SPELL_NAME_ONLY, desc = desc }
	end

	local nameOnlyOptions = {
		spell = NameOnly("SPELL_NAME_ONLY", "spellNameOnly", TTI_OPTIONS_SPELL_NAME_ONLY_DESC),
		item = NameOnly("ITEM_NAME_ONLY", "itemNameOnly", TTI_OPTIONS_ITEM_NAME_ONLY_DESC),
		toy = NameOnly("TOY_NAME_ONLY", "toyNameOnly", TTI_OPTIONS_TOY_NAME_ONLY_DESC),
		companion = NameOnly("COMPANION_NAME_ONLY", "companionNameOnly", TTI_OPTIONS_COMPANION_NAME_ONLY_DESC),
		mount = NameOnly("MOUNT_NAME_ONLY", "mountNameOnly", TTI_OPTIONS_MOUNT_NAME_ONLY_DESC),
		unit = NameOnly("UNIT_NAME_ONLY", "unitNameOnly", TTI_OPTIONS_UNIT_NAME_ONLY_DESC),
	}

	-- The categories stand at the left edge (greyed out while the master switch is off). Only options that depend
	-- on a category are children of it: the panel draws a child indented, in a smaller font.
	for _, kind in ipairs(ns.kindList) do
		local key, name, tooltip = unpack(kind)
		local setting, initializer = AddCheckbox("KIND_" .. key, name, tooltip,
			function() return ns.IsKindEnabled(key) end,
			function(value) ns.SetKindEnabled(key, value) end)
		initializer:AddModifyPredicate(MasterOn)

		-- "name only next to the icon": right under its category, greyed out while the category is off
		local nameOnly = nameOnlyOptions[key]
		if nameOnly then
			local _, nameOnlyInitializer = AddCheckbox(nameOnly.variable, nameOnly.name, nameOnly.desc,
				function() return ns.IsNameOnly(nameOnly.key) end,
				function(value) ns.SetNameOnly(nameOnly.key, value) end, false)
			nameOnlyInitializer:SetParentInitializer(initializer, function()
				return setting:GetValue()
			end)
			nameOnlyInitializer:AddModifyPredicate(MasterOn)
		end

		if key == "unit" then
			-- how the class and the faction of a player are shown: right under "Units", greyed out while it is off
			local classModeSetting = Settings.RegisterProxySetting(category, "TOOLTIPICON_UNIT_CLASS_MODE",
				Settings.VarType.Number, TTI_OPTIONS_CLASS_MODE, 2, ns.GetUnitClassMode, ns.SetUnitClassMode)
			settings[#settings + 1] = classModeSetting
			local classModeInitializer = Settings.CreateDropdown(category, classModeSetting, function()
				local container = Settings.CreateControlTextContainer()
				for _, mode in ipairs(ns.unitClassModes) do
					container:Add(mode[1], mode[2], mode[3])
				end
				return container:GetData()
			end, TTI_OPTIONS_CLASS_MODE_DESC)
			classModeInitializer:SetParentInitializer(initializer, function()
				return setting:GetValue()
			end)
			classModeInitializer:AddModifyPredicate(MasterOn)

			local _, classColorInitializer = AddCheckbox("UNIT_CLASS_COLOR", TTI_OPTIONS_CLASS_COLOR,
				TTI_OPTIONS_CLASS_COLOR_DESC,
				ns.IsUnitClassColor, ns.SetUnitClassColor)
			classColorInitializer:SetParentInitializer(initializer, function()
				return setting:GetValue()
			end)
			classColorInitializer:AddModifyPredicate(MasterOn)

			local _, roundInitializer = AddCheckbox("ROUND_PORTRAITS", TTI_OPTIONS_ROUND_PORTRAITS,
				TTI_OPTIONS_ROUND_PORTRAITS_DESC, ns.IsRoundPortraits, ns.SetRoundPortraits, false)
			roundInitializer:SetParentInitializer(initializer, function()
				return setting:GetValue()
			end)
			roundInitializer:AddModifyPredicate(MasterOn)

			local _, skipInitializer = AddCheckbox("SKIP_BG_ENEMIES", TTI_OPTIONS_SKIP_BG_ENEMIES,
				TTI_OPTIONS_SKIP_BG_ENEMIES_DESC, ns.IsSkipBgEnemies, ns.SetSkipBgEnemies, false)
			skipInitializer:SetParentInitializer(initializer, function()
				return setting:GetValue()
			end)
			skipInitializer:AddModifyPredicate(MasterOn)

			-- sizes and shifts of the icons on the level line
			for _, icon in ipairs({ "FACTION", "CLASS" }) do
				local Name = icon:sub(1, 1) .. icon:sub(2):lower()
				local sizeDefault, offsetDefault = icon == "CLASS" and 16 or 20, -2
				local _, sizeInitializer = AddSlider(icon .. "_ICON_SIZE", _G["TTI_OPTIONS_" .. icon .. "_ICON_SIZE"],
					_G["TTI_OPTIONS_" .. icon .. "_ICON_SIZE_DESC"], sizeDefault, ns.INLINE_SIZE_MIN, ns.INLINE_SIZE_MAX,
					1, ns["Get" .. Name .. "IconSize"], ns["Set" .. Name .. "IconSize"])
				local _, offsetInitializer = AddSlider(icon .. "_ICON_OFFSET", _G["TTI_OPTIONS_" .. icon .. "_ICON_OFFSET"],
					_G["TTI_OPTIONS_" .. icon .. "_ICON_OFFSET_DESC"], offsetDefault, ns.INLINE_OFFSET_MIN,
					ns.INLINE_OFFSET_MAX, 1, ns["Get" .. Name .. "IconOffset"], ns["Set" .. Name .. "IconOffset"])
				for _, child in ipairs({ sizeInitializer, offsetInitializer }) do
					child:SetParentInitializer(initializer, function()
						return setting:GetValue()
					end)
				end
			end
		end
	end

	-- every option back to its default: a button at the end of the list, like the one of TerrainWorldMap
	layout:AddInitializer(CreateSettingsButtonInitializer(TTI_OPTIONS_RESET, TTI_OPTIONS_RESET, function()
		ns.ResetSettings()
	end, TTI_OPTIONS_RESET_DESC, true))

	-- the panel's own "Defaults" button offers to reset every interface setting of the game:
	-- hidden while this category is shown
	if SettingsPanel and SettingsPanel.DisplayCategory then
		hooksecurefunc(SettingsPanel, "DisplayCategory", function(panel, displayed)
			panel:GetSettingsList().Header.DefaultsButton:SetShown(displayed ~= category)
		end)
	end

	-- every setting back to its default (/tti reset)
	function ns.ResetSettings()
		for _, setting in ipairs(settings) do
			setting:SetValueToDefault()
		end
	end
end

function ns.OpenSettings()
	if category then
		Settings.OpenToCategory(category:GetID())
	end
end
