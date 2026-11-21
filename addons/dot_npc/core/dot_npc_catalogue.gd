@tool
class_name GSNpcCatalogue
extends Resource

## Every NPC kind a server offers, and the file an operator edits.
## Plain JSON for the person with a text editor; one bad entry does not condemn the file;
## an exact id match wins a search. Same shape as GSPropCatalogue and GSMapCatalogue.

const CHANNEL := "npc.catalogue"

const FORMAT_VERSION := 1

@export var npcs: Array[GSNpcDef] = []

@export var meta: Dictionary = {}

var _by_id: Dictionary = {}


func add(npc: GSNpcDef) -> GSResult:
	if npc == null:
		return GSResult.fail(GSError.CODE_INVALID, "No NPC to add.")

	var valid := npc.validate()

	if not valid.ok:
		return valid

	if _by_id.size() != npcs.size():
		_reindex()

	if _by_id.has(npc.id):
		var existing: GSNpcDef = _by_id[npc.id]
		npcs[npcs.find(existing)] = npc
		_by_id[npc.id] = npc
		return GSResult.success(npc)

	npcs.append(npc)
	_by_id[npc.id] = npc

	return GSResult.success(npc)


## Download every pack this catalogue's NPCs live in. Non-fatal: a failed pack leaves that NPC unspawnable.
## At load, not on demand: a spawn request is a player's and must not make this machine fetch,
## and it keeps the spawn path synchronous. See [method GSContent.ensure_all].
func ensure_content() -> GSResult:
	if _by_id.size() != npcs.size():
		_reindex()

	var ids := PackedStringArray()

	for entry in npcs:
		if entry != null and String(entry.content_id) != "":
			ids.append(String(entry.content_id))

	return await GSContent.ensure_all(ids)


func get_npc(id: StringName) -> GSNpcDef:
	if _by_id.size() != npcs.size():
		_reindex()

	var found: Variant = _by_id.get(id)
	return found if found is GSNpcDef else null


func has(id: StringName) -> bool:
	return get_npc(id) != null


func size() -> int:
	return npcs.size()


func remove(id: StringName) -> bool:
	_reindex()

	if not _by_id.has(id):
		return false

	npcs.erase(_by_id[id])
	_by_id.erase(id)

	return true


func _reindex() -> void:
	_by_id.clear()

	for npc in npcs:
		_by_id[npc.id] = npc


## Every category, in alphabetical order. For a spawn menu's tabs.
func categories() -> PackedStringArray:
	var seen := {}

	for npc in npcs:
		if npc.enabled:
			seen[String(npc.category)] = true

	var out := PackedStringArray(seen.keys())
	out.sort()

	return out


func in_category(category: StringName) -> Array[GSNpcDef]:
	var out: Array[GSNpcDef] = []

	for npc in npcs:
		if npc.enabled and npc.category == category:
			out.append(npc)

	return out


func in_faction(faction: StringName) -> Array[GSNpcDef]:
	var out: Array[GSNpcDef] = []

	for npc in npcs:
		if npc.enabled and npc.faction == faction:
			out.append(npc)

	return out


## NPCs whose id or name contains [param text]. An exact id wins outright.
func search(text: String, limit: int = 30) -> Array[GSNpcDef]:
	var needle := text.strip_edges().to_lower()
	var out: Array[GSNpcDef] = []

	if needle == "":
		return out

	var exact := get_npc(StringName(needle))

	if exact != null:
		out.append(exact)
		return out

	for npc in npcs:
		if out.size() >= limit:
			break
		if String(npc.id).to_lower().contains(needle) \
				or npc.display_name.to_lower().contains(needle):
			out.append(npc)

	return out


func to_dictionary() -> Dictionary:
	var entries: Array = []

	for npc in npcs:
		entries.append(npc.to_dictionary())

	return {
		"format": FORMAT_VERSION,
		"npcs": entries,
		"meta": meta.duplicate(true),
	}


## Reads a catalogue, keeping the good entries and reporting the bad ones.
## One bad entry must not leave the operator with no NPCs rather than thirty-nine.
static func from_dictionary(data: Dictionary, rejected: PackedStringArray = PackedStringArray()) -> GSNpcCatalogue:
	var cat := GSNpcCatalogue.new()
	var rejected_before := rejected.size()

	var raw: Variant = data.get("npcs", [])

	if raw is Array:
		for entry in (raw as Array):
			if not (entry is Dictionary):
				rejected.append("not an object")
				continue

			var npc := GSNpcDef.from_dictionary(entry as Dictionary)
			var added := cat.add(npc)

			if not added.ok:
				rejected.append(added.error.message if added.error != null else "invalid")

	# Said here whatever the caller does with [param rejected]: the operator who can fix the
	# entry reads this, and a dropped NPC otherwise surfaces as "does not exist" much later.
	if rejected.size() > rejected_before:
		GSLog.warn(CHANNEL, "some npc entries were dropped", {
			"count": rejected.size() - rejected_before,
			"entries": ", ".join(rejected.slice(rejected_before)),
		})

	var meta_value: Variant = data.get("meta", {})
	cat.meta = (
		(meta_value as Dictionary).duplicate(true) if meta_value is Dictionary else {}
	)

	return cat


func describe() -> Dictionary:
	return {
		"npcs": npcs.size(),
		"categories": categories().size(),
	}
