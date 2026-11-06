-- Native Blizzard AddOn settings panel (Interface Options): a master switch and a checkbox per tooltip category.
-- Every option is a proxy setting (getter/setter over TooltipIconDB, see TooltipIcon.lua).

local ADDON, ns = ...

local category

function ns.RegisterSettings()
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory("TooltipIcon")
	Settings.RegisterAddOnCategory(category)

	local settings = {}

	local function AddCheckbox(variable, name, tooltip, getValue, setValue)
		local setting = Settings.RegisterProxySetting(category, "TOOLTIPICON_" .. variable, Settings.VarType.Boolean,
			name, true, getValue, setValue)
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

	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(TTI_OPTIONS_CATEGORIES))

	-- The categories stand at the left edge (greyed out while the master switch is off). Only options that depend
	-- on a category are children of it: the panel draws a child indented, in a smaller font.
	for _, kind in ipairs(ns.kindList) do
		local key, name, tooltip = unpack(kind)
		local setting, initializer = AddCheckbox("KIND_" .. key, name, tooltip,
			function() return ns.IsKindEnabled(key) end,
			function(value) ns.SetKindEnabled(key, value) end)
		initializer:AddModifyPredicate(MasterOn)

		if key == "unit" then
			-- how the class and the faction of a player are shown: right under "Units", greyed out while it is off
			local classModeSetting = Settings.RegisterProxySetting(category, "TOOLTIPICON_UNIT_CLASS_MODE",
				Settings.VarType.Number, TTI_OPTIONS_CLASS_MODE, 1, ns.GetUnitClassMode, ns.SetUnitClassMode)
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
		end
	end

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
