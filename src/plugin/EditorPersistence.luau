--!strict
-- EditorPersistence — 过场编辑草稿(Plugin GetSetting/SetSetting)。

local EditorPersistence = {}

export type PluginLike = {
	GetSetting: (self: PluginLike, key: string) -> any,
	SetSetting: (self: PluginLike, key: string, value: any) -> (),
}

local DRAFT_KEY = "AnimaEditorDraft_v1"

function EditorPersistence.saveDraft(plugin: PluginLike, serialized: string)
	plugin:SetSetting(DRAFT_KEY, serialized)
end

function EditorPersistence.clearDraft(plugin: PluginLike)
	plugin:SetSetting(DRAFT_KEY, nil)
end

function EditorPersistence.readDraft(plugin: PluginLike): string?
	local raw = plugin:GetSetting(DRAFT_KEY)
	if type(raw) == "string" and raw ~= "" then
		return raw
	end
	return nil
end

return EditorPersistence
