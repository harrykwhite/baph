package baph

import "core:fmt"
import "core:math"
import "core:math/rand"
import "zf4"

ENEMY_LIMIT :: 256
ENEMY_SPAWN_INTERVAL :: 200
ENEMY_SPAWN_DIST_RANGE: [2]f32 : {256.0, 400.0}
ENEMY_DMG_FLASH_TIME :: 5

Enemy :: struct {
	pos:        zf4.Vec_2D,
	vel:        zf4.Vec_2D,
	hp:         int,
	flash_time: int,
	type:       Enemy_Type,
	type_data:  Enemy_Type_Data,
}

Enemy_Type :: enum {
	Melee,
	Ranger,
}

Enemy_Type_Data :: struct #raw_union {
	melee:  Melee_Enemy,
	ranger: Ranger_Enemy,
}

Melee_Enemy :: struct {
	attacking:   bool,
	attack_time: int,
	moving:      bool,
	move_time:   int,
	move_dir:    zf4.Vec_2D,
}

Ranger_Enemy :: struct {
	shoot_time: int,
}

Enemy_Type_Info :: struct {
	ai_func:     Enemy_Type_AI_Func,
	sprite:      Sprite,
	hp_limit:    int,
	flags:       Enemy_Type_Flag_Set,
	contact_dmg: int, // NOTE: We might want to assert correctness on things like this, e.g. if the flag is set this should be greater than zero.
	contact_kb:  f32,
}

Enemy_Type_AI_Func :: proc(enemy_index: int, game: ^Game, solid_colliders: []zf4.Rect) -> bool

Enemy_Type_Flag :: enum {}

Enemy_Type_Flag_Set :: bit_set[Enemy_Type_Flag]

// NOTE: Consider accessor function instead.
ENEMY_TYPE_INFOS :: [len(Enemy_Type)]Enemy_Type_Info {
	Enemy_Type.Melee = {
		ai_func = melee_enemy_ai,
		sprite = Sprite.Melee_Enemy,
		hp_limit = 30,
		contact_dmg = 2,
		contact_kb = 9.0,
	},
	Enemy_Type.Ranger = {
		ai_func = ranger_enemy_ai,
		sprite = Sprite.Ranger_Enemy,
		hp_limit = 10,
		contact_dmg = 1,
		contact_kb = 4.0,
	},
}

proc_enemy_ais :: proc(game: ^Game, solid_colliders: []zf4.Rect) -> bool {
	enemy_type_infos := ENEMY_TYPE_INFOS

	for i in 0 ..< game.enemy_cnt {
		enemy := &game.enemies[i]

		if enemy.flash_time > 0 {
			enemy.flash_time -= 1
		}

		if !enemy_type_infos[enemy.type].ai_func(i, game, solid_colliders) {
			return false
		}
	}

	return true
}

proc_enemy_deaths :: proc(game: ^Game) {
	for i := 0; i < game.enemy_cnt; i += 1 {
		assert(game.enemies[i].hp >= 0)

		if game.enemies[i].hp == 0 {
			apply_camera_shake(&game.cam, 3.0)

			item_drop_cnt := int(rand.float32_range(3.0, 6.0))

			for j in 0 ..< item_drop_cnt {
				drop_vel_len := rand.float32_range(1.5, 4.0)
				drop_vel_dir := (math.TAU / f32(item_drop_cnt)) * f32(j)
				drop_vel := zf4.calc_len_dir(drop_vel_len, drop_vel_dir)

				spawn_item_drop(Item_Type.Rock, 1, game.enemies[i].pos, game, drop_vel)
			}

			game.enemy_cnt -= 1
			game.enemies[i] = game.enemies[game.enemy_cnt]
			i -= 1
		}
	}
}

melee_enemy_ai :: proc(enemy_index: int, game: ^Game, solid_colliders: []zf4.Rect) -> bool {
	assert(enemy_index >= 0 && enemy_index < game.enemy_cnt)
	assert(game != nil)

	enemy := &game.enemies[enemy_index]
	enemy_melee := &enemy.type_data.melee

	assert(enemy.type == Enemy_Type.Melee)

	if game.player.killed && enemy_melee.attacking {
		enemy_melee.attacking = false
		enemy_melee.moving = false
		enemy_melee.move_time = 0
	}

	MOVE_SPD: f32 = 1.0

	vel_targ: zf4.Vec_2D

	if enemy_melee.attacking {
		player_dist := zf4.calc_dist(enemy.pos, game.player.pos)
		player_dir := zf4.calc_normal_or_zero(game.player.pos - enemy.pos)

		if player_dist > 40.0 {
			vel_targ = player_dir * MOVE_SPD
		}
	} else {
		if enemy_melee.move_time > 0 {
			enemy_melee.move_time -= 1
		} else {
			enemy_melee.moving = !enemy_melee.moving
			enemy_melee.move_time = 60
			enemy_melee.move_dir = zf4.calc_len_dir(1.0, rand.float32() * math.TAU)
		}

		vel_targ = enemy_melee.moving ? enemy_melee.move_dir * MOVE_SPD : {}

		enemy_melee.attack_time = 0
	}

	enemy.vel += (vel_targ - enemy.vel) * 0.2

	proc_solid_collisions(
		&enemy.vel,
		gen_enemy_movement_collider(enemy.type, enemy.pos),
		solid_colliders,
	)

	enemy.pos += enemy.vel

	if enemy_melee.attacking {
		if enemy_melee.attack_time < 60 {
			enemy_melee.attack_time += 1
		} else {
			attack_dir := zf4.calc_normal_or_zero(game.player.pos - enemy.pos)

			ATTACK_HITBOX_OFFS_DIST :: 32.0
			ATTACK_HITBOX_SIZE :: 32.0
			ATTACK_KNOCKBACK :: 6.0

			if !spawn_hitmask_quad(
				enemy.pos + (attack_dir * ATTACK_HITBOX_OFFS_DIST),
				{ATTACK_HITBOX_SIZE, ATTACK_HITBOX_SIZE},
				{dmg = 9, kb = attack_dir * ATTACK_KNOCKBACK},
				{Damage_Flag.Damage_Player},
				game,
			) {
				return false
			}

			enemy.type_data.melee.attack_time = 0
		}
	}

	return true
}

ranger_enemy_ai :: proc(enemy_index: int, game: ^Game, solid_colliders: []zf4.Rect) -> bool {
	assert(enemy_index >= 0 && enemy_index < game.enemy_cnt)
	assert(game != nil)

	enemy := &game.enemies[enemy_index]

	assert(enemy.type == Enemy_Type.Ranger)

	enemy.vel *= 0.8

	proc_solid_collisions(
		&enemy.vel,
		gen_enemy_movement_collider(enemy.type, enemy.pos),
		solid_colliders,
	)

	enemy.pos += enemy.vel

	if !game.player.killed {
		if enemy.type_data.ranger.shoot_time < 60 {
			enemy.type_data.ranger.shoot_time += 1
		} else {
			player_dir := zf4.calc_dir(game.player.pos - enemy.pos)

			if !spawn_projectile(
				enemy.pos,
				8.0,
				player_dir,
				5,
				{Damage_Flag.Damage_Player},
				game,
			) {
				fmt.eprint("Failed to spawn projectile!") // NOTE: Should this be integrated into the function?
			}

			enemy.type_data.ranger.shoot_time = 0
		}
	}

	return true
}

append_enemy_render_tasks :: proc(tasks: ^[dynamic]Render_Task, enemies: []Enemy) -> bool {
	sprite_src_rects := SPRITE_SRC_RECTS
	enemy_type_infos := ENEMY_TYPE_INFOS

	for &enemy in enemies {
		sprite := enemy_type_infos[enemy.type].sprite

		task := Render_Task {
			pos        = enemy.pos,
			origin     = {0.5, 0.5},
			scale      = {1.0, 1.0},
			rot        = 0.0,
			alpha      = 1.0,
			sprite     = sprite,
			flash_time = enemy.flash_time,
			sort_depth = enemy.pos.y + (f32(sprite_src_rects[sprite].height) / 2.0),
		}

		n, err := append(tasks, task)

		if err != nil {
			return false
		}
	}

	return true
}

render_enemy_hp_bars :: proc(
	rendering_context: ^zf4.Rendering_Context,
	enemies: []Enemy,
	cam: ^Camera,
	textures: ^zf4.Textures,
) {
	sprite_src_rects := SPRITE_SRC_RECTS
	type_infos := ENEMY_TYPE_INFOS

	for &enemy in enemies {
		if enemy.hp == type_infos[enemy.type].hp_limit {
			continue
		}

		enemy_size := zf4.calc_rect_i_size(sprite_src_rects[type_infos[enemy.type].sprite])

		hp_bar_pos := camera_to_display_pos(
			enemy.pos + {0.0, (f32(enemy_size.y) / 2.0) + 8.0},
			cam,
			rendering_context.display_size,
		)
		hp_bar_size := zf4.Vec_2D{f32(enemy_size.x) - 2.0, 2.0} * CAMERA_SCALE
		hp_bar_rect := zf4.Rect {
			hp_bar_pos.x - (hp_bar_size.x / 2.0),
			hp_bar_pos.y - (hp_bar_size.y / 2.0),
			hp_bar_size.x,
			hp_bar_size.y,
		}

		zf4.render_bar_hor(
			rendering_context,
			hp_bar_rect,
			f32(enemy.hp) / f32(type_infos[enemy.type].hp_limit),
			zf4.WHITE.rgb,
			zf4.BLACK.rgb,
		)
	}
}

spawn_enemy :: proc(
	type: Enemy_Type,
	pos: zf4.Vec_2D,
	game: ^Game,
	solid_colliders: []zf4.Rect,
) -> bool {
	type_infos := ENEMY_TYPE_INFOS

	if game.enemy_cnt == ENEMY_LIMIT {
		fmt.eprintln("Failed to spawn enemy due to insufficient space!")
		return false
	}

	game.enemies[game.enemy_cnt] = {
		pos  = pos,
		hp   = type_infos[type].hp_limit,
		type = type,
	}

	game.enemy_cnt += 1

	return true
}

proc_enemy_spawning :: proc(game: ^Game, solid_colliders: []zf4.Rect) {
	if game.enemy_spawn_time < ENEMY_SPAWN_INTERVAL {
		game.enemy_spawn_time += 1
	} else {
		SPAWN_TRIAL_LIMIT :: 1000

		spawned := false

		for t in 0 ..< SPAWN_TRIAL_LIMIT {
			spawn_offs_dir := rand.float32_range(0.0, math.PI * 2.0)
			spawn_offs_dist := rand.float32_range(
				ENEMY_SPAWN_DIST_RANGE[0],
				ENEMY_SPAWN_DIST_RANGE[1],
			)
			spawn_pos := game.cam.pos_no_offs + zf4.calc_len_dir(spawn_offs_dist, spawn_offs_dir)

			enemy_type := rand.float32() < 0.7 ? Enemy_Type.Melee : Enemy_Type.Ranger

			if !is_valid_enemy_spawn_pos(spawn_pos, enemy_type, game, solid_colliders) {
				continue
			}

			spawned = spawn_enemy(enemy_type, spawn_pos, game, solid_colliders)

			break
		}

		if !spawned {
			fmt.eprintfln("Failed to spawn enemy after %d trials.", SPAWN_TRIAL_LIMIT)
		}

		game.enemy_spawn_time = 0
	}
}

is_valid_enemy_spawn_pos :: proc(
	pos: zf4.Vec_2D,
	type: Enemy_Type,
	game: ^Game,
	solid_colliders: []zf4.Rect,
) -> bool {
	movement_collider := gen_enemy_movement_collider(type, pos)

	for &building in game.buildings {
		interior_collider := gen_building_interior_collider(&building)

		if zf4.do_rects_inters(movement_collider, interior_collider) {
			return false
		}
	}

	for sc in solid_colliders {
		if zf4.do_rects_inters(movement_collider, sc) {
			return false
		}
	}

	return true
}

damage_enemy :: proc(enemy_index: int, game: ^Game, dmg_info: Damage_Info) {
	assert(enemy_index >= 0 && enemy_index < game.enemy_cnt)
	assert(dmg_info.dmg > 0)

	enemy := &game.enemies[enemy_index]
	enemy.vel += dmg_info.kb
	enemy.hp = max(enemy.hp - dmg_info.dmg, 0)
	enemy.flash_time = ENEMY_DMG_FLASH_TIME

	if enemy.type == Enemy_Type.Melee {
		enemy.type_data.melee.attacking = true
	}

	spawn_damage_text(game, dmg_info.dmg, enemy.pos)

	apply_camera_shake(&game.cam, 0.75)
}

gen_enemy_movement_collider :: proc(type: Enemy_Type, enemy_pos: zf4.Vec_2D) -> zf4.Rect {
	type_infos := ENEMY_TYPE_INFOS
	spr_collider := gen_collider_rect_from_sprite(type_infos[type].sprite, enemy_pos)

	mv_collider := spr_collider
	mv_collider.height = spr_collider.height / 4.0
	mv_collider.y = zf4.calc_rect_bottom(spr_collider) - mv_collider.height
	return mv_collider
}

gen_enemy_damage_collider :: proc(type: Enemy_Type, enemy_pos: zf4.Vec_2D) -> zf4.Rect {
	type_infos := ENEMY_TYPE_INFOS
	return gen_collider_rect_from_sprite(type_infos[type].sprite, enemy_pos)
}

