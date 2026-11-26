class_name GSNpcGore
extends RefCounted

## One process-wide dial (`gore_level`) plus the gib cap for how much dismemberment is shown and allowed.
## Static on purpose: gore is presentation policy and a listen server and its client share a process.
## Level 0 makes every limb call a no-op. Read by [GSNpcLimbs] (server) and [GSNpcGibs] (drawn).

const OFF := 0
## Limbs come off as clean stumps: no flying gib, no spray, no drip.
const STUMPS := 1
## Limbs fly off with a spray and a drip (the default).
const GIBS := 2
## Limbs give way sooner and the spray is heavier.
const SPLATTER := 3

## Largest value of [member level].
const MAX_LEVEL := 3
## The most flying limbs alive at once on this machine; the oldest is recycled for the next.
const DEFAULT_MAX_GIBS := 24
const DEFAULT_MAX_WOUNDS := 48

## 0 to 3, see the constants. Clamped on write.
static var level: int = GIBS:
	set(v):
		level = clampi(v, OFF, MAX_LEVEL)
## The most a player on this machine asks to see (their own setting; a game maps its `gore` toggle onto it).
## It only trims what is drawn: whether a limb comes off is the server's `level`, which reaches a client as the
## replicated limb mask, so no gore level crosses the wire and a client can never show more than the server allowed.
static var view_cap: int = MAX_LEVEL:
	set(v):
		view_cap = clampi(v, OFF, MAX_LEVEL)
## Wound marks on bodies and blood pools on the floor allowed at once on this machine (client-only, drawn); 0 is unlimited.
static var max_wounds: int = DEFAULT_MAX_WOUNDS:
	set(v):
		max_wounds = maxi(v, 0)
## Live gib bodies allowed. 0 is unlimited (set [member level] to 1 for stumps without gibs).
static var max_gibs: int = DEFAULT_MAX_GIBS:
	set(v):
		max_gibs = maxi(v, 0)


## Whether any limb can come off.
static func dismember_enabled() -> bool:
	return level >= STUMPS


## What this machine draws: the rule level, trimmed by the player's [member view_cap].
static func drawn_level() -> int:
	return mini(level, view_cap)


## Whether a severed limb is thrown as a body.
static func gibs_enabled() -> bool:
	return drawn_level() >= GIBS 


## Whether the cut sprays and drips blood.
static func spray_enabled() -> bool:
	return drawn_level() >= GIBS


## Whether wound marks and blood pools are drawn.
static func wounds_enabled() -> bool:
	return drawn_level() >= GIBS 


## What dealt the blow that is about to take a limb off. A game sets [member hit_style] just before the
## synchronous [method GSNpcLimbs.hit_limb] call and the cut reads it; it shapes only what is drawn.
const STYLE_GENERIC := 0
## Narrow jet along the shot, a fast clean gib.
const STYLE_RIFLE := 1
## Wide, heavy spray and a hard throw.
const STYLE_SHOTGUN := 2
## Short and wet: a slow gib and a lot of drip.
const STYLE_MELEE := 3
## Radial and upward: the limb is thrown high and spins.
const STYLE_BLAST := 4

static var hit_style: int = STYLE_GENERIC


## Per-style shaping for the cut: `throw` (gib speed scale), `lift` (upward speed), `spin`, `spread` (spray cone
## degrees), `amount` (spray count scale), `speed` (droplet speed scale).
static func style_params(style: int) -> Dictionary:
	match style:
		STYLE_RIFLE:
			return {"throw": 1.0, "lift": 1.2, "spin": 3.0, "spread": 18.0, "amount": 0.8, "speed": 1.4}
		STYLE_SHOTGUN:
			return {"throw": 1.8, "lift": 2.2, "spin": 6.0, "spread": 50.0, "amount": 1.8, "speed": 1.2}
		STYLE_MELEE:
			return {"throw": 0.45, "lift": 1.0, "spin": 2.0, "spread": 35.0, "amount": 1.0, "speed": 0.6}
		STYLE_BLAST:
			return {"throw": 1.4, "lift": 5.0, "spin": 9.0, "spread": 80.0, "amount": 1.6, "speed": 1.0}
	return {"throw": 1.0, "lift": 2.5, "spin": 4.0, "spread": 55.0, "amount": 1.0, "speed": 1.0}


## Particle count multiplier for blood at the current level.
static func spray_scale() -> float:
	return 2.0 if drawn_level() >= SPLATTER else 1.0


## Multiplier on the health a limb has: at the top level a limb gives way to less.
static func health_scale() -> float:
	return 0.6 if level >= SPLATTER else 1.0


## Back to the defaults (a suite, or a game unloading).
static func reset() -> void:
	level = GIBS
	view_cap = MAX_LEVEL
	max_gibs = DEFAULT_MAX_GIBS
	max_wounds = DEFAULT_MAX_WOUNDS
